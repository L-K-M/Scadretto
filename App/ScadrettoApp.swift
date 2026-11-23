import AppKit
import ScadrettoEngineClient
import ScadrettoViewport

@main
@MainActor
final class ScadrettoApp: NSObject, NSApplicationDelegate {
    private(set) var engineClient: EngineClient?
    private(set) var engineStartupError: String?

    static func main() {
        let application = NSApplication.shared
        let delegate = ScadrettoApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A hidden default lets UI tests shorten or postpone in-place autosave. Without it AppKit
        // keeps its own schedule, about 15 seconds after an edit on macOS 27.
        let autosaveDelay = UserDefaults.standard.double(forKey: "ScadrettoAutosaveDelay")
        if autosaveDelay > 0 { NSDocumentController.shared.autosavingDelay = autosaveDelay }
        do {
            engineClient = EngineClient(runtime: try WorkerRuntime(bundle: .main))
        } catch {
            engineStartupError = error.localizedDescription
        }
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engineClient else { return .terminateNow }
        Task {
            await engineClient.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        do {
            try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
            return true
        } catch {
            sender.presentError(error)
            return false
        }
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let app = addMenu("Scadretto", to: menu)
        app.addItem(withTitle: "About Scadretto", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Scadretto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = addMenu("File", to: menu)
        let documents = NSDocumentController.shared
        let new = file.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)),
                               keyEquivalent: "n")
        new.target = documents
        let open = file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)),
                                keyEquivalent: "o")
        open.target = documents
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = file.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)),
                                  keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Revert to Saved", action: #selector(ScadrettoDocument.revertToLastSaved(_:)),
                     keyEquivalent: "")

        let edit = addMenu("Edit", to: menu)
        edit.addItem(withTitle: "Undo", action: #selector(ScadrettoDocument.undoSource(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: #selector(ScadrettoDocument.redoSource(_:)),
                                keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = edit.addItem(withTitle: "Find…", action: #selector(NSTextView.performTextFinderAction(_:)),
                                keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        let replace = edit.addItem(withTitle: "Find and Replace…",
                                   action: #selector(NSTextView.performTextFinderAction(_:)),
                                   keyEquivalent: "f")
        replace.keyEquivalentModifierMask = [.command, .option]
        replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue

        let view = addMenu("View", to: menu)
        view.addItem(withTitle: "Frame Model", action: #selector(ScadrettoDocument.frameModel(_:)), keyEquivalent: "0")
        let standard = addMenu("Standard Views", to: view)
        for (index, direction) in ViewportStandardView.allCases.enumerated() {
            standard.addItem(withTitle: direction.rawValue.capitalized,
                             action: #selector(ScadrettoDocument.standardView(_:)),
                             keyEquivalent: String(index + 1)).tag = index
        }
        view.addItem(.separator())
        view.addItem(withTitle: "Orthographic Projection", action: #selector(ScadrettoDocument.toggleOrthographic(_:)),
                     keyEquivalent: "")
        view.addItem(withTitle: "Show Edges", action: #selector(ScadrettoDocument.toggleEdges(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Show Axes", action: #selector(ScadrettoDocument.toggleAxes(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Swap Orbit and Pan", action: #selector(ScadrettoDocument.toggleOrbitPan(_:)),
                     keyEquivalent: "")
        let snap = addMenu("Drag Snap", to: view)
        for (title, step) in [("Off", 0.0), ("0.25 model units", 0.25), ("0.5 model units", 0.5), ("1 model unit", 1.0)] {
            snap.addItem(withTitle: title, action: #selector(ScadrettoDocument.setDragSnap(_:)),
                         keyEquivalent: "").representedObject = step
        }

        let model = addMenu("Model", to: menu)
        model.addItem(withTitle: "Retry Preview", action: #selector(ScadrettoDocument.retryPreview(_:)), keyEquivalent: "r")
        model.addItem(withTitle: "Cancel Evaluation", action: #selector(ScadrettoDocument.cancelPreview(_:)), keyEquivalent: "")
        model.addItem(withTitle: "Reveal Selected Source", action: #selector(ScadrettoDocument.revealSelectedInstance(_:)),
                      keyEquivalent: "")
        model.addItem(withTitle: "Show Worker Log…", action: #selector(ScadrettoDocument.showWorkerLog(_:)), keyEquivalent: "")

        let help = addMenu("Help", to: menu)
        help.addItem(withTitle: "Open Example", action: #selector(openExample(_:)), keyEquivalent: "").target = self
        NSApp.helpMenu = help
        return menu
    }

    /// Opens an editable untitled copy of the mounting-plate example. The build copies it from
    /// Tests/Fixtures/mounting-plate.scad; the bundled file itself is never written.
    @objc private func openExample(_ sender: Any?) {
        let documents = NSDocumentController.shared
        do {
            guard let url = Bundle.main.url(forResource: "mounting-plate", withExtension: "scad") else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "The example is missing from the application.",
                    NSLocalizedRecoverySuggestionErrorKey: "Reinstall Scadretto.",
                ])
            }
            let type = try documents.typeForContents(of: url)
            let document = try documents.makeUntitledDocument(ofType: type)
            try document.read(from: Data(contentsOf: url), ofType: type)
            document.displayName = "Mounting Plate"
            documents.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        } catch {
            NSApp.presentError(error)
        }
    }

    private func addMenu(_ title: String, to parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        parent.addItem(item)
        return submenu
    }
}
