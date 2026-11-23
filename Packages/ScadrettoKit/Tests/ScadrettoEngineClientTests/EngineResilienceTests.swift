import Darwin
import Foundation
import Testing
@testable import ScadrettoCore
@testable import ScadrettoEngineClient

// MARK: - Shared helpers

private func testWorkerDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "Engine resilience \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func script(_ code: String, in directory: URL) throws -> URL {
    let worker = directory.appending(path: "test-worker")
    try Data(("#!/bin/sh\n" + code + "\n").utf8).write(to: worker)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
    return worker
}

private func sourceData(_ text: String = "cube(1);\n") -> Data {
    Data(text.utf8)
}

private func makeSnapshot(_ text: String = "cube(1);\n") throws -> SourceSnapshot {
    SourceSnapshot(documentID: UUID(), revision: 1, buffer: try SourceBuffer(bytes: sourceData(text)))
}

private func makeRequest(engine: EngineClient, directory: URL, name: String) async throws -> EngineRequest {
    try await engine.makeRequest(snapshot: makeSnapshot(), fileURL: directory.appending(path: name),
                                 dependencyGeneration: 0, requestID: UUID())
}

private func waitForFile(_ url: URL, timeout: Duration = .seconds(5)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

private func readTrimmed(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func sessionDirectory(in storageRoot: URL) throws -> URL {
    let sessions = storageRoot.appending(path: "sessions", directoryHint: .isDirectory)
    let names = try FileManager.default.contentsOfDirectory(atPath: sessions.path)
    let sessionName = try #require(names.first { name in
        name.hasPrefix("session-") && UUID(uuidString: String(name.dropFirst("session-".count))) != nil
    })
    return sessions.appending(path: sessionName)
}

private func jobDirectoryNames(in session: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: session.path).filter { $0.hasPrefix("job-") }
}

// MARK: - Timeout support

private enum AwaitOutcome<T: Sendable>: Sendable {
    case value(T)
    case failed(EngineFailure)
    case otherFailure
    case timedOut
}

private final class Settlement<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private let continuation: CheckedContinuation<AwaitOutcome<T>, Never>

    init(continuation: CheckedContinuation<AwaitOutcome<T>, Never>) {
        self.continuation = continuation
    }

    func settle(_ value: AwaitOutcome<T>) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        lock.unlock()
        continuation.resume(returning: value)
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var hasTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}

private final class FinishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func mark() {
        lock.lock()
        done = true
        lock.unlock()
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}

private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async -> AwaitOutcome<T> {
    await withCheckedContinuation { (continuation: CheckedContinuation<AwaitOutcome<T>, Never>) in
        let settlement = Settlement(continuation: continuation)
        let timeoutState = TimeoutState()
        let finished = FinishFlag()
        let work = Task<Void, Never> {
            defer { finished.mark() }
            do {
                let value = try await operation()
                guard !timeoutState.hasTimedOut else { return }
                settlement.settle(.value(value))
            } catch let failure as EngineFailure {
                guard !timeoutState.hasTimedOut else { return }
                settlement.settle(.failed(failure))
            } catch {
                guard !timeoutState.hasTimedOut else { return }
                settlement.settle(.otherFailure)
            }
        }
        let timer = Task<Void, Never> {
            try? await Task.sleep(for: timeout)
            timeoutState.markTimedOut()
            work.cancel()
            // Let a cancelled operation settle before reporting the timeout, so
            // a timed-out probe cannot leave work queued behind the next one.
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline && !finished.isDone {
                try? await Task.sleep(for: .milliseconds(10))
            }
            settlement.settle(.timedOut)
        }
        _ = timer
    }
}

// MARK: - Tests

