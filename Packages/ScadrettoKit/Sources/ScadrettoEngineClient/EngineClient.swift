import Foundation
import ScadrettoCore

public struct EngineEvaluation: Sendable {
    public let outcome: EvaluationOutcome
    public let queueTime: Duration
    public let workerTime: Duration
    public let decodeTime: Duration
    public let peakWorkerBytes: UInt64
    public let log: String
}

public actor EngineClient {
    private static let pendingLimit = 32
    private struct Pending: Sendable {
        let request: EngineRequest
        let source: Data
        let limits: EngineWorkerLimits
        let submitted: ContinuousClock.Instant
        let completion: CheckedContinuation<EngineEvaluation, any Error>

        var documentID: UUID { request.key.documentID }
    }

    private struct Active {
        let pending: Pending
        let worker: WorkerProcess
    }

    private let runtime: WorkerRuntime
    private let workerLimit: Int
    private let decoder: ResultDecoder
    private var store: WorkerJobStore?
    private var buildSHA: String?
    private var pending: [Pending] = []
    private var active: [UUID: Active] = [:]
    private var underPressure = false
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var shuttingDown = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(runtime: WorkerRuntime, workerLimit: Int = 2, decoder: ResultDecoder = ResultDecoder()) {
        self.runtime = runtime
        self.workerLimit = max(1, workerLimit)
        self.decoder = decoder
    }

    public func makeRequest(
        snapshot: SourceSnapshot,
        fileURL: URL?,
        untitledBaseDirectory: URL? = nil,
        preferredLibraries: [URL] = [],
        dependencyGeneration: UInt64,
        requestID: UUID
    ) throws -> EngineRequest {
        let (store, identity) = try setup()
        let untitled: URL?
        let logicalURL: URL
        if let fileURL {
            untitled = nil
            logicalURL = fileURL
        } else {
            let base = try untitledBaseDirectory ?? store.makeUntitledWorkspace(for: snapshot.documentID)
            untitled = base
            logicalURL = base.appending(path: "Untitled.scad")
        }
        return try EngineRequest.make(
            snapshot: snapshot,
            logicalPath: logicalURL.path,
            untitledBaseDirectory: untitled?.path,
            libraryRoots: libraryPaths(preferred: preferredLibraries),
            resourceRoots: runtime.resourceRoots.map(\.path),
            dependencyGeneration: dependencyGeneration,
            workerBuild: identity,
            requestID: requestID
        )
    }

    public func evaluate(
        _ request: EngineRequest,
        source: Data,
        limits: EngineWorkerLimits = EngineWorkerLimits()
    ) async throws -> EngineEvaluation {
        try Task.checkCancellation()
        guard source.count <= 16 * 1024 * 1024 else {
            throw EngineFailure.unavailable("The source snapshot exceeds the worker's 16 MB limit.")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(Pending(request: request, source: source, limits: limits, submitted: .now,
                                completion: continuation))
            }
        } onCancel: {
            Task { await self.cancel(requestID: request.requestID, documentID: request.key.documentID) }
        }
    }

    public func cancel(requestID: UUID, documentID: UUID) async {
        if let index = pending.firstIndex(where: { $0.request.requestID == requestID && $0.documentID == documentID }) {
            pending.remove(at: index).completion.resume(throwing: EngineFailure.cancelled)
        }
        if let entry = active[documentID], entry.pending.request.requestID == requestID {
            await entry.worker.requestStop(.cancelled)
        }
    }

    public func shutdown() async {
        shuttingDown = true
        pressureSource?.cancel()
        pressureSource = nil
        for item in pending { item.completion.resume(throwing: EngineFailure.cancelled) }
        pending.removeAll()
        for entry in active.values { await entry.worker.requestStop(.cancelled) }
        if !active.isEmpty { await withCheckedContinuation { drainWaiters.append($0) } }
        store = nil
    }

    private func enqueue(_ item: Pending) {
        guard !shuttingDown else {
            item.completion.resume(throwing: EngineFailure.cancelled)
            return
        }
        if let earlier = pending.firstIndex(where: { $0.documentID == item.documentID }) {
            let superseded = pending.remove(at: earlier)
            superseded.completion.resume(throwing: EngineFailure.superseded)
        }
        guard pending.count < Self.pendingLimit else {
            item.completion.resume(throwing: EngineFailure.unavailable("The preview queue is full. Choose Retry Preview when a worker is available."))
            return
        }
        pending.append(item)
        if let running = active[item.documentID] {
            Task { await running.worker.requestStop(.superseded) }
        }
        pump()
    }

    private func pump() {
        guard !shuttingDown && !underPressure else { return }
        while active.count < workerLimit,
              let index = pending.firstIndex(where: { active[$0.documentID] == nil }) {
            let item = pending.remove(at: index)
            let worker = WorkerProcess()
            active[item.documentID] = Active(pending: item, worker: worker)
            let queueTime = item.submitted.duration(to: .now)
            Task {
                let result: Result<EngineEvaluation, any Error>
                do {
                    result = .success(try await execute(item, worker: worker, queueTime: queueTime))
                } catch {
                    result = .failure(error)
                }
                finish(item, result: result)
            }
        }
    }

    private func execute(_ item: Pending, worker: WorkerProcess, queueTime: Duration) async throws -> EngineEvaluation {
        let (store, _) = try setup()
        let runtime = self.runtime
        let decoder = self.decoder
        return try await Task.detached(priority: .userInitiated) {
            let job = try store.makeJob()
            defer { try? FileManager.default.removeItem(at: job) }
            let request = job.appending(path: "request.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try item.source.write(to: job.appending(path: EngineRequest.snapshotFileName), options: .atomic)
            try encoder.encode(item.request).write(to: request, options: .atomic)
            let report = try await worker.run(executable: runtime.executable, request: request,
                                              environment: store.environment(for: job, resourceRoots: runtime.resourceRoots),
                                              limits: item.limits)
            let decodeStart = ContinuousClock.now
            let outcome = try decoder.decode(jobDirectory: job, request: item.request, termination: .exited(report.exitCode),
                                             sourceByteLength: UInt64(item.source.count))
            return EngineEvaluation(outcome: outcome, queueTime: queueTime, workerTime: report.elapsed,
                                    decodeTime: decodeStart.duration(to: .now), peakWorkerBytes: report.peakBytes,
                                    log: report.log)
        }.value
    }

    private func finish(_ item: Pending, result: Result<EngineEvaluation, any Error>) {
        active[item.documentID] = nil
        item.completion.resume(with: result)
        if active.isEmpty {
            let waiters = drainWaiters
            drainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        pump()
    }

    private func setup() throws -> (WorkerJobStore, String) {
        guard !shuttingDown else { throw EngineFailure.cancelled }
        if let store, let buildSHA { return (store, buildSHA) }
        let identity = try runtime.identity()
        let store = try WorkerJobStore(storageRoot: runtime.storageRoot, workerBuild: identity)
        self.store = store
        buildSHA = identity
        startPressureMonitor()
        return (store, identity)
    }

    private func startPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .critical],
                                                            queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let critical = source.data.contains(.critical)
            Task { await self.setCriticalPressure(critical) }
        }
        pressureSource = source
        source.activate()
    }

    func setCriticalPressure(_ critical: Bool) async {
        underPressure = critical
        if critical {
            for entry in active.values { await entry.worker.requestStop(.memoryPressure) }
        } else {
            pump()
        }
    }

    private func libraryPaths(preferred: [URL]) -> [String] {
        let inherited = ProcessInfo.processInfo.environment["OPENSCADPATH", default: ""]
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let user = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/OpenSCAD/libraries", directoryHint: .isDirectory)
        let roots = preferred + inherited + [user] + (runtime.bundleLibraries.map { [$0] } ?? [])
        // Do not touch Documents until a worker lookup reaches this root.
        var seen = Set<String>()
        return roots.map { $0.standardizedFileURL.path }.filter { seen.insert($0).inserted }
    }
}
