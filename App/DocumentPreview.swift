import Foundation
import ScadrettoCore
import ScadrettoEngineClient
import ScadrettoViewport

@MainActor
final class DocumentPreview {
    enum Phase {
        case evaluating
        case outcome(EvaluationOutcome, ViewportMeshUpload?)
        case failure(String)
        case cancelled
    }

    private struct Input {
        let source: SourceSnapshot
        let fileURL: URL?
    }

    private let engine: EngineClient?
    private let startupError: String?
    private var input: Input?
    private var currentID: UUID?
    private var task: Task<Void, Never>?
    private var dependencies: DependencyWatch?
    private var dependencyRequest: UUID?
    private var dependencyCheck: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var dependencyRetries = 0

    var onUpdate: ((Phase) -> Void)?
    private(set) var request: EngineRequest?
    private(set) var outcome: EvaluationOutcome?
    private(set) var lastGood: EvaluationResult?
    private(set) var log = ""

    init(engine: EngineClient?, startupError: String?) {
        self.engine = engine
        self.startupError = startupError
    }

    func schedule(_ source: SourceSnapshot, fileURL: URL?, immediate: Bool) {
        if input?.fileURL != fileURL {
            stopWatchingDependencies()
        }
        input = Input(source: source, fileURL: fileURL)
        dependencyRetries = 0
        begin(immediate: immediate)
    }

    func retry() {
        dependencyRetries = 0
        begin(immediate: true)
    }

    func cancel() {
        currentID = nil
        request = nil
        task?.cancel()
        task = nil
        stopWatchingDependencies()
        onUpdate?(.cancelled)
    }

    func close() {
        task?.cancel()
        currentID = nil
        stopWatchingDependencies()
        input = nil
        onUpdate = nil
    }

    func acceptsNavigation(from source: EvaluationResult) -> Bool {
        currentID == source.requestID && outcome?.result.requestID == source.requestID && request?.key == source.key
    }

    private func begin(immediate: Bool) {
        guard let input else { return }
        task?.cancel()
        request = nil
        outcome = nil
        let id = UUID()
        currentID = id
        guard let engine else {
            log = startupError ?? "The OpenSCAD preview service could not start."
            onUpdate?(.failure(log))
            return
        }
        onUpdate?(.evaluating)

        let generation = self.generation
        let roots = UserDefaults.standard.stringArray(forKey: "libraryRoots")?.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? []
        let configuredTimeout = UserDefaults.standard.double(forKey: "previewTimeoutSeconds")
        let timeout = configuredTimeout.isFinite && configuredTimeout > 0
            ? min(3_600, configuredTimeout) : 20
        let limits = EngineWorkerLimits(timeout: .seconds(timeout))
        task = Task { [weak self] in
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(150)) }
                let request = try await engine.makeRequest(snapshot: input.source, fileURL: input.fileURL,
                                                           preferredLibraries: roots, dependencyGeneration: generation,
                                                           requestID: id)
                guard self?.isCurrent(request, input: input) == true, !Task.isCancelled else { return }
                self?.request = request
                let evaluation = try await engine.evaluate(request, source: input.source.buffer.bytes, limits: limits)
                guard self?.isCurrent(request, input: input) == true, !Task.isCancelled else { return }

                let result = evaluation.outcome.result
                let changed: @Sendable () -> Void = { [weak self] in
                    Task { @MainActor in self?.dependencyChanged(for: id) }
                }
                let prepared = await Task.detached(priority: .utility) {
                    let watch = DependencyWatch(result: result, onChange: changed)
                    let upload = result.scene?.mesh.map {
                        ViewportMeshUpload(mesh: ViewportMesh(positions: $0.positions, indices: $0.indices))
                    }
                    return (watch: watch, upload: upload)
                }.value
                guard let self, isCurrent(request, input: input), !Task.isCancelled,
                      result.requestID == id, result.key == request.key else { return }

                // Route new watch events before the final dependency check.
                dependencies = prepared.watch
                dependencyRequest = id
                let dependenciesAreCurrent = await Task.detached(priority: .utility) {
                    prepared.watch.isCurrent()
                }.value
                guard isCurrent(request, input: input), !Task.isCancelled, dependencyRequest == id else { return }
                guard dependenciesAreCurrent else {
                    stopWatchingDependencies()
                    changedDuringEvaluation()
                    return
                }

                dependencyRetries = 0
                outcome = evaluation.outcome
                log = evaluation.log
                switch evaluation.outcome {
                case .rendered, .empty: lastGood = result
                case .modelError, .unsupportedDimension: break
                }
                onUpdate?(.outcome(evaluation.outcome, prepared.upload))
            } catch {
                guard let self, currentID == id, !Task.isCancelled else { return }
                if case EngineFailure.crashed(_, let logs) = error { log = logs }
                else { log = error.localizedDescription }
                onUpdate?(.failure(error.localizedDescription))
            }
        }
    }

    private func isCurrent(_ request: EngineRequest, input: Input) -> Bool {
        currentID == request.requestID
            && self.input?.source.documentID == input.source.documentID
            && self.input?.source.revision == input.source.revision
            && self.input?.fileURL == input.fileURL
            && generation == request.key.dependencyGeneration
    }

    private func dependencyChanged(for requestID: UUID) {
        guard dependencyRequest == requestID, let dependencies else { return }
        dependencyCheck?.cancel()
        dependencyCheck = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) }
            catch { return }
            let current = await Task.detached(priority: .utility) { dependencies.isCurrent() }.value
            guard !current, let self, !Task.isCancelled, dependencyRequest == requestID else { return }
            self.dependencies = nil
            self.dependencyRequest = nil
            changedDuringEvaluation()
        }
    }

    private func stopWatchingDependencies() {
        dependencyCheck?.cancel()
        dependencyCheck = nil
        dependencyRequest = nil
        dependencies = nil
    }

    private func changedDuringEvaluation() {
        guard generation < UInt64.max else {
            onUpdate?(.failure("The dependency generation limit has been reached."))
            return
        }
        generation += 1
        dependencyRetries += 1
        if dependencyRetries <= 3 { begin(immediate: false) }
        else { onUpdate?(.failure("A dependency changed during evaluation. Choose Retry Preview to try again.")) }
    }
}
