import Foundation
import Testing
@testable import ScadrettoCore

private func fixture(_ name: String) throws -> Data {
    var directory = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { directory.deleteLastPathComponent() }
    return try Data(contentsOf: directory.appending(path: "Tests/Fixtures/\(name)"))
}

@Test func goldenLiteralRoundTrip() throws {
    let original = try fixture("editor-bom-crlf.scad")
    let golden = try fixture("editor-bom-crlf-edited.scad")
    let buffer = try SourceBuffer(bytes: original)
    #expect(buffer.bytes == original)
    #expect(buffer.bomLength == 3)
    #expect(buffer.displayText == "// 🔧 original\nsize = 9; // keep this\ncube(size);\n")

    let selection = (buffer.displayText as NSString).range(of: "9")
    let edit = try buffer.textEdit(range: selection, replacement: "10")
    #expect(edit.expected == Data("9".utf8))
    #expect(try buffer.textRange(for: edit.range) == selection)
    let edited = try buffer.applying([edit])
    #expect(edited.buffer.bytes == golden)
    #expect(try edited.buffer.applying(edited.inverse).buffer.bytes == original)
}

@Test func unicodeBoundariesAndLineEndings() throws {
    let original = Data("\u{FEFF}🔧\tCafe\u{301}\r\nnext\rline\nfinal".utf8)
    let buffer = try SourceBuffer(bytes: original)
    #expect(try buffer.byteRange(for: NSRange(location: 0, length: 2)) == 3..<7)
    #expect(throws: SourceError.invalidRange) {
        try buffer.byteRange(for: NSRange(location: 1, length: 1))
    }
    #expect(throws: SourceError.invalidRange) {
        try buffer.byteRange(for: NSRange(location: NSNotFound, length: 1))
    }
    let lines = buffer.displayText as NSString
    let next = lines.range(of: "next")
    let final = lines.range(of: "final")
    let insertion = "a\n\r\r\nb\u{2028}c\u{2029}d"
    let firstLine = try buffer.textEdit(range: NSRange(location: 0, length: 0), replacement: insertion)
    #expect(firstLine.replacement == Data("a\r\n\r\n\r\nb\r\nc\r\nd".utf8))
    let secondLine = try buffer.textEdit(range: NSRange(location: next.location, length: 0), replacement: "\n")
    #expect(secondLine.replacement == Data("\r".utf8))
    let lastLine = try buffer.textEdit(range: NSRange(location: final.location, length: 0), replacement: "\n")
    #expect(lastLine.replacement == Data("\n".utf8))
    #expect(buffer.lineNumber(atUTF16Offset: final.location) == 4)

    let unicodeLines = try SourceBuffer(bytes: Data("first\u{2028}second\u{2029}last".utf8))
    #expect(unicodeLines.displayText == "first\nsecond\nlast")
    for (offset, separator) in [(0, "\u{2028}"), (6, "\u{2029}"), (13, "\u{2029}")] {
        let edit = try unicodeLines.textEdit(range: NSRange(location: offset, length: 0), replacement: "\r\n")
        #expect(edit.replacement == Data(separator.utf8))
        let changed = try unicodeLines.applying([edit])
        #expect(try changed.buffer.applying(changed.inverse).buffer == unicodeLines)
    }
}

@Test func invalidEncodingsHaveAnOffset() throws {
    for (file, position) in [("invalid-utf8.scad", 12), ("truncated-utf8.scad", 12), ("utf16-bom.scad", 0)] {
        let invalid = try fixture(file)
        #expect(throws: SourceError.invalidUTF8(byte: position)) {
            try SourceBuffer(bytes: invalid)
        }
    }
    #expect(throws: SourceError.invalidUTF8(byte: 1)) {
        try SourceBuffer(bytes: Data([0x20, 0xF0, 0x90, 0x80, 0x20]))
    }
}

@Test func disjointEditsAndUndoRestoreEveryByte() throws {
    let buffer = try SourceBuffer(bytes: Data("aab\r\n😀a".utf8))
    let edits = [
        SourceEdit(range: 0..<1, expected: Data("a".utf8), replacement: Data()),
        SourceEdit(range: 1..<2, expected: Data("a".utf8), replacement: Data()),
        SourceEdit(range: 9..<10, expected: Data("a".utf8), replacement: Data("wide".utf8)),
    ]
    let changed = try buffer.applying(edits.reversed())
    #expect(changed.buffer.bytes == Data("b\r\n😀wide".utf8))
    #expect(try changed.buffer.applying(changed.inverse).buffer.bytes == buffer.bytes)
    #expect(throws: SourceError.changedBytes) {
        try buffer.applying([.init(range: 0..<1, expected: Data("z".utf8), replacement: Data())])
    }
    #expect(throws: SourceError.overlappingEdits) {
        try buffer.applying([edits[0], edits[0]])
    }

    let noChange = try buffer.applying([
        edits[0],
        .init(range: 1..<2, expected: Data("a".utf8), replacement: Data("aa".utf8)),
    ])
    #expect(noChange.buffer == buffer)
    #expect(noChange.inverse.isEmpty)
}

@Test func undoCanSeparateNaturallyJoinedNewlines() throws {
    let buffer = try SourceBuffer(bytes: Data("a\rb\nc".utf8))
    let edit = try buffer.textEdit(range: NSRange(location: 2, length: 1), replacement: "")
    let changed = try buffer.applying([edit])
    #expect(changed.buffer.bytes == Data("a\r\nc".utf8))
    #expect(try changed.buffer.applying(changed.inverse).buffer == buffer)
}

@Test @MainActor func transactionsCheckIdentityAndAdvanceAcrossUndo() async throws {
    let original = try SourceBuffer(bytes: Data("width = 9;\n".utf8))
    let document = SourceDocument(buffer: original)
    let peer = SourceDocument(buffer: original)
    let edit = try original.textEdit(range: NSRange(location: 8, length: 1), replacement: "10")
    let proposed = document.transaction(edits: [edit], label: "Change Width")
    #expect(throws: SourceError.staleRevision) { try peer.apply(proposed) }

    let firstUndo = try document.apply(proposed)
    let saved = document.snapshot
    let snapshotDigest = await Task.detached { saved.buffer.sha256 }.value
    #expect(snapshotDigest == saved.buffer.sha256)
    let inserted = try document.buffer.textEdit(range: NSRange(location: 0, length: 0), replacement: "// note\n")
    let secondUndo = try document.apply(document.transaction(edits: [inserted], label: "Typing"))
    document.acknowledgeSaved(saved)
    #expect(document.isEdited)
    #expect(throws: SourceError.staleRevision) { try document.apply(proposed) }

    let secondRedo = try document.apply(document.transaction(edits: secondUndo, label: "Typing"))
    #expect(!document.isEdited)
    let firstRedo = try document.apply(document.transaction(edits: firstUndo, label: "Change Width"))
    #expect(document.revision == 4)
    #expect(document.buffer == original)
    try document.apply(document.transaction(edits: firstRedo, label: "Change Width"))
    try document.apply(document.transaction(edits: secondRedo, label: "Typing"))
    #expect(document.buffer.displayText == "// note\nwidth = 10;\n")
    #expect(document.revision == 6)
    #expect(peer.revision == 0)
}
