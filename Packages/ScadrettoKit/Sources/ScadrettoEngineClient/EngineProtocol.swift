import CryptoKit
import Foundation
import ScadrettoCore

public enum EngineError: Error, Equatable, LocalizedError, Sendable {
    case workerSignaled(Int32)
    case workerExit(Int32)
    case fileUnreadable(name: String, detail: String)
    case fileNotRegular(name: String)
    case fileOversized(name: String)
    case manifestMalformed(String)
    case payloadMalformed(name: String, detail: String)
    case pathRejected(String)
    case protocolMismatch
    case buildMismatch
    case internalError
    case identityMismatch(field: String)
    case statusContradiction(String)
    case limitExceeded(String)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .workerSignaled(let signal):
            "The engine worker ended on signal \(signal)."
        case .workerExit(let code):
            "The engine worker exited with status \(code)."
        case .fileUnreadable(let name, let detail):
            "The job file \(name) could not be read: \(detail)."
        case .fileNotRegular(let name):
            "The job file \(name) is not a regular file."
        case .fileOversized(let name):
            "The job file \(name) exceeds its size limit."
        case .manifestMalformed(let detail):
            "The worker manifest is malformed: \(detail)."
        case .payloadMalformed(let name, let detail):
            "The payload \(name) is malformed: \(detail)."
        case .pathRejected(let path):
            "The payload path \(path) is not an allowed job-relative name."
        case .protocolMismatch:
            "The worker reports a different protocol version."
        case .buildMismatch:
            "The worker build digest differs from the bundled executable."
        case .internalError:
            "The worker reported an internal error."
        case .identityMismatch(let field):
            "The result \(field) does not match the request."
        case .statusContradiction(let detail):
            "The worker result contradicts its termination: \(detail)."
        case .limitExceeded(let what):
            "The worker result exceeds the \(what) limit."
        case .validationFailed(let detail):
            "The worker result failed validation: \(detail)."
        }
    }
}

// The reason the engine child process ended, adapted from Process.TerminationReason.
public enum TerminationStatus: Equatable, Sendable {
    case exited(Int32)
    case uncaughtSignal(Int32)
}

/// Identity of one evaluated document state. Digests are lowercase SHA-256 hex
/// computed over the length-prefixed context fields listed in Engine/protocol.
public struct EvaluationKey: Codable, Equatable, Sendable {
    public let documentID: UUID
    public let sourceRevision: UInt64
    public let dependencyGeneration: UInt64
    public let resolutionDigest: String
    public let optionsDigest: String
    public let workerBuild: String

    public init(
        documentID: UUID,
        sourceRevision: UInt64,
        dependencyGeneration: UInt64,
        resolutionDigest: String,
        optionsDigest: String,
        workerBuild: String
    ) {
        self.documentID = documentID
        self.sourceRevision = sourceRevision
        self.dependencyGeneration = dependencyGeneration
        self.resolutionDigest = resolutionDigest
        self.optionsDigest = optionsDigest
        self.workerBuild = workerBuild
    }
}

