import Darwin
import Foundation

/// Reads a private job directory after the worker exits and returns the only
/// acceptable outcomes: exit 0 with a validated `ok` manifest, or exit 1 with
/// a validated `modelError`/`unsupportedDimension` manifest. Everything else —
/// signals, unexpected exits, malformed or contradictory manifests, identity
/// mismatches and failed validation — throws `EngineError`.
///
/// All job files are opened relative to the job directory descriptor with
/// O_NOFOLLOW, required to be regular files and read under byte caps. Manifest
/// payload paths are never used for I/O; each must equal its expected constant
/// before the corresponding fixed file name is opened.
public struct ResultDecoder: Sendable {
    public struct Limits: Sendable {
        public var manifestByteLimit: UInt64 = 16 * 1024 * 1024
        public var payloadByteLimit: UInt64 = 256 * 1024 * 1024
        public var fileLimit = 65_536
        public var diagnosticLimit = 65_536
        public var consoleLimit = 65_536
        public var instanceLimit = 1_048_576
        public var operandLimit = 1_048_576
        public var operationLimit = 1_048_576
        public var dependencyEdgeLimit = 4_194_304
        public var lookupLimit = 1_048_576
        public var lookupCandidateLimit = 1_024
        public var callPathLimit = 16_384
        public var diameterChainLimit = 16_384
        public var argumentLimit = 128
        public var argumentListLimit = 1_048_576
        public var propertyLimit = 64
        public var propertyDefinitionLimit = 1_048_576
        public var propertyChainLimit = 256
        public var propertyInputLimit = 64
        public var vertexLimit: UInt64 = 1 << 26
        public var indexLimit: UInt64 = 1 << 28

        public init() {}
    }

    public static let meshPayloadName = "mesh.bin"
    public static let operandPayloadName = "operands.bin"
    private static let payloadHeaderSize: UInt64 = 16
    private static let payloadMagic = Array("SCADMESH".utf8)
    private static let matrixEpsilon = 1e-9
    private static let boundsEpsilon = 1e-12
    private static let displayMultipliers: Set<Double> = [0.5, 1, 2]

    public let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    private enum Status: String, Decodable {
        case ok
        case error
    }

    private enum Detail: String, Decodable {
        case rendered
        case empty
        case modelError
        case unsupportedDimension
        case protocolMismatch
        case buildMismatch
        case internalError
    }

    private struct OperandRecord: Decodable {
        let id: UInt32
        let mesh: MeshDescriptor
    }

    /// Property fields that every execution of a call site shares.
    private struct PropertyDefinition: Decodable {
        let semantic: PropertyRecord.Semantic
        let formal: String
        let status: PropertyRecord.Status
        let displayMultiplier: Double
        let centered: Bool
        let expression: WireSpan?
        let chain: [ChainLink]
        let inputs: [WireSpan]
        let impactComplete: Bool
    }

    private struct PropertyValue: Decodable {
        let definition: Int
        let value: Double
        let dragVerified: Bool?
        let pitch: PropertyRecord.Pitch?
    }

    private struct WireInstance: Decodable {
        let id: UInt32
        let parent: UInt32?
        let name: String
        let span: WireSpan?
        let iteration: [String: Double]
        let local: [Double]
        let world: [Double]
        let operand: UInt32?
        let diameter: DiameterRecord?
        let definitionSpan: WireSpan?
        let arguments: Int?
        let properties: [PropertyValue]?
        let opaqueFrame: Bool?
    }

    private struct Manifest: Decodable {
        let protocolVersion: Int
        let requestID: UUID
        let key: EvaluationKey
        let buildSHA: String
        let status: Status
        let detail: Detail
        let files: [FileRecord]?
        let diagnostics: [EngineDiagnostic]?
        let console: [ConsoleMessage]?
        let droppedConsoleMessages: UInt64?
        let mesh: MeshDescriptor?
        let operands: [OperandRecord]?
        let instances: [WireInstance]?
        let propertyDefinitions: [PropertyDefinition]?
        let argumentLists: [[ArgumentRecord]]?
        let propertiesOmitted: Bool?
        let operations: [OperationRecord]?
        let dependencyEdges: [DependencyEdge]?
        let lookups: [LookupRecord]?
    }

