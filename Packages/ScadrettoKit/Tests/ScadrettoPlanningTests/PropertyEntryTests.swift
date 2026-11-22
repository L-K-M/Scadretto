import Foundation
import ScadrettoCore
import ScadrettoPlanning
import Testing

@Test(arguments: [
    ("de_DE", "2,5", 2.5), ("de_DE", " 2.5 ", 2.5), ("fr_FR", "-0,75", -0.75),
    ("en_US", "2.5", 2.5), ("de_DE", "1e3", 1000),
])
func anEntryAcceptsTheLocalesDecimalSeparator(locale: String, text: String, value: Double) {
    #expect(PropertyEntry.value(of: text, locale: Locale(identifier: locale)) == value)
}

@Test(arguments: [("de_DE", "1.234,5"), ("en_US", "1,234"), ("en_US", "2,5"), ("de_DE", "inf"), ("de_DE", "")])
func anAmbiguousOrNonfiniteEntryIsRefused(locale: String, text: String) {
    #expect(PropertyEntry.value(of: text, locale: Locale(identifier: locale)) == nil)
}

/// A comma in the field must never become a comma in the OpenSCAD source.
@Test @MainActor func aCommaEntryWritesAPoint() throws {
    let value = try #require(PropertyEntry.value(of: "2,5", locale: Locale(identifier: "de_DE")))
    let document = SourceDocument(buffer: try SourceBuffer(bytes: Data("cube(4);\n".utf8))).snapshot
    let span = try document.span(for: 5..<6)
    let literal = try ScalarLiteral(source: document, span: span, numericToken: 5..<6,
                                    authoredValue: 4, displayMultiplier: 1)
    let edit = try #require(try literal.edit(setting: value, in: document))
    #expect(edit.replacement == Data("2.5".utf8))
}
