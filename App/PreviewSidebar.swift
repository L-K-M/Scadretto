import AppKit
import ScadrettoEngineClient

@MainActor
final class PreviewSidebar: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate {
    private final class Item: NSObject {
        let instance: InstanceRecord
        let role: OperationRole?
        var children: [Item] = []

        init(instance: InstanceRecord, role: OperationRole?) {
            self.instance = instance
            self.role = role
        }

        var title: String {
            let bindings = instance.iteration.sorted(by: { $0.key < $1.key }).map {
                "\($0.key) = \($0.value.formatted(.number.grouping(.never)))"
            }
            let name = role == .subtracted ? "− \(instance.name)" : instance.name
            return bindings.isEmpty ? name : "\(name)  (\(bindings.joined(separator: ", ")))"
        }
    }

    private struct ConsoleRow {
        let text: String
        let group: String
        let fileID: UInt32?
        let span: WireSpan?
    }

    private let instanceOutline = NSOutlineView()
    private let console = NSTextView(usingTextLayoutManager: false)
    private let filter = NSPopUpButton()
    private let diagnosticMenu = NSPopUpButton()
    private let consoleHeading = NSTextField(labelWithString: "Evaluation Console")
    private var roots: [Item] = []
    private var result: EvaluationResult?
    private var messages: [ConsoleRow] = []
    private var current = false

    var onReveal: ((UInt32, WireSpan?, EvaluationResult) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        instanceOutline.setAccessibilityIdentifier("sceneOutline")
        instanceOutline.setAccessibilityLabel("Executed instances")
        instanceOutline.dataSource = self
        instanceOutline.delegate = self
        instanceOutline.headerView = nil
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("instance"))
        instanceOutline.addTableColumn(column)
        instanceOutline.outlineTableColumn = column
        instanceOutline.target = self
        instanceOutline.doubleAction = #selector(revealOccurrence)

        let consoleScroll = NSScrollView()
        consoleScroll.hasVerticalScroller = true
        consoleScroll.autohidesScrollers = true
        consoleScroll.documentView = console
        console.isEditable = false
        console.isSelectable = true
        console.textContainerInset = NSSize(width: 6, height: 5)
        console.isRichText = false
        console.autoresizingMask = [.width]
        console.textContainer?.widthTracksTextView = true
        console.setAccessibilityIdentifier("console")
        console.setAccessibilityLabel("Evaluation console")
        console.delegate = self

        diagnosticMenu.setAccessibilityLabel("Jump to a diagnostic")
        diagnosticMenu.setAccessibilityIdentifier("modelDiagnostics")
        diagnosticMenu.target = self
        diagnosticMenu.action = #selector(revealDiagnostic)
        filter.addItems(withTitles: ["All messages", "Warnings and errors", "Echo"])
        filter.target = self
        filter.action = #selector(rebuildConsole)
        filter.setAccessibilityLabel("Console message filter")

        let outlineScroll = NSScrollView()
        outlineScroll.hasVerticalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.documentView = instanceOutline

