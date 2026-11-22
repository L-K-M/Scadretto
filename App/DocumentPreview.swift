import Foundation
import ScadrettoCore
import ScadrettoEngineClient
import ScadrettoPlanning
import ScadrettoViewport
import simd

struct PreviewGeometry: Sendable {
    let upload: ViewportMeshUpload
    let picker: ViewportPicker?
    let occurrences: [UInt32: ViewportOperand]
    let bounds: [UInt32: SceneSnapshot.BoundingBox]
    private let meshes: [UInt32: ViewportMesh]
    private let scene: SceneSnapshot
    /// Bounds of everything rendered at or below each instance, in world space.
    private let extents: [UInt32: ViewportBounds]

    init?(scene: SceneSnapshot) {
        guard let final = scene.mesh else { return nil }
        let mesh = ViewportMesh(positions: final.positions, indices: final.indices)
        upload = ViewportMeshUpload(mesh: mesh)
        let meshes = Dictionary(uniqueKeysWithValues: scene.operands.map {
            ($0.id, ViewportMesh(positions: $0.mesh.positions, indices: $0.mesh.indices))
        })
        self.meshes = meshes
        bounds = Dictionary(uniqueKeysWithValues: scene.operands.map { ($0.id, $0.mesh.bounds) })
        self.scene = scene
        let subtracted = scene.subtractedInstances
        var occurrences: [UInt32: ViewportOperand] = [:]
        for instance in scene.instances {
            if let meshID = instance.operand {
                occurrences[instance.id] = ViewportOperand(id: instance.id, meshID: meshID,
                                                           world: Self.matrix(instance.world),
                                                           isSubtracted: subtracted.contains(instance.id))
            }
        }
        self.occurrences = occurrences
        extents = Self.extents(of: scene.instances, occurrences: occurrences, bounds: bounds)
        picker = ViewportPicker(mesh: mesh, owners: final.triangleOwners, operandMeshes: meshes,
                                occurrences: Array(occurrences.values))
    }

    func guide(for instanceID: UInt32) -> ViewportDiameterGuide? {
        guard let operand = occurrences[instanceID], let bounds = bounds[operand.meshID],
              operand.world.isInvertibleFrame else { return nil }
        return ViewportDiameterGuide(
            bottom: Self.point(SIMD3(0, 0, bounds.min.z), in: operand.world),
            top: Self.point(SIMD3(0, 0, bounds.max.z), in: operand.world),
            radialX: Self.xyz(operand.world.columns.0), radialY: Self.xyz(operand.world.columns.1)
        )
    }

    func localPoint(_ worldPoint: SIMD3<Double>, on instanceID: UInt32) -> SIMD3<Double>? {
        guard let operand = occurrences[instanceID], operand.world.isInvertibleFrame else { return nil }
        return Self.point(worldPoint, in: operand.world.inverse)
    }

    func handle(for instanceID: UInt32, localPoint: SIMD3<Double>?, diameter: Double) -> ViewportDiameterHandle? {
        guard let operand = occurrences[instanceID], let bounds = bounds[operand.meshID],
              operand.world.isInvertibleFrame else { return nil }
        var center = SIMD3(0.0, 0.0, (bounds.min.z + bounds.max.z) / 2)
        var radial = SIMD3(1.0, 0.0, 0.0)
        if let local = localPoint {
            let direction = SIMD3(local.x, local.y, 0)
            if simd_length(direction) > diameter * 0.01 {
                radial = simd_normalize(direction)
                if (bounds.min.z...bounds.max.z).contains(local.z) { center.z = local.z }
            }
        }
        return ViewportDiameterHandle(center: Self.point(center, in: operand.world),
                                      radialUnit: Self.xyz(operand.world * SIMD4(radial, 0)), diameter: diameter)
    }

    /// One reverse pass, since a child always follows its parent.
    private static func extents(of instances: [InstanceRecord], occurrences: [UInt32: ViewportOperand],
                                bounds: [UInt32: SceneSnapshot.BoundingBox]) -> [UInt32: ViewportBounds] {
        var extents: [UInt32: ViewportBounds] = [:]
        for instance in instances.reversed() {
            if let operand = occurrences[instance.id], let local = bounds[operand.meshID] {
                for corner in 0..<8 {
                    let position = SIMD3(corner & 1 == 0 ? local.min.x : local.max.x,
                                         corner & 2 == 0 ? local.min.y : local.max.y,
                                         corner & 4 == 0 ? local.min.z : local.max.z)
                    let world = point(position, in: operand.world)
                    extents[instance.id] = extents[instance.id]?.including(world) ?? ViewportBounds(min: world, max: world)
                }
            }
            if let parent = instance.parent, let own = extents[instance.id] {
                extents[parent] = extents[parent]?.including(own.min).including(own.max) ?? own
            }
        }
        return extents
    }

