import Darwin
import Foundation

public enum EngineFailure: Error, LocalizedError, Sendable {
    case unavailable(String)
    case cancelled
    case superseded
    case timedOut
    case memoryLimit(peakBytes: UInt64)
    case memoryPressure(peakBytes: UInt64)
    case crashed(signal: Int32, log: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .cancelled: "Preview canceled."
        case .superseded: "A newer preview replaced this evaluation."
        case .timedOut: "The preview exceeded the evaluation time limit."
        case .memoryLimit(let peakBytes): "The preview exceeded its memory budget at \(Self.megabytes(peakBytes)) MB."
        case .memoryPressure(let peakBytes): "macOS reported critical memory pressure. The worker used \(Self.megabytes(peakBytes)) MB."
        case .crashed(let signal, _): "The OpenSCAD worker ended unexpectedly (signal \(signal))."
        }
    }

    private static func megabytes(_ bytes: UInt64) -> UInt64 { bytes / (1024 * 1024) }
}

public struct EngineWorkerLimits: Sendable {
    public var timeout: Duration
    public var memoryBytes: UInt64

    public init(timeout: Duration = .seconds(20), memoryBytes: UInt64 = 768 * 1024 * 1024) {
        self.timeout = timeout
        self.memoryBytes = memoryBytes
    }
}

struct WorkerReport: Sendable {
    let exitCode: Int32
    let log: String
    let peakBytes: UInt64
    let elapsed: Duration
}

enum WorkerStop: Sendable {
    case cancelled, superseded, timedOut, memoryLimit, memoryPressure

    func failure(peak: UInt64) -> EngineFailure {
        switch self {
        case .cancelled: .cancelled
        case .superseded: .superseded
        case .timedOut: .timedOut
        case .memoryLimit: .memoryLimit(peakBytes: peak)
        case .memoryPressure: .memoryPressure(peakBytes: peak)
        }
    }
}

private enum WorkerLog {
    static func read(_ handle: FileHandle) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let capacity = 64 * 1024
                var bytes = Data()
                while let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
                    bytes.append(contentsOf: chunk.prefix(capacity - bytes.count))
                }
                continuation.resume(returning: String(decoding: bytes, as: UTF8.self))
            }
        }
    }
}

actor WorkerProcess {
    private let process = Process()
    private var live = false
    private var stopReason: WorkerStop?
    private var waiter: CheckedContinuation<Exit, Never>?
    private var peakBytes: UInt64 = 0
    private var initialStart: UInt64?
    private var escalation: Task<Void, Never>?

    private struct Exit: Sendable {
        let status: Int32
        let signaled: Bool
    }

    func run(
        executable: URL,
        request: URL,
        environment: [String: String],
        limits: EngineWorkerLimits
    ) async throws -> WorkerReport {
        if let stopReason { throw stopReason.failure(peak: peakBytes) }
        let begin = ContinuousClock.now
        let lifetime = Pipe()
        let sentry = lifetime.fileHandleForWriting
        let logs = Pipe()
        guard fcntl(sentry.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw EngineFailure.unavailable("Could not protect the worker's lifetime pipe.")
        }

        process.executableURL = executable
        process.arguments = ["--scadretto-job", request.path]
        process.currentDirectoryURL = request.deletingLastPathComponent()
        process.environment = environment
        process.standardInput = lifetime
        process.standardOutput = logs
        process.standardError = logs
        process.terminationHandler = { [weak self] process in
            let exit = Exit(status: process.terminationStatus, signaled: process.terminationReason == .uncaughtSignal)
            Task { await self?.didExit(exit) }
        }

        defer {
            escalation?.cancel()
            try? sentry.close()
        }
        do {
            try process.run()
        } catch {
            throw EngineFailure.unavailable("Could not launch the bundled OpenSCAD worker: \(error.localizedDescription)")
        }
        try? logs.fileHandleForWriting.close()
        let logReader = Task { await WorkerLog.read(logs.fileHandleForReading) }
        live = true
        let pid = process.processIdentifier
        sample(pid)
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                await self?.checkLimits(pid, begin: begin, limits: limits)
            }
        }
        defer { monitor.cancel() }

        let exit = await withCheckedContinuation { waiter = $0 }
        let log = await logReader.value
        if let stopReason { throw stopReason.failure(peak: peakBytes) }
        if exit.signaled { throw EngineFailure.crashed(signal: exit.status, log: log) }
        return WorkerReport(exitCode: exit.status, log: log, peakBytes: peakBytes, elapsed: begin.duration(to: .now))
    }

    func requestStop(_ reason: WorkerStop) {
        guard stopReason == nil else { return }
        stopReason = reason
        guard live, process.isRunning else { return }
        process.terminate()
        escalation = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.forceStop()
        }
    }

    private func forceStop() {
        guard live, process.isRunning else { return }
        let pid = process.processIdentifier
        if let initialStart, let current = usage(pid), initialStart != current.ri_proc_start_abstime { return }
        kill(pid, SIGKILL)
    }

    private func didExit(_ exit: Exit) {
        live = false
        waiter?.resume(returning: exit)
        waiter = nil
    }

    private func checkLimits(_ pid: Int32, begin: ContinuousClock.Instant, limits: EngineWorkerLimits) {
        guard live, process.isRunning else { return }
        sample(pid)
        if peakBytes > limits.memoryBytes {
            requestStop(.memoryLimit)
        } else if begin.duration(to: .now) >= limits.timeout {
            requestStop(.timedOut)
        }
    }

    private func sample(_ pid: Int32) {
        guard let sample = usage(pid) else { return }
        initialStart = initialStart ?? sample.ri_proc_start_abstime
        peakBytes = max(peakBytes, sample.ri_phys_footprint)
    }

    private func usage(_ pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info : nil
    }
}