    public func decode(
        jobDirectory: URL,
        request: EngineRequest,
        termination: TerminationStatus,
        sourceByteLength: UInt64? = nil
    ) throws -> EvaluationOutcome {
        let exitCode: Int32
        switch termination {
        case .exited(let code):
            exitCode = code
        case .uncaughtSignal(let signal):
            throw EngineError.workerSignaled(signal)
        }
        guard exitCode == 0 || exitCode == 1 else { throw EngineError.workerExit(exitCode) }

        let directoryFD = open(jobDirectory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard directoryFD >= 0 else {
            throw EngineError.fileUnreadable(name: jobDirectory.path, detail: Self.errnoDetail())
        }
        defer { close(directoryFD) }
        var directoryStatus = stat()
        guard fstat(directoryFD, &directoryStatus) == 0,
              (directoryStatus.st_mode & S_IFMT) == S_IFDIR
        else {
            throw EngineError.fileUnreadable(name: jobDirectory.path, detail: "not a directory")
        }

        let manifestData = try readJobFile(
            directoryFD: directoryFD, name: "result.json", byteLimit: limits.manifestByteLimit
        )
        let manifest = try decodeManifest(manifestData)
        try validateIdentity(manifest: manifest, request: request)
        if exitCode == 1 && manifest.status == .error {
            switch manifest.detail {
            case .protocolMismatch: throw EngineError.protocolMismatch
            case .buildMismatch: throw EngineError.buildMismatch
            case .internalError: throw EngineError.internalError
            case .modelError, .unsupportedDimension, .rendered, .empty: break
            }
        }

        // Error manifests carry dependencies and diagnostics observed before
        // failure but no trustworthy scene, so instance-level references are
        // not checked against a scene that cannot be published.
        let instances = manifest.status == .ok ? try resolveInstances(manifest) : nil
        let tables = try decodeTables(
            manifest: manifest, request: request, sourceByteLength: sourceByteLength, instances: instances
        )
        let makeResult = { (scene: SceneSnapshot?) in
            tables.result(
                requestID: manifest.requestID, key: manifest.key,
                workerBuild: manifest.buildSHA, scene: scene
            )
        }

        switch (exitCode, manifest.status, manifest.detail) {
        case (0, .ok, .rendered):
            guard let descriptor = manifest.mesh else {
                throw EngineError.statusContradiction("rendered result has no mesh descriptor")
            }
            let scene = try decodeScene(
                directoryFD: directoryFD, manifest: manifest, instances: instances ?? [],
                meshDescriptor: descriptor, tables: tables
            )
            return .rendered(makeResult(scene))

        case (0, .ok, .empty):
            guard manifest.mesh == nil else {
                throw EngineError.statusContradiction("empty result carries a mesh descriptor")
            }
            let scene = try decodeScene(
                directoryFD: directoryFD, manifest: manifest, instances: instances ?? [],
                meshDescriptor: nil, tables: tables
            )
            return .empty(makeResult(scene))

        case (1, .error, .modelError), (1, .error, .unsupportedDimension):
            guard manifest.mesh == nil, manifest.operands?.isEmpty != false,
                  manifest.instances?.isEmpty != false, manifest.operations?.isEmpty != false,
                  manifest.dependencyEdges?.isEmpty != false, manifest.propertyDefinitions?.isEmpty != false,
                  manifest.argumentLists?.isEmpty != false else {
                throw EngineError.statusContradiction("error manifest must not carry a scene")
            }
            let result = makeResult(nil)
            return manifest.detail == .modelError ? .modelError(result) : .unsupportedDimension(result)

        default:
            throw EngineError.statusContradiction(
                "exit \(exitCode) with status \(manifest.status.rawValue) detail \(manifest.detail.rawValue)"
            )
        }
    }

    // MARK: - Manifest identity

    private func decodeManifest(_ data: Data) throws -> Manifest {
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw EngineError.manifestMalformed(String(describing: error))
        }
    }

    private func validateIdentity(manifest: Manifest, request: EngineRequest) throws {
        guard request.protocolVersion == EngineRequest.currentProtocolVersion,
              manifest.protocolVersion == request.protocolVersion else {
            throw EngineError.protocolMismatch
        }
        guard manifest.requestID == request.requestID else {
            throw EngineError.identityMismatch(field: "requestID")
        }
        guard manifest.key == request.key else {
            throw EngineError.identityMismatch(field: "key")
        }
        guard manifest.buildSHA.isSHA256HexDigest else {
            throw EngineError.validationFailed("buildSHA is not a SHA-256 digest")
        }
        guard manifest.buildSHA == request.expectedWorkerBuild else {
            throw EngineError.buildMismatch
        }
    }