        let instancesHeading = NSTextField(labelWithString: "Instances")
        instancesHeading.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        consoleHeading.font = instancesHeading.font
        let panel = NSStackView(views: [instancesHeading, outlineScroll, consoleHeading,
                                       diagnosticMenu, filter, consoleScroll])
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 6
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            outlineScroll.widthAnchor.constraint(equalTo: panel.widthAnchor),
            outlineScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
            consoleScroll.widthAnchor.constraint(equalTo: panel.widthAnchor),
            consoleScroll.heightAnchor.constraint(equalTo: outlineScroll.heightAnchor, multiplier: 0.65),
            diagnosticMenu.widthAnchor.constraint(lessThanOrEqualTo: panel.widthAnchor),
            filter.widthAnchor.constraint(lessThanOrEqualTo: panel.widthAnchor),
        ])
        setCurrent(false)
        rebuildDiagnostics()
    }

    required init?(coder: NSCoder) { nil }

    func show(result: EvaluationResult, instances: [InstanceRecord], operations: [OperationRecord]) {
        self.result = result
        var roles: [UInt32: OperationRole] = [:]
        for operation in operations {
            for child in operation.children { roles[child.instanceID] = child.role }
        }
        var byID: [UInt32: Item] = [:]
        roots = []
        for instance in instances {
            let item = Item(instance: instance, role: roles[instance.id])
            if let parent = instance.parent.flatMap({ byID[$0] }) {
                parent.children.append(item)
            } else {
                roots.append(item)
            }
            byID[instance.id] = item
        }
        instanceOutline.reloadData()
        for root in roots {
            instanceOutline.expandItem(root)
            let visibleOperands: [Item]
            if root.children.count == 1 {
                let child = root.children[0]
                instanceOutline.expandItem(child)
                visibleOperands = child.children
            } else {
                visibleOperands = root.children
            }
            for operand in visibleOperands where ["for", "intersection_for"].contains(operand.instance.name) {
                instanceOutline.expandItem(operand)
            }
        }
        instanceOutline.deselectAll(nil)

        messages = result.console.map {
            ConsoleRow(text: $0.text, group: $0.group, fileID: $0.fileID ?? $0.span?.fileID, span: $0.span)
        }
        if result.droppedConsoleMessages > 0 {
            messages.append(ConsoleRow(text: "\(result.droppedConsoleMessages) messages omitted.",
                                       group: "warning", fileID: nil, span: nil))
        }
        rebuildDiagnostics()
        rebuildConsole()
        setCurrent(true)
    }

    func setCurrent(_ isCurrent: Bool) {
        current = isCurrent
        instanceOutline.isEnabled = isCurrent
        consoleHeading.stringValue = !isCurrent && result != nil ? "Evaluation Console · Out of Date" : "Evaluation Console"
        diagnosticMenu.isEnabled = isCurrent && !(result?.diagnostics.isEmpty ?? true)
    }

    private func rebuildDiagnostics() {
        diagnosticMenu.removeAllItems()
        let diagnostics = result?.diagnostics ?? []
        let title = diagnostics.isEmpty ? "No diagnostics" : "\(diagnostics.count) diagnostics"
        diagnosticMenu.addItem(withTitle: title)
        for (index, diagnostic) in diagnostics.enumerated() {
            let line = diagnostic.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? diagnostic.message
            let summary = String(line.prefix(75))
            diagnosticMenu.addItem(withTitle: "\(diagnostic.severity.rawValue.capitalized) · \(summary)")
            diagnosticMenu.lastItem?.tag = index + 1
        }
        diagnosticMenu.selectItem(at: 0)
    }

    @objc private func revealDiagnostic() {
        guard let result, let tag = diagnosticMenu.selectedItem?.tag, tag > 0 else { return }
        diagnosticMenu.selectItem(at: 0)
        let diagnostic = result.diagnostics[tag - 1]
        if let file = diagnostic.fileID ?? diagnostic.span?.fileID { onReveal?(file, diagnostic.span, result) }
    }

    @objc private func rebuildConsole() {
        let content = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for (index, row) in messages.enumerated() {
            let group = row.group.lowercased()
            if filter.indexOfSelectedItem == 1 && ["echo", "trace"].contains(group) { continue }
            if filter.indexOfSelectedItem == 2 && group != "echo" { continue }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if row.fileID != nil { attributes[.link] = NSNumber(value: index) }
            content.append(NSAttributedString(string: row.text + "\n", attributes: attributes))
        }
        console.textStorage?.setAttributedString(content)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard current, let result, let number = link as? NSNumber, messages.indices.contains(number.intValue) else {
            return true
        }
        let row = messages[number.intValue]
        if let file = row.fileID { onReveal?(file, row.span, result) }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Item)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Item)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let label = NSTextField(labelWithString: item.title)
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel(item.title)
        return label
    }

    var canRevealOccurrence: Bool { selectedInstance?.span != nil }

    private var selectedInstance: InstanceRecord? {
        guard current, instanceOutline.selectedRow >= 0 else { return nil }
        return (instanceOutline.item(atRow: instanceOutline.selectedRow) as? Item)?.instance
    }

    @objc func revealOccurrence() {
        guard let result, let span = selectedInstance?.span else { return }
        onReveal?(span.fileID, span, result)
    }
}
