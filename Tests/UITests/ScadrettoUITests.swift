import XCTest

final class ScadrettoUITests: XCTestCase {
    @MainActor
    func testViewportNavigationFromMenuAndMouse() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Navigation.scad")
        try fixture("mounting-plate").write(to: url)
        _ = open(url, in: app)
        waitForText("Preview ready", in: app.staticTexts["renderStatus"].firstMatch, timeout: 15)

        let viewport = app.descendants(matching: .any)["viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 6))
        let initial = viewport.screenshot().pngRepresentation
        app.typeKey("1", modifierFlags: .command)
        let top = viewport.screenshot().pngRepresentation
        XCTAssertNotEqual(initial, top, "The Top view command must change the rendered frame")
        let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.22))
        let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.40))
        start.click(forDuration: 0.1, thenDragTo: end)
        XCTAssertNotEqual(top, viewport.screenshot().pngRepresentation, "A mouse orbit must change the rendered frame")

        start.rightClick()
        let frames = app.menuItems.matching(identifier: "Frame Model")
        let visible = frames.allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(visible, "The motionless right click must open the viewport menu. \(app.debugDescription)")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testLiveMountingPlatePreviewRecoversAfterSyntaxError() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Mounting Plate.scad")
        let original = try fixture("mounting-plate")
        try original.write(to: url)

        let editor = open(url, in: app)
        let status = app.staticTexts["renderStatus"].firstMatch
        waitForText("Preview ready", in: status, timeout: 15)
        let initialPreview = status.value as? String

        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        for _ in 0..<3 { editor.typeKey(.downArrow, modifierFlags: []) }
        editor.typeKey(.leftArrow, modifierFlags: .command)
        for _ in 0..<8 { editor.typeKey(.rightArrow, modifierFlags: []) }
        editor.typeKey(.rightArrow, modifierFlags: .shift)
        editor.typeText("5")
        waitForText("count = 5;", in: editor)
        let changedPreview = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH %@ AND value != %@", "Preview ready", initialPreview ?? ""),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changedPreview], timeout: 12), .completed)
        let fifth = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "i = 4")).firstMatch
        XCTAssertTrue(fifth.waitForExistence(timeout: 5), "The fifth executed occurrence should be visible in the outline")
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Live mounting plate with five bores"
        preview.lifetime = .keepAlways
        add(preview)
        XCTAssertEqual(try Data(contentsOf: url), original)

        editor.typeKey(.delete, modifierFlags: [])
        waitForText("count = ;", in: editor)
        waitForText("Preview out of date", in: status, timeout: 15)
        waitForText("Parser error", in: status, timeout: 15)
        editor.typeText("5")
        waitForText("Preview ready", in: status, timeout: 15)

        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("difference(){ cube(2); cube(2); }")
        waitForText("Empty model", in: status, timeout: 15)
    }

    @MainActor
    func testWarningKeepsGeometryAndJumpsToItsSource() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Warning.scad")
        try fixture("warning-only").write(to: url)

        let editor = open(url, in: app)
        let status = app.staticTexts["renderStatus"].firstMatch
        waitForText("Preview ready", in: status, timeout: 15)
        waitForText("missing_parameter", in: status)
        let initialTriangles = try triangleCount(in: status)

        let diagnostics = app.popUpButtons["modelDiagnostics"].firstMatch
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 6))
        diagnostics.click()
        let warning = diagnostics.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "missing_parameter")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        warning.click()
        editor.typeText("0")
        waitForText("echo(\"preview:\", $preview, 0);", in: editor)
        waitForText("Preview ready", in: status, timeout: 15)
        let finalTriangles = try triangleCount(in: status)
        XCTAssertEqual(initialTriangles, finalTriangles)
    }

    @MainActor
    func testMissingIncludeRecoversWhenDependencyAppears() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Dependencies.scad")
        let library = directory.appending(path: "parts", directoryHint: .isDirectory)
        let include = library.appending(path: "part.scad")
        try Data("include <parts/part.scad>\n".utf8).write(to: url)

        _ = open(url, in: app)
        let status = app.staticTexts["renderStatus"].firstMatch
        let missing = "Could not resolve parts/part.scad"
        waitForText(missing, in: status, timeout: 15)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        let directoryOnly = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT value CONTAINS %@", missing),
                                                      object: status)
        directoryOnly.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [directoryOnly], timeout: 0.75), .completed)
        try Data("cube(2);\n".utf8).write(to: include, options: .atomic)
        waitForText("Preview ready · 12 triangles", in: status, timeout: 15)
        try FileManager.default.removeItem(at: include)
        waitForText("Preview out of date", in: status, timeout: 15)
        try Data("cube(3);\n".utf8).write(to: include, options: .atomic)
        waitForText("Preview ready · 12 triangles", in: status, timeout: 15)

        choose("Cancel Evaluation", from: "Model", in: app)
        waitForText("Preview canceled", in: status)
        try Data("sphere(1, $fn = 16);\n".utf8).write(to: include, options: .atomic)
        let restarted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT value CONTAINS %@", "Preview canceled"),
                                                  object: status)
        restarted.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [restarted], timeout: 0.75), .completed)
        choose("Retry Preview", from: "Model", in: app)
        waitForText("Preview ready", in: status, timeout: 15)
        XCTAssertNotEqual(status.value as? String, "Preview ready · 12 triangles")
    }

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
    private func triangleCount(in status: XCUIElement) throws -> Int {
        let label = try XCTUnwrap(status.value as? String)
        let count = try XCTUnwrap(label.components(separatedBy: " · ").dropFirst().first)
        let suffix = " triangles"
        XCTAssertTrue(count.hasSuffix(suffix), "Expected a triangle count in the render status")
        return try XCTUnwrap(Int(count.dropLast(suffix.count)))
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
    private func waitForText(_ text: String, in element: XCUIElement, timeout: TimeInterval = 5,
                             file: StaticString = #filePath, line: UInt = #line) {
        let matches = NSPredicate(format: "value CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Expected “\(text)”, got \(element.value ?? "(no value)")", file: file, line: line)
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
