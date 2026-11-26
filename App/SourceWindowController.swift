import AppKit
import ScadrettoCore
import ScadrettoSyntax
import ScadrettoViewport

final class SourceWindowController: NSWindowController, NSTextViewDelegate, NSToolbarDelegate, NSUserInterfaceValidations {
    private weak var sourceDocument: ScadrettoDocument?
    private let editor = SourceTextView(usingTextLayoutManager: false)
    private let scroll = NSScrollView()
    private let layout = NSSplitViewController()
    private let sourcePane = NSViewController()
    private lazy var sourceItem = NSSplitViewItem(viewController: sourcePane)
    private lazy var inspectorItem = NSSplitViewItem(inspectorWithViewController: host(previewWorkspace.sidebar))
    private let status = NSTextField(labelWithString: "")
    private let parser = SyntaxParser()
    private var parseTask: Task<Void, Never>?
    private var snapshot: SourceSnapshot?
    private var mirroring = false
    private var ruler: LineRuler?
    private var placedDividers = false
    private var restoredSourceWidth: CGFloat?
    private var restoredInspectorWidth: CGFloat?
    private let position = NSTextField(labelWithString: "")
    let previewWorkspace = PreviewWorkspace()

    var selection: NSRange { editor.selectedRange() }
    var sourceHasFocus: Bool { window?.firstResponder === editor }

    /// One more than the highest number among the document's other windows, so each title
    /// names a different window in the Window menu.
    private let windowNumber: Int

    init(document: ScadrettoDocument, restoringWindowNumber: Int? = nil) {
        self.sourceDocument = document
        windowNumber = restoringWindowNumber
            ?? (document.windowControllers.compactMap { ($0 as? SourceWindowController)?.windowNumber }.max() ?? 0) + 1
        let workspaceSize = NSSize(width: 1160, height: 690)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: workspaceSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.contentMinSize = NSSize(width: 880, height: 440)
        window.identifier = Self.identifier(for: windowNumber)
        window.isRestorable = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        configureEditor()
        configureSourcePane()

        layout.splitView.isVertical = true
        layout.splitView.dividerStyle = .thin
        let modelItem = NSSplitViewItem(viewController: host(previewWorkspace.panel))
        modelItem.minimumThickness = 290
        for (item, minimum, fraction) in [(sourceItem, 330.0, 0.34), (inspectorItem, 250.0, 0.24)] {
            item.canCollapse = true
            item.canCollapseFromWindowResize = false
            item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            item.minimumThickness = minimum
            item.maximumThickness = 620
            item.preferredThicknessFraction = fraction
            item.holdingPriority = .defaultHigh
        }
        for item in [sourceItem, modelItem, inspectorItem] { layout.addSplitViewItem(item) }
        window.contentViewController = layout

        let toolbar = NSToolbar(identifier: "Scadretto.Document")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.autorecalculatesKeyViewLoop = true
        window.initialFirstResponder = editor
        // Installing a split view controller can resize the window to its minimum fitting size.
        window.setContentSize(workspaceSize)
        window.center()
        previewWorkspace.onConsoleVisibilityChange = { [weak self] in self?.paneVisibilityChanged() }
        previewWorkspace.onEvaluationActivityChange = { [weak self] in self?.window?.toolbar?.validateVisibleItems() }
    }

