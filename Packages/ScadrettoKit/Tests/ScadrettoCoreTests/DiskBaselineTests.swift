import Foundation
import Testing
@testable import ScadrettoCore

private let saved = Data("cube(1);\n".utf8)
private let edited = Data("// local\ncube(1);\n".utf8)
private let external = Data("cube(2);\n".utf8)
private let later = Data("cube(3);\n".utf8)

@Test func unchangedBytesNeedNothing() {
    var baseline = DiskBaseline(acknowledged: saved)
    #expect(baseline.observe(.bytes(saved), local: edited) == .none)
    #expect(baseline.allowsWrite(over: .bytes(saved)))
}

@Test func aCleanDocumentTakesAnExternalChange() {
    var baseline = DiskBaseline(acknowledged: saved)
    #expect(baseline.observe(.bytes(external), local: saved) == .reload(external))
    #expect(baseline.acknowledged == saved, "Nothing changes until the new bytes load")
    baseline.adopt(external)
    #expect(baseline.conflict == nil)
    #expect(baseline.allowsWrite(over: .bytes(external)))
}

@Test func bytesThatCannotLoadKeepTheDocumentsText() {
    var baseline = DiskBaseline(acknowledged: saved)
    let unreadable = Data([0xFF, 0xFE])
    #expect(baseline.observe(.bytes(unreadable), local: saved) == .reload(unreadable))
    #expect(baseline.decline(unreadable) == .conflict(.changed(unreadable)))
    #expect(baseline.acknowledged == saved)
    #expect(!baseline.allowsWrite(over: .bytes(unreadable)))
}

@Test func unsavedEditsTurnAnExternalChangeIntoAConflict() {
    var baseline = DiskBaseline(acknowledged: saved)
    #expect(baseline.observe(.bytes(external), local: edited) == .conflict(.changed(external)))
    // The same notice again asks nothing new.
    #expect(baseline.observe(.bytes(external), local: edited) == .none)
    #expect(baseline.acknowledged == saved)
    #expect(!baseline.allowsWrite(over: .bytes(external)))
    #expect(!baseline.allowsWrite(over: .bytes(saved)))
}

@Test func anOverwriteIsBoundToTheReviewedVersion() {
    var baseline = DiskBaseline(acknowledged: saved)
    _ = baseline.observe(.bytes(external), local: edited)
    baseline.approveOverwrite()
    #expect(baseline.allowsWrite(over: .bytes(external)))
    #expect(!baseline.allowsWrite(over: .bytes(later)))
    #expect(!baseline.allowsWrite(over: .missing))

    // A second replacement after the approval needs a fresh decision.
    #expect(baseline.observe(.bytes(later), local: edited) == .conflict(.changed(later)))
    #expect(!baseline.allowsWrite(over: .bytes(later)))
}

@Test func aRemovedFileIsNeverRecreatedBySave() {
    for local in [saved, edited] {
        var baseline = DiskBaseline(acknowledged: saved)
        #expect(baseline.observe(.missing, local: local) == .conflict(.removed))
        #expect(baseline.observe(.missing, local: local) == .none)
        baseline.approveOverwrite()
        #expect(!baseline.allowsWrite(over: .missing))
    }
}

@Test func aRestoredFileClearsTheConflict() {
    var baseline = DiskBaseline(acknowledged: saved)
    _ = baseline.observe(.missing, local: edited)
    #expect(baseline.observe(.bytes(saved), local: edited) == .none)
    #expect(baseline.conflict == nil)
    #expect(baseline.allowsWrite(over: .bytes(saved)))
}

@Test func aCleanDocumentStillReloadsAfterKeepingAConflict() {
    var baseline = DiskBaseline(acknowledged: saved)
    _ = baseline.observe(.bytes(external), local: edited)
    // Undo brought the text back to the acknowledged bytes, so reloading loses nothing.
    #expect(baseline.observe(.bytes(later), local: saved) == .reload(later))
    baseline.adopt(later)
    #expect(baseline.conflict == nil)
}

@Test func writingOrReloadingAdoptsTheBytes() {
    var baseline = DiskBaseline(acknowledged: saved)
    _ = baseline.observe(.bytes(external), local: edited)
    baseline.adopt(edited)
    #expect(baseline.conflict == nil)
    #expect(baseline.acknowledged == edited)
    #expect(baseline.allowsWrite(over: .bytes(edited)))
    #expect(!baseline.allowsWrite(over: .bytes(external)))
}

@Test func anUntitledDocumentHasNoBaselineToProtect() {
    var baseline = DiskBaseline(acknowledged: nil)
    #expect(baseline.observe(.missing, local: edited) == .none)
    #expect(baseline.allowsWrite(over: .missing))
}
