import Foundation
import Testing
@testable import ScadrettoCore

private func snapshot(_ text: String, documentID: UUID = UUID(), revision: UInt64 = 0) throws -> SourceSnapshot {
    try SourceSnapshot(documentID: documentID, revision: revision,
                       buffer: SourceBuffer(bytes: Data(text.utf8)))
}

private func tokenRange(_ needle: String, in text: String, occurrence: Int = 0) -> Range<Int> {
    let data = Data(text.utf8)
    var search = data.startIndex..<data.endIndex
    var found: Range<Int>?
    for _ in 0...occurrence {
        found = data.range(of: Data(needle.utf8), in: search)
        search = found!.upperBound..<data.endIndex
    }
    return found!
}

private func scalar(_ text: String, token: String, authored: Double,
                    multiplier: Double = 1, constraint: ScalarConstraint = .finite,
                    tokenOccurrence: Int = 0) throws -> (ScalarLiteral, SourceSnapshot) {
    let snap = try snapshot(text)
    let range = tokenRange(token, in: text, occurrence: tokenOccurrence)
    let literal = try ScalarLiteral(source: snap, span: snap.span(for: range), numericToken: range,
                                    authoredValue: authored, displayMultiplier: multiplier,
                                    constraint: constraint)
    return (literal, snap)
}

@Test func scalarEditAcrossBOMCRLFAndEmoji() throws {
    let text = "\u{FEFF}// 🔧 plate\r\nwidth = 9;\r\ncube([width, 20, 3]);\r\n"
    let (scalar, snap) = try scalar(text, token: "20", authored: 20, constraint: .positive)
    #expect(scalar.displayValue == 20)

    let edit = try #require(try scalar.edit(setting: 24, in: snap))
    let range = tokenRange("20", in: text)
    #expect(edit.range == range)
    #expect(edit.expected == Data("20".utf8))
    #expect(edit.replacement == Data("24".utf8))

    let changed = try snap.buffer.applying([edit])
    var expected = Data(text.utf8)
    expected.replaceSubrange(range, with: Data("24".utf8))
    #expect(changed.buffer.bytes == expected)
    #expect(changed.buffer.bomLength == 3)
    #expect(try changed.buffer.applying(changed.inverse).buffer.bytes == Data(text.utf8))
}

@Test func radiusPresentedAsDiameterThroughMultiplier() throws {
    let (scalar, snap) = try scalar("cylinder(h = 8, r = 2);\n", token: "2",
                                    authored: 2, multiplier: 2, constraint: .positive)
    #expect(scalar.displayValue == 4)

    let edit = try #require(try scalar.edit(setting: 5, in: snap))
    #expect(edit.replacement == Data("2.5".utf8))
    let changed = try snap.buffer.applying([edit])
    #expect(changed.buffer.displayText == "cylinder(h = 8, r = 2.5);\n")

    // An unchanged display value produces no patch.
    #expect(try scalar.edit(setting: 4, in: snap) == nil)
}

@Test func finiteConstraintKeepsNegativesAndZeroForTranslate() throws {
    let text = "translate([-10, 0, 0]) cube(8);\n"
    // The adapter supplies the signed token when the grammar stores the sign.
    let (scalar, snap) = try scalar(text, token: "-10", authored: -10, constraint: .finite)
    #expect(scalar.displayValue == -10)

    let negative = try #require(try scalar.edit(setting: -12, in: snap))
    #expect(negative.replacement == Data("-12".utf8))
    let zero = try #require(try scalar.edit(setting: 0, in: snap))
    #expect(zero.replacement == Data("0".utf8))
    #expect(try scalar.edit(setting: -10, in: snap) == nil)
}

@Test func positiveConstraintRejectsInvalidValues() throws {
    let (scalar, snap) = try scalar("size = 9;\n", token: "9", authored: 9, constraint: .positive)
    for value: Double in [0, -4, .nan, .infinity, -.infinity] {
        #expect(throws: ScalarEditError.invalidValue(.positive)) {
            try scalar.edit(setting: value, in: snap)
        }
    }
}

