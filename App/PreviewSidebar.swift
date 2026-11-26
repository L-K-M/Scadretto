import AppKit
import ScadrettoEngineClient
import ScadrettoPlanning

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
    private let candidateList = NSPopUpButton()
    let inspector = DiameterInspector()
    let consolePane = NSView()
    var outlineFocusView: NSView { instanceOutline }
    var consoleFocusView: NSView { console }
    var hasConsoleDiagnostics: Bool {
        result?.diagnostics.contains { [.error, .warning, .deprecated].contains($0.severity) } == true
    }
    private var roots: [Item] = []
    private var byID: [UInt32: Item] = [:]
    private var candidates: [UInt32] = []
    private var result: EvaluationResult?
    private var messages: [ConsoleRow] = []
    private var current = false
    private var selectingOccurrence = false

    var onReveal: ((UInt32, WireSpan?, EvaluationResult) -> Void)?
    var onOccurrence: ((UInt32?) -> Void)?
    var onCandidate: ((UInt32) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        instanceOutline.setAccessibilityIdentifier("sceneOutline")
        instanceOutline.setAccessibilityLabel("Executed instances")
        instanceOutline.dataSource = self
        instanceOutline.delegate = self
        instanceOutline.headerView = nil
        instanceOutline.style = .inset
        instanceOutline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
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
        console.textContainerInset = NSSize(width: 10, height: 5)
        console.textColor = .textColor
        console.backgroundColor = .textBackgroundColor
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
        let propertiesHeading = NSTextField(labelWithString: "Properties")
        for heading in [instancesHeading, propertiesHeading, consoleHeading] {
            heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        }
        candidateList.setAccessibilityIdentifier("candidateList")
        candidateList.setAccessibilityLabel("Matching surface instances")
        candidateList.target = self
        candidateList.action = #selector(chooseCandidate)
        candidateList.isHidden = true

        let divider = NSBox()
        divider.boxType = .separator
        let panel = NSStackView(views: [instancesHeading, outlineScroll, candidateList, divider,
                                       propertiesHeading, inspector])
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 7
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        let outlineHeight = outlineScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 82)
        outlineHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            outlineScroll.widthAnchor.constraint(equalTo: panel.widthAnchor),
            outlineHeight,
            divider.widthAnchor.constraint(equalTo: panel.widthAnchor),
            candidateList.widthAnchor.constraint(lessThanOrEqualTo: panel.widthAnchor),
            inspector.widthAnchor.constraint(equalTo: panel.widthAnchor),
        ])
        inspector.onFinishEditing = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(instanceOutline)
        }
        configureConsole(scroll: consoleScroll)
        setCurrent(false)
        rebuildDiagnostics()
        rebuildConsole()
    }

    private func configureConsole(scroll: NSScrollView) {
        for menu in [diagnosticMenu, filter] {
            menu.controlSize = .small
            menu.lineBreakMode = .byTruncatingTail
            menu.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        consoleHeading.lineBreakMode = .byTruncatingTail
        let header = NSStackView(views: [consoleHeading, NSView(), diagnosticMenu, filter])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        for view in [header, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            consolePane.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: consolePane.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: consolePane.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: consolePane.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: consolePane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: consolePane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: consolePane.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(result: EvaluationResult, instances: [InstanceRecord], operations: [OperationRecord]) {
        self.result = result
        var roles: [UInt32: OperationRole] = [:]
        for operation in operations {
            for child in operation.children { roles[child.instanceID] = child.role }
        }
        byID = [:]
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
        showCandidates([])

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
        candidateList.isEnabled = isCurrent
        if !isCurrent { inspector.disableEditing() }
    }

    func showCandidates(_ ids: [UInt32]) {
        candidates = ids
        candidateList.removeAllItems()
        candidateList.isHidden = candidates.isEmpty
        guard !candidates.isEmpty else { return }
        candidateList.addItem(withTitle: "Choose a matching surface")
        for id in candidates {
            let title = byID[id]?.title ?? "Instance \(id)"
            candidateList.addItem(withTitle: "\(title) · \(id)")
        }
        candidateList.selectItem(at: 0)
    }

    @objc private func chooseCandidate() {
        let index = candidateList.indexOfSelectedItem - 1
        guard current, candidates.indices.contains(index) else { return }
        let id = candidates[index]
        showCandidates([])
        selectOccurrence(id)
        onCandidate?(id)
    }

    func selectOccurrence(_ id: UInt32?) {
        selectingOccurrence = true
        defer { selectingOccurrence = false }
        guard let id, let item = byID[id] else {
            instanceOutline.deselectAll(nil)
            return
        }
        var ancestors: [Item] = []
        var parent = item.instance.parent
        while let id = parent, let item = byID[id] {
            ancestors.append(item)
            parent = item.instance.parent
        }
        for parent in ancestors.reversed() { instanceOutline.expandItem(parent) }
        let row = instanceOutline.row(forItem: item)
        guard row >= 0 else { return }
        instanceOutline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        instanceOutline.scrollRowToVisible(row)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !selectingOccurrence, current else { return }
        showCandidates([])
        onOccurrence?(selectedInstance?.id)
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
        if content.length == 0 {
            let text = result == nil ? "No evaluation messages yet." : "No messages for this filter."
            content.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
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
        label.toolTip = item.title
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

struct DiameterInspection {
    struct Target: Equatable {
        let scene: UUID
        let instance: UInt32
        let property: String
    }

    let title: String
    var target: Target?
    var property = "Diameter"
    var fieldIdentifier = "diameterField"
    var choices: [String] = []
    var selectedChoice: Int?
    var binding = ""
    var scope = ""
    var value: Double?
    var writable = false
    var detail = ""
}

@MainActor
final class DiameterInspector: NSStackView, NSTextFieldDelegate {
    private let title = NSTextField(labelWithString: "")
    private let binding = NSTextField(wrappingLabelWithString: "")
    private let scope = NSTextField(wrappingLabelWithString: "")
    private let choices = NSPopUpButton()
    private let dimension = NSTextField(labelWithString: "Diameter")
    private let field = NSTextField()
    private let empty = NSTextField(wrappingLabelWithString: "Select an instance or click the model to inspect its properties.")
    var onFinishEditing: (() -> Void)?
    private let fieldRow = NSStackView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var inspection: DiameterInspection?
    /// The selection and property VoiceOver last heard about, so a refresh of the same
    /// selection after an evaluation stays quiet.
    private var announcedSelection: (title: String, property: String)?

    var onCommit: ((String) -> Void)?
    var onChoice: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        // A group keeps the labels and field inside reachable and carries the summary as its value.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("inspector")
        setAccessibilityLabel("Property inspector")
        title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        title.lineBreakMode = .byTruncatingTail
        title.setAccessibilityIdentifier("inspectorSelection")
        binding.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        binding.textColor = .secondaryLabelColor
        scope.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        empty.textColor = .secondaryLabelColor
        scope.setAccessibilityIdentifier("targetScope")
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.setAccessibilityIdentifier("editStatus")
        choices.target = self
        choices.action = #selector(changeProperty)
        choices.setAccessibilityIdentifier("propertyChoice")
        choices.setAccessibilityLabel("Choose a property")
        choices.lineBreakMode = .byTruncatingTail

        fieldRow.orientation = .horizontal
        fieldRow.alignment = .firstBaseline
        dimension.lineBreakMode = .byTruncatingTail
        dimension.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fieldRow.addArrangedSubview(dimension)
        field.cell = PropertyFieldCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.drawsBackground = true
        field.target = self
        field.action = #selector(commit)
        field.delegate = self
        field.setAccessibilityIdentifier("diameterField")
        field.setAccessibilityLabel("Diameter in model units")
        field.setAccessibilityHelp("Press Return to apply the value or Escape to discard the draft.")
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        fieldRow.addArrangedSubview(field)
        for view in [empty, title, choices, binding, scope, fieldRow, detail] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        }
        show(nil)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ inspection: DiameterInspection?) {
        let sameProperty = self.inspection?.target == inspection?.target
            && self.inspection?.value == inspection?.value
        if !sameProperty { discardDraft() }
        self.inspection = inspection
        empty.isHidden = inspection != nil
        guard let inspection else {
            for view in [title, choices, binding, scope, fieldRow, detail] { view.isHidden = true }
            setAccessibilityValue(nil)
            announcedSelection = nil
            return
        }
        let summary = Self.summary(of: inspection)
        setAccessibilityValue(summary)
        if announcedSelection.map({ $0 != (inspection.title, inspection.property) }) ?? true {
            announcedSelection = (inspection.title, inspection.property)
            Announcements.post(summary)
        }
        if choices.itemTitles != inspection.choices {
            choices.removeAllItems()
            choices.addItems(withTitles: inspection.choices)
        }
        // Without a selection even a single property needs an explicit choice.
        choices.isHidden = inspection.choices.isEmpty
            || (inspection.choices.count == 1 && inspection.selectedChoice != nil)
        choices.isEnabled = true
        choices.selectItem(at: inspection.selectedChoice ?? -1)
        for (label, text) in [(title, inspection.title), (binding, inspection.binding),
                              (scope, inspection.scope), (detail, inspection.detail)] {
            label.stringValue = text
            label.toolTip = text
            label.isHidden = text.isEmpty
        }
        fieldRow.isHidden = inspection.value == nil
        dimension.stringValue = inspection.property
        field.setAccessibilityIdentifier(inspection.fieldIdentifier)
        field.setAccessibilityLabel(inspection.property)
        if field.currentEditor() == nil {
            field.stringValue = committedValue
        }
        field.isEnabled = inspection.writable
    }

    /// The breadcrumb, property, evaluated value and scope in one line, or what the selection
    /// needs next when it has no value.
    private static func summary(of inspection: DiameterInspection) -> String {
        let value = inspection.value.map { "\(inspection.property) \(PropertyEntry.text(of: $0))" }
        let next = value == nil ? inspection.detail : ""
        return [inspection.title, value ?? "", inspection.scope, next].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    func disableEditing() {
        discardDraft()
        choices.isEnabled = false
        field.isEnabled = false
    }

    func showPreview(_ diameter: Double?) {
        if let diameter, let initial = inspection?.value {
            detail.stringValue = "Preview · \(PropertyEntry.text(of: initial)) → \(PropertyEntry.text(of: diameter))"
            detail.isHidden = false
        } else {
            showMessage(inspection?.detail ?? "")
        }
    }

    func showMessage(_ text: String) {
        detail.stringValue = text
        detail.isHidden = text.isEmpty
    }

    private var committedValue: String {
        inspection?.value.map { PropertyEntry.text(of: $0) } ?? ""
    }

    private func discardDraft() {
        if field.currentEditor() != nil {
            field.abortEditing()
            onFinishEditing?()
        }
        field.stringValue = committedValue
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        field.stringValue = committedValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.cancelOperation(_:)):
            discardDraft()
            showMessage(inspection?.detail ?? "")
        case #selector(NSResponder.insertNewline(_:)):
            onCommit?(textView.string)
        default:
            return false
        }
        return true
    }

    @objc private func commit() { onCommit?(field.stringValue) }
    @objc private func changeProperty() {
        onChoice?(choices.indexOfSelectedItem)
    }
}

private final class PropertyFieldCell: NSTextFieldCell {
    private let editor = PropertyFieldEditor()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor
    }
}

/// A draft belongs to this field. Only the validated Return action enters document history.
private final class PropertyFieldEditor: NSTextView {
    private let draftHistory = UndoManager()

    override var undoManager: UndoManager? { draftHistory }

    init() {
        super.init(frame: .zero, textContainer: nil)
        isFieldEditor = true
        allowsUndo = true
    }

    required init?(coder: NSCoder) { nil }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        draftHistory.removeAllActions()
        return true
    }
}