    // MARK: - Tables

    private struct Tables {
        let files: [FileRecord]
        let filesByID: [UInt32: FileRecord]
        let diagnostics: [EngineDiagnostic]
        let console: [ConsoleMessage]
        let droppedConsoleMessages: UInt64
        let dependencyEdges: [DependencyEdge]
        let lookups: [LookupRecord]

        func result(requestID: UUID, key: EvaluationKey, workerBuild: String, scene: SceneSnapshot?) -> EvaluationResult {
            EvaluationResult(
                requestID: requestID,
                key: key,
                workerBuild: workerBuild,
                files: files,
                diagnostics: diagnostics,
                console: console,
                droppedConsoleMessages: droppedConsoleMessages,
                dependencyEdges: dependencyEdges,
                lookups: lookups,
                scene: scene
            )
        }
    }

    private func decodeTables(
        manifest: Manifest,
        request: EngineRequest,
        sourceByteLength: UInt64?,
        instances: [InstanceRecord]?
    ) throws -> Tables {
        let files = manifest.files ?? []
        let diagnostics = manifest.diagnostics ?? []
        let console = manifest.console ?? []
        let dependencyEdges = manifest.dependencyEdges ?? []
        let lookups = manifest.lookups ?? []

        try requireLimit(files.count, limit: limits.fileLimit, name: "file")
        try requireLimit(diagnostics.count, limit: limits.diagnosticLimit, name: "diagnostic")
        try requireLimit(console.count, limit: limits.consoleLimit, name: "console")
        try requireLimit(dependencyEdges.count, limit: limits.dependencyEdgeLimit, name: "dependencyEdge")
        try requireLimit(lookups.count, limit: limits.lookupLimit, name: "lookup")

        var filesByID: [UInt32: FileRecord] = [:]
        filesByID.reserveCapacity(files.count)
        var mainFiles = 0
        for file in files {
            guard filesByID[file.id] == nil else {
                throw EngineError.validationFailed("duplicate file id \(file.id)")
            }
            filesByID[file.id] = file
            guard file.sha256.isSHA256HexDigest else {
                throw EngineError.validationFailed("file \(file.id) sha256 is not a digest")
            }
            guard file.logicalPath.hasPrefix("/") else {
                throw EngineError.validationFailed("file \(file.id) logicalPath is not absolute")
            }
            if let resolved = file.resolvedPath, !resolved.hasPrefix("/") {
                throw EngineError.validationFailed("file \(file.id) resolvedPath is not absolute")
            }
            if file.kind == .main {
                mainFiles += 1
                guard file.logicalPath == request.logicalPath else {
                    throw EngineError.validationFailed("main file path does not match the request")
                }
                guard file.sha256 == request.sourceSHA256 else {
                    throw EngineError.validationFailed("main file digest does not match the request")
                }
                if let sourceByteLength, file.byteLength != sourceByteLength {
                    throw EngineError.validationFailed("main file byte length does not match the snapshot")
                }
            }
        }
        guard mainFiles == 1 else {
            throw EngineError.validationFailed("expected exactly one main file, saw \(mainFiles)")
        }

        let instanceIDs: Set<UInt32>? = instances.map { Set($0.map(\.id)) }

        func checkCallPath(_ callPath: [UInt32], context: String) throws {
            try requireLimit(callPath.count, limit: limits.callPathLimit, name: "\(context) callPath")
            guard let instanceIDs else { return }
            for id in callPath where !instanceIDs.contains(id) {
                throw EngineError.validationFailed("\(context) callPath references unknown instance \(id)")
            }
        }

        for (index, diagnostic) in diagnostics.enumerated() {
            let context = "diagnostic \(index)"
            if let fileID = diagnostic.fileID, filesByID[fileID] == nil {
                throw EngineError.validationFailed("\(context) references unknown file \(fileID)")
            }
            if let span = diagnostic.span { try checkSpan(span, filesByID: filesByID, context: context) }
            try checkCallPath(diagnostic.callPath, context: context)
        }

        for (index, message) in console.enumerated() {
            let context = "console \(index)"
            if let fileID = message.fileID, filesByID[fileID] == nil {
                throw EngineError.validationFailed("\(context) references unknown file \(fileID)")
            }
            if let span = message.span { try checkSpan(span, filesByID: filesByID, context: context) }
            try checkCallPath(message.callPath, context: context)
        }

        for (index, edge) in dependencyEdges.enumerated() {
            let context = "dependencyEdge \(index)"
            try checkSpan(edge.span, filesByID: filesByID, context: context)
            if let instanceIDs, !instanceIDs.contains(edge.instanceID) {
                throw EngineError.validationFailed("\(context) references unknown instance \(edge.instanceID)")
            }
        }

        for (index, lookup) in lookups.enumerated() {
            let context = "lookup \(index)"
            if let fileID = lookup.requestingFileID, filesByID[fileID] == nil {
                throw EngineError.validationFailed("\(context) references unknown file \(fileID)")
            }
            try requireLimit(lookup.candidates.count, limit: limits.lookupCandidateLimit, name: "\(context) candidates")
            for candidate in lookup.candidates where !candidate.hasPrefix("/") {
                throw EngineError.validationFailed("\(context) candidate is not absolute")
            }
            if let winner = lookup.winner, !lookup.candidates.contains(winner) {
                throw EngineError.validationFailed("\(context) winner was not a candidate")
            }
            if let resolved = lookup.resolvedWinner, (lookup.winner == nil || !resolved.hasPrefix("/")) {
                throw EngineError.validationFailed("\(context) has an invalid resolved winner")
            }
        }

        return Tables(
            files: files,
            filesByID: filesByID,
            diagnostics: diagnostics,
            console: console,
            droppedConsoleMessages: manifest.droppedConsoleMessages ?? 0,
            dependencyEdges: dependencyEdges,
            lookups: lookups
        )
    }

