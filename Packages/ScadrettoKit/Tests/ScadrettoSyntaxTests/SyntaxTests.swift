import Foundation
import ScadrettoCore
import Testing
@testable import ScadrettoSyntax

@Test @MainActor func canonicalRangesAgreeWithWorkerTrace() async throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let raw = try Data(contentsOf: root.appending(path: "Tests/Fixtures/mounting-plate.scad"))
    let document = SourceDocument(buffer: try SourceBuffer(bytes: raw))
    let parser = SyntaxParser()
    let syntax = try await parser.parse(document.snapshot)
    #expect(syntax.documentID == document.id)
    #expect(syntax.revision == 0)
    #expect(syntax.ranges.contains { $0.range == 74..<75 && $0.kind == .number })
    #expect(!syntax.ranges.contains { $0.kind == .error })
    let cylinder = try #require(syntax.calls.first { raw.subdata(in: $0.name) == Data("cylinder".utf8) })
    #expect(cylinder.call == 153..<185)
    #expect(raw.subdata(in: cylinder.call) == Data("cylinder(h = plate_h + 2, d = d)".utf8))
}

@Test @MainActor func bomAndMalformedSourceKeepOriginalCoordinates() async throws {
    let raw = Data("\u{FEFF}// 🔧 comment\r\nsize = 4;\r\ncube(size);\nmodule broken(\n".utf8)
    let buffer = try SourceBuffer(bytes: raw)
    let document = SourceDocument(buffer: buffer)
    let parser = SyntaxParser()
    let syntax = try await parser.parse(document.snapshot)
    let comment = try #require(syntax.ranges.first { $0.kind == .comment })
    #expect(comment.range.lowerBound == 3)
    #expect(raw.subdata(in: comment.range).starts(with: "// 🔧".utf8))
    #expect(syntax.ranges.contains { $0.kind == .number && raw.subdata(in: $0.range) == Data("4".utf8) })
    #expect(syntax.calls.contains { raw.subdata(in: $0.name) == Data("cube".utf8) })
    #expect(syntax.ranges.contains { $0.kind == .error })
    try document.reload(buffer)
    let updated = try await parser.parse(document.snapshot)
    #expect(updated.revision == 1)
}

@Test @MainActor func acceptsEmptyDocuments() async throws {
    let document = SourceDocument(buffer: try SourceBuffer())
    let result = try await SyntaxParser().parse(document.snapshot)
    #expect(result.ranges.isEmpty)
    #expect(result.calls.isEmpty)
}
