import AppKit
import ScadrettoEngineClient
import ScadrettoViewport

@main
@MainActor
final class ScadrettoApp: NSObject, NSApplicationDelegate {
    private(set) var engineClient: EngineClient?
    private(set) var engineStartupError: String?
    private let recentDocuments = RecentDocumentsMenu(title: "Open Recent")
    private var settingsWindow: PreviewSettingsWindowController?

    static func main() {
        let application = NSApplication.shared
        let delegate = ScadrettoApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // UI tests start from the default library folders, time limit and 3D mouse settings.
        if UserDefaults.standard.bool(forKey: "ScadrettoResetPreviewSettings") {
            PreviewSettings.shared.reset()
            ThreeDMouseController.resetSettings()
        }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThreeDMouseController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ThreeDMouseController.shared.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engineClient else { return .terminateNow }
        Task {
            await engineClient.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }
        if let minimized = sender.windows.first(where: { $0.isMiniaturized && $0.windowController?.document != nil }) {
            minimized.deminiaturize(nil)
            minimized.makeKeyAndOrderFront(nil)
            return true
        }
        return applicationOpenUntitledFile(sender)
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

    @objc private func showSettings(_ sender: Any?) {
        let controller = settingsWindow ?? PreviewSettingsWindowController()
        settingsWindow = controller
        controller.showWindow(sender)
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let app = addMenu("Scadretto", to: menu)
        app.addItem(withTitle: "About Scadretto", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        app.addItem(.separator())
        let services = addMenu("Services", to: app)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Scadretto", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                    keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
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
        let recent = NSMenuItem(title: recentDocuments.title, action: nil, keyEquivalent: "")
        recent.submenu = recentDocuments
        file.addItem(recent)
        file.addItem(.separator())
        let window = file.addItem(withTitle: "New Window", action: #selector(ScadrettoDocument.newWindowForDocument(_:)),
                                  keyEquivalent: "n")
        window.keyEquivalentModifierMask = [.command, .option]
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = file.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)),
                                  keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Revert to Saved", action: #selector(ScadrettoDocument.revertToLastSaved(_:)),
                     keyEquivalent: "")

        let edit = addMenu("Edit", to: menu)
        edit.addItem(withTitle: "Undo", action: #selector(ScadrettoDocument.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: #selector(ScadrettoDocument.redo(_:)),
                                keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = addMenu("Find", to: edit)
        for (title, key, modifiers, action) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find and Replace…", "f", [.command, .option], .showReplaceInterface),
            ("Find Next", "g", [.command], .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", [.command], .setSearchString),
        ] {
            let item = find.addItem(withTitle: title, action: #selector(SourceWindowController.findInSource(_:)),
                                    keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = action.rawValue
        }

        let view = addMenu("View", to: menu)
        for (title, key, action) in [
            ("Hide Source", "1", #selector(SourceWindowController.toggleSourcePane(_:))),
            ("Hide Inspector", "2", #selector(SourceWindowController.toggleInspectorPane(_:))),
            ("Show Evaluation Console", "3", #selector(SourceWindowController.toggleConsolePane(_:))),
        ] {
            view.addItem(withTitle: title, action: action, keyEquivalent: key)
                .keyEquivalentModifierMask = [.command, .option]
        }
        view.addItem(.separator())
        view.addItem(withTitle: "Frame Model", action: #selector(ScadrettoDocument.frameModel(_:)), keyEquivalent: "0")
        Self.addStandardViews(to: addMenu("Standard Views", to: view))
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

        view.addItem(.separator())
        view.addItem(withTitle: "Show Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Customize Toolbar…", action: #selector(NSWindow.runToolbarCustomizationPalette(_:)),
                     keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let model = addMenu("Model", to: menu)
        model.addItem(withTitle: "Evaluate Preview", action: #selector(ScadrettoDocument.retryPreview(_:)), keyEquivalent: "r")
        model.addItem(withTitle: "Cancel Evaluation", action: #selector(ScadrettoDocument.cancelPreview(_:)), keyEquivalent: "")
        model.addItem(withTitle: "Reveal Selected Source", action: #selector(ScadrettoDocument.revealSelectedInstance(_:)),
                      keyEquivalent: "")
        model.addItem(withTitle: "Show Worker Log…", action: #selector(ScadrettoDocument.showWorkerLog(_:)), keyEquivalent: "")

        // AppKit lists the open windows below these items.
        let windows = addMenu("Window", to: menu)
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
                        keyEquivalent: "")
        NSApp.windowsMenu = windows

        let help = addMenu("Help", to: menu)
        help.addItem(withTitle: "Open Example", action: #selector(openExample(_:)), keyEquivalent: "").target = self
        NSApp.helpMenu = help
        return menu
    }

    static func addStandardViews(to menu: NSMenu) {
        for (index, direction) in ViewportStandardView.allCases.enumerated() {
            menu.addItem(withTitle: direction.rawValue.capitalized,
                         action: #selector(ScadrettoDocument.standardView(_:)),
                         keyEquivalent: String(index + 1)).tag = index
        }
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


/// Populated on demand so AppKit remains the owner of the recent document list.
@MainActor
private final class RecentDocumentsMenu: NSMenu, NSMenuDelegate {
    override init(title: String) {
        super.init(title: title)
        delegate = self
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        let documents = NSDocumentController.shared
        let urls = documents.recentDocumentURLs
        let counts = Dictionary(grouping: urls, by: \.lastPathComponent)
        for url in urls {
            let filename = url.lastPathComponent
            let title = (counts[filename]?.count ?? 0) > 1 ? "\(filename) · \(url.deletingLastPathComponent().path)" : filename
            let item = addItem(withTitle: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
            item.target = self
        }
        if !urls.isEmpty { addItem(.separator()) }
        addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                keyEquivalent: "").target = documents
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }
}