    // MARK: - Shared details

    /// Joins each occurrence to its shared definitions. Arrays taken from one
    /// table entry share storage, so the join grows with the occurrence count.
    private func resolveInstances(_ manifest: Manifest) throws -> [InstanceRecord] {
        let wire = manifest.instances ?? []
        let definitions = manifest.propertyDefinitions ?? []
        let lists = manifest.argumentLists ?? []
        try requireLimit(wire.count, limit: limits.instanceLimit, name: "instance")
        try requireLimit(definitions.count, limit: limits.propertyDefinitionLimit, name: "propertyDefinition")
        try requireLimit(lists.count, limit: limits.argumentListLimit, name: "argumentList")

        return try wire.enumerated().map { index, instance in
            let context = "instance \(index)"
            if let list = instance.arguments, !lists.indices.contains(list) {
                throw EngineError.validationFailed("\(context) arguments reference a missing list")
            }
            return InstanceRecord(
                id: instance.id, parent: instance.parent, name: instance.name, span: instance.span,
                iteration: instance.iteration, local: instance.local, world: instance.world,
                operand: instance.operand, diameter: instance.diameter, definitionSpan: instance.definitionSpan,
                arguments: instance.arguments.map { lists[$0] },
                properties: try instance.properties.map {
                    try resolveProperties($0, definitions: definitions, context: context)
                },
                opaqueFrame: instance.opaqueFrame ?? false
            )
        }
    }