@Test func wrongTokenAndStaleSourceRejected() throws {
    let text = "width = 9;\n"
    let snap = try snapshot(text)
    let good = tokenRange("9", in: text)

    // Token range covering identifier bytes cannot parse to the value.
    let identifier = tokenRange("th", in: text)
    let identifierSpan = try snap.span(for: identifier)
    #expect(throws: ScalarEditError.unverifiedLiteral) {
        try ScalarLiteral(source: snap, span: identifierSpan, numericToken: identifier,
                          authoredValue: 9, constraint: .finite)
    }

    // Authored value must equal the evaluated token text.
    #expect(throws: ScalarEditError.unverifiedLiteral) {
        try ScalarLiteral(source: snap, span: snap.span(for: good), numericToken: good,
                          authoredValue: 8, constraint: .finite)
    }

    // The token must lie inside the binding span.
    let narrow = try snap.span(for: tokenRange("wid", in: text))
    #expect(throws: ScalarEditError.unverifiedLiteral) {
        try ScalarLiteral(source: snap, span: narrow, numericToken: good,
                          authoredValue: 9, constraint: .finite)
    }

    // Digest and file identity mismatches are stale, not merely unverified.
    for span in [
        SourceSpan(fileID: snap.documentID, contentDigest: "deadbeef", bytes: good),
        SourceSpan(fileID: UUID(), contentDigest: snap.buffer.sha256, bytes: good),
    ] {
        #expect(throws: ScalarEditError.staleSource) {
            try ScalarLiteral(source: snap, span: span, numericToken: good,
                              authoredValue: 9, constraint: .finite)
        }
    }

    let scalar = try ScalarLiteral(source: snap, span: snap.span(for: good), numericToken: good,
                                   authoredValue: 9, constraint: .positive)
    // A later revision and a different document both look stale at edit time.
    let revised = try snapshot("width = 10;\n", documentID: snap.documentID, revision: 1)
    #expect(throws: ScalarEditError.staleSource) { try scalar.edit(setting: 5, in: revised) }
    let other = try snapshot("width = 9;\n")
    #expect(throws: ScalarEditError.staleSource) { try scalar.edit(setting: 5, in: other) }

    // The patch itself carries the expected bytes: a divergent buffer rejects it.
    let edit = try #require(try scalar.edit(setting: 5, in: snap))
    let foreign = try SourceBuffer(bytes: Data("width = 4;\n".utf8))
    #expect(throws: SourceError.changedBytes) { try foreign.applying([edit]) }
}

@Test func offsetWrapsExpressionVerbatim() throws {
    let text = "translate([wall/2, 0, 0]) cube(8);\n"
    let snap = try snapshot(text)
    let expression = tokenRange("wall/2", in: text)
    let offset = try ExplicitSourceEdit.Offset(source: snap, span: snap.span(for: expression),
                                               expression: expression)

    let edit = try #require(try offset.edit(adding: 3, in: snap))
    #expect(edit.range == expression)
    #expect(edit.expected == Data("wall/2".utf8))
    #expect(edit.replacement == Data("(wall/2) + 3".utf8))

    var expected = Data(text.utf8)
    expected.replaceSubrange(expression, with: edit.replacement)
    let changed = try snap.buffer.applying([edit])
    #expect(changed.buffer.bytes == expected)
    #expect(try changed.buffer.applying(changed.inverse).buffer.bytes == Data(text.utf8))

    // Negative deltas are written as subtraction; zero produces no patch.
    let minus = try #require(try offset.edit(adding: -1.5, in: snap))
    #expect(minus.replacement == Data("(wall/2) - 1.5".utf8))
    #expect(try offset.edit(adding: 0, in: snap) == nil)
    #expect(throws: ExplicitEditError.invalidValue) { try offset.edit(adding: .nan, in: snap) }
}