    private func host(_ view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    private func configureSourcePane() {
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        let ruler = LineRuler(scroll: scroll, editor: editor) { [weak self] offset in
            self?.snapshot?.buffer.lineNumber(atUTF16Offset: offset) ?? 1
        }
        scroll.verticalRulerView = ruler
        self.ruler = ruler

        let footer = NSStackView(views: [status, NSView(), position])
        footer.orientation = .horizontal
        footer.alignment = .firstBaseline
        for label in [status, position] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        status.setAccessibilityIdentifier("statusArea")
        let content = NSView()
        sourcePane.view = content
        for view in [scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 5),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
        ])
    }

    // MARK: - Window state and pane commands

    private static let windowIdentifierPrefix = "Scadretto.Document."

    private static func identifier(for windowNumber: Int) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(windowIdentifierPrefix + String(windowNumber))
    }

    static func windowNumber(for identifier: NSUserInterfaceItemIdentifier) -> Int? {
        guard identifier.rawValue.hasPrefix(windowIdentifierPrefix) else { return nil }
        return Int(identifier.rawValue.dropFirst(windowIdentifierPrefix.count))
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        windowNumber > 1 ? "\(displayName) (\(windowNumber))" : displayName
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !placedDividers else { return }
        placeInitialDividers()
    }

    func placeInitialDividers() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let split = layout.splitView
        let width = split.bounds.width
        guard !placedDividers, width >= 880 else { return }
        let sourceWidth = min(restoredSourceWidth ?? width * 0.34, width - 560)
        let inspectorWidth = min(restoredInspectorWidth ?? 272, width - sourceWidth - 292)
        if !sourceItem.isCollapsed { split.setPosition(sourceWidth, ofDividerAt: 0) }
        if !inspectorItem.isCollapsed { split.setPosition(width - inspectorWidth, ofDividerAt: 1) }
        placedDividers = true
        resetSourceScroll()
    }

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(sourceItem.isCollapsed, forKey: "sourceHidden")
        coder.encode(inspectorItem.isCollapsed, forKey: "inspectorHidden")
        coder.encode(previewWorkspace.isConsoleVisible, forKey: "consoleVisible")
        if !sourceItem.isCollapsed { coder.encode(Double(sourcePane.view.bounds.width), forKey: "sourceWidth") }
        if !inspectorItem.isCollapsed {
            coder.encode(Double(previewWorkspace.sidebar.bounds.width), forKey: "inspectorWidth")
        }
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        if coder.containsValue(forKey: "sourceWidth") { restoredSourceWidth = coder.decodeDouble(forKey: "sourceWidth") }
        if coder.containsValue(forKey: "inspectorWidth") {
            restoredInspectorWidth = coder.decodeDouble(forKey: "inspectorWidth")
        }
        sourceItem.isCollapsed = coder.decodeBool(forKey: "sourceHidden")
        inspectorItem.isCollapsed = coder.decodeBool(forKey: "inspectorHidden")
        previewWorkspace.setConsoleVisible(coder.decodeBool(forKey: "consoleVisible"))
        placedDividers = false
        placeInitialDividers()
        if sourceItem.isCollapsed {
            window?.initialFirstResponder = previewWorkspace.viewport
        }
    }

    @IBAction func toggleSourcePane(_ sender: Any?) {
        let hiding = !sourceItem.isCollapsed
        if hiding && focusIsInside(sourcePane.view) {
            finishComposition()
            window?.makeFirstResponder(previewWorkspace.viewport)
        }
        sourceItem.isCollapsed = hiding
        if !hiding {
            window?.makeFirstResponder(editor)
        }
        paneVisibilityChanged()
    }

    @IBAction func toggleInspectorPane(_ sender: Any?) {
        let hiding = !inspectorItem.isCollapsed
        if hiding && focusIsInside(previewWorkspace.sidebar) {
            window?.makeFirstResponder(sourceItem.isCollapsed ? previewWorkspace.viewport : editor)
        }
        inspectorItem.isCollapsed = hiding
        if !hiding { window?.makeFirstResponder(previewWorkspace.sidebar.outlineFocusView) }
        paneVisibilityChanged()
    }

    @IBAction func toggleConsolePane(_ sender: Any?) {
        let hiding = previewWorkspace.isConsoleVisible
        if hiding && focusIsInside(previewWorkspace.sidebar.consolePane) {
            window?.makeFirstResponder(sourceItem.isCollapsed ? previewWorkspace.viewport : editor)
        }
        previewWorkspace.setConsoleVisible(!hiding)
        if !hiding { window?.makeFirstResponder(previewWorkspace.sidebar.consoleFocusView) }
    }

    private func focusIsInside(_ pane: NSView) -> Bool {
        (window?.firstResponder as? NSView)?.isDescendant(of: pane) == true
    }

    private func paneVisibilityChanged() {
        window?.invalidateRestorableState()
        window?.toolbar?.validateVisibleItems()
    }

    @IBAction func findInSource(_ sender: NSMenuItem) {
        reveal(nil)
        editor.performTextFinderAction(sender)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let shown: Bool
        let name: String
        switch item.action {
        case #selector(toggleSourcePane(_:)):
            shown = !sourceItem.isCollapsed
            name = "Source"
        case #selector(toggleInspectorPane(_:)):
            shown = !inspectorItem.isCollapsed
            name = "Inspector"
        case #selector(toggleConsolePane(_:)):
            shown = previewWorkspace.isConsoleVisible
            name = "Evaluation Console"
        case #selector(findInSource(_:)):
            if let menu = item as? NSMenuItem, menu.tag == NSTextFinder.Action.setSearchString.rawValue {
                return editor.selectedRange().length > 0
            }
            return true
        default:
            return true
        }
        let title = "\(shown ? "Hide" : "Show") \(name)"
        if let menu = item as? NSMenuItem { menu.title = title }
        if let toolbar = item as? NSToolbarItem {
            toolbar.toolTip = title
            toolbar.menuFormRepresentation?.title = title
        }
        return true
    }

    // MARK: - Toolbar

    private static let sourceTool = NSToolbarItem.Identifier("Source")
    private static let inspectorTool = NSToolbarItem.Identifier("Inspector")
    private static let consoleTool = NSToolbarItem.Identifier("Console")
    private static let frameTool = NSToolbarItem.Identifier("FrameModel")
    private static let cameraTool = NSToolbarItem.Identifier("Camera")
    private static let previewTool = NSToolbarItem.Identifier("EvaluatePreview")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.cameraTool, .space, Self.previewTool,
         .space, Self.sourceTool, Self.consoleTool, Self.inspectorTool]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Self.frameTool]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.cameraTool {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Camera"
            item.toolTip = "Frame Model and Camera Views"
            item.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Camera")
            item.action = #selector(ScadrettoDocument.frameModel(_:))
            let menu = NSMenu()
            menu.addItem(withTitle: "Frame Model", action: #selector(ScadrettoDocument.frameModel(_:)),
                         keyEquivalent: "")
            menu.addItem(.separator())
            ScadrettoApp.addStandardViews(to: menu)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Orthographic Projection", action: #selector(ScadrettoDocument.toggleOrthographic(_:)),
                         keyEquivalent: "")
            item.menu = menu
            return item
        }

        let label: String
        let symbol: String
        let action: Selector
        switch identifier {
        case Self.sourceTool: (label, symbol, action) = ("Source", "sidebar.leading", #selector(toggleSourcePane(_:)))
        case Self.inspectorTool: (label, symbol, action) = ("Inspector", "sidebar.trailing", #selector(toggleInspectorPane(_:)))
        case Self.consoleTool: (label, symbol, action) = ("Evaluation Console", "terminal", #selector(toggleConsolePane(_:)))
        case Self.frameTool: (label, symbol, action) = ("Frame Model", "viewfinder",
                                                      #selector(ScadrettoDocument.frameModel(_:)))
        case Self.previewTool: (label, symbol, action) = ("Evaluate Preview", "arrow.clockwise",
                                                         #selector(ScadrettoDocument.retryPreview(_:)))
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.menuFormRepresentation = NSMenuItem(title: label, action: action, keyEquivalent: "")
        return item
    }

    // MARK: - Source editor

    private func configureEditor() {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.font = font
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.insertionPointColor = .textColor
        editor.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 12, height: 10)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = editor.maxSize
        editor.setAccessibilityIdentifier("sourceEditor")
        editor.delegate = self
        editor.sourceDocument = sourceDocument
        editor.onCompositionEnd = { [weak self] in
            self?.commitComposedText()
            self?.onCompositionFinished?()
        }
    }

    /// Shows the document's text. Without a selection, as for an edit made in another window of
    /// the same document, the current selection follows the text around the change.
    func show(_ snapshot: SourceSnapshot, selecting requested: NSRange?) {
        let firstView = self.snapshot == nil
        self.snapshot = snapshot
        mirroring = true
        var selection = requested ?? editor.selectedRange()
        if !editor.string.utf16.elementsEqual(snapshot.buffer.displayText.utf16) {
            let change = TextDelta.between(editor.string, snapshot.buffer.displayText)
            if requested == nil { selection = Self.follow(selection, through: change) }
            let replacement = NSAttributedString(string: change.replacement, attributes: editor.typingAttributes)
            editor.textStorage?.replaceCharacters(in: change.range, with: replacement)
            editor.didChangeText()
        }
        let length = snapshot.buffer.utf16Length
        let location = min(selection.location, length)
        editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        if firstView { resetSourceScroll() }
        mirroring = false
        ruler?.needsDisplay = true
        updateSourcePosition()
        scheduleSyntax(snapshot)
    }

    /// Keeps a selection before the change, moves one after it by the change in length and
    /// collapses one that overlaps it to the end of the new text.
    private static func follow(_ selection: NSRange, through change: TextDelta) -> NSRange {
        let inserted = change.replacement.utf16.count
        if NSMaxRange(selection) <= change.range.location { return selection }
        if selection.location >= NSMaxRange(change.range) {
            return NSRange(location: selection.location + inserted - change.range.length, length: selection.length)
        }
        return NSRange(location: change.range.location + inserted, length: 0)
    }

    /// Recent macOS releases lay the line-number ruler over the clip view and inset its content
    /// rather than narrowing it, so the first visible column sits at a negative bounds origin.
    /// Scrolling to zero would leave the start of each line under the ruler.
    private func resetSourceScroll() {
        let insets = scroll.contentView.contentInsets
        scroll.contentView.scroll(to: NSPoint(x: -insets.left, y: -insets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextInRanges affectedRanges: [NSValue],
        replacementStrings: [String]?
    ) -> Bool {
        guard let replacementStrings else { return true }
        if mirroring || editor.updatingComposition || editor.hasMarkedText() { return true }
        guard let sourceDocument else { return false }
        sourceDocument.changeText(affectedRanges.map(\.rangeValue),
                                  replacements: replacementStrings, coalescing: true, from: self)
        return false
    }

    private func updateSourcePosition() {
        guard let snapshot else { return }
        position.stringValue = "Line \(snapshot.buffer.lineNumber(atUTF16Offset: editor.selectedRange().location))"
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateSourcePosition()
        if !mirroring && !editor.updatingComposition && !editor.hasMarkedText() {
            sourceDocument?.endTypingGroup()
        }
    }

    func finishComposition() {
        if editor.hasMarkedText() { editor.unmarkText() }
    }

    var isComposing: Bool { editor.hasMarkedText() }
    /// Called after composed text reaches the document, or after the composition is cancelled.
    var onCompositionFinished: (() -> Void)?

    private(set) var currentSyntax: SyntaxSnapshot?
    var onSyntaxReady: (() -> Void)?

    func highlightSource(_ range: NSRange) {
        guard !isComposing else { return }
        let clip = scroll.contentView
        let originalX = clip.bounds.minX
        // Text under the ruler's inset is not visible, even though it lies inside the bounds.
        let visibleMinX = originalX + clip.contentInsets.left
        let visibleMaxX = clip.bounds.maxX - clip.contentInsets.right
        let tokenRect = editor.layoutManager.flatMap { layout in
            editor.textContainer.map { container in
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                return layout.boundingRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
            }
        }
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
        if let tokenRect, tokenRect.minX >= visibleMinX, tokenRect.maxX <= visibleMaxX {
            clip.scroll(to: NSPoint(x: originalX, y: clip.bounds.minY))
            scroll.reflectScrolledClipView(clip)
        }
    }

    func reveal(_ range: NSRange?) {
        if sourceItem.isCollapsed { toggleSourcePane(nil) }
        if let range {
            editor.setSelectedRange(range)
            editor.scrollRangeToVisible(range)
        }
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
    }

    private func commitComposedText() {
        guard let snapshot, !editor.string.utf16.elementsEqual(snapshot.buffer.displayText.utf16) else { return }
        let change = TextDelta.between(snapshot.buffer.displayText, editor.string)
        sourceDocument?.changeText([change.range], replacements: [change.replacement], coalescing: false, from: self)
    }

    private func scheduleSyntax(_ snapshot: SourceSnapshot) {
        parseTask?.cancel()
        let parser = self.parser
        parseTask = Task { [weak self] in
            do {
                let syntax = try await parser.parse(snapshot)
                guard let self, !Task.isCancelled, self.snapshot?.revision == syntax.revision else { return }
                currentSyntax = syntax
                paint(syntax, with: snapshot.buffer)
                onSyntaxReady?()
            } catch {
                guard !Task.isCancelled, self?.snapshot?.revision == snapshot.revision else { return }
                self?.status.stringValue = "Syntax highlighting unavailable"
            }
        }
    }

    private func paint(_ syntax: SyntaxSnapshot, with buffer: SourceBuffer) {
        guard !editor.hasMarkedText(), let layout = editor.layoutManager else { return }
        let totalRange = NSRange(location: 0, length: buffer.utf16Length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: totalRange)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: totalRange)
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: totalRange)

        var errors = 0
        for entry in syntax.ranges {
            if entry.kind == .error { errors += 1 }
            guard let range = try? buffer.textRange(for: entry.range), range.length > 0 else { continue }
            switch entry.kind {
            case .comment:
                layout.addTemporaryAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                             forCharacterRange: range)
            case .string:
                layout.addTemporaryAttribute(.foregroundColor, value: NSColor.systemBrown,
                                             forCharacterRange: range)
            case .number:
                layout.addTemporaryAttribute(.foregroundColor, value: NSColor.systemBlue,
                                             forCharacterRange: range)
            case .keyword:
                layout.addTemporaryAttribute(.foregroundColor, value: NSColor.systemPurple,
                                             forCharacterRange: range)
            case .error:
                layout.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSColor.systemRed,
                ], forCharacterRange: range)
            case .identifier:
                break
            }
        }
        status.stringValue = errors == 0 ? "UTF-8" : "\(errors) syntax \(errors == 1 ? "error" : "errors")"
    }
}