    private func resolveProperties(
        _ values: [PropertyValue],
        definitions: [PropertyDefinition],
        context: String
    ) throws -> [PropertyRecord] {
        try requireLimit(values.count, limit: limits.propertyLimit, name: "\(context) properties")
        var declared: Set<PropertyKey> = []
        return try values.enumerated().map { index, entry in
            let context = "\(context) property \(index)"
            guard definitions.indices.contains(entry.definition) else {
                throw EngineError.validationFailed("\(context) references a missing definition")
            }
            let shared = definitions[entry.definition]
            guard declared.insert(PropertyKey(semantic: shared.semantic, formal: shared.formal)).inserted else {
                throw EngineError.validationFailed(
                    "\(context) repeats \(shared.semantic.rawValue) for formal \(shared.formal)"
                )
            }
            guard entry.value.isFinite else {
                throw EngineError.validationFailed("\(context) value is not finite")
            }
            if shared.semantic == .pitch {
                guard let pitch = entry.pitch else {
                    throw EngineError.validationFailed("\(context) lacks its pitch record")
                }
                // Iteration 0 is valid. The app offers it numeric entry only.
                guard pitch.iteration.isFinite else {
                    throw EngineError.validationFailed("\(context) pitch iteration is not finite")
                }
            } else if entry.pitch != nil {
                throw EngineError.validationFailed("\(context) is not a pitch property but carries one")
            }
            let dragVerified = entry.dragVerified ?? false
            guard !dragVerified || (shared.status == .bound && shared.impactComplete) else {
                throw EngineError.validationFailed("\(context) verifies a drag without complete impact")
            }
            return PropertyRecord(
                semantic: shared.semantic, formal: shared.formal, status: shared.status, value: entry.value,
                displayMultiplier: shared.displayMultiplier, centered: shared.centered,
                expression: shared.expression, chain: shared.chain, inputs: shared.inputs,
                impactComplete: shared.impactComplete, dragVerified: dragVerified, pitch: entry.pitch
            )
        }
    }

    private func checkSharedDetails(_ manifest: Manifest, filesByID: [UInt32: FileRecord]) throws {
        for (index, definition) in (manifest.propertyDefinitions ?? []).enumerated() {
            let context = "property definition \(index)"
            guard Self.displayMultipliers.contains(definition.displayMultiplier) else {
                throw EngineError.validationFailed("\(context) has an illegal displayMultiplier")
            }
            try requireLimit(definition.chain.count, limit: limits.propertyChainLimit, name: "\(context) chain")
            try requireLimit(definition.inputs.count, limit: limits.propertyInputLimit, name: "\(context) inputs")
            if let span = definition.expression {
                try checkSpan(span, filesByID: filesByID, context: context)
            }
            for span in definition.chain.compactMap(\.span) + definition.inputs {
                try checkSpan(span, filesByID: filesByID, context: context)
            }
        }
        for (index, list) in (manifest.argumentLists ?? []).enumerated() {
            try requireLimit(list.count, limit: limits.argumentLimit, name: "argument list \(index)")
            for (entry, argument) in list.enumerated() {
                if let span = argument.expression {
                    try checkSpan(span, filesByID: filesByID, context: "argument list \(index) entry \(entry)")
                }
            }
        }
    }

    // MARK: - Scene

