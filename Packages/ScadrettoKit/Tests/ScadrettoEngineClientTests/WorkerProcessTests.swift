import Foundation
import Testing
import ScadrettoCore
@testable import ScadrettoEngineClient

@Test func childSignalIsReportedAsCrash() async throws {
    let directory = try testWorkerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let worker = try script("kill -TERM $$", in: directory)
    let process = WorkerProcess()
    do {
        _ = try await process.run(executable: worker, request: directory.appending(path: "request.json"),
                                  environment: ["PATH": "/bin:/usr/bin"], limits: EngineWorkerLimits())
        Issue.record("A signaled child returned successfully")
    } catch EngineFailure.crashed(let signal, _) {
        #expect(signal == 15)
    }
}

@Test func childTimeoutTerminatesUnresponsiveWorker() async throws {
    let directory = try testWorkerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let worker = try script("trap '' TERM\nwhile :; do :; done", in: directory)
    let process = WorkerProcess()
    let start = ContinuousClock.now
    do {
        _ = try await process.run(executable: worker, request: directory.appending(path: "request.json"),
                                  environment: ["PATH": "/bin:/usr/bin"],
                                  limits: EngineWorkerLimits(timeout: .milliseconds(150)))
        Issue.record("An unresponsive child returned successfully")
    } catch EngineFailure.timedOut {
        #expect(start.duration(to: .now) < .seconds(3))
    }
}

@Test func processLogsDrainToEOFAndStayBounded() async throws {
    let directory = try testWorkerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let worker = try script("printf 'out:'\nprintf 'err:' >&2\nprintf '%070000d' 0", in: directory)
    let report = try await WorkerProcess().run(
        executable: worker, request: directory.appending(path: "request.json"),
        environment: ["PATH": "/bin:/usr/bin"], limits: EngineWorkerLimits(timeout: .seconds(3))
    )
    #expect(report.exitCode == 0)
    #expect(report.log.hasPrefix("out:err:"))
    #expect(report.log.utf8.count == 64 * 1024)
}

@Test @MainActor func latestJobSupersedesRunningJobInSameDocument() async throws {
    let directory = try testWorkerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let code = """
    if /usr/bin/grep -q holding main.scad; then
        printf %s $$ > running
        while :; do :; done
    fi
    exit 73
    """
    let executable = try script(code, in: directory)
    let runtime = WorkerRuntime(executable: executable, resourceRoots: [], storageRoot: directory)
    let engine = EngineClient(runtime: runtime, workerLimit: 1)
    let document = SourceDocument(buffer: try SourceBuffer(bytes: Data("// holding\n".utf8)))
    let original = document.snapshot
    let first = try await engine.makeRequest(snapshot: original, fileURL: nil, dependencyGeneration: 0,
                                             requestID: UUID())
    let old = Task { try await engine.evaluate(first, source: original.buffer.bytes) }

    let ready = await Task.detached {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let paths = FileManager.default.enumerator(atPath: directory.path),
               paths.contains(where: { ($0 as? String)?.hasSuffix("/running") == true }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }.value
    #expect(ready)
    try document.reload(SourceBuffer(bytes: Data("cube(2);\n".utf8)))
    let latest = document.snapshot
    let second = try await engine.makeRequest(snapshot: latest, fileURL: nil, dependencyGeneration: 0,
                                              requestID: UUID())
    #expect(first.requestID != second.requestID)
    let new = Task { try await engine.evaluate(second, source: latest.buffer.bytes) }
    do {
        _ = try await old.value
        Issue.record("The superseded evaluation completed")
    } catch EngineFailure.superseded {}
    do {
        _ = try await new.value
        Issue.record("The injected worker did not report its failure")
    } catch EngineError.workerExit(let status) {
        #expect(status == 73)
    }
    await engine.shutdown()
    let sessions = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "sessions").path)
    #expect(sessions == ["registry.lock"])
}

private func testWorkerDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "Worker process \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func script(_ code: String, in directory: URL) throws -> URL {
    let worker = directory.appending(path: "test-worker")
    try Data(("#!/bin/sh\n" + code + "\n").utf8).write(to: worker)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
    return worker
}