private final class SourceTextView: NSTextView {
    weak var sourceDocument: ScadrettoDocument?
    private(set) var updatingComposition = false

    @objc private func undo(_ sender: Any?) { sourceDocument?.undo(sender) }
    @objc private func redo(_ sender: Any?) { sourceDocument?.redo(sender) }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) {
            return sourceDocument?.validateUserInterfaceItem(item) ?? false
        }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .shift, .command, .option])
        if event.charactersIgnoringModifiers == "\t" && modifiers == .control {
            window?.selectNextKeyView(self)
        } else if event.charactersIgnoringModifiers == "\t" && modifiers == [.control, .shift] {
            window?.selectPreviousKeyView(self)
        } else {
            super.keyDown(with: event)
        }
    }
    var onCompositionEnd: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        updatingComposition = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        updatingComposition = false
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        if wasComposing { updatingComposition = true }
        super.insertText(string, replacementRange: replacementRange)
        if wasComposing {
            updatingComposition = false
            if !hasMarkedText() { onCompositionEnd?() }
        }
    }

    override func unmarkText() {
        let wasComposing = hasMarkedText()
        super.unmarkText()
        if wasComposing && !updatingComposition { onCompositionEnd?() }
    }
}

private struct TextDelta {
    let range: NSRange
    let replacement: String

