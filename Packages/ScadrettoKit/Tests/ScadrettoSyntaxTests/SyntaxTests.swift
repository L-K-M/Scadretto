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

// MARK: - M4: expression spans and translate-prefix anchors

@MainActor private func parsed(_ source: String) async throws -> (bytes: Data, syntax: SyntaxSnapshot) {
    let bytes = Data(source.utf8)
    let document = SourceDocument(buffer: try SourceBuffer(bytes: bytes))
    return (bytes, try await SyntaxParser().parse(document.snapshot))
}

private func span(of needle: String, in bytes: Data) -> Range<Int> {
    let match = bytes.range(of: Data(needle.utf8))!
    return match.lowerBound..<match.upperBound
}

@MainActor private func anchored(_ source: String, call needle: String, name: String = "cube") async throws
    -> (bytes: Data, anchor: SyntaxPrefixAnchor) {
    let (bytes, syntax) = try await parsed(source)
    let anchor = syntax.translatePrefixAnchor(call: span(of: needle, in: bytes), name: name, in: bytes)
    return (bytes, try anchor.get())
}

@Test @MainActor func prefixAnchorInsertsAtCallStart() async throws {
    let (bytes, anchor) = try await anchored("cube(8);", call: "cube(8)")
    #expect(anchor.insertionPoint == 0)
    #expect(anchor.statement == span(of: "cube(8);", in: bytes))
    var patched = bytes
    patched.replaceSubrange(anchor.insertionPoint..<anchor.insertionPoint, with: Data("translate([2, 0, 0]) ".utf8))
    #expect(patched == Data("translate([2, 0, 0]) cube(8);".utf8))
    // The prefix planner keeps bytes adjacent to the insertion point as a
    // nonempty expected-bytes guard, so the point must sit inside the span.
    #expect(anchor.statement.contains(anchor.insertionPoint))
    #expect(!anchor.statement.isEmpty)
    #expect(bytes.subdata(in: anchor.statement) == Data("cube(8);".utf8))
}

@Test @MainActor func prefixAnchorFollowsVerifiedModifiers() async throws {
    // Plan file 02: `!cube(8);` becomes `!translate([2, 0, 0]) cube(8);`.
    for (source, modifiers, expected) in [
        ("!cube(8);", "!", "!translate([2, 0, 0]) cube(8);"),
        ("#cube(8);", "#", "#translate([2, 0, 0]) cube(8);"),
        ("!#cube(8);", "!#", "!#translate([2, 0, 0]) cube(8);"),
        ("#! cube(8);", "#!", "#! translate([2, 0, 0]) cube(8);"),
    ] {
        let (bytes, syntax) = try await parsed(source)
        let anchor = try syntax.translatePrefixAnchor(
            call: span(of: "cube(8)", in: bytes), name: "cube", in: bytes).get()
        let call = try #require(syntax.calls.first)
        #expect(call.modifiers == Data(modifiers.utf8))
        #expect(anchor.insertionPoint == span(of: "cube", in: bytes).lowerBound)
        #expect(anchor.statement == 0..<bytes.count)
        var patched = bytes
        patched.replaceSubrange(anchor.insertionPoint..<anchor.insertionPoint, with: Data("translate([2, 0, 0]) ".utf8))
        #expect(patched == Data(expected.utf8))
    }
}

@Test @MainActor func prefixAnchorPreservesModifierTrivia() async throws {
    let (bytes, anchor) = try await anchored("! /*a*/ # // b\ncube(8);", call: "cube(8)")
    #expect(anchor.insertionPoint == span(of: "cube", in: bytes).lowerBound)
    #expect(bytes.subdata(in: anchor.statement) == Data("! /*a*/ # // b\ncube(8);".utf8))
    var patched = bytes
    patched.replaceSubrange(anchor.insertionPoint..<anchor.insertionPoint, with: Data("translate([2, 0, 0]) ".utf8))
    #expect(patched == Data("! /*a*/ # // b\ntranslate([2, 0, 0]) cube(8);".utf8))
}