    private func decodeScene(
        directoryFD: Int32,
        manifest: Manifest,
        instances: [InstanceRecord],
        meshDescriptor: MeshDescriptor?,
        tables: Tables
    ) throws -> SceneSnapshot {
        let operandRecords = manifest.operands ?? []
        let operations = manifest.operations ?? []

        try requireLimit(operandRecords.count, limit: limits.operandLimit, name: "operand")
        try requireLimit(operations.count, limit: limits.operationLimit, name: "operation")
        try checkSharedDetails(manifest, filesByID: tables.filesByID)

        var indexByID: [UInt32: Int] = [:]
        indexByID.reserveCapacity(instances.count)
        var worlds: [UInt32: [Double]] = [:]
        worlds.reserveCapacity(instances.count)
        for (index, instance) in instances.enumerated() {
            let context = "instance \(index)"
            guard instance.id != SceneSnapshot.Mesh.unknownOwner else {
                throw EngineError.validationFailed("\(context) uses the reserved owner id")
            }
            guard indexByID[instance.id] == nil else {
                throw EngineError.validationFailed("\(context) duplicate instance id \(instance.id)")
            }
            indexByID[instance.id] = index
            if let span = instance.span { try checkSpan(span, filesByID: tables.filesByID, context: context) }
            try checkMatrix(instance.local, context: "\(context) local")
            try checkMatrix(instance.world, context: "\(context) world")
            for (name, value) in instance.iteration where !value.isFinite {
                throw EngineError.validationFailed("\(context) iteration \(name) is not finite")
            }
            if let diameter = instance.diameter {
                guard diameter.value.isFinite else {
                    throw EngineError.validationFailed("\(context) diameter is not finite")
                }
                try requireLimit(diameter.chain.count, limit: limits.diameterChainLimit, name: "\(context) chain")
                for link in diameter.chain {
                    if let span = link.span { try checkSpan(span, filesByID: tables.filesByID, context: context) }
                }
            }
            if let span = instance.definitionSpan {
                try checkSpan(span, filesByID: tables.filesByID, context: "\(context) definitionSpan")
            }

            // Instances arrive in executed order, so a parent is always decoded
            // before its children; this both forbids cycles and supplies the
            // parent's world transform for the relationship check below.
            if let parent = instance.parent {
                guard let parentWorld = worlds[parent] else {
                    throw EngineError.validationFailed("\(context) parent \(parent) is missing or follows it")
                }
                let expected = multiply(parentWorld, instance.local)
                guard matricesApproximatelyEqual(instance.world, expected) else {
                    throw EngineError.validationFailed("\(context) world is not parent x local")
                }
            } else {
                guard matricesApproximatelyEqual(instance.world, instance.local) else {
                    throw EngineError.validationFailed("\(context) root world differs from local")
                }
            }
            worlds[instance.id] = instance.world
        }

        var operandIDs = Set<UInt32>()
        operandIDs.reserveCapacity(operandRecords.count)
        for record in operandRecords {
            guard operandIDs.insert(record.id).inserted else {
                throw EngineError.validationFailed("duplicate operand id \(record.id)")
            }
            // The descriptor path is validated, never opened: payloads always
            // come from the fixed job-relative names below.
            guard record.mesh.path == Self.operandPayloadName else {
                throw EngineError.pathRejected(record.mesh.path)
            }
        }
        for instance in instances {
            if let operand = instance.operand, !operandIDs.contains(operand) {
                throw EngineError.validationFailed("instance \(instance.id) references unknown operand \(operand)")
            }
        }

        var childOwners: [UInt32: UInt32] = [:]
        for operation in operations {
            guard indexByID[operation.instanceID] != nil else {
                throw EngineError.validationFailed("operation references unknown instance \(operation.instanceID)")
            }
            for child in operation.children {
                guard let childIndex = indexByID[child.instanceID] else {
                    throw EngineError.validationFailed("operation child \(child.instanceID) is unknown")
                }
                guard instances[childIndex].parent == operation.instanceID else {
                    throw EngineError.validationFailed(
                        "operation child \(child.instanceID) is not parented to \(operation.instanceID)"
                    )
                }
                guard childOwners.updateValue(operation.instanceID, forKey: child.instanceID) == nil else {
                    throw EngineError.validationFailed("instance \(child.instanceID) is a child of two operations")
                }
            }
        }

        let instanceIDs = Set(worlds.keys)
        var operands: [SceneSnapshot.Operand] = []
        if !operandRecords.isEmpty {
            let payload = try readPayload(directoryFD: directoryFD, name: Self.operandPayloadName)
            operands = try operandRecords.map { record in
                SceneSnapshot.Operand(
                    id: record.id,
                    mesh: try decodeMesh(
                        record.mesh, payload: payload, expectedPath: Self.operandPayloadName,
                        instanceIDs: instanceIDs
                    )
                )
            }
        }

        var mesh: SceneSnapshot.Mesh?
        if let meshDescriptor {
            guard meshDescriptor.path == Self.meshPayloadName else {
                throw EngineError.pathRejected(meshDescriptor.path)
            }
            let payload = try readPayload(directoryFD: directoryFD, name: Self.meshPayloadName)
            mesh = try decodeMesh(
                meshDescriptor, payload: payload, expectedPath: Self.meshPayloadName,
                instanceIDs: instanceIDs
            )
        }

        return SceneSnapshot(mesh: mesh, operands: operands, instances: instances, operations: operations,
                             propertiesOmitted: manifest.propertiesOmitted ?? false)
    }

    /// A span must name a file in the result table and fit inside its declared
    /// byte length, in the same raw-byte coordinates the digest covers.
    private func checkSpan(_ span: WireSpan, filesByID: [UInt32: FileRecord], context: String) throws {
        guard span.start <= span.end else {
            throw EngineError.validationFailed("\(context) span start exceeds end")
        }
        guard let file = filesByID[span.fileID] else {
            throw EngineError.validationFailed("\(context) span references unknown file \(span.fileID)")
        }
        guard span.end <= file.byteLength else {
            throw EngineError.validationFailed("\(context) span exceeds file \(span.fileID) length")
        }
    }

