import Carbon.HIToolbox
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
        waitForFile(url, toEqual: expected, timeout: 5)

        choose("Close", from: "File", in: app)
        let reopened = open(url, in: app)
        waitForText("size = 10; // keep this", in: reopened)
        XCTAssertEqual(try Data(contentsOf: url), expected)

        reopened.click()
        reopened.typeKey(.upArrow, modifierFlags: .command)
        reopened.typeText("// unsaved")
        waitForText("// unsaved", in: reopened)
        choose("Revert to Saved", from: "File", in: app)
        let confirmation = app.sheets.buttons["Revert"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.click()
        let savedText = "// 🔧 original\nsize = 10; // keep this\ncube(size);\n"
        waitForText(savedText, in: reopened)
        XCTAssertEqual(reopened.value as? String, savedText)
        XCTAssertEqual(try Data(contentsOf: url), expected)
    }

    @MainActor
    func testUnsavedDependencyEditsAreLabeledUntilSaved() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        let part = directory.appending(path: "part.scad")
        try Data("module part() cube(2);\n".utf8).write(to: part)
        let parent = directory.appending(path: "Parent.scad")
        try Data("include <part.scad>\npart();\n".utf8).write(to: parent)

        _ = open(parent, in: app)
        let parentWindow = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", "Parent")).firstMatch
        let status = parentWindow.staticTexts["renderStatus"]
        let notice = parentWindow.staticTexts["dependencyNotice"]
        waitForText("Preview ready · 12 triangles", in: status, timeout: 15)
        XCTAssertFalse(notice.exists, "A notice appeared with nothing unsaved")

        // The parent keeps evaluating the saved part and says so.
        let partEditor = open(part, in: app)
        partEditor.click()
        partEditor.typeKey("a", modifierFlags: .command)
        partEditor.typeText("module part() cylinder(r = 2, h = 2);\n")
        waitForText("part.scad has unsaved edits", in: notice, timeout: 5)
        settle(2)
        XCTAssertEqual(status.value as? String, "Preview ready · 12 triangles", "The parent read unsaved text")

        // Saving the part re-evaluates the parent through its dependency watch.
        partEditor.typeKey("s", modifierFlags: .command)
        waitForFile(part, toEqual: Data("module part() cylinder(r = 2, h = 2);\n".utf8), timeout: 5)
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5), "The notice stayed after Save")
        // The part's window covers the parent's, whose viewport presents once it is visible.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(partEditor.waitForNonExistence(timeout: 5), "Closing the saved part asked")
        let cylinder = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value BEGINSWITH %@ AND NOT (value CONTAINS %@)", "Preview ready", "· 12 triangles"
        ), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [cylinder], timeout: 15), .completed,
                       "Expected the saved cylinder, got \(status.value ?? "(no value)")")
        XCTAssertEqual(try Data(contentsOf: parent), Data("include <part.scad>\npart();\n".utf8))
    }

    // MARK: - Benchmarks
    //
    // These run only when SCADRETTO_BENCHMARK_DIR names a directory, as Scripts/benchmark-macos
    // does through TEST_RUNNER_SCADRETTO_BENCHMARK_DIR. The app writes its timing log there and
    // Scripts/benchmark-report computes the percentiles.

    private func benchmarkLog(_ name: String) throws -> URL {
        let directory = ProcessInfo.processInfo.environment["SCADRETTO_BENCHMARK_DIR"]
        try XCTSkipIf(directory == nil, "Set SCADRETTO_BENCHMARK_DIR to run benchmarks")
        return URL(fileURLWithPath: directory!).appending(path: "\(name).jsonl")
    }

    /// Five warm-up and thirty measured diameter commits on the plate, each waiting for its frame.
    @MainActor
    func testBenchmarkPlateCommitToFrame() throws {
        let log = try benchmarkLog("plate-commits")
        let app = launch(arguments: ["-ScadrettoTimingLog", log.path])
        defer { app.terminate() }
        let directory = try makeDirectory()
        let url = directory.appending(path: "Benchmark Plate.scad")
        try fixture("mounting-plate").write(to: url)

        _ = open(url, in: app)
        waitForText("Preview ready", in: app.staticTexts["renderStatus"].firstMatch, timeout: 30)
        let viewport = app.descendants(matching: .any)["viewport"].firstMatch
        try selectThirdBore(in: viewport, app: app)
        let field = app.textFields["diameterField"].firstMatch
        for index in 0..<35 {
            waitUntilEnabled(field)
            let value = index.isMultiple(of: 2) ? "4.5" : "4"
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeText(value + "\n")
            let applied = XCTNSPredicateExpectation(predicate: NSPredicate(
                format: "value == %@ AND enabled == true", value
            ), object: field)
            XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 30), .completed, "Commit \(index) did not settle")
        }
    }

    /// Twenty seconds of orbiting the plate, then the hundred-cutter plate, and a handle drag.
    @MainActor
    func testBenchmarkOrbitAndDragFrames() throws {
        for (name, data) in [("orbit-plate", try fixture("mounting-plate")), ("orbit-stress", try fixture("stress-100-cutters"))] {
            let log = try benchmarkLog(name)
            let app = launch(arguments: ["-ScadrettoTimingLog", log.path])
            let directory = try makeDirectory()
            let url = directory.appending(path: "\(name).scad")
            try data.write(to: url)
            _ = open(url, in: app)
            waitForText("Preview ready", in: app.staticTexts["renderStatus"].firstMatch, timeout: 60)
            let viewport = app.descendants(matching: .any)["viewport"].firstMatch
            settle(2)
            let started = Date()
            var forward = true
            while Date().timeIntervalSince(started) < 20 {
                let from = viewport.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.3 : 0.7, dy: 0.5))
                let to = viewport.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.7 : 0.3, dy: 0.55))
                // A mouse drag, as in testViewportNavigationFromMenuAndMouse; press(...) drew no frames.
                from.click(forDuration: 0.05, thenDragTo: to, withVelocity: 150, thenHoldForDuration: 0)
                forward.toggle()
            }
            if name == "orbit-plate" {
                choose("Frame Model", from: "View", in: app)
                try selectThirdBore(in: viewport, app: app)
                let (grip, outward) = diameterDragCoordinates(in: viewport)
                grip.click(forDuration: 0.2, thenDragTo: outward, withVelocity: 20, thenHoldForDuration: 0.2)
                waitForText("Preview ready", in: app.staticTexts["renderStatus"].firstMatch, timeout: 30)
            }
            app.terminate()
        }
    }

    /// A hundred keystrokes, 120 ms apart, into the hundred-cutter plate while its evaluations run.
    @MainActor
    func testBenchmarkTypingWhileWorkerIsBusy() throws {
        let log = try benchmarkLog("typing-busy")
        let app = launch(arguments: ["-ScadrettoTimingLog", log.path])
        defer { app.terminate() }
        let directory = try makeDirectory()
        let url = directory.appending(path: "Benchmark Stress.scad")
        try fixture("stress-100-cutters").write(to: url)

        let editor = open(url, in: app)
        waitForText("Preview ready", in: app.staticTexts["renderStatus"].firstMatch, timeout: 60)
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("// ")
        for index in 0..<100 {
            editor.typeText(String(index % 10))
            Thread.sleep(forTimeInterval: 0.12)
        }
        waitForText("Preview ready", in: app.staticTexts["renderStatus"].firstMatch, timeout: 60)
    }

    @MainActor
    func testExternalBackupRenameDoesNotRedirectSave() throws {
        try saveAfterExternalMove(refilledWith: Data("cube(2);\n".utf8))
    }

    @MainActor
    func testFileMovedAwayIsNeitherFollowedNorRecreated() throws {
        try saveAfterExternalMove(refilledWith: nil)
    }

    /// Edits a file, moves it aside as another program would, then takes Save's default answer.
    @MainActor
    private func saveAfterExternalMove(refilledWith external: Data?) throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Shared.scad")
        let moved = directory.appending(path: "Shared-backup.scad")
        let original = Data("cube(1);\n".utf8)
        try original.write(to: url)

        let editor = open(url, in: app)
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("// local ")
        waitForText("// local cube(1);", in: editor)

        // AppKit reports a path refilled within half a second as a change. It follows the move
        // when the path stays empty longer, so wait before any refill.
        try FileManager.default.moveItem(at: url, to: moved)
        settle(3)
        try external?.write(to: url)
        settle(2)

        // Keep the edits through any external-change sheet, then try to save them.
        let keep = app.sheets.buttons["Keep Editing"].firstMatch
        if keep.waitForExistence(timeout: 5) { keep.click() }
        choose("Save", from: "File", in: app)
        // A followed move makes Save, under the new name, the default answer of AppKit's sheet.
        let acceptDefault = app.sheets.buttons["Save"].firstMatch
        if acceptDefault.waitForExistence(timeout: 3) { acceptDefault.click() }
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: moved)) != original || (try? Data(contentsOf: url)) != external
        }, object: nil)
        written.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 4), .completed,
                       "Save wrote to a file the user did not choose")
        XCTAssertEqual(try Data(contentsOf: moved), original)
        XCTAssertEqual(try? Data(contentsOf: url), external)
        XCTAssertTrue((editor.value as? String)?.contains("// local") == true, "The local edit was lost")
    }

    @MainActor
    func testCleanDocumentReloadsAnExternalChange() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Watched.scad")
        try Data("cube(1);\n".utf8).write(to: url)

        let editor = open(url, in: app)
        let external = Data("cube(2);\n".utf8)
        try external.write(to: url, options: .atomic)
        waitForText("cube(2);", in: editor, timeout: 8)
        settle(1)
        XCTAssertEqual(app.sheets.count, 0, "A document without edits needs no decision")
        choose("Save", from: "File", in: app)
        settle(1)
        XCTAssertEqual(app.sheets.count, 0, "Saving the reloaded text needs no decision")
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    @MainActor
    func testOverwriteAfterASecondExternalChangeAsksAgain() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Twice.scad")
        try Data("cube(1);\n".utf8).write(to: url)

        let editor = open(url, in: app)
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("// local ")
        waitForText("// local cube(1);", in: editor)
        try Data("cube(2);\n".utf8).write(to: url, options: .atomic)
        let keep = app.sheets.buttons["Keep Editing"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 8), "Expected the external change sheet")
        keep.click()

        // The file changes again while Save's question is open.
        choose("Save", from: "File", in: app)
        let overwrite = app.sheets.buttons["Overwrite"].firstMatch
        XCTAssertTrue(overwrite.waitForExistence(timeout: 5), "Expected Save to ask before overwriting")
        let second = Data("cube(3);\n".utf8)
        try second.write(to: url, options: .atomic)
        settle(3)
        overwrite.click()
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "Overwrite did not show the newer version")
        XCTAssertEqual(try Data(contentsOf: url), second, "Overwrite replaced a version the user had not seen")
        XCTAssertEqual(editor.value as? String, "// local cube(1);\n")
    }

    @MainActor
    func testUnsavedEditsAskBeforeAnExternalChangeIsReplaced() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Watched.scad")
        try Data("cube(1);\n".utf8).write(to: url)

        let editor = open(url, in: app)
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("// local ")
        waitForText("// local cube(1);", in: editor)

        let external = Data("cube(2);\n".utf8)
        try external.write(to: url, options: .atomic)
        let keep = app.sheets.buttons["Keep Editing"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 8), "Expected the external change sheet")
        XCTAssertTrue(app.sheets.buttons["Reload from Disk"].exists)
        app.sheets.buttons["Compare"].firstMatch.click()
        let diskWindow = app.windows.matching(NSPredicate(format: "title CONTAINS %@", "Disk Version")).firstMatch
        XCTAssertTrue(diskWindow.waitForExistence(timeout: 5), "Expected the disk version window")
        waitForText("cube(2);", in: diskWindow.textViews.firstMatch)
        diskWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertEqual(editor.value as? String, "// local cube(1);\n")
        XCTAssertEqual(try Data(contentsOf: url), external)

        // Save asks before replacing the version the user reviewed.
        choose("Save", from: "File", in: app)
        let overwrite = app.sheets.buttons["Overwrite"].firstMatch
        XCTAssertTrue(overwrite.waitForExistence(timeout: 5), "Expected Save to ask before overwriting")
        XCTAssertEqual(try Data(contentsOf: url), external)
        overwrite.click()
        let local = Data("// local cube(1);\n".utf8)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: url)) == local
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)

        // A later change is a new decision; reloading discards the local text.
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("// more")
        waitForText("// more", in: editor)
        let later = Data("cube(3);\n".utf8)
        try later.write(to: url, options: .atomic)
        let reload = app.sheets.buttons["Reload from Disk"].firstMatch
        XCTAssertTrue(reload.waitForExistence(timeout: 8), "Expected a fresh decision")
        reload.click()
        waitForText("cube(3);", in: editor)
        XCTAssertEqual(editor.value as? String, "cube(3);\n")
        XCTAssertEqual(try Data(contentsOf: url), later)
    }

    @MainActor
    func testRemovedFileKeepsItsTextAndOffersSaveAs() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Removed.scad")
        try Data("cube(1);\n".utf8).write(to: url)

        let editor = open(url, in: app)
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("// local ")
        waitForText("// local cube(1);", in: editor)
        // A plain delete sends no file presenter notice. Save checks the path itself.
        try FileManager.default.removeItem(at: url)

        choose("Save", from: "File", in: app)
        let saveAs = app.sheets.buttons["Save As…"].firstMatch
        XCTAssertTrue(saveAs.waitForExistence(timeout: 5), "Expected the removed-file sheet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        saveAs.click()
        let panel = app.sheets.buttons["Save"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "Expected the Save As panel")
        app.typeKey(.escape, modifierFlags: [])
        settle(1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(editor.value as? String, "// local cube(1);\n")
    }

    @MainActor
    func testAMovedFileFollowsOnlyWhenAccepted() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Before.scad")
        let moved = directory.appending(path: "After.scad")
        try Data("cube(1);\n".utf8).write(to: url)

        let editor = open(url, in: app)
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("// local ")
        waitForText("// local cube(1);", in: editor)
        try FileManager.default.moveItem(at: url, to: moved)
        let follow = app.sheets.buttons["Use New Location"].firstMatch
        XCTAssertTrue(follow.waitForExistence(timeout: 8), "Expected the moved-file sheet")
        XCTAssertEqual(try Data(contentsOf: moved), Data("cube(1);\n".utf8))
        follow.click()
        XCTAssertTrue(app.windows["After.scad"].waitForExistence(timeout: 5))
        choose("Save", from: "File", in: app)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: moved)) == Data("// local cube(1);\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testAutosaveWritesCommittedTextInPlace() throws {
        let app = launch(autosaveDelay: 2)
        defer { app.terminate() }
        let directory = try makeDirectory()
        let url = directory.appending(path: "Autosaved.scad")
        try Data("cube(1);\n".utf8).write(to: url)

        let editor = open(url, in: app)
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("// kept ")
        waitForFile(url, toEqual: Data("// kept cube(1);\n".utf8), timeout: 12)

        // The text is already in the file, so closing needs no decision.
        choose("Close", from: "File", in: app)
        settle(1)
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertFalse(editor.exists)
        XCTAssertEqual(try Data(contentsOf: url), Data("// kept cube(1);\n".utf8))
    }

    @MainActor
    func testRevertAfterAutosaveRestoresTheSavedVersion() throws {
        let app = launch(autosaveDelay: 2)
        defer { app.terminate() }
        let directory = try makeDirectory()
        let url = directory.appending(path: "Drafted.scad")
        let saved = Data("cube(1);\n".utf8)
        try saved.write(to: url)

        let editor = open(url, in: app)
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("// draft ")
        waitForFile(url, toEqual: Data("// draft cube(1);\n".utf8), timeout: 12)

        // The file now holds the draft; Revert goes back to what was opened, on disk as well.
        choose("Revert to Saved", from: "File", in: app)
        let confirmation = app.sheets.buttons["Revert"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), "Expected Revert to ask first")
        confirmation.click()
        waitForText("cube(1);", in: editor)
        XCTAssertEqual(editor.value as? String, "cube(1);\n")
        waitForFile(url, toEqual: saved, timeout: 5)
        settle(4)
        XCTAssertEqual(try Data(contentsOf: url), saved, "An autosave wrote the reverted draft back")
    }

    @MainActor
    func testClosingOrQuittingRightAfterTypingKeepsTheText() throws {
        // Autosave is ten minutes away, so only closing and quitting write these files.
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        let closed = directory.appending(path: "Closed.scad")
        let quit = directory.appending(path: "Quit.scad")
        try Data("cube(1);\n".utf8).write(to: closed)
        try Data("cube(1);\n".utf8).write(to: quit)

        // Both keys follow the typing well inside the pause that ends a typing group.
        let first = open(closed, in: app)
        first.click()
        first.typeKey(.upArrow, modifierFlags: .command)
        first.typeText("// closed ")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(first.waitForNonExistence(timeout: 5), "Closing asked instead of autosaving")
        waitForFile(closed, toEqual: Data("// closed cube(1);\n".utf8), timeout: 5)

        let second = open(quit, in: app)
        second.click()
        second.typeKey(.upArrow, modifierFlags: .command)
        second.typeText("// quit ")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Quitting asked instead of autosaving")
        XCTAssertEqual(try Data(contentsOf: quit), Data("// quit cube(1);\n".utf8))
    }

    @MainActor
    func testAutosaveLeavesMarkedTextToItsComposition() throws {
        let app = launch(autosaveDelay: 2)
        defer { app.terminate() }
        let directory = try makeDirectory()
        let url = directory.appending(path: "Composed.scad")
        let original = Data("cube(1);\n".utf8)
        try original.write(to: url)

        let editor = open(url, in: app)
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        // On the Swiss German layout this key is a dead circumflex, which stays marked text. On a
        // layout where it types a plain caret, nothing here composes.
        try XCTSkipUnless(Self.keyboardLayoutID == "com.apple.keylayout.SwissGerman",
                          "Needs the Swiss German layout, where ^ is a dead key")
        editor.typeText("// ")
        editor.typeKey("^", modifierFlags: [])
        // The typed "// " is due for autosave during the composition, which holds it back.
        settle(6)
        XCTAssertEqual(try Data(contentsOf: url), original, "Autosave wrote during the composition")
        editor.typeText("e")
        waitForText("// ê", in: editor)
        waitForFile(url, toEqual: Data("// êcube(1);\n".utf8), timeout: 12)

        // Closing commits a pending composition and autosaves it with the rest. The window's
        // close button is used because the input method takes Command-W while a dead key is
        // pending, and opening the menu bar cancels the composition.
        editor.typeKey("^", modifierFlags: [])
        app.windows["Composed.scad"].buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Closing asked instead of autosaving")
        waitForFile(url, toEqual: Data("// ê^cube(1);\n".utf8), timeout: 5)
    }

    /// The current keyboard layout's input source ID, such as com.apple.keylayout.SwissGerman.
    private static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }

    @MainActor
    func testAutosaveNeverWritesOverAPendingConflict() throws {
        let app = launch(autosaveDelay: 2)
        defer { app.terminate() }
        let directory = try makeDirectory()
        let url = directory.appending(path: "Contested.scad")
        try Data("cube(1);\n".utf8).write(to: url)

        let editor = open(url, in: app)
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("// local ")
        let external = Data("cube(2);\n".utf8)
        try external.write(to: url, options: .atomic)
        let keep = app.sheets.buttons["Keep Editing"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 8), "Expected the external change sheet")
        keep.click()
        settle(6)
        XCTAssertEqual(try Data(contentsOf: url), external, "Autosave wrote over the external version")
        XCTAssertEqual(editor.value as? String, "// local cube(1);\n")

        // Closing asks in a sheet and quitting in an alert, instead of dropping the text or
        // failing quietly.
        let discard = app.buttons["Don’t Save"].firstMatch
        choose("Close", from: "File", in: app)
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "Closing did not ask about the unsaved text")
        app.sheets.buttons["Cancel"].firstMatch.click()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "Quitting did not ask about the unsaved text")
        app.buttons["Cancel"].firstMatch.click()
        settle(2)
        XCTAssertEqual(app.state, .runningForeground, "Cancel did not keep the app open")
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertEqual(editor.value as? String, "// local cube(1);\n")

        choose("Close", from: "File", in: app)
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Don’t Save kept the window open")
        XCTAssertEqual(try Data(contentsOf: url), external, "Closing wrote over the external version")
    }

    @MainActor
    func testClosingWithNothingLeftToWriteIgnoresAPendingChange() throws {
        let app = launch(autosaveDelay: 2)
        defer { app.terminate() }
        let directory = try makeDirectory()
        let url = directory.appending(path: "Settled.scad")
        try Data("cube(1);\n".utf8).write(to: url)

        let editor = open(url, in: app)
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("x")
        let external = Data("cube(2);\n".utf8)
        try external.write(to: url, options: .atomic)
        let keep = app.sheets.buttons["Keep Editing"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 8), "Expected the external change sheet")
        keep.click()

        // Deleting the character leaves the text the file held before the change, so there is
        // nothing to write and nothing to lose. The document is clean again, so a disk check
        // that lands before Close, such as a late presenter notice, may load the external
        // version first; closing must not ask either way.
        editor.typeKey(.delete, modifierFlags: [])
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value == %@ OR value == %@", "cube(1);\n", "cube(2);\n"
        ), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                       "Unexpected text \(editor.value ?? "(no value)")")
        choose("Close", from: "File", in: app)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Closing refused with nothing to write")
        XCTAssertEqual(try Data(contentsOf: url), external, "Closing wrote over the external version")
    }

    @MainActor
    func testACoordinatedWriterHoldingTheFileWinsOverAutosave() throws {
        let app = launch(autosaveDelay: 2)
        defer { app.terminate() }
        let directory = try makeDirectory()
        let url = directory.appending(path: "Held.scad")
        try Data("cube(1);\n".utf8).write(to: url)

        let editor = open(url, in: app)
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        // Another program takes the file before the autosave is due and replaces it after.
        let external = Data("cube(2);\n".utf8)
        let writerDone = XCTestExpectation(description: "The other writer finished")
        let holding = XCTestExpectation(description: "The other writer holds the file")
        Thread.detachNewThread {
            var coordination: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { target in
                holding.fulfill()
                Thread.sleep(forTimeInterval: 6)
                try? external.write(to: target, options: .atomic)
            }
            writerDone.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [holding], timeout: 5), .completed)
        editor.typeText("// local ")
        XCTAssertEqual(XCTWaiter.wait(for: [writerDone], timeout: 12), .completed)
        settle(4)
        XCTAssertEqual(try Data(contentsOf: url), external, "Autosave replaced the other writer's version")
        XCTAssertEqual(editor.value as? String, "// local cube(1);\n")
        let keep = app.sheets.buttons["Keep Editing"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "Expected the external change sheet")
        keep.click()

        // Quitting without saving leaves the other writer's version in place.
        app.typeKey("q", modifierFlags: .command)
        let discard = app.buttons["Don’t Save"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "Quitting did not ask about the unsaved text")
        discard.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Don’t Save did not let the app quit")
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    @MainActor
    func testVoiceOverHearsSceneSelectionAndEditChanges() throws {
        let directory = try makeDirectory()
        let log = directory.appending(path: "announcements.txt")
        let app = launch(arguments: ["-ScadrettoAnnouncementLog", log.path])
        defer { app.terminate() }
        let url = directory.appending(path: "Spoken.scad")
        let text = "cylinder(h = 4, d = 6, $fn = 32);\n"
        try Data(text.utf8).write(to: url)

        let editor = open(url, in: app)
        let status = app.staticTexts["renderStatus"].firstMatch
        waitForText("Preview ready", in: status, timeout: 15)
        waitForAnnouncement("Preview ready", in: log)

        // The selection summary is announced and stays readable on the inspector.
        let viewport = app.descendants(matching: .any)["viewport"].firstMatch
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let field = app.textFields["diameterField"].firstMatch
        waitUntilEnabled(field)
        let inspector = app.descendants(matching: .any)["inspector"].firstMatch
        let summary = inspector.value as? String ?? ""
        XCTAssertTrue(summary.contains("cylinder, Diameter 6, "), "Summary: \(summary)")
        waitForAnnouncement(summary, in: log)

        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("8\n")
        waitForText("d = 8", in: editor)
        waitForAnnouncement("Diameter changed from 6 to 8, ", in: log)

        // A failure is announced once, and so is the recovery; evaluations between them that end
        // the same way stay quiet.
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("cube(")
        waitForText("Preview out of date", in: status, timeout: 15)
        waitForAnnouncement("Preview out of date", in: log)
        editor.typeKey(.delete, modifierFlags: [])
        editor.typeKey(.delete, modifierFlags: [])
        editor.typeKey(.delete, modifierFlags: [])
        editor.typeKey(.delete, modifierFlags: [])
        editor.typeKey(.delete, modifierFlags: [])
        waitForText("Preview ready", in: status, timeout: 15)
        let spoken = announcements(in: log)
        let failure = try XCTUnwrap(spoken.lastIndex { $0.hasPrefix("Preview out of date") })
        XCTAssertEqual(spoken.filter { $0.hasPrefix("Preview out of date") }.count, 1, "\(spoken)")
        waitForAnnouncement("Preview ready", in: log, after: failure)
        let heard = XCTAttachment(string: announcements(in: log).joined(separator: "\n"))
        heard.name = "Announcements"
        heard.lifetime = .keepAlways
        add(heard)
    }

    @MainActor
    func testTwoWindowsOfOneDocumentShareTextUndoAndSelectionSafely() throws {
        let app = launch()
        defer { app.terminate() }
        let directory = try makeDirectory()
        let url = directory.appending(path: "Shared.scad")
        let text = "cylinder(h = 4, d = 6, $fn = 32);\n"
        try Data(text.utf8).write(to: url)

        _ = open(url, in: app)
        let first = app.windows.matching(NSPredicate(format: "title == %@", "Shared.scad")).firstMatch
        let second = app.windows.matching(NSPredicate(format: "title == %@", "Shared.scad (2)")).firstMatch
        waitForText("Preview ready", in: first.staticTexts["renderStatus"], timeout: 15)
        choose("New Window", from: "File", in: app)
        XCTAssertTrue(second.waitForExistence(timeout: 5), "Expected a second window on the document")
        let firstEditor = first.textViews["sourceEditor"]
        let secondEditor = second.textViews["sourceEditor"]
        XCTAssertEqual(secondEditor.value as? String, text)
        waitForText("Preview ready", in: second.staticTexts["renderStatus"], timeout: 15)

        // Typing in either window reaches the one buffer.
        secondEditor.click()
        secondEditor.typeKey(.upArrow, modifierFlags: .command)
        // Single lines, so each window adds exactly one typing step to the undo history.
        secondEditor.typeText("/* two */ ")
        waitForText("/* two */", in: firstEditor)
        choose("Shared.scad", from: "Window", in: app)
        firstEditor.typeKey(.downArrow, modifierFlags: .command)
        firstEditor.typeText("// one")
        let both = "/* two */ " + text + "// one"
        waitForText("// one", in: secondEditor)
        XCTAssertEqual(firstEditor.value as? String, both)
        XCTAssertEqual(secondEditor.value as? String, both)

        // One undo stack: two undos remove both lines, in either window, and nothing is left.
        choose("Undo Typing", from: "Edit", in: app)
        waitForText(text, in: secondEditor)
        choose("Shared.scad (2)", from: "Window", in: app)
        choose("Undo Typing", from: "Edit", in: app)
        let original = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: firstEditor)
        XCTAssertEqual(XCTWaiter.wait(for: [original], timeout: 5), .completed, "Undo did not reach both windows")
        XCTAssertEqual(secondEditor.value as? String, text)
        app.menuBarItems["Edit"].click()
        let undo = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Undo")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertFalse(undo.isEnabled, "An undo item was registered twice")
        app.typeKey(.escape, modifierFlags: [])

        // A selection lives in one window. Selecting in the other clears it here, and an edit
        // there leaves this window's inspector clear.
        waitForText("Preview ready", in: second.staticTexts["renderStatus"], timeout: 15)
        second.descendants(matching: .any)["viewport"].firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        waitForText("cylinder", in: second.staticTexts["inspectorSelection"], timeout: 8)
        choose("Shared.scad", from: "Window", in: app)
        waitForText("Preview ready", in: first.staticTexts["renderStatus"], timeout: 15)
        first.descendants(matching: .any)["viewport"].firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let field = first.textFields["diameterField"]
        waitUntilEnabled(field)
        XCTAssertFalse(second.staticTexts["inspectorSelection"].exists, "The other window kept its selection")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("8\n")
        let edited = text.replacingOccurrences(of: "d = 6", with: "d = 8")
        waitForText("d = 8", in: secondEditor)
        XCTAssertEqual(firstEditor.value as? String, edited)
        XCTAssertFalse(second.staticTexts["inspectorSelection"].exists, "The other window gained a selection")
        choose("Undo Change Diameter", from: "Edit", in: app)
        waitForText("d = 6", in: secondEditor)
        XCTAssertEqual(firstEditor.value as? String, text)

        // Closing one window leaves the document open in the other.
        choose("Shared.scad (2)", from: "Window", in: app)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(second.waitForNonExistence(timeout: 5), "The second window did not close")
        XCTAssertTrue(firstEditor.exists, "Closing one window closed the document")
        choose("Redo Change Diameter", from: "Edit", in: app)
        waitForText("d = 8", in: firstEditor)
        app.typeKey("s", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: url)) == Data(edited.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed, "Save did not write the shared text")
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
    func testKeyboardDiameterEditOnThirdBoreSurvivesSaveUndoRedoAndReopen() throws {
        let app = launch(arguments: ["-dragSnapIncrement", "0.5"])
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Keyboard Diameter.scad")
        // An equal-valued literal on an unrelated solid inside the plate must
        // not be rewritten by the shared-parameter edit.
        let extra = "\ntranslate([100, 8, 0]) cylinder(h = 6, d = 4);\n"
        let originalText = String(decoding: try fixture("mounting-plate"), as: UTF8.self) + extra
        XCTAssertEqual(originalText.components(separatedBy: "hole_d = 4;").count - 1, 1,
                       "The fixture must contain exactly one shared hole diameter literal")
        let editedText = originalText.replacingOccurrences(of: "hole_d = 4;", with: "hole_d = 5;")
        let original = Data(originalText.utf8)
        let edited = Data(editedText.utf8)
        try original.write(to: url)

        let editor = open(url, in: app)
        let status = app.staticTexts["renderStatus"].firstMatch
        waitForText("Preview ready", in: status, timeout: 15)

        let viewport = app.descendants(matching: .any)["viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 6))

        try selectThirdBore(in: viewport, app: app)

        XCTAssertEqual(app.staticTexts["targetScope"].firstMatch.value as? String, "Shared parameter · 4 cutters")
        let field = app.textFields["diameterField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let writable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [writable], timeout: 8), .completed,
                       "The diameter field must enable once the literal is verified")
        XCTAssertEqual(field.value as? String, "4")

        let (grip, outward) = diameterDragCoordinates(in: viewport)
        grip.click(forDuration: 0.2, thenDragTo: outward)
        waitForText("hole_d = 5;", in: editor)
        XCTAssertEqual(editor.value as? String, editedText)
        choose("Undo Change Diameter", from: "Edit", in: app)
        waitForText("hole_d = 4;", in: editor)
        XCTAssertEqual(editor.value as? String, originalText)
        waitForText("Preview ready", in: status, timeout: 15)
        let writableAfterUndo = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [writableAfterUndo], timeout: 8), .completed)

        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("5")
        XCTAssertEqual(field.value as? String, "5")
        field.typeKey(.return, modifierFlags: [])
        waitForText("Source change · 4 → 5", in: app.staticTexts["editStatus"].firstMatch, timeout: 8)
        XCTAssertEqual(editor.value as? String, editedText)
        XCTAssertEqual(try Data(contentsOf: url), original)

        choose("Save", from: "File", in: app)
        waitForFile(url, toEqual: edited, timeout: 5)

        choose("Undo", from: "Edit", in: app, prefix: true)
        waitForText("hole_d = 4;", in: editor)
        choose("Save", from: "File", in: app)
        waitForFile(url, toEqual: original, timeout: 5)

        choose("Redo", from: "Edit", in: app, prefix: true)
        waitForText("hole_d = 5;", in: editor)
        choose("Save", from: "File", in: app)
        waitForFile(url, toEqual: edited, timeout: 5)

        choose("Close", from: "File", in: app)
        let reopened = open(url, in: app)
        waitForText("hole_d = 5;", in: reopened)
        waitForText("Preview ready", in: status, timeout: 15)
        XCTAssertEqual(try Data(contentsOf: url), edited)
    }

    @MainActor
    func testViewportDragAndSaveFiveBores() throws {
        let app = launch(arguments: ["-dragSnapIncrement", "0.5"])
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Dragged Mounting Plate.scad")
        let original = try fixture("mounting-plate")
        let originalText = String(decoding: original, as: UTF8.self)
        let diameterText = originalText.replacingOccurrences(of: "hole_d = 4;", with: "hole_d = 5;")
        let finalText = diameterText.replacingOccurrences(of: "count = 4;", with: "count = 5;")
        try original.write(to: url)

        let editor = open(url, in: app)
        let status = app.staticTexts["renderStatus"].firstMatch
        let viewport = app.descendants(matching: .any)["viewport"].firstMatch
        let field = app.textFields["diameterField"].firstMatch
        waitForText("Preview ready · 1052 triangles", in: status, timeout: 15)
        choose("Save", from: "File", in: app)
        waitForFile(url, toEqual: original, timeout: 5)

        try selectThirdBore(in: viewport, app: app)
        waitForText("Shared parameter · 4 cutters", in: app.staticTexts["targetScope"].firstMatch)
        waitForText("4", in: field)
        let (grip, outward) = diameterDragCoordinates(in: viewport)
        grip.click()
        XCTAssertEqual(editor.value as? String, originalText)
        XCTAssertEqual(field.value as? String, "4")
        XCTAssertEqual(try Data(contentsOf: url), original)
        app.menuBarItems["Edit"].click()
        XCTAssertFalse(app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Undo")).firstMatch.isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeKey(.leftArrow, modifierFlags: [])
        editor.typeKey(.delete, modifierFlags: [])
        waitForText("Parser error", in: status, timeout: 15)
        XCTAssertFalse(field.isEnabled)
        choose("Undo", from: "Edit", in: app, prefix: true)
        waitForText("Preview ready · 1052 triangles", in: status, timeout: 15)
        XCTAssertEqual(editor.value as? String, originalText)

        let writable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [writable], timeout: 8), .completed)
        grip.click(forDuration: 0.2, thenDragTo: outward)
        waitForText("hole_d = 5;", in: editor)
        XCTAssertEqual(editor.value as? String, diameterText)
        choose("Undo Change Diameter", from: "Edit", in: app)
        waitForText("hole_d = 4;", in: editor)
        XCTAssertEqual(editor.value as? String, originalText)
        choose("Redo Change Diameter", from: "Edit", in: app)
        waitForText("hole_d = 5;", in: editor)

        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        for _ in 0..<3 { editor.typeKey(.downArrow, modifierFlags: []) }
        editor.typeKey(.leftArrow, modifierFlags: .command)
        for _ in 0..<8 { editor.typeKey(.rightArrow, modifierFlags: []) }
        editor.typeKey(.rightArrow, modifierFlags: .shift)
        editor.typeText("5")
        waitForText("Preview ready · 1312 triangles", in: status, timeout: 15)
        waitForText("Shared parameter · 5 cutters", in: app.staticTexts["targetScope"].firstMatch)
        XCTAssertEqual(editor.value as? String, finalText)
        choose("Save", from: "File", in: app)
        let saved = try Data(contentsOf: url)
        XCTAssertEqual(saved, Data(finalText.utf8))
        let acceptedFile = XCTAttachment(data: saved, uniformTypeIdentifier: "public.source-code")
        acceptedFile.name = "Saved Mounting Plate.scad"
        acceptedFile.lifetime = .keepAlways
        add(acceptedFile)
        choose("Close", from: "File", in: app)
        let reopened = open(url, in: app)
        waitForText("Preview ready · 1312 triangles", in: status, timeout: 15)
        XCTAssertEqual(reopened.value as? String, finalText)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        try selectThirdBore(in: viewport, app: app, afterDiameterEdit: true)
        waitForText("Shared parameter · 5 cutters", in: app.staticTexts["targetScope"].firstMatch)
        XCTAssertEqual(field.value as? String, "5")
        let screenshot = XCTAttachment(screenshot: viewport.screenshot())
        screenshot.name = "Reopened Five-Bore Preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testPitchDragEscapeSyntaxRecoveryAndIterationZero() throws {
        let app = launch(arguments: ["-dragSnapIncrement", "0.5"])
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Pitched Mounting Plate.scad")
        let original = try fixture("mounting-plate")
        let originalText = String(decoding: original, as: UTF8.self)
        let pitchedText = originalText.replacingOccurrences(of: "pitch = 20;", with: "pitch = 22;")
        try original.write(to: url)

        let editor = open(url, in: app)
        let status = app.staticTexts["renderStatus"].firstMatch
        let viewport = app.descendants(matching: .any)["viewport"].firstMatch
        let detail = app.staticTexts["editStatus"].firstMatch
        waitForText("Preview ready", in: status, timeout: 15)
        waitForText("Snap 0.5", in: app.staticTexts["dragSnap"].firstMatch)

        // Step 6: iteration 2 moves +4 along local X.
        try selectThirdBore(in: viewport, app: app)
        chooseProperty("Pitch", in: app)
        waitForText("Shared parameter · 4 cutters", in: app.staticTexts["targetScope"].firstMatch)
        let field = app.textFields["pitchField"].firstMatch
        waitUntilEnabled(field)
        XCTAssertEqual(field.value as? String, "20")
        waitForText("Snap 0.5", in: detail)
        let grip = plateCoordinate(CGPoint(x: 289.19969, y: 310.45504), in: viewport)
        let plusFour = plateCoordinate(CGPoint(x: 301.01570, y: 317.27702), in: viewport)
        grip.click(forDuration: 0.2, thenDragTo: plusFour)
        waitForText("pitch = 22;", in: editor)
        XCTAssertEqual(editor.value as? String, pitchedText)
        waitForText("Preview ready", in: status, timeout: 15)
        waitForText("Source change · 20 → 22", in: detail, timeout: 8)
        choose("Save", from: "File", in: app)
        waitForFile(url, toEqual: Data(pitchedText.utf8), timeout: 5)
        let saved = XCTAttachment(data: Data(pitchedText.utf8), uniformTypeIdentifier: "public.source-code")
        saved.name = "Saved Pitched Plate.scad"
        saved.lifetime = .keepAlways
        add(saved)
        let shot = XCTAttachment(screenshot: viewport.screenshot())
        shot.name = "Pitch 22 Preview"
        shot.lifetime = .keepAlways
        add(shot)

        choose("Undo Change Pitch", from: "Edit", in: app)
        waitForText("pitch = 20;", in: editor)
        XCTAssertEqual(editor.value as? String, originalText)
        waitForText("Preview ready", in: status, timeout: 15)
        waitUntilEnabled(field)

        // Step 7: Escape while the button is held leaves bytes and undo depth alone.
        waitForText("Snap 0.5", in: detail)
        try cancelDrag(from: grip.screenPoint, to: plusFour.screenPoint) {
            waitForText("Preview · 20 → 22", in: detail)
            let guides = XCTAttachment(screenshot: viewport.screenshot())
            guides.name = "Held Pitch Drag Guides"
            guides.lifetime = .keepAlways
            add(guides)
        }
        XCTAssertEqual(editor.value as? String, originalText)
        XCTAssertEqual(field.value as? String, "20")
        app.menuBarItems["Edit"].click()
        XCTAssertFalse(app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Undo")).firstMatch.isEnabled)
        XCTAssertTrue(app.menuItems["Redo Change Pitch"].firstMatch.isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeKey(.leftArrow, modifierFlags: [])
        editor.typeKey(.delete, modifierFlags: [])
        waitForText("Parser error", in: status, timeout: 15)
        waitForText("Preview out of date", in: status)
        XCTAssertFalse(field.isEnabled)
        editor.typeText("}")
        waitForText("Preview ready", in: status, timeout: 15)
        waitUntilEnabled(field)
        XCTAssertEqual(editor.value as? String, originalText)

        // Iteration zero cannot define a drag, and still accepts the number.
        // A wall point whose sight line clears the opening's rim by one unit.
        let firstBore = plateCoordinate(CGPoint(x: 180.18168, y: 239.88722), in: viewport)
        firstBore.click()
        waitForText("i = 0", in: app.staticTexts["inspectorSelection"].firstMatch, timeout: 8)
        chooseProperty("Pitch", in: app)
        waitForText("Iteration zero keeps its position", in: detail)
        waitUntilEnabled(field)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("22")
        field.typeKey(.return, modifierFlags: [])
        waitForText("pitch = 22;", in: editor, timeout: 8)
        XCTAssertEqual(editor.value as? String, pitchedText)
    }

    @MainActor
    func testOutlineReachesEnclosedOperandWithCommaEntry() throws {
        let app = launch(arguments: ["-AppleLocale", "de_DE"])
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Enclosed Cutter.scad")
        let originalText = """
            difference() {
                cube(20, center = true);
                cylinder(h = 4, d = 4, center = true, $fn = 16); // cavity
            }

            """
        let editedText = originalText.replacingOccurrences(of: "d = 4,", with: "d = 4.5,")
        try Data(originalText.utf8).write(to: url)

        let editor = open(url, in: app)
        let status = app.staticTexts["renderStatus"].firstMatch
        waitForText("Preview ready", in: status, timeout: 15)

        // A ray through the cavity stops at the enclosing cube.
        let viewport = app.descendants(matching: .any)["viewport"].firstMatch
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let selection = app.staticTexts["inspectorSelection"].firstMatch
        waitForText("cube", in: selection, timeout: 8)

        let operand = app.outlines["sceneOutline"].staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "cylinder")).firstMatch
        XCTAssertTrue(operand.waitForExistence(timeout: 5), "The enclosed operand must be listed in the outline")
        operand.click()
        waitForText("cylinder", in: selection, timeout: 8)
        let ghost = XCTAttachment(screenshot: viewport.screenshot())
        ghost.name = "Enclosed Operand Ghost"
        ghost.lifetime = .keepAlways
        add(ghost)

        let diameter = app.textFields["diameterField"].firstMatch
        waitUntilEnabled(diameter)
        XCTAssertEqual(diameter.value as? String, "4")
        diameter.click()
        diameter.typeKey("a", modifierFlags: .command)
        diameter.typeText("9")
        chooseProperty("Height (centered)", in: app)
        let height = app.textFields["propertyValue"].firstMatch
        waitUntilEnabled(height)
        XCTAssertEqual(height.value as? String, "4", "Text typed for the diameter must not reach the height")
        XCTAssertEqual(editor.value as? String, originalText, "Changing the property must not commit unfinished text")

        chooseProperty("Diameter", in: app)
        waitUntilEnabled(diameter)
        diameter.click()
        diameter.typeKey("a", modifierFlags: .command)
        diameter.typeText("4,5")
        diameter.typeKey(.return, modifierFlags: [])
        waitForText("d = 4.5,", in: editor, timeout: 8)
        XCTAssertEqual(editor.value as? String, editedText)
        waitForText("Preview ready", in: status, timeout: 15)
        waitForText("4,5", in: diameter, timeout: 8)

        choose("Save", from: "File", in: app)
        waitForFile(url, toEqual: Data(editedText.utf8), timeout: 5)
        choose("Undo Change Diameter", from: "Edit", in: app)
        waitForText("d = 4,", in: editor)
        XCTAssertEqual(editor.value as? String, originalText)
    }

    @MainActor
    func testANewPressAbandonsADragWhoseReleaseWasLost() throws {
        let app = launch(arguments: ["-dragSnapIncrement", "0.5"])
        defer { app.terminate() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Lost Release.scad")
        let original = try fixture("mounting-plate")
        try original.write(to: url)

        let editor = open(url, in: app)
        waitForText("Preview ready", in: app.staticTexts["renderStatus"].firstMatch, timeout: 15)
        let viewport = app.descendants(matching: .any)["viewport"].firstMatch
        try selectThirdBore(in: viewport, app: app)
        chooseProperty("Pitch", in: app)
        let detail = app.staticTexts["editStatus"].firstMatch
        waitUntilEnabled(app.textFields["pitchField"].firstMatch)
        waitForText("Snap 0.5", in: detail)
        let grip = plateCoordinate(CGPoint(x: 289.19969, y: 310.45504), in: viewport).screenPoint
        let moved = plateCoordinate(CGPoint(x: 301.01570, y: 317.27702), in: viewport).screenPoint
        let background = plateCoordinate(CGPoint(x: 520, y: 120), in: viewport).screenPoint

        XCTAssertTrue(CGPreflightPostEventAccess(), "The UI test runner needs permission to post events")
        let events = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        // Two presses and one release stand for a release that another app received.
        for (type, point) in [(CGEventType.mouseMoved, grip), (.leftMouseDown, grip), (.leftMouseDragged, moved),
                              (.leftMouseDown, background), (.leftMouseUp, background)] {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: events, mouseType: type,
                                              mouseCursorPosition: point, mouseButton: .left))
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.3)
        }
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", String(decoding: original, as: UTF8.self)), object: editor
        )
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 2), .completed, "A new press committed the old drag")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private static let plateViewportSize = CGSize(width: 608, height: 638)

    @MainActor
    private func chooseProperty(_ title: String, in app: XCUIApplication) {
        let choices = app.popUpButtons["propertyChoice"].firstMatch
        XCTAssertTrue(choices.waitForExistence(timeout: 8), "Expected the property choices")
        choices.click()
        let item = choices.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Missing the \(title) property")
        item.click()
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed, "Expected \(element) to become enabled")
    }

    /// XCUITest cannot press a key during its own drag, so this posts HID events.
    @MainActor
    private func cancelDrag(from start: CGPoint, to end: CGPoint, whileHeld check: () -> Void) throws {
        XCTAssertTrue(CGPreflightPostEventAccess(), "The UI test runner needs permission to post events")
        let events = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        func post(_ type: CGEventType, at point: CGPoint) throws {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: events, mouseType: type,
                                              mouseCursorPosition: point, mouseButton: .left))
            event.post(tap: .cghidEventTap)
        }
        try post(.mouseMoved, at: start)
        try post(.leftMouseDown, at: start)
        Thread.sleep(forTimeInterval: 0.15)
        for step in 1...10 {
            let progress = Double(step) / 10
            try post(.leftMouseDragged, at: CGPoint(x: start.x + progress * (end.x - start.x),
                                                    y: start.y + progress * (end.y - start.y)))
            Thread.sleep(forTimeInterval: 0.02)
        }
        check()
        for isDown in [true, false] {
            let key = try XCTUnwrap(CGEvent(keyboardEventSource: events, virtualKey: CGKeyCode(kVK_Escape), keyDown: isDown))
            key.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.2)
        try post(.leftMouseUp, at: end)
    }

    @MainActor
    private func selectThirdBore(in viewport: XCUIElement, app: XCUIApplication, afterDiameterEdit: Bool = false) throws {
        // Projected centroids of final triangles 352 (original) and 307
        // (saved five-bore variant) in the initial 608 × 638 viewport.
        let size = viewport.frame.size
        let expected = Self.plateViewportSize
        let matchesViewport = abs(size.width - expected.width) <= 1 && abs(size.height - expected.height) <= 1
        _ = try XCTUnwrap(matchesViewport ? size : nil,
                          "The bore ray requires a 608 × 638 point viewport. Measured \(size).")
        let point = afterDiameterEdit ? CGPoint(x: 280.75186, y: 303.55458) : CGPoint(x: 283.52664, y: 303.54620)
        let bore = plateCoordinate(point, in: viewport)
        let selection = app.staticTexts["inspectorSelection"].firstMatch
        for _ in 0..<8 {
            bore.click()
            let matched = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "mounting_hole", "i = 2"),
                object: selection
            )
            if XCTWaiter.wait(for: [matched], timeout: 1.5) == .completed { return }
        }
        XCTFail("Clicking the third bore must select its instance in viewport \(viewport.frame)")
    }

    @MainActor
    private func diameterDragCoordinates(in viewport: XCUIElement) -> (XCUICoordinate, XCUICoordinate) {
        (plateCoordinate(CGPoint(x: 283.52062, y: 303.54250), in: viewport),
         plateCoordinate(CGPoint(x: 282.11575, y: 302.67948), in: viewport))
    }

    @MainActor
    private func plateCoordinate(_ point: CGPoint, in viewport: XCUIElement) -> XCUICoordinate {
        let size = Self.plateViewportSize
        return viewport.coordinate(withNormalizedOffset: CGVector(dx: point.x / size.width, dy: point.y / size.height))
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
    private func launch(arguments: [String] = [], autosaveDelay: TimeInterval = 600) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Each test opens its own documents rather than the last test's windows. Autosave waits
        // ten minutes unless a test asks for it, so unsaved edits stay unsaved while it runs.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-ScadrettoAutosaveDelay", String(autosaveDelay)] + arguments
        // A failed assertion ends a test without running its defer blocks.
        addTeardownBlock { await MainActor.run { app.terminate() } }
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
        XCTAssertTrue(panel.waitForExistence(timeout: 20), "Expected the system Open panel")
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

    private func announcements(in log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @MainActor
    private func waitForAnnouncement(_ prefix: String, in log: URL, after index: Int = -1,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let spoken = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            announcements(in: log).enumerated().contains { $0.offset > index && $0.element.hasPrefix(prefix) }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [spoken], timeout: 8), .completed,
                       "Expected an announcement starting “\(prefix)”, heard \(announcements(in: log))",
                       file: file, line: line)
    }

    @MainActor
    private func waitForText(_ text: String, in element: XCUIElement, timeout: TimeInterval = 5,
                             file: StaticString = #filePath, line: UInt = #line) {
        let matches = NSPredicate(format: "value CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Expected “\(text)”, got \(element.value ?? "(no value)")", file: file, line: line)
    }

    @MainActor
    private func waitForFile(_ url: URL, toEqual expected: Data, timeout: TimeInterval,
                             file: StaticString = #filePath, line: UInt = #line) {
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: url)) == expected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: timeout), .completed,
                       "Expected \(url.lastPathComponent) to hold \(String(decoding: expected, as: UTF8.self))",
                       file: file, line: line)
    }

    /// File presenter notices arrive asynchronously and have no element to wait for.
    @MainActor
    private func settle(_ seconds: TimeInterval) {
        let pause = XCTestExpectation(description: "File notices settle")
        pause.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [pause], timeout: seconds), .completed)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "scad"))
        return try Data(contentsOf: url)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "UI-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Go to Folder completes against every leftover here on each typed key.
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