/// Contents of request.json for one evaluation attempt (protocol version 1).
public struct EngineRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1
    public static let snapshotFileName = "main.scad"
    public static let defaultBackend = "manifold"

    public let protocolVersion: Int
    public let requestID: UUID
    public let key: EvaluationKey
    public let logicalPath: String
    public let untitledBaseDirectory: String?
    public let snapshot: String
    public let sourceSHA256: String
    public let libraryRoots: [String]
    public let resourceRoots: [String]
    public let preview: Bool
    public let backend: String
    public let expectedWorkerBuild: String

    public init(
        protocolVersion: Int,
        requestID: UUID,
        key: EvaluationKey,
        logicalPath: String,
        untitledBaseDirectory: String?,
        snapshot: String,
        sourceSHA256: String,
        libraryRoots: [String],
        resourceRoots: [String],
        preview: Bool,
        backend: String,
        expectedWorkerBuild: String
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.key = key
        self.logicalPath = logicalPath
        self.untitledBaseDirectory = untitledBaseDirectory
        self.snapshot = snapshot
        self.sourceSHA256 = sourceSHA256
        self.libraryRoots = libraryRoots
        self.resourceRoots = resourceRoots
        self.preview = preview
        self.backend = backend
        self.expectedWorkerBuild = expectedWorkerBuild
    }

    /// Builds a v1 request for a final ($preview = false) evaluation of an
    /// immutable source snapshot. A fresh requestID is minted per call so a
    /// superseded or cancelled job can never match a newer attempt.
    public static func make(
        snapshot: SourceSnapshot,
        logicalPath: String,
        untitledBaseDirectory: String? = nil,
        libraryRoots: [String] = [],
        resourceRoots: [String] = [],
        dependencyGeneration: UInt64,
        workerBuild: String,
        requestID: UUID = UUID()
    ) throws -> EngineRequest {
        guard logicalPath.hasPrefix("/") else {
            throw EngineError.validationFailed("logicalPath must be absolute")
        }
        if let untitledBaseDirectory, !untitledBaseDirectory.hasPrefix("/") {
            throw EngineError.validationFailed("untitledBaseDirectory must be absolute")
        }
        for root in libraryRoots + resourceRoots where !root.hasPrefix("/") {
            throw EngineError.validationFailed("root must be absolute: \(root)")
        }
        guard workerBuild.isSHA256HexDigest else {
            throw EngineError.validationFailed("workerBuild must be a lowercase SHA-256 digest")
        }

        let backend = Self.defaultBackend
        let resolutionDigest = Self.contextDigest(
            ["resolution-v1", logicalPath, untitledBaseDirectory ?? "", String(libraryRoots.count)]
                + libraryRoots + [String(resourceRoots.count)] + resourceRoots
        )
        let optionsDigest = Self.contextDigest(["options-v1", backend, "false"])
        let key = EvaluationKey(
            documentID: snapshot.documentID,
            sourceRevision: snapshot.revision,
            dependencyGeneration: dependencyGeneration,
            resolutionDigest: resolutionDigest,
            optionsDigest: optionsDigest,
            workerBuild: workerBuild
        )
        return EngineRequest(
            protocolVersion: Self.currentProtocolVersion,
            requestID: requestID,
            key: key,
            logicalPath: logicalPath,
            untitledBaseDirectory: untitledBaseDirectory,
            snapshot: Self.snapshotFileName,
            sourceSHA256: snapshot.buffer.sha256,
            libraryRoots: libraryRoots,
            resourceRoots: resourceRoots,
            preview: false,
            backend: backend,
            expectedWorkerBuild: workerBuild
        )
    }

    /// Each field contributes its decimal UTF-8 byte length, an ASCII colon,
    /// then its exact UTF-8 bytes, concatenated in order and hashed once.
    static func contextDigest(_ fields: [String]) -> String {
        var bytes: [UInt8] = []
        for field in fields {
            let utf8 = Array(field.utf8)
            bytes.append(contentsOf: Array("\(utf8.count):".utf8))
            bytes.append(contentsOf: utf8)
        }
        return SHA256.hash(data: bytes).hexString
    }
}

/// A byte span in a result file's original bytes, including any BOM.
public struct WireSpan: Codable, Equatable, Sendable {
    public let fileID: UInt32
    public let start: UInt64
    public let end: UInt64

    public init(fileID: UInt32, start: UInt64, end: UInt64) {
        self.fileID = fileID
        self.start = start
        self.end = end
    }
}

public enum FileKind: String, Codable, Sendable {
    case main
    case include
    case use
    case `import`
    case surface
    case dxf
    case font
}

public struct FileRecord: Codable, Equatable, Sendable {
    public let id: UInt32
    public let logicalPath: String
    public let resolvedPath: String?
    public let sha256: String
    public let byteLength: UInt64
    public let kind: FileKind
    public let writable: Bool

    public init(
        id: UInt32,
        logicalPath: String,
        resolvedPath: String?,
        sha256: String,
        byteLength: UInt64,
        kind: FileKind,
        writable: Bool
    ) {
        self.id = id
        self.logicalPath = logicalPath
        self.resolvedPath = resolvedPath
        self.sha256 = sha256
        self.byteLength = byteLength
        self.kind = kind
        self.writable = writable
    }
}

public enum DiagnosticSeverity: String, Codable, Sendable {
    case error
    case warning
    case deprecated
    case unknown
}

public struct EngineDiagnostic: Codable, Equatable, Sendable {
    public let severity: DiagnosticSeverity
    public let message: String
    public let fileID: UInt32?
    public let span: WireSpan?
    /// Instance IDs from the outermost call inward; empty when not reported.
    public let callPath: [UInt32]
    public let repeatCount: UInt64

    public init(
        severity: DiagnosticSeverity,
        message: String,
        fileID: UInt32?,
        span: WireSpan?,
        callPath: [UInt32],
        repeatCount: UInt64
    ) {
        self.severity = severity
        self.message = message
        self.fileID = fileID
        self.span = span
        self.callPath = callPath
        self.repeatCount = repeatCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        severity = try container.decode(DiagnosticSeverity.self, forKey: .severity)
        message = try container.decode(String.self, forKey: .message)
        fileID = try container.decodeIfPresent(UInt32.self, forKey: .fileID)
        span = try container.decodeIfPresent(WireSpan.self, forKey: .span)
        callPath = try container.decodeIfPresent([UInt32].self, forKey: .callPath) ?? []
        repeatCount = try container.decodeIfPresent(UInt64.self, forKey: .repeatCount) ?? 0
    }
}