@Test func repeatedOffsetsNestWithoutFolding() throws {
    var text = "translate([wall/2, 0, 0]) cube(8);\n"
    var snap = try snapshot(text)
    var expression = tokenRange("wall/2", in: text)
    var offset = try ExplicitSourceEdit.Offset(source: snap, span: snap.span(for: expression),
                                               expression: expression)
    let first = try #require(try offset.edit(adding: 3, in: snap))
    let changed = try snap.buffer.applying([first])
    text = changed.buffer.displayText

    // A fresh offset wraps the whole current expression verbatim; the
    // user-authored-looking "+ 3" is never folded.
    snap = try snapshot(text)
    expression = tokenRange("(wall/2) + 3", in: text)
    offset = try ExplicitSourceEdit.Offset(source: snap, span: snap.span(for: expression),
                                           expression: expression)
    let second = try #require(try offset.edit(adding: 2, in: snap))
    #expect(second.replacement == Data("((wall/2) + 3) + 2".utf8))
    let again = try snap.buffer.applying([second])
    #expect(again.buffer.displayText == "translate([((wall/2) + 3) + 2, 0, 0]) cube(8);\n")
}

@Test func offsetRejectsCommentsAndStringsThatSwallowTheParen() throws {
    // A line comment running to the end of the expression would comment out
    // the appended `)`; unterminated block comments and strings do the same.
    for expression in ["wall/2 // note", "wall/2 /* open", "\"abc"] {
        let text = "value = \(expression)\n"
        let snap = try snapshot(text)
        let range = tokenRange(expression, in: text)
        #expect(throws: ExplicitEditError.unverifiedTarget) {
            try ExplicitSourceEdit.Offset(source: snap, span: snap.span(for: range),
                                          expression: range)
        }
    }

    // Closed comments and a line comment followed by real code are safe: the
    // expression ends in code, so the closing paren lands outside the comment.
    let text = "value = wall/2 /* mid */ + 1 // tail\n"
    let snap = try snapshot(text)
    let range = tokenRange("wall/2 /* mid */ + 1", in: text)
    let offset = try ExplicitSourceEdit.Offset(source: snap, span: snap.span(for: range),
                                               expression: range)
    let edit = try #require(try offset.edit(adding: 3, in: snap))
    #expect(edit.replacement == Data("(wall/2 /* mid */ + 1) + 3".utf8))
}

@Test func offsetAndLiteralRangesMustBeVerified() throws {
    let snap = try snapshot("value = wall/2;\n")
    let expression = tokenRange("wall/2", in: snap.buffer.displayText)
    // Empty or out-of-span expressions cannot be targeted.
    #expect(throws: ExplicitEditError.unverifiedTarget) {
        try ExplicitSourceEdit.Offset(source: snap, span: snap.span(for: expression),
                                      expression: expression.lowerBound..<expression.lowerBound)
    }
    let narrow = try snap.span(for: tokenRange("wall", in: "value = wall/2;\n"))
    #expect(throws: ExplicitEditError.unverifiedTarget) {
        try ExplicitSourceEdit.Offset(source: snap, span: narrow, expression: expression)
    }
    // Identity or digest mismatch is stale.
    let bogus = SourceSpan(fileID: snap.documentID, contentDigest: "0", bytes: expression)
    #expect(throws: ExplicitEditError.staleSource) {
        try ExplicitSourceEdit.Offset(source: snap, span: bogus, expression: expression)
    }

    let offset = try ExplicitSourceEdit.Offset(source: snap, span: snap.span(for: expression),
                                               expression: expression)
    let revised = try snapshot("value = wall/4;\n", documentID: snap.documentID, revision: 1)
    #expect(throws: ExplicitEditError.staleSource) { try offset.edit(adding: 1, in: revised) }
}