@Test @MainActor func prefixAnchorRejectsDisabledModifiers() async throws {
    for source in ["%cube(8);", "*cube(8);", "!%cube(8);", "#*cube(8);"] {
        let (bytes, syntax) = try await parsed(source)
        #expect(syntax.translatePrefixAnchor(call: span(of: "cube(8)", in: bytes), name: "cube", in: bytes)
            == .failure(.disabledOrBackground))
    }
}

@Test @MainActor func prefixAnchorRequiresLoneSemicolonTail() async throws {
    let (bytes, syntax) = try await parsed("translate([10,0,0]) cube(8);")
    #expect(syntax.translatePrefixAnchor(call: span(of: "translate([10,0,0])", in: bytes), name: "translate", in: bytes)
        == .failure(.notStandalone))
    let anchor = try syntax.translatePrefixAnchor(call: span(of: "cube(8)", in: bytes), name: "cube", in: bytes).get()
    #expect(bytes.subdata(in: anchor.statement) == Data("cube(8);".utf8))

    let nested = try await parsed("difference() { cube(8); }")
    #expect(nested.syntax.translatePrefixAnchor(call: span(of: "difference()", in: nested.bytes), name: "difference", in: nested.bytes)
        == .failure(.notStandalone))
    _ = try nested.syntax.translatePrefixAnchor(call: span(of: "cube(8)", in: nested.bytes), name: "cube", in: nested.bytes).get()

    let chained = try await parsed("cube(8) sphere(1);")
    #expect(chained.syntax.translatePrefixAnchor(call: span(of: "cube(8)", in: chained.bytes), name: "cube", in: chained.bytes)
        == .failure(.notStandalone))
    _ = try chained.syntax.translatePrefixAnchor(call: span(of: "sphere(1)", in: chained.bytes), name: "sphere", in: chained.bytes).get()

    // A missing `;` is a zero-width error token at the statement boundary.
    let missing = try await parsed("translate([1,0,0])")
    #expect(missing.syntax.translatePrefixAnchor(call: span(of: "translate([1,0,0])", in: missing.bytes), name: "translate", in: missing.bytes)
        == .failure(.parseError))
}

@Test @MainActor func prefixAnchorChecksCallSpanAndName() async throws {
    let (bytes, syntax) = try await parsed("x = f(3);\ncube(8);\n")
    #expect(syntax.translatePrefixAnchor(call: span(of: "f(3)", in: bytes), name: "f", in: bytes)
        == .failure(.unknownCall))
    #expect(syntax.translatePrefixAnchor(call: span(of: "cube(8)", in: bytes), name: "sphere", in: bytes)
        == .failure(.nameMismatch))
    #expect(syntax.translatePrefixAnchor(call: 0..<4, name: "cube", in: bytes) == .failure(.unknownCall))
    // The same call span is still reachable under its own callee name.
    _ = try syntax.translatePrefixAnchor(call: span(of: "cube(8)", in: bytes), name: "cube", in: bytes).get()
}

@Test @MainActor func prefixAnchorRejectsParseErrorsCrossingTheStatement() async throws {
    let (bytes, syntax) = try await parsed("cube(8)")
    #expect(syntax.translatePrefixAnchor(call: span(of: "cube(8)", in: bytes), name: "cube", in: bytes)
        == .failure(.parseError))

    // An error in a *later* statement does not block the clean candidate.
    let later = try await parsed("cube(8);\n@@@\n")
    _ = try later.syntax.translatePrefixAnchor(call: span(of: "cube(8)", in: later.bytes), name: "cube", in: later.bytes).get()
}

