import Foundation
import ScadrettoCore
import ScadrettoEngineClient
import ScadrettoSyntax
import ScadrettoTestSupport
import ScadrettoViewport
import Testing
import simd

@Test @MainActor func plateBindingResolvesThirdCutterAndPlansCheckedPatch() async throws {
    let plate = try await PlateGolden.load()
    let document = plate.document
    let snapshot = plate.snapshot
    let result = plate.result

    // The original third cutter carries iteration i == 2 in the engine trace.
    let scene = try #require(result.scene)
    let cutters = scene.instances.filter { $0.name == "cylinder" }
    #expect(cutters.map(\.id) == [7, 10, 13, 16])
    #expect(cutters.map { $0.iteration["i"] } == [0, 1, 2, 3])
    let expected = try #require(cutters.first { $0.iteration["i"] == 2 })
    let final = try #require(scene.mesh)
    #expect(final.triangleOwners == nil)
    let mesh = ViewportMesh(positions: final.positions, indices: final.indices)
    let operandMeshes = Dictionary(uniqueKeysWithValues: scene.operands.map {
        ($0.id, ViewportMesh(positions: $0.mesh.positions, indices: $0.mesh.indices))
    })
    let occurrences = scene.instances.compactMap { instance -> ViewportOperand? in
        guard let meshID = instance.operand else { return nil }
        func column(_ index: Int) -> SIMD4<Double> {
            SIMD4(instance.world[index], instance.world[index + 1], instance.world[index + 2], instance.world[index + 3])
        }
        let world = simd_double4x4(columns: (column(0), column(4), column(8), column(12)))
        return ViewportOperand(id: instance.id, meshID: meshID, world: world, isSubtracted: instance.name == "cylinder")
    }
    let picker = try #require(ViewportPicker(mesh: mesh, owners: final.triangleOwners,
                                           operandMeshes: operandMeshes, occurrences: occurrences))
    let ray = ViewportRay(origin: SIMD3(expected.world[12], expected.world[13], 3),
                          direction: SIMD3(cos(0.041), sin(0.041), 0))
    let hit = try #require(picker.pick(along: ray))
    #expect(hit.candidates == [expected.id])
    #expect(hit.hit.distance > 1.99 && hit.hit.distance < 2)
    #expect(simd_dot(hit.hit.normal, ray.direction) < -0.99)
    let pickedID = try #require(hit.candidates.first)

    let target = try result.diameterTarget(for: pickedID, in: snapshot)
    #expect(target.span.bytes == 74..<75)
    #expect(target.span.fileID == snapshot.documentID)
    #expect(target.scope == .parameter("hole_d"))
    #expect(target.value == 4)
    #expect(target.affectedInstances == [7, 10, 13, 16])

    let syntax = try await SyntaxParser().parse(snapshot)
    let token = try #require(syntax.ranges.first { $0.kind == .number && $0.range == target.span.bytes })
    let literal = try DiameterLiteral(source: snapshot, span: target.span,
                                      numericToken: token.range, value: target.value)
    let edit = try #require(try literal.edit(setting: 5, in: snapshot))
    #expect(edit == SourceEdit(range: 74..<75,
                               expected: Data("4".utf8), replacement: Data("5".utf8)))

    // The checked patch applies through the document transaction and round-trips.
    let inverse = try document.apply(document.transaction(edits: [edit], label: "hole diameter"))
    #expect(document.buffer.bytes.subdata(in: 74..<75) == Data("5".utf8))
    #expect(inverse == [SourceEdit(range: 74..<75,
                                  expected: Data("5".utf8), replacement: Data("4".utf8))])

    // Binding and literal both refuse the superseded snapshot.
    #expect(throws: DiameterBindingError.staleSource) {
        try result.diameterTarget(for: pickedID, in: document.snapshot)
    }
    #expect(throws: DiameterEditError.staleSource) {
        try literal.edit(setting: 6, in: document.snapshot)
    }
}

@Test @MainActor func equalValuedLiteralsEditDistinctSpans() throws {
    // Equal values at different byte ranges are independent checked targets.
    let document = SourceDocument(buffer: try SourceBuffer(bytes: Data("hole_d = 4;\npin_d = 4;\n".utf8)))
    let snapshot = document.snapshot
    let first = try DiameterLiteral(source: snapshot, span: snapshot.span(for: 9..<10),
                                    numericToken: 9..<10, value: 4)
    let second = try DiameterLiteral(source: snapshot, span: snapshot.span(for: 20..<21),
                                     numericToken: 20..<21, value: 4)

    let firstEdit = try #require(try first.edit(setting: 5, in: snapshot))
    let secondEdit = try #require(try second.edit(setting: 7, in: snapshot))
    #expect(firstEdit == SourceEdit(range: 9..<10,
                                    expected: Data("4".utf8), replacement: Data("5".utf8)))
    #expect(secondEdit == SourceEdit(range: 20..<21,
                                     expected: Data("4".utf8), replacement: Data("7".utf8)))

    // One transaction rewrites each token and preserves every other byte.
    try document.apply(document.transaction(edits: [firstEdit, secondEdit], label: "diameters"))
    #expect(document.buffer.bytes == Data("hole_d = 5;\npin_d = 7;\n".utf8))
}

@Test @MainActor func literalPlannerRejectsUnverifiedInvalidAndStale() throws {
    let document = SourceDocument(buffer: try SourceBuffer(bytes: Data("hole_d = 4;\n".utf8)))
    let snapshot = document.snapshot
    let span = try snapshot.span(for: 9..<10)
    let literal = try DiameterLiteral(source: snapshot, span: span, numericToken: 9..<10, value: 4)

    // The token must spell the claimed value.
    #expect(throws: DiameterEditError.unverifiedLiteral) {
        try DiameterLiteral(source: snapshot, span: span, numericToken: 9..<10, value: 8)
    }
    // A span not minted by this snapshot cannot be verified.
    let foreign = SourceSpan(fileID: UUID(), contentDigest: span.contentDigest, bytes: 9..<10)
    #expect(throws: DiameterEditError.staleSource) {
        try DiameterLiteral(source: snapshot, span: foreign, numericToken: 9..<10, value: 4)
    }

    // Only positive diameters may be written; the same value produces no edit.
    #expect(throws: DiameterEditError.invalidDiameter) {
        try literal.edit(setting: 0, in: snapshot)
    }
    #expect(throws: DiameterEditError.invalidDiameter) {
        try literal.edit(setting: -2, in: snapshot)
    }
    #expect(try literal.edit(setting: 4, in: snapshot) == nil)

    // A revision the literal did not capture is stale.
    let edit = try #require(try literal.edit(setting: 5, in: snapshot))
    try document.apply(document.transaction(edits: [edit], label: "diameter"))
    #expect(throws: DiameterEditError.staleSource) {
        try literal.edit(setting: 6, in: document.snapshot)
    }
}