@Test func prefixInsertsTranslateAfterRootModifier() throws {
    let text = "!cube(8);\n"
    let snap = try snapshot(text)
    // The adapter verifies the statement span and the boundary after `!`.
    let statement = try snap.span(for: 0..<8)
    let prefix = try ExplicitSourceEdit.Prefix(source: snap, span: statement, insertionPoint: 1)

    let edit = try #require(try prefix.edit(translateByX: 2, y: 0, z: 0, in: snap))
    #expect(edit.range == 0..<2)
    #expect(edit.expected == Data("!c".utf8))
    #expect(edit.replacement == Data("!translate([2, 0, 0]) c".utf8))

    let changed = try snap.buffer.applying([edit])
    #expect(changed.buffer.bytes == Data("!translate([2, 0, 0]) cube(8);\n".utf8))
    #expect(try changed.buffer.applying(changed.inverse).buffer.bytes == Data(text.utf8))

    // Zero movement and non-finite components produce no patch or fail.
    #expect(try prefix.edit(translateByX: 0, y: 0, z: 0, in: snap) == nil)
    #expect(throws: ExplicitEditError.invalidValue) {
        try prefix.edit(translateByX: .infinity, y: 0, z: 0, in: snap)
    }
    // The guard bytes make the edit stale once the boundary changed.
    let revised = try snapshot("cube(8);\n", documentID: snap.documentID, revision: 1)
    #expect(throws: ExplicitEditError.staleSource) {
        try prefix.edit(translateByX: 2, y: 0, z: 0, in: revised)
    }
}

@Test func prefixInsertionWithoutModifierGuardsTrailingByte() throws {
    let text = "  cube(8);\n"
    let snap = try snapshot(text)
    let statement = try snap.span(for: 2..<9)
    let prefix = try ExplicitSourceEdit.Prefix(source: snap, span: statement, insertionPoint: 2)

    let edit = try #require(try prefix.edit(translateByX: -1.5, y: 2.25, z: 3, in: snap))
    #expect(edit.range == 1..<3)
    #expect(edit.expected == Data(" c".utf8))
    #expect(edit.replacement == Data(" translate([-1.5, 2.25, 3]) c".utf8))
    let changed = try snap.buffer.applying([edit])
    #expect(changed.buffer.displayText == "  translate([-1.5, 2.25, 3]) cube(8);\n")
}

@Test func prefixRejectsUnverifiedBoundaries() throws {
    let text = "abé;"
    let snap = try snapshot(text)
    let whole = try snap.span(for: 0..<4)
    // The boundary must lie inside the statement span.
    #expect(throws: ExplicitEditError.unverifiedTarget) {
        try ExplicitSourceEdit.Prefix(source: snap, span: whole, insertionPoint: 4)
    }
    // ... and must be a character boundary, not the middle of `é`.
    #expect(throws: ExplicitEditError.unverifiedTarget) {
        try ExplicitSourceEdit.Prefix(source: snap, span: whole, insertionPoint: 3)
    }
}

@Test @MainActor func scalarEditRestoresOriginalBytesThroughDocumentUndo() throws {
    let document = SourceDocument(buffer: try SourceBuffer(bytes: Data("width = 9;\n".utf8)))
    let snap = document.snapshot
    let range = tokenRange("9", in: "width = 9;\n")
    let scalar = try ScalarLiteral(source: snap, span: snap.span(for: range), numericToken: range,
                                   authoredValue: 9, constraint: .positive)

    let edit = try #require(try scalar.edit(setting: 10, in: snap))
    let undo = try document.apply(document.transaction(edits: [edit], label: "Set Width"))
    #expect(document.buffer.displayText == "width = 10;\n")

    // The committed transaction advanced the revision: the plan is now stale.
    #expect(throws: ScalarEditError.staleSource) { try scalar.edit(setting: 11, in: document.snapshot) }

    try document.apply(document.transaction(edits: undo, label: "Set Width"))
    #expect(document.buffer.bytes == Data("width = 9;\n".utf8))
}