    // MARK: - Binary payloads

    private func readPayload(directoryFD: Int32, name: String) throws -> Data {
        let payload = try readJobFile(directoryFD: directoryFD, name: name, byteLimit: limits.payloadByteLimit)
        guard payload.count >= Self.payloadHeaderSize,
              Array(payload.prefix(Self.payloadMagic.count)) == Self.payloadMagic,
              readUInt32(payload, at: 8) == 1,
              readUInt32(payload, at: 12) == 0
        else {
            throw EngineError.payloadMalformed(name: name, detail: "bad magic or version")
        }
        return payload
    }

    private func decodeMesh(
        _ descriptor: MeshDescriptor,
        payload: Data,
        expectedPath: String,
        instanceIDs: Set<UInt32>
    ) throws -> SceneSnapshot.Mesh {
        // The descriptor path is validated, never opened: payloads always come
        // from the fixed job-relative names.
        guard descriptor.path == expectedPath else {
            throw EngineError.pathRejected(descriptor.path)
        }
        guard descriptor.vertexStride == 24, descriptor.indexStride == 4 else {
            throw EngineError.validationFailed("\(expectedPath) has an unsupported stride")
        }
        try requireLimit(descriptor.vertexCount, limit: limits.vertexLimit, name: "vertex")
        try requireLimit(descriptor.indexCount, limit: limits.indexLimit, name: "index")
        guard descriptor.indexCount % 3 == 0 else {
            throw EngineError.validationFailed("\(expectedPath) index count is not a triangle list")
        }

        let fileSize = UInt64(payload.count)
        try checkRegion(descriptor.vertexOffset, count: descriptor.vertexCount, stride: 24, fileSize: fileSize, path: expectedPath)
        try checkRegion(descriptor.indexOffset, count: descriptor.indexCount, stride: 4, fileSize: fileSize, path: expectedPath)

        guard descriptor.bounds.min.count == 3, descriptor.bounds.max.count == 3,
              descriptor.bounds.min.allSatisfy(\.isFinite), descriptor.bounds.max.allSatisfy(\.isFinite),
              zip(descriptor.bounds.min, descriptor.bounds.max).allSatisfy({ $0 <= $1 })
        else {
            throw EngineError.validationFailed("\(expectedPath) bounds are malformed")
        }
        if descriptor.vertexCount == 0 {
            guard descriptor.indexCount == 0 else {
                throw EngineError.validationFailed("\(expectedPath) indexes into zero vertices")
            }
        }

        let positions: [SIMD3<Double>] = payload.withUnsafeBytes { raw in
            var decoded = [SIMD3<Double>]()
            decoded.reserveCapacity(Int(descriptor.vertexCount))
            for index in 0..<Int(descriptor.vertexCount) {
                let base = Int(descriptor.vertexOffset) + index * 24
                decoded.append(SIMD3(
                    Self.loadDouble(raw, at: base),
                    Self.loadDouble(raw, at: base + 8),
                    Self.loadDouble(raw, at: base + 16)
                ))
            }
            return decoded
        }
        for (index, position) in positions.enumerated() {
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
                throw EngineError.validationFailed("\(expectedPath) position \(index) is not finite")
            }
            for axis in 0..<3 {
                let tolerance = Self.boundsEpsilon * max(1, abs(position[axis]))
                guard position[axis] >= descriptor.bounds.min[axis] - tolerance,
                      position[axis] <= descriptor.bounds.max[axis] + tolerance
                else {
                    throw EngineError.validationFailed("\(expectedPath) position \(index) escapes its bounds")
                }
            }
        }

        let indices: [UInt32] = payload.withUnsafeBytes { raw in
            var decoded = [UInt32]()
            decoded.reserveCapacity(Int(descriptor.indexCount))
            for index in 0..<Int(descriptor.indexCount) {
                decoded.append(Self.loadUInt32(raw, at: Int(descriptor.indexOffset) + index * 4))
            }
            return decoded
        }
        for (index, vertex) in indices.enumerated() where UInt64(vertex) >= descriptor.vertexCount {
            throw EngineError.validationFailed("\(expectedPath) index \(index) is out of range")
        }

