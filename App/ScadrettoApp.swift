import AppKit

@main
final class ScadrettoApp: NSObject, NSApplicationDelegate {
    static func main() {
        let application = NSApplication.shared
        let delegate = ScadrettoApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSDocumentController.shared.autosavingDelay = 0
        NSApp.mainMenu = makeMainMenu()
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
        file.addItem(withTitle: "Revert to Saved", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")

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
        return menu
    }

    private func addMenu(_ title: String, to parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        parent.addItem(item)
        return submenu
    }
}
