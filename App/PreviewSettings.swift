import AppKit

/// Preview settings shared by every document: library folders searched before OpenSCADPATH and
/// the user library, and the evaluation time limit. A change posts `didChange`, including a
/// change another program writes to the defaults.
@MainActor
final class PreviewSettings: NSObject {
    static let shared = PreviewSettings()
    static let didChange = Notification.Name("ScadrettoPreviewSettingsDidChange")
    static let defaultTimeout: TimeInterval = 20
    static let timeoutRange: ClosedRange<TimeInterval> = 1...3_600

    private enum Key {
        static let libraryRoots = "libraryRoots"
        static let timeout = "previewTimeoutSeconds"
        static let all = [libraryRoots, timeout]
    }

    private let defaults = UserDefaults.standard

    private override init() {
        super.init()
        // Key-value observing also sees writes made outside the app, such as `defaults write`.
        for key in Key.all { defaults.addObserver(self, forKeyPath: key, context: nil) }
    }

    /// Folders searched first, in this order.
    var libraryRoots: [URL] {
        get {
            defaults.stringArray(forKey: Key.libraryRoots)?.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? []
        }
        set { defaults.set(newValue.map(\.path), forKey: Key.libraryRoots) }
    }

    var timeout: TimeInterval {
        get {
            let stored = defaults.double(forKey: Key.timeout)
            guard stored.isFinite, stored > 0 else { return Self.defaultTimeout }
            return min(max(stored, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
        }
        set {
            guard newValue.isFinite else { return }
            defaults.set(min(max(newValue, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound),
                         forKey: Key.timeout)
        }
    }

    /// Returns both settings to their defaults.
    func reset() {
        for key in Key.all { defaults.removeObject(forKey: key) }
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?,
                                           context: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.didChange, object: PreviewSettings.shared)
        }
    }
}

/// Settings window: the ordered library folders, the preview time limit and the 3D mouse.
@MainActor
final class PreviewSettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate {
    private let settings: PreviewSettings
    private let table = NSTableView()
    private let remove = NSButton()
    private let moveUp = NSButton()
    private let moveDown = NSButton()
    private let timeoutField = NSTextField()
    private var roots: [URL] = []
    private var changeObserver: (any NSObjectProtocol)?

    init(settings: PreviewSettings = .shared) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Settings"
        window.identifier = NSUserInterfaceItemIdentifier("settingsWindow")
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        reload()
        // A change written elsewhere, such as with `defaults write`, refreshes the window, so its
        // next edit starts from the stored folders instead of writing an older list back.
        changeObserver = NotificationCenter.default.addObserver(
            forName: PreviewSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsDidChange() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func makeContent() -> NSView {
        let heading = NSTextField(labelWithString: "Library folders")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let explanation = NSTextField(wrappingLabelWithString:
            "include and use look in these folders first, in this order, then in OPENSCADPATH and "
            + "~/Documents/OpenSCAD/libraries.")
        explanation.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.title = "Folder"
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("libraryRootsTable")
        table.setAccessibilityLabel("Library folders")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let add = button("Add Folder…", identifier: "addLibraryRoot", action: #selector(addFolder(_:)))
        configure(remove, title: "Remove", identifier: "removeLibraryRoot", action: #selector(removeFolder(_:)))
        configure(moveUp, title: "Move Up", identifier: "moveLibraryRootUp", action: #selector(moveFolderUp(_:)))
        configure(moveDown, title: "Move Down", identifier: "moveLibraryRootDown",
                  action: #selector(moveFolderDown(_:)))
        let buttons = NSStackView(views: [add, remove, moveUp, moveDown])

        let timeoutLabel = NSTextField(labelWithString: "Preview time limit:")
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: PreviewSettings.timeoutRange.lowerBound)
        formatter.maximum = NSNumber(value: PreviewSettings.timeoutRange.upperBound)
        timeoutField.formatter = formatter
        timeoutField.cell?.sendsActionOnEndEditing = true
        timeoutField.target = self
        timeoutField.action = #selector(timeoutChanged(_:))
        timeoutField.setAccessibilityIdentifier("previewTimeoutField")
        timeoutField.setAccessibilityLabel("Preview time limit in seconds")
        timeoutField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let timeout = NSStackView(views: [timeoutLabel, timeoutField, NSTextField(labelWithString: "seconds")])

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [heading, explanation, scroll, buttons, timeout, separator,
                                        ThreeDMouseSettingsSection()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        explanation.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        separator.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        return stack
    }

    private func button(_ title: String, identifier: String, action: Selector) -> NSButton {
        let button = NSButton()
        configure(button, title: title, identifier: identifier, action: action)
        return button
    }

    private func configure(_ button: NSButton, title: String, identifier: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
    }

    private func reload(selecting row: Int? = nil) {
        roots = settings.libraryRoots
        table.reloadData()
        if let row, roots.indices.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        timeoutField.integerValue = Int(settings.timeout)
        updateButtons()
    }

    private func settingsDidChange() {
        // The window's own edits have already reloaded by the time their notification arrives.
        guard roots != settings.libraryRoots || timeoutField.integerValue != Int(settings.timeout) else { return }
        reload(selecting: table.selectedRow)
    }

    private func updateButtons() {
        let row = table.selectedRow
        remove.isEnabled = roots.indices.contains(row)
        moveUp.isEnabled = row > 0
        moveDown.isEnabled = roots.indices.contains(row) && row < roots.count - 1
    }

    @objc private func addFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders for include and use to search."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let known = Set(roots.map(\.standardizedFileURL))
            let added = panel.urls.map(\.standardizedFileURL).filter { !known.contains($0) }
            guard !added.isEmpty else { return }
            settings.libraryRoots = roots + added
            reload(selecting: roots.count + added.count - 1)
        }
    }

    @objc private func removeFolder(_ sender: Any?) {
        let row = table.selectedRow
        guard roots.indices.contains(row) else { return }
        var changed = roots
        changed.remove(at: row)
        settings.libraryRoots = changed
        reload(selecting: min(row, changed.count - 1))
    }

    @objc private func moveFolderUp(_ sender: Any?) { move(by: -1) }
    @objc private func moveFolderDown(_ sender: Any?) { move(by: 1) }

    private func move(by offset: Int) {
        let row = table.selectedRow
        let target = row + offset
        guard roots.indices.contains(row), roots.indices.contains(target) else { return }
        var changed = roots
        changed.swapAt(row, target)
        settings.libraryRoots = changed
        reload(selecting: target)
    }

    @objc private func timeoutChanged(_ sender: NSTextField) {
        guard sender.integerValue > 0, TimeInterval(sender.integerValue) != settings.timeout else { return }
        settings.timeout = TimeInterval(sender.integerValue)
        reload(selecting: table.selectedRow)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { roots.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: roots[row].path)
        label.lineBreakMode = .byTruncatingMiddle
        label.setAccessibilityIdentifier("libraryRoot")
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // Ends editing so a time limit typed without Return still takes effect.
    func windowWillClose(_ notification: Notification) { window?.makeFirstResponder(nil) }
}