@Test func queueRejectsWorkPastItsLimit() async throws {
    let directory = try testWorkerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let holdingMarker = directory.appending(path: "holding.pid")
    let code = """
    printf %s $$ > "\(holdingMarker.path).partial" && mv "\(holdingMarker.path).partial" "\(holdingMarker.path)"
    exec /bin/sleep 30
    """
    let executable = try script(code, in: directory)
    let runtime = WorkerRuntime(executable: executable, resourceRoots: [], storageRoot: directory)
    let engine = EngineClient(runtime: runtime, workerLimit: 1)

    let firstRequest = try await makeRequest(engine: engine, directory: directory, name: "first.scad")
    let firstTask = Task { try await engine.evaluate(firstRequest, source: sourceData()) }
    let firstStarted = await waitForFile(holdingMarker)
    #expect(firstStarted)

    var waitingTasks: [Task<EngineEvaluation, Error>] = []
    for index in 0..<32 {
        let request = try await makeRequest(engine: engine, directory: directory, name: "waiting-\(index).scad")
        waitingTasks.append(Task { try await engine.evaluate(request, source: sourceData()) })
    }

    var extraMessage: String?
    let deadline = ContinuousClock.now + .seconds(5)
    while extraMessage == nil && ContinuousClock.now < deadline {
        let request = try await makeRequest(
            engine: engine, directory: directory, name: "extra-\(UUID().uuidString).scad"
        )
        let outcome = await withTimeout(.milliseconds(150)) {
            try await engine.evaluate(request, source: sourceData())
        }
        if case .failed(let failure) = outcome, case .unavailable(let message) = failure {
            extraMessage = message
        } else if case .value = outcome {
            Issue.record("A job past the queue limit was accepted and completed")
            break
        }
    }

    let message = try #require(extraMessage)
    #expect(message.contains("queue is full"))

    await engine.shutdown()
    _ = try? await firstTask.value
    for task in waitingTasks {
        _ = try? await task.value
    }
}

@Test func memoryBudgetStopsAGrowingWorker() async throws {
    let directory = try testWorkerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let code = "exec /usr/bin/perl -e '$x = \"a\" x (512*1024*1024); sleep 20'"
    let executable = try script(code, in: directory)
    let request = directory.appending(path: "request.json")
    let budget = 64 * 1024 * 1024
    let start = ContinuousClock.now
    let outcome = await withTimeout(.seconds(15)) {
        try await WorkerProcess().run(
            executable: executable, request: request,
            environment: ["PATH": "/usr/bin:/bin"],
            limits: EngineWorkerLimits(timeout: .seconds(20), memoryBytes: UInt64(budget))
        )
    }
    let elapsed = start.duration(to: .now)
    #expect(elapsed < .seconds(10))
    guard case .failed(let failure) = outcome, case .memoryLimit(let peak) = failure else {
        Issue.record("Expected EngineFailure.memoryLimit, got \(String(describing: outcome))")
        return
    }
    #expect(peak >= UInt64(budget))
}

@Test func criticalPressureStopsWorkersAndHoldsTheQueue() async throws {
    let directory = try testWorkerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let aMarker = directory.appending(path: "a.pid")
    let bMarker = directory.appending(path: "b.started")
    let code = """
    if /usr/bin/grep -q "document-a" request.json; then
        printf %s $$ > "\(aMarker.path).partial" && mv "\(aMarker.path).partial" "\(aMarker.path)"
        exec /bin/sleep 30
    fi
    printf started > "\(bMarker.path)"
    exit 73
    """
    let executable = try script(code, in: directory)
    let runtime = WorkerRuntime(executable: executable, resourceRoots: [], storageRoot: directory)
    let engine = EngineClient(runtime: runtime, workerLimit: 1)

    let aRequest = try await engine.makeRequest(
        snapshot: makeSnapshot("// a\n"), fileURL: directory.appending(path: "document-a.scad"),
        dependencyGeneration: 0, requestID: UUID()
    )
    let aTask = Task { try await engine.evaluate(aRequest, source: sourceData("// a\n")) }
    let aStarted = await waitForFile(aMarker)
    #expect(aStarted)

    await engine.setCriticalPressure(true)
    let aOutcome = await withTimeout(.seconds(5)) { try await aTask.value }
    guard case .failed(let failure) = aOutcome, case .memoryPressure = failure else {
        Issue.record("Expected EngineFailure.memoryPressure for the running job, got \(String(describing: aOutcome))")
        await engine.setCriticalPressure(false)
        await engine.shutdown()
        return
    }

    let bRequest = try await engine.makeRequest(
        snapshot: makeSnapshot("// b\n"), fileURL: directory.appending(path: "document-b.scad"),
        dependencyGeneration: 0, requestID: UUID()
    )
    let bTask = Task { try await engine.evaluate(bRequest, source: sourceData("// b\n")) }
    let bStartedEarly = await waitForFile(bMarker, timeout: .seconds(1))
    #expect(!bStartedEarly)

    await engine.setCriticalPressure(false)
    let bStarted = await waitForFile(bMarker)
    #expect(bStarted)
    let bOutcome = await withTimeout(.seconds(5)) { try await bTask.value }
    if case .timedOut = bOutcome {
        Issue.record("Job B did not finish after memory pressure was released")
        bTask.cancel()
    }

    await engine.shutdown()
}