public struct ConsoleMessage: Codable, Equatable, Sendable {
    public let group: String
    public let text: String
    public let fileID: UInt32?
    public let span: WireSpan?
    public let callPath: [UInt32]

    public init(
        group: String,
        text: String,
        fileID: UInt32?,
        span: WireSpan?,
        callPath: [UInt32]
    ) {
        self.group = group
        self.text = text
        self.fileID = fileID
        self.span = span
        self.callPath = callPath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        group = try container.decode(String.self, forKey: .group)
        text = try container.decode(String.self, forKey: .text)
        fileID = try container.decodeIfPresent(UInt32.self, forKey: .fileID)
        span = try container.decodeIfPresent(WireSpan.self, forKey: .span)
        callPath = try container.decodeIfPresent([UInt32].self, forKey: .callPath) ?? []
    }
}

/// A binary mesh range inside a payload file, as declared in result.json.
/// Offsets are byte offsets from the start of the named payload file.
public struct MeshDescriptor: Codable, Equatable, Sendable {
    public enum PositionType: String, Codable, Sendable {
        case float64
    }

    public enum IndexType: String, Codable, Sendable {
        case uint32
    }

    public enum Winding: String, Codable, Sendable {
        case ccw
    }

    public struct Bounds: Codable, Equatable, Sendable {
        public let min: [Double]
        public let max: [Double]

        public init(min: [Double], max: [Double]) {
            self.min = min
            self.max = max
        }
    }

    public let path: String
    public let vertexOffset: UInt64
    public let vertexCount: UInt64
    public let vertexStride: UInt64
    public let positionType: PositionType
    public let indexOffset: UInt64
    public let indexCount: UInt64
    public let indexStride: UInt64
    public let indexType: IndexType
    public let winding: Winding
    public let bounds: Bounds
    public let ownerOffset: UInt64?

    public init(
        path: String,
        vertexOffset: UInt64,
        vertexCount: UInt64,
        vertexStride: UInt64,
        positionType: PositionType,
        indexOffset: UInt64,
        indexCount: UInt64,
        indexStride: UInt64,
        indexType: IndexType,
        winding: Winding,
        bounds: Bounds,
        ownerOffset: UInt64?
    ) {
        self.path = path
        self.vertexOffset = vertexOffset
        self.vertexCount = vertexCount
        self.vertexStride = vertexStride
        self.positionType = positionType
        self.indexOffset = indexOffset
        self.indexCount = indexCount
        self.indexStride = indexStride
        self.indexType = indexType
        self.winding = winding
        self.bounds = bounds
        self.ownerOffset = ownerOffset
    }
}

/// One executed call-tree occurrence. `local` and `world` are 16-element
/// column-major affine matrices, right-handed Z up, `world = parent x local`.
public struct InstanceRecord: Codable, Equatable, Sendable {
    public let id: UInt32
    public let parent: UInt32?
    public let name: String
    public let span: WireSpan?
    public let iteration: [String: Double]
    public let local: [Double]
    public let world: [Double]
    public let operand: UInt32?
    public let diameter: DiameterRecord?

    public init(
        id: UInt32,
        parent: UInt32?,
        name: String,
        span: WireSpan?,
        iteration: [String: Double],
        local: [Double],
        world: [Double],
        operand: UInt32?,
        diameter: DiameterRecord?
    ) {
        self.id = id
        self.parent = parent
        self.name = name
        self.span = span
        self.iteration = iteration
        self.local = local
        self.world = world
        self.operand = operand
        self.diameter = diameter
    }
}

public struct DiameterRecord: Codable, Equatable, Sendable {
    public let value: Double
    public let chain: [ChainLink]

    public init(value: Double, chain: [ChainLink]) {
        self.value = value
        self.chain = chain
    }
}

public struct ChainLink: Codable, Equatable, Sendable {
    public let kind: String
    public let name: String
    public let span: WireSpan?

    public init(kind: String, name: String, span: WireSpan?) {
        self.kind = kind
        self.name = name
        self.span = span
    }
}

public enum OperationRole: String, Codable, Sendable {
    case positive
    case subtracted
    case intersection
}

/// Ordered operand roles of one union, difference or intersection instance.
public struct OperationRecord: Codable, Equatable, Sendable {
    public struct Child: Codable, Equatable, Sendable {
        public let instanceID: UInt32
        public let role: OperationRole

        public init(instanceID: UInt32, role: OperationRole) {
            self.instanceID = instanceID
            self.role = role
        }
    }

    public let instanceID: UInt32
    public let children: [Child]

    public init(instanceID: UInt32, children: [Child]) {
        self.instanceID = instanceID
        self.children = children
    }
}

public struct DependencyEdge: Codable, Equatable, Sendable {
    public let span: WireSpan
    public let instanceID: UInt32
    public let property: String

