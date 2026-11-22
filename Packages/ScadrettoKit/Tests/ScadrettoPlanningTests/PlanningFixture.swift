import Foundation
import ScadrettoCore
import ScadrettoEngineClient
import ScadrettoSyntax
import Testing

/// A hand-written executed scene over real source bytes and real syntax.
struct PlanningFixture {
    let snapshot: SourceSnapshot
    let syntax: SyntaxSnapshot
    let result: EvaluationResult
    let scene: SceneSnapshot

    var byID: [UInt32: InstanceRecord] {
        Dictionary(uniqueKeysWithValues: scene.instances.map { ($0.id, $0) })
    }

    @MainActor
    static func make(_ source: String, instances: [InstanceRecord], operations: [OperationRecord] = [],
                     propertiesOmitted: Bool = false) async throws -> PlanningFixture {
        let document = SourceDocument(buffer: try SourceBuffer(bytes: Data(source.utf8)))
        let snapshot = document.snapshot
        let scene = SceneSnapshot(mesh: nil, operands: [], instances: instances, operations: operations,
                                  propertiesOmitted: propertiesOmitted)
        let key = EvaluationKey(documentID: snapshot.documentID, sourceRevision: snapshot.revision,
                                dependencyGeneration: 0, resolutionDigest: "", optionsDigest: "", workerBuild: "")
        let file = FileRecord(id: 0, logicalPath: "/fixture.scad", resolvedPath: nil, sha256: snapshot.buffer.sha256,
                              byteLength: UInt64(snapshot.buffer.bytes.count), kind: .main, writable: true)
        let result = EvaluationResult(requestID: UUID(), key: key, workerBuild: "", files: [file], diagnostics: [],
                                      console: [], droppedConsoleMessages: 0, dependencyEdges: [], lookups: [],
                                      scene: scene)
        return PlanningFixture(snapshot: snapshot, syntax: try await SyntaxParser().parse(snapshot),
                               result: result, scene: scene)
    }
}

/// The span of `needle`, or of `part` inside that occurrence.
func span(_ needle: String, _ part: String? = nil, in source: String) -> WireSpan {
    let bytes = Data(source.utf8)
    var found = bytes.range(of: Data(needle.utf8))!
    if let part { found = bytes.range(of: Data(part.utf8), options: .backwards, in: found)! }
    return WireSpan(fileID: 0, start: UInt64(found.lowerBound), end: UInt64(found.upperBound))
}

func instance(_ id: UInt32, _ name: String, parent: UInt32? = nil, at span: WireSpan? = nil,
              operand: UInt32? = nil, definition: WireSpan? = nil, iteration: [String: Double] = [:],
              properties: [PropertyRecord]? = nil, opaque: Bool = false) -> InstanceRecord {
    let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    return InstanceRecord(id: id, parent: parent, name: name, span: span, iteration: iteration, local: identity,
                          world: identity, operand: operand, diameter: nil, definitionSpan: definition,
                          properties: properties, opaqueFrame: opaque)
}

func literal(_ semantic: PropertyRecord.Semantic, _ formal: String, _ value: Double, at span: WireSpan,
             drag: Bool = true) -> PropertyRecord {
    PropertyRecord(semantic: semantic, formal: formal, status: .bound, value: value, displayMultiplier: 1,
                   centered: false, expression: span,
                   chain: [ChainLink(kind: "argument", name: "", span: span),
                           ChainLink(kind: "literal", name: "", span: span)],
                   inputs: [span], impactComplete: true, dragVerified: drag, pitch: nil)
}

func expression(_ semantic: PropertyRecord.Semantic, _ formal: String, _ value: Double, at span: WireSpan,
                inputs: [WireSpan] = []) -> PropertyRecord {
    PropertyRecord(semantic: semantic, formal: formal, status: .bound, value: value, displayMultiplier: 1,
                   centered: false, expression: span, chain: [ChainLink(kind: "divide", name: "", span: span)],
                   inputs: inputs, pitch: nil)
}