@Test func jobDirectoryIsRemovedAfterEvaluation() async throws {
    let directory = try testWorkerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let failingCwd = directory.appending(path: "failing-cwd.txt")
    let successCwd = directory.appending(path: "success-cwd.txt")
    let perl = """
    local $/;
    open my $fh, "<", "request.json" or die "request.json: $!";
    my $request = decode_json(<$fh>);
    close $fh;
    my $bytes = shift;
    $bytes =~ s/[^0-9]//g;
    my $manifest = {
      protocolVersion => 1,
      requestID => $request->{requestID},
      key => $request->{key},
      buildSHA => $request->{expectedWorkerBuild},
      status => "ok",
      detail => "empty",
      files => [{
        id => 0,
        logicalPath => $request->{logicalPath},
        sha256 => $request->{sourceSHA256},
        byteLength => $bytes + 0,
        kind => "main",
        writable => JSON::PP::true,
      }],
      diagnostics => [],
      console => [],
      droppedConsoleMessages => 0,
      instances => [],
      operations => [],
      operands => [],
      dependencyEdges => [],
      lookups => [],
    };
    open my $out, ">", "result.json" or die "result.json: $!";
    print $out encode_json($manifest);
    close $out;
    """
    let code = """
    if /usr/bin/grep -q "failing" request.json; then
        pwd > "\(failingCwd.path)"
        exit 73
    fi
    pwd > "\(successCwd.path)"
    bytes=$(/usr/bin/wc -c < main.scad | /usr/bin/tr -d ' ')
    exec /usr/bin/perl -MJSON::PP -e '\(perl)' "$bytes"
    """
    let executable = try script(code, in: directory)
    let runtime = WorkerRuntime(executable: executable, resourceRoots: [], storageRoot: directory)
    let engine = EngineClient(runtime: runtime, workerLimit: 1)

    let failingRequest = try await makeRequest(engine: engine, directory: directory, name: "failing.scad")
    do {
        _ = try await engine.evaluate(failingRequest, source: sourceData())
        Issue.record("The failing evaluation returned successfully")
    } catch EngineError.workerExit(let status) {
        #expect(status == 73)
    }
    let session = try sessionDirectory(in: directory)
    #expect(try jobDirectoryNames(in: session) == [])
    let failingJob = try readTrimmed(failingCwd)
    #expect(!FileManager.default.fileExists(atPath: failingJob))

    let successRequest = try await makeRequest(engine: engine, directory: directory, name: "success.scad")
    let evaluation = try await engine.evaluate(successRequest, source: sourceData())
    #expect(evaluation.outcome.scene?.mesh == nil)
    #expect(try jobDirectoryNames(in: session) == [])
    let successJob = try readTrimmed(successCwd)
    #expect(!FileManager.default.fileExists(atPath: successJob))

    await engine.shutdown()
}