    /// The operands below these instances, and how many did not fit the budget.
    func ghost(for instanceIDs: [UInt32]) -> (mesh: ViewportMesh?, omitted: Int) {
        let operands = scene.renderedOperands(below: instanceIDs).compactMap { occurrences[$0] }
        let ghost = ViewportGhost(operands: operands, meshes: meshes)
        return (ghost.mesh, ghost.omitted)
    }

    func moveHandle(shape: UInt32, in frame: InstanceRecord, axis: ModelAxis, value: Double,
                    valuePerUnit: Double = 1) -> ViewportLinearHandle? {
        let transform = Self.matrix(frame.world)
        guard let origin = extents[shape]?.center, transform.isInvertibleFrame else { return nil }
        return ViewportLinearHandle(anchor: origin, axis: Self.axis(axis, of: transform),
                                    value: value, valuePerUnit: valuePerUnit)
    }

    func moveGuide(for frame: InstanceRecord, localUnitsPerValue: SIMD3<Double>) -> ViewportLinearGuide? {
        let transform = Self.matrix(frame.world)
        guard let origin = extents[frame.id]?.center, transform.isInvertibleFrame else { return nil }
        return ViewportLinearGuide(anchor: origin,
                                   worldUnitsPerValue: Self.xyz(transform * SIMD4(localUnitsPerValue, 0)))
    }

    func sizeHandle(for instanceID: UInt32, property: PropertyRecord,
                    localPoint: SIMD3<Double>?) -> ViewportLinearHandle? {
        guard let operand = occurrences[instanceID], let bounds = bounds[operand.meshID],
              operand.world.isInvertibleFrame else { return nil }
        let center = (bounds.min + bounds.max) / 2
        var anchor = center
        var axis = SIMD3<Double>.zero
        var factor = property.centered ? 2.0 : 1.0
        switch property.semantic {
        case .cubeUniformSize, .cubeSizeX:
            axis.x = 1
            anchor.x = bounds.max.x
        case .cubeSizeY:
            axis.y = 1
            anchor.y = bounds.max.y
        case .cubeSizeZ, .cylinderHeight:
            axis.z = 1
            anchor.z = bounds.max.z
        case .sphereDiameter:
            let direction = localPoint.map { $0 - center } ?? SIMD3(1.0, 0, 0)
            axis = simd_length(direction) > 1e-10 ? simd_normalize(direction) : SIMD3(1, 0, 0)
            anchor += axis * (property.value / 2)
            factor = 2
        case .cylinderBottomRadius, .cylinderTopRadius:
            let direction = localPoint.map { SIMD3($0.x, $0.y, 0) } ?? SIMD3(1.0, 0, 0)
            axis = simd_length(direction) > 1e-10 ? simd_normalize(direction) : SIMD3(1, 0, 0)
            anchor += axis * property.value
            anchor.z = property.semantic == .cylinderTopRadius ? bounds.max.z : bounds.min.z
            factor = 1
        default:
            return nil
        }
        return ViewportLinearHandle(anchor: Self.point(anchor, in: operand.world),
                                    axis: Self.xyz(operand.world * SIMD4(axis, 0)),
                                    value: property.value, valuePerUnit: factor, exclusiveMinimum: 0)
    }

    private static func axis(_ axis: ModelAxis, of matrix: simd_double4x4) -> SIMD3<Double> {
        var local = SIMD4<Double>.zero
        local[axis.index] = 1
        return xyz(matrix * local)
    }

    private static func matrix(_ values: [Double]) -> simd_double4x4 {
        func column(_ index: Int) -> SIMD4<Double> {
            SIMD4(values[index], values[index + 1], values[index + 2], values[index + 3])
        }
        return simd_double4x4(columns: (column(0), column(4), column(8), column(12)))
    }

    private static func point(_ point: SIMD3<Double>, in matrix: simd_double4x4) -> SIMD3<Double> {
        xyz(matrix * SIMD4(point, 1))
    }

    private static func xyz(_ vector: SIMD4<Double>) -> SIMD3<Double> {
        SIMD3(vector.x, vector.y, vector.z)
    }
}

@MainActor
final class DocumentPreview {
    enum Phase {
        case evaluating
        case outcome(EvaluationOutcome, PreviewGeometry?)
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

    func acceptsWriteBack(from source: EvaluationResult) -> Bool {
        acceptsNavigation(from: source) && dependencyCheck == nil
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
                    let geometry = result.scene.flatMap(PreviewGeometry.init)
                    return (watch: watch, geometry: geometry)
                }.value
                guard let self, isCurrent(request, input: input), !Task.isCancelled,
                      result.requestID == id, result.key == request.key else { return }

                // Retire the prior request's pending check before arming the
                // new watch. A fresh recheck covers changes during the handoff.
                stopWatchingDependencies()
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
                onUpdate?(.outcome(evaluation.outcome, prepared.geometry))
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
            guard let self, !Task.isCancelled, dependencyRequest == requestID else { return }
            dependencyCheck = nil
            guard !current else { return }
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