    public init(span: WireSpan, instanceID: UInt32, property: String) {
        self.span = span
        self.instanceID = instanceID
        self.property = property
    }
}

public struct LookupRecord: Codable, Equatable, Sendable {
    public let requestingFileID: UInt32?
    public let name: String
    public let candidates: [String]
    public let winner: String?
    public let resolvedWinner: String?

    public init(requestingFileID: UInt32?, name: String, candidates: [String], winner: String?,
                resolvedWinner: String? = nil) {
        self.requestingFileID = requestingFileID
        self.name = name
        self.candidates = candidates
        self.winner = winner
        self.resolvedWinner = resolvedWinner
    }
}

/// The validated, immutable geometry and trace of one accepted result.
/// Final positions are world-space doubles; operand positions are local.
public struct SceneSnapshot: Equatable, Sendable {
    public struct BoundingBox: Equatable, Sendable {
        public let min: SIMD3<Double>
        public let max: SIMD3<Double>

        public init(min: SIMD3<Double>, max: SIMD3<Double>) {
            self.min = min
            self.max = max
        }
    }

    public struct Mesh: Equatable, Sendable {
        public static let unknownOwner: UInt32 = 0xFFFF_FFFF

        public let positions: [SIMD3<Double>]
        public let indices: [UInt32]
        /// One owner instance ID per triangle, or nil when the backend sent no
        /// owner table. `unknownOwner` marks unowned triangles.
        public let triangleOwners: [UInt32]?
        public let bounds: BoundingBox

        public init(
            positions: [SIMD3<Double>],
            indices: [UInt32],
            triangleOwners: [UInt32]?,
            bounds: BoundingBox
        ) {
            self.positions = positions
            self.indices = indices
            self.triangleOwners = triangleOwners
            self.bounds = bounds
        }
    }

    public struct Operand: Equatable, Sendable {
        public let id: UInt32
        public let mesh: Mesh

        public init(id: UInt32, mesh: Mesh) {
            self.id = id
            self.mesh = mesh
        }
    }

    /// The final world-space mesh, nil for a valid empty scene.
    public let mesh: Mesh?
    /// Operand meshes in manifest order, shared by instances via `operand`.
    public let operands: [Operand]
    /// Instances in the worker's executed order; parents always precede children.
    public let instances: [InstanceRecord]
    public let operations: [OperationRecord]

    public init(
        mesh: Mesh?,
        operands: [Operand],
        instances: [InstanceRecord],
        operations: [OperationRecord]
    ) {
        self.mesh = mesh
        self.operands = operands
        self.instances = instances
        self.operations = operations
    }

    public func operandMesh(for id: UInt32) -> Mesh? {
        operands.first { $0.id == id }?.mesh
    }
}

/// The non-geometry tables every accepted manifest carries, including error
/// manifests, which still report dependencies observed before failure.
public struct EvaluationResult: Equatable, Sendable {
    public let requestID: UUID
    public let key: EvaluationKey
    public let workerBuild: String
    public let files: [FileRecord]
    public let diagnostics: [EngineDiagnostic]
    public let console: [ConsoleMessage]
    public let droppedConsoleMessages: UInt64
    public let dependencyEdges: [DependencyEdge]
    public let lookups: [LookupRecord]
    /// Validated scene tables; nil on model error or unsupported dimension.
    public let scene: SceneSnapshot?

    public init(
        requestID: UUID,
        key: EvaluationKey,
        workerBuild: String,
        files: [FileRecord],
        diagnostics: [EngineDiagnostic],
        console: [ConsoleMessage],
        droppedConsoleMessages: UInt64,
        dependencyEdges: [DependencyEdge],
        lookups: [LookupRecord],
        scene: SceneSnapshot?
    ) {
        self.requestID = requestID
        self.key = key
        self.workerBuild = workerBuild
        self.files = files
        self.diagnostics = diagnostics
        self.console = console
        self.droppedConsoleMessages = droppedConsoleMessages
        self.dependencyEdges = dependencyEdges
        self.lookups = lookups
        self.scene = scene
    }
}

/// The only result a caller may act on: exit 0 with `ok`, or exit 1 with a
/// validated model error or unsupported-dimension manifest.
public enum EvaluationOutcome: Equatable, Sendable {
    case rendered(EvaluationResult)
    case empty(EvaluationResult)
    case modelError(EvaluationResult)
    case unsupportedDimension(EvaluationResult)

    public var result: EvaluationResult {
        switch self {
        case .rendered(let result), .empty(let result),
             .modelError(let result), .unsupportedDimension(let result):
            result
        }
    }

    public var scene: SceneSnapshot? { result.scene }
}

extension String {
    var isSHA256HexDigest: Bool {
        count == 64 && allSatisfy { character in
            character.isASCII && (character.isNumber || ("a"..."f").contains(character))
        }
    }
}

extension Sequence where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