    static func between(_ before: String, _ after: String) -> TextDelta {
        let old = Array(before.utf16)
        let new = Array(after.utf16)
        var start = 0
        let sharedLimit = min(old.count, new.count)
        while start < sharedLimit && old[start] == new[start] { start += 1 }
        if start < old.count && (0xDC00...0xDFFF).contains(old[start]) { start -= 1 }

        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start && newEnd > start && old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        if oldEnd < old.count && (0xDC00...0xDFFF).contains(old[oldEnd]) {
            oldEnd += 1
            newEnd += 1
        }
        return TextDelta(range: NSRange(location: start, length: oldEnd - start),
                         replacement: String(decoding: new[start..<newEnd], as: UTF16.self))
    }
}

private final class LineRuler: NSRulerView {
    private weak var editor: NSTextView?
    private let lineNumber: (Int) -> Int

    init(scroll: NSScrollView, editor: NSTextView, lineNumber: @escaping (Int) -> Int) {
        self.editor = editor
        self.lineNumber = lineNumber
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 44
    }

    required init(coder: NSCoder) {
        lineNumber = { _ in 1 }
        super.init(coder: coder)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer,
              let clip = scrollView?.contentView else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let origin = editor.textContainerOrigin
        let visible = clip.bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
            let line = self.lineNumber(layout.characterIndexForGlyph(at: range.location))
            let label = NSAttributedString(string: String(line), attributes: attributes)
            label.draw(at: NSPoint(x: self.ruleThickness - label.size().width - 8,
                                   y: used.minY + origin.y - clip.bounds.minY))
        }
        if layout.extraLineFragmentTextContainer === container {
            let label = NSAttributedString(string: String(lineNumber(editor.string.utf16.count)),
                                           attributes: attributes)
            let y = layout.extraLineFragmentUsedRect.minY + origin.y - clip.bounds.minY
            label.draw(at: NSPoint(x: ruleThickness - label.size().width - 8, y: y))
        }
    }
}