@Test func shutdownStopsAndReapsRunningWorkers() async throws {
    let directory = try testWorkerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appending(path: "worker.pid")
    let code = """
    trap '' TERM
    printf %s $$ > "\(pidFile.path).partial" && mv "\(pidFile.path).partial" "\(pidFile.path)"
    exec /bin/sleep 30
    """
    let executable = try script(code, in: directory)
    let runtime = WorkerRuntime(executable: executable, resourceRoots: [], storageRoot: directory)
    let engine = EngineClient(runtime: runtime, workerLimit: 1)
    let request = try await makeRequest(engine: engine, directory: directory, name: "holding.scad")
    let task = Task { try await engine.evaluate(request, source: sourceData()) }
    let started = await waitForFile(pidFile)
    #expect(started)
    let pidString = try readTrimmed(pidFile)
    let pid = try #require(Int32(pidString))

    await engine.shutdown()

    let deadline = ContinuousClock.now + .seconds(2)
    var reaped = false
    while ContinuousClock.now < deadline {
        if kill(pid, 0) != 0 && errno == ESRCH {
            reaped = true
            break
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(reaped)
    _ = try? await task.value
}

@Test func abandonedSessionIsReclaimedAndLiveSessionIsKept() async throws {
    let directory = try testWorkerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessions = directory.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let abandoned = sessions.appending(path: "session-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
    try Data().write(to: abandoned.appending(path: "owner.lock"))
    let build = String(repeating: "a", count: 64)

    var store1: WorkerJobStore? = try WorkerJobStore(storageRoot: directory, workerBuild: build)
    #expect(store1 != nil)
    #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    let liveSession = try sessionDirectory(in: directory)
    #expect(FileManager.default.fileExists(atPath: liveSession.path))

    var store2: WorkerJobStore? = try WorkerJobStore(storageRoot: directory, workerBuild: build)
    #expect(store2 != nil)
    #expect(FileManager.default.fileExists(atPath: liveSession.path))
    let sessionNames = try FileManager.default.contentsOfDirectory(atPath: sessions.path)
        .filter { $0.hasPrefix("session-") }
    #expect(sessionNames.count == 2)

    store1 = nil
    store2 = nil
}

@Test func workerEnvironmentIgnoresTheHostEnvironment() async throws {
    let directory = try testWorkerDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let dump = directory.appending(path: "environment.txt")
    let executable = try script("/usr/bin/env > \"\(dump.path)\"\nexit 73", in: directory)
    let runtime = WorkerRuntime(executable: executable, resourceRoots: [], storageRoot: directory)
    let engine = EngineClient(runtime: runtime, workerLimit: 1)
    let request = try await makeRequest(engine: engine, directory: directory, name: "environment.scad")
    do {
        _ = try await engine.evaluate(request, source: sourceData())
        Issue.record("The environment probe returned successfully")
    } catch EngineError.workerExit(let status) {
        #expect(status == 73)
    }
    await engine.shutdown()

    // The worker sees only the variables the store chooses, never the app's own, such as USER,
    // DYLD_* or OPENSCADPATH. The shell adds PWD, SHLVL and _ itself.
    let host = ProcessInfo.processInfo.environment
    #expect(host["USER"] != nil || host["LOGNAME"] != nil)
    let lines = try String(contentsOf: dump, encoding: .utf8).split(separator: "\n")
    var seen: [String: String] = [:]
    for line in lines {
        guard let equals = line.firstIndex(of: "=") else { continue }
        seen[String(line[..<equals])] = String(line[line.index(after: equals)...])
    }
    let shellOwned: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]
    #expect(Set(seen.keys).subtracting(shellOwned) == [
        "PATH", "HOME", "TMPDIR", "LANG", "LC_CTYPE", "LC_NUMERIC", "XDG_CACHE_HOME",
    ])
    #expect(seen["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(seen["HOME"] != host["HOME"])
    // Each job's temporary files stay in its own job directory, which is the worker's directory.
    // The job directory is gone by now, so compare names rather than resolving /var.
    let unprefixed = { (path: String?) in path.map { $0.hasPrefix("/private/") ? String($0.dropFirst(8)) : $0 } }
    #expect(unprefixed(seen["TMPDIR"]) == unprefixed(seen["PWD"]), "\(seen)")
}
