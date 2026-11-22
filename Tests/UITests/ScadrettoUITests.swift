import XCTest

final class ScadrettoUITests: XCTestCase {
    @MainActor
    func testOpenKeyboardEditSaveAndReopenPreserveBytes() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try fixture("editor-bom-crlf")
        let expected = try fixture("editor-bom-crlf-edited")
        XCTAssertNotEqual(original, expected)
        let url = directory.appending(path: "Fidelity.scad")
        try original.write(to: url)

        let editor = open(url, in: app)
        XCTAssertTrue((editor.value as? String)?.contains("// 🔧 original") == true)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertEqual(try Data(contentsOf: url), original)
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeKey(.downArrow, modifierFlags: [])
        editor.typeKey(.leftArrow, modifierFlags: .command)
        for _ in 0..<7 { editor.typeKey(.rightArrow, modifierFlags: []) }
        editor.typeKey(.rightArrow, modifierFlags: .shift)
        editor.typeText("10")
        waitForText("size = 10; // keep this", in: editor)
        choose("Save", from: "File", in: app)
        XCTAssertEqual(try Data(contentsOf: url), expected)

        choose("Close", from: "File", in: app)
        let reopened = open(url, in: app)
        waitForText("size = 10; // keep this", in: reopened)
        XCTAssertEqual(try Data(contentsOf: url), expected)

        reopened.click()
        reopened.typeKey(.upArrow, modifierFlags: .command)
        reopened.typeText("// unsaved")
        waitForText("// unsaved", in: reopened)
        choose("Revert to Saved", from: "File", in: app)
        let confirmation = app.buttons["Revert"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.click()
        let savedText = "// 🔧 original\nsize = 10; // keep this\ncube(size);\n"
        waitForText(savedText, in: reopened)
        XCTAssertEqual(reopened.value as? String, savedText)
        XCTAssertEqual(try Data(contentsOf: url), expected)
    }

    @MainActor
    func testNativeUndoRedoAndIndependentDocuments() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appending(path: "Alpha.scad")
        let secondURL = directory.appending(path: "Beta.scad")
        try Data("alpha = 3;".utf8).write(to: firstURL)
        try Data("beta = 4;".utf8).write(to: secondURL)

        let first = open(firstURL, in: app)
        replaceFinalDigit(in: first, with: "6")
        waitForText("alpha = 6;", in: first)

        let second = open(secondURL, in: app)
        replaceFinalDigit(in: second, with: "7")
        waitForText("beta = 7;", in: second)

        choose("Undo", from: "Edit", in: app, prefix: true)
        waitForText("beta = 4;", in: second)
        waitForText("alpha = 6;", in: first)
        choose("Redo", from: "Edit", in: app, prefix: true)
        waitForText("beta = 7;", in: second)
        choose("Undo", from: "Edit", in: app, prefix: true)
        waitForText("beta = 4;", in: second)

        choose("Close", from: "File", in: app)
        choose("Undo", from: "Edit", in: app, prefix: true)
        waitForText("alpha = 3;", in: first)
        XCTAssertEqual(try Data(contentsOf: firstURL), Data("alpha = 3;".utf8))
        XCTAssertEqual(try Data(contentsOf: secondURL), Data("beta = 4;".utf8))
    }

    @MainActor
    func testInvalidUTF8ReportsOffsetWithoutOpeningDocument() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Invalid Encoding.scad")
        let bytes = Data("// bad\n".utf8) + Data([0xFF])
        try bytes.write(to: url)

        submitOpenPanel(url, in: app)
        let reason = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "at byte 7")).firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 8), "Expected the open error to include the invalid byte offset")
        app.buttons["OK"].firstMatch.click()
        XCTAssertFalse(sourceEditor(for: url, in: app).exists)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.activate()
        return app
    }

    @MainActor
    private func open(_ url: URL, in app: XCUIApplication) -> XCUIElement {
        submitOpenPanel(url, in: app)
        let editor = sourceEditor(for: url, in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 8), "Expected the source editor for \(url.lastPathComponent)")
        return editor
    }

    @MainActor
    private func submitOpenPanel(_ url: URL, in app: XCUIApplication) {
        let panel = app.windows["Open"]
        if !panel.exists { app.typeKey("o", modifierFlags: .command) }
        XCTAssertTrue(panel.waitForExistence(timeout: 8), "Expected the system Open panel")
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let path = panel.sheets.firstMatch.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5), "Expected the Go to Folder path field")
        path.typeKey("a", modifierFlags: .command)
        path.typeText(url.path)
        path.typeKey(.return, modifierFlags: [])
        let open = panel.buttons["Open"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        open.click()
    }

    @MainActor
    private func sourceEditor(for url: URL, in app: XCUIApplication) -> XCUIElement {
        let name = url.deletingPathExtension().lastPathComponent
        let window = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", name)).firstMatch
        return window.textViews["sourceEditor"]
    }

    @MainActor
    private func choose(_ title: String, from menu: String, in app: XCUIApplication, prefix: Bool = false) {
        app.activate()
        app.menuBarItems[menu].click()
        let predicate = prefix ? NSPredicate(format: "title BEGINSWITH %@", title)
                               : NSPredicate(format: "title == %@", title)
        let item = app.menuItems.matching(predicate).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Missing \(menu) → \(title)")
        XCTAssertTrue(item.isEnabled, "\(menu) → \(title) is disabled")
        item.click()
    }

    @MainActor
    private func replaceFinalDigit(in editor: XCUIElement, with text: String) {
        editor.click()
        editor.typeKey(.rightArrow, modifierFlags: .command)
        editor.typeKey(.leftArrow, modifierFlags: [])
        editor.typeKey(.leftArrow, modifierFlags: .shift)
        editor.typeText(text)
    }

    @MainActor
    private func waitForText(_ text: String, in editor: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let matches = NSPredicate(format: "value CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Expected “\(text)” in source editor, got \(editor.value ?? "(no value)")", file: file, line: line)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "scad"))
        return try Data(contentsOf: url)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ScadrettoUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