        var owners: [UInt32]?
        if let ownerOffset = descriptor.ownerOffset {
            let triangleCount = descriptor.indexCount / 3
            try checkRegion(ownerOffset, count: triangleCount, stride: 4, fileSize: fileSize, path: expectedPath)
            let decoded: [UInt32] = payload.withUnsafeBytes { raw in
                var values = [UInt32]()
                values.reserveCapacity(Int(triangleCount))
                for index in 0..<Int(triangleCount) {
                    values.append(Self.loadUInt32(raw, at: Int(ownerOffset) + index * 4))
                }
                return values
            }
            for (index, owner) in decoded.enumerated()
            where owner != SceneSnapshot.Mesh.unknownOwner && !instanceIDs.contains(owner) {
                throw EngineError.validationFailed("\(expectedPath) owner \(index) is an unknown instance")
            }
            owners = decoded
        }

        return SceneSnapshot.Mesh(
            positions: positions,
            indices: indices,
            triangleOwners: owners,
            bounds: SceneSnapshot.BoundingBox(
                min: SIMD3(descriptor.bounds.min[0], descriptor.bounds.min[1], descriptor.bounds.min[2]),
                max: SIMD3(descriptor.bounds.max[0], descriptor.bounds.max[1], descriptor.bounds.max[2])
            )
        )
    }

    /// An occupied region must lie fully after the payload header and inside
    /// the file, computed without overflow.
    private func checkRegion(
        _ offset: UInt64, count: UInt64, stride: UInt64, fileSize: UInt64, path: String
    ) throws {
        guard count > 0 else { return }
        guard offset >= Self.payloadHeaderSize, offset <= fileSize,
              count <= (fileSize - offset) / stride
        else {
            throw EngineError.validationFailed("\(path) region at \(offset) is out of range")
        }
    }

    private func checkMatrix(_ matrix: [Double], context: String) throws {
        guard matrix.count == 16, matrix.allSatisfy(\.isFinite) else {
            throw EngineError.validationFailed("\(context) is not 16 finite values")
        }
    }

    /// Column-major 4x4 product: result[c*4+r] = sum_k a[k*4+r] * b[c*4+k].
    private func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                var sum = 0.0
                for k in 0..<4 { sum += a[k * 4 + row] * b[column * 4 + k] }
                result[column * 4 + row] = sum
            }
        }
        return result
    }

    private func matricesApproximatelyEqual(_ actual: [Double], _ expected: [Double]) -> Bool {
        zip(actual, expected).allSatisfy { value, reference in
            abs(value - reference) <= Self.matrixEpsilon * max(1, abs(reference))
        }
    }

    // MARK: - Files

    private func readJobFile(directoryFD: Int32, name: String, byteLimit: UInt64) throws -> Data {
        let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw EngineError.fileUnreadable(name: name, detail: Self.errnoDetail())
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw EngineError.fileUnreadable(name: name, detail: Self.errnoDetail())
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw EngineError.fileNotRegular(name: name)
        }
        guard status.st_size >= 0, UInt64(status.st_size) <= byteLimit else {
            throw EngineError.fileOversized(name: name)
        }

        var data = Data(count: Int(status.st_size))
        let consumed = data.withUnsafeMutableBytes { buffer -> Int in
            var total = 0
            while total < buffer.count {
                let read = pread(
                    descriptor, buffer.baseAddress!.advanced(by: total),
                    buffer.count - total, off_t(total)
                )
                guard read > 0 else { break }
                total += read
            }
            return total
        }
        guard consumed == data.count else {
            throw EngineError.fileUnreadable(name: name, detail: "short read")
        }
        return data
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in Self.loadUInt32(raw, at: offset) }
    }

    private static func loadUInt32(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    private static func loadDouble(_ raw: UnsafeRawBufferPointer, at offset: Int) -> Double {
        Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
    }

    private static func errnoDetail() -> String {
        String(cString: strerror(errno))
    }

    private func requireLimit(_ count: Int, limit: Int, name: String) throws {
        guard count <= limit else { throw EngineError.limitExceeded(name) }
    }

    private func requireLimit(_ count: UInt64, limit: UInt64, name: String) throws {
        guard count <= limit else { throw EngineError.limitExceeded(name) }
    }

    /// The semantic+formal pair that must stay unique within one instance.
    private struct PropertyKey: Hashable {
        let semantic: PropertyRecord.Semantic
        let formal: String
    }
}