@Test @MainActor func expressionSpansConfirmNestedArithmeticAndCommentBoundaries() async throws {
    let (bytes, syntax) = try await parsed("translate([x0 + i * pitch /*step*/, 20, -1]) sphere(1);")
    #expect(syntax.containsExpression(span(of: "x0 + i * pitch", in: bytes)))
    #expect(syntax.containsExpression(span(of: "i * pitch", in: bytes)))
    #expect(syntax.containsExpression(span(of: "x0", in: bytes)))
    #expect(syntax.containsExpression(span(of: "-1", in: bytes)))
    #expect(syntax.containsExpression(span(of: "[x0 + i * pitch /*step*/, 20, -1]", in: bytes)))
    #expect(syntax.containsExpression(span(of: "1)", in: bytes).lowerBound..<span(of: "1)", in: bytes).lowerBound + 1))
    #expect(!syntax.containsExpression(span(of: "x0 + i", in: bytes)))
    #expect(!syntax.containsExpression(span(of: "x0 + i * pitch /*step*/", in: bytes)))
    #expect(!syntax.containsExpression(span(of: "pitch /*step*/", in: bytes)))
    #expect(!syntax.containsExpression(span(of: "translate", in: bytes)))
    #expect(!syntax.containsExpression(span(of: "sphere(1)", in: bytes)))
    // Wrong spans, off by one either way, are not confirmed.
    let expr = span(of: "i * pitch", in: bytes)
    #expect(!syntax.containsExpression(expr.lowerBound..<expr.upperBound + 1))
    #expect(!syntax.containsExpression(expr.lowerBound + 1..<expr.upperBound))
}

@Test @MainActor func expressionSpansDistinguishVariablesFromNames() async throws {
    let (bytes, syntax) = try await parsed("d = hole_d;\nx = f(3) + obj.prop;\nc($fa = 1, d);\n")
    #expect(syntax.containsExpression(span(of: "hole_d", in: bytes)))
    #expect(syntax.containsExpression(span(of: "f(3)", in: bytes)))
    #expect(syntax.containsExpression(span(of: "f", in: bytes)))
    #expect(syntax.containsExpression(span(of: "obj.prop", in: bytes)))
    #expect(syntax.containsExpression(span(of: "obj", in: bytes)))
    #expect(syntax.containsExpression(span(of: "1", in: bytes)))
    #expect(!syntax.containsExpression(span(of: "d =", in: bytes).lowerBound..<span(of: "d =", in: bytes).lowerBound + 1))
    #expect(!syntax.containsExpression(span(of: "x", in: bytes)))
    #expect(!syntax.containsExpression(span(of: "prop", in: bytes)))
    #expect(!syntax.containsExpression(span(of: "$fa", in: bytes)))
    #expect(!syntax.containsExpression(span(of: "c", in: bytes)))
    // The positional `d` argument is an expression; its `d` callee is not.
    #expect(syntax.containsExpression(span(of: "d);", in: bytes).lowerBound..<span(of: "d);", in: bytes).lowerBound + 1))
}

@Test @MainActor func anchorsAndExpressionsKeepDocumentCoordinates() async throws {
    let (bytes, syntax) = try await parsed("\u{FEFF}! /*a*/ cube(8);\r\nwall = a/2 + i * pitch;\r\n")
    #expect(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
    let anchor = try syntax.translatePrefixAnchor(call: span(of: "cube(8)", in: bytes), name: "cube", in: bytes).get()
    #expect(anchor.insertionPoint == span(of: "cube", in: bytes).lowerBound)
    #expect(anchor.insertionPoint == 3 + "! /*a*/ ".utf8.count)
    #expect(bytes.subdata(in: anchor.statement) == Data("! /*a*/ cube(8);".utf8))
    let call = try #require(syntax.calls.first)
    #expect(call.modifiers == Data("!".utf8))
    #expect(call.terminator == span(of: ";", in: bytes))
    #expect(syntax.containsExpression(span(of: "a/2 + i * pitch", in: bytes)))
    #expect(!syntax.containsExpression(span(of: "a/2 + i", in: bytes)))
    // The same statement stays anchored after a BOM-free twin.
    let plain = try await parsed("! /*a*/ cube(8);\r\n")
    let plainAnchor = try plain.syntax.translatePrefixAnchor(
        call: span(of: "cube(8)", in: plain.bytes), name: "cube", in: plain.bytes).get()
    #expect(plainAnchor.insertionPoint == anchor.insertionPoint - 3)
}
