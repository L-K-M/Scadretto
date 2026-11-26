import AppKit
import Carbon.HIToolbox
import ScadrettoCore
import ScadrettoSyntax
import ScadrettoViewport

struct ConstellationMarker {
    let id: UInt32
    let point: SIMD3<Double>?
    let travel: SIMD3<Double>
    let kind: ConstellationOverlay.Kind
}

final class SourceWindowController: NSWindowController, NSTextViewDelegate {
    private weak var sourceDocument: ScadrettoDocument?
    private let editor = SourceTextView(usingTextLayoutManager: false)
    private let scroll = NSScrollView()
    private let split = NSSplitView()
    private let status = NSTextField(labelWithString: "")
    private let parser = SyntaxParser()
    private var parseTask: Task<Void, Never>?
    private var snapshot: SourceSnapshot?
    private var mirroring = false
    private var ruler: LineRuler?
    private var placedDividers = false
    private struct SourceRelationship {
        let scene: UUID
        let token: NSRange
        let title: String
        let selected: ConstellationMarker
        let baseline: Double
        let markers: [ConstellationMarker]
    }

    private let constellation = ConstellationOverlay(frame: .zero)
    private var relationship: SourceRelationship?
    private var constellationMonitor: Any?
    private var constellationObservers: [any NSObjectProtocol] = []
    private var optionExpanded = false
    private var dragExpanded = false
    private(set) var isConstellationPinned = false
    var canShowConstellation: Bool {
        relationship != nil && previewWorkspace.viewport?.isComparing == false
    }
    let previewWorkspace = PreviewWorkspace()

    var selection: NSRange { editor.selectedRange() }

    /// One more than the highest number among the document's other windows, so each title
    /// names a different window in the Window menu.
    private let windowNumber: Int

    init(document: ScadrettoDocument) {
        self.sourceDocument = document
        windowNumber = (document.windowControllers.compactMap { ($0 as? SourceWindowController)?.windowNumber }
            .max() ?? 0) + 1
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.minSize = NSSize(width: 780, height: 390)
        window.center()
        configureEditor()

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

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("statusArea")
        let content = NSView()
        window.contentView = content
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        for pane in [scroll, previewWorkspace.panel, previewWorkspace.sidebar] {
            split.addArrangedSubview(pane)
        }
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        content.addSubview(status)
        constellation.translatesAutoresizingMaskIntoConstraints = false
        constellation.isHidden = true
        content.addSubview(constellation)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 310),
            previewWorkspace.panel.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            previewWorkspace.sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            status.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 5),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
            constellation.topAnchor.constraint(equalTo: split.topAnchor),
            constellation.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            constellation.trailingAnchor.constraint(equalTo: previewWorkspace.panel.trailingAnchor),
            constellation.bottomAnchor.constraint(equalTo: split.bottomAnchor),
        ])
        window.initialFirstResponder = editor
        window.acceptsMouseMovedEvents = true
        previewWorkspace.viewport?.onOverlayGeometryChange = { [weak self] in self?.updateConstellation() }
        observeConstellation(in: window)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    isolated deinit {
        stopObservingConstellation()
    }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        windowNumber > 1 ? "\(displayName) (\(windowNumber))" : displayName
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !placedDividers else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        let width = split.bounds.width
        guard width >= 780 else { return }
        split.setPosition(width * 0.31, ofDividerAt: 0)
        split.setPosition(width - 240, ofDividerAt: 1)
        placedDividers = true
        resetSourceScroll()
    }

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
        editor.onCompositionEnd = { [weak self] in
            self?.commitComposedText()
            self?.onCompositionFinished?()
        }
    }

    /// Shows the document's text. Without a selection, as for an edit made in another window of
    /// the same document, the current selection follows the text around the change.
    func show(_ snapshot: SourceSnapshot, selecting requested: NSRange?) {
        let firstView = self.snapshot == nil
        if self.snapshot?.revision != snapshot.revision { clearConstellation(keepingPin: true) }
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

    func textViewDidChangeSelection(_ notification: Notification) {
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
        let tokenRect = sourceRect(for: range)
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
        if let tokenRect, tokenRect.minX >= visibleMinX, tokenRect.maxX <= visibleMaxX {
            clip.scroll(to: NSPoint(x: originalX, y: clip.bounds.minY))
            scroll.reflectScrolledClipView(clip)
        }
        updateConstellation()
    }

    private func sourceRect(for range: NSRange, firstGlyphOnly: Bool = false) -> NSRect? {
        guard NSMaxRange(range) <= editor.string.utf16.count,
              let layout = editor.layoutManager, let container = editor.textContainer else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        // The connection leaves the first glyph; a multiline expression must not
        // send the ray from whitespace in the middle of its bounding rectangle.
        let anchor = firstGlyphOnly ? NSRange(location: glyphs.location, length: min(glyphs.length, 1)) : glyphs
        return layout.boundingRect(forGlyphRange: anchor, in: container)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
    }

    func showConstellation(scene: UUID, token: NSRange, title: String, selectedID: UInt32,
                           baseline: Double, markers: [ConstellationMarker]) {
        guard let selected = markers.first(where: { $0.id == selectedID }) else {
            clearConstellation()
            return
        }
        if relationship?.scene != scene || relationship?.token != token || relationship?.selected.id != selectedID {
            optionExpanded = false
            clearHover()
        }
        relationship = SourceRelationship(scene: scene, token: token, title: title, selected: selected,
                                          baseline: baseline, markers: markers)
        updateConstellation()
    }

    func clearConstellation(keepingPin: Bool = false) {
        if !keepingPin { isConstellationPinned = false }
        guard relationship != nil else { return }
        relationship = nil
        optionExpanded = false
        dragExpanded = false
        constellation.diagram = nil
        constellation.isHidden = true
        clearHover()
    }

    func toggleConstellation() {
        guard canShowConstellation, let relationship, !isComposing else { return }
        isConstellationPinned.toggle()
        optionExpanded = false
        if isConstellationPinned {
            highlightSource(relationship.token)
            if let viewport = previewWorkspace.viewport { window?.makeFirstResponder(viewport) }
            let count = relationship.markers.count
            Announcements.post("\(relationship.title), \(count) \(count == 1 ? "instance" : "instances"). Use the arrow keys to inspect an instance.")
        }
        updateConstellation()
    }

    private func updateConstellation() {
        guard let relationship, let viewport = previewWorkspace.viewport,
              viewport.presentedSceneID == relationship.scene, !viewport.isComparing, !isComposing,
              let sourceRect = sourceRect(for: relationship.token, firstGlyphOnly: true) else {
            constellation.diagram = nil
            constellation.isHidden = true
            clearHover()
            return
        }
        let clip = scroll.contentView
        let sourceEdge = constellation.convert(sourceRect, from: editor)
        let insets = clip.contentInsets
        let visibleText = clip.bounds.insetBy(dx: 10, dy: 10)
        let sourcePane = constellation.convert(CGRect(
            x: visibleText.minX + insets.left, y: visibleText.minY + insets.top,
            width: max(0, visibleText.width - insets.left - insets.right),
            height: max(0, visibleText.height - insets.top - insets.bottom)
        ), from: clip)
        let sourcePoint = CGPoint(x: min(max(sourceEdge.minX - 9, sourcePane.minX), sourcePane.maxX),
                                  y: min(max(sourceEdge.midY, sourcePane.minY), sourcePane.maxY))
        let rect = constellation.convert(viewport.bounds, from: viewport)
        let transform = viewport.viewportTransform()
        let delta = (viewport.handleDragValue ?? relationship.baseline) - relationship.baseline
        if viewport.isDraggingHandle {
            dragExpanded = dragExpanded || constellation.isExpanded
            clearHover()
        } else {
            dragExpanded = false
        }
        let expanded = isConstellationPinned || optionExpanded || dragExpanded
        let markers = expanded ? relationship.markers : [relationship.selected]
        let nodes: [ConstellationOverlay.Node] = markers.compactMap { marker in
            guard let anchor = marker.point else { return nil }
            let point = transform.project(anchor + marker.travel * delta)
            let visible = point.flatMap { value in
                (0...1).contains(value.z) && value.x.isFinite && value.y.isFinite
                    ? CGPoint(x: rect.minX + value.x, y: rect.minY + value.y) : nil
            }
            return ConstellationOverlay.Node(id: marker.id, point: visible ?? CGPoint(x: CGFloat.infinity, y: CGFloat.infinity),
                                             kind: marker.kind)
        }
        let tokenEnd = expanded ? self.sourceRect(for: relationship.token).map {
            constellation.convert($0, from: editor).maxX
        } : nil
        constellation.diagram = .init(source: sourcePoint, viewport: rect, nodes: nodes,
                                      instanceCount: relationship.markers.count,
                                      selectedID: relationship.selected.id, title: relationship.title,
                                      badgeMinX: min(tokenEnd ?? sourcePoint.x, sourcePane.maxX) + 16)
        constellation.isExpanded = expanded
        constellation.isHidden = false
        if !expanded { clearHover() }
    }

    private func syncConstellationExpansion() {
        let expanded = isConstellationPinned || optionExpanded || dragExpanded
        if constellation.isExpanded != expanded { updateConstellation() }
    }

    private func clearHover() {
        highlightConstellationNode(nil)
    }

    private func highlightConstellationNode(_ id: UInt32?) {
        guard constellation.highlightedID != id else { return }
        constellation.highlightedID = id
        previewWorkspace.previewRelatedOccurrence(id)
    }

    private func observeConstellation(in window: NSWindow) {
        let center = NotificationCenter.default
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        constellation.postsFrameChangedNotifications = true
        let geometryNotifications: [(Notification.Name, NSView)] = [
            (NSView.boundsDidChangeNotification, clip), (NSView.frameDidChangeNotification, constellation),
        ]
        for (name, object) in geometryNotifications {
            constellationObservers.append(center.addObserver(forName: name, object: object, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.updateConstellation() }
            })
        }
        constellationObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.optionExpanded = false
                self?.syncConstellationExpansion()
                self?.clearHover()
                self?.previewWorkspace.viewport?.endTemporaryComparison()
            }
        })
        constellationObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stopObservingConstellation() } })
        constellationMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .mouseMoved, .mouseExited, .keyDown]) {
            [weak self] event in self?.trackConstellation(event) == true ? nil : event
        }
    }

    private func stopObservingConstellation() {
        if let constellationMonitor { NSEvent.removeMonitor(constellationMonitor) }
        constellationMonitor = nil
        constellationObservers.forEach(NotificationCenter.default.removeObserver)
        constellationObservers.removeAll()
        previewWorkspace.viewport?.endTemporaryComparison()
    }

    private func trackConstellation(_ event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, !constellation.isHidden,
              let viewport = previewWorkspace.viewport else { return false }
        if event.type == .keyDown {
            guard window.firstResponder === viewport, !viewport.isDraggingHandle, constellation.isExpanded,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return false
            }
            switch Int(event.keyCode) {
            case kVK_Escape:
                isConstellationPinned = false
                optionExpanded = false
                syncConstellationExpansion()
                return true
            case kVK_LeftArrow, kVK_UpArrow:
                return isConstellationPinned && stepThroughConstellation(by: -1)
            case kVK_RightArrow, kVK_DownArrow:
                return isConstellationPinned && stepThroughConstellation(by: 1)
            default:
                return false
            }
        }
        if event.type == .mouseExited {
            clearHover()
            return false
        }
        let point = constellation.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !event.modifierFlags.contains(.option) {
            optionExpanded = false
        } else if !optionExpanded && constellation.isSocket(at: point) {
            optionExpanded = true
        }
        syncConstellationExpansion()
        if constellation.isExpanded && !viewport.isDraggingHandle {
            highlightConstellationNode(constellation.target(at: point))
        }
        return false
    }

    private func stepThroughConstellation(by step: Int) -> Bool {
        let targets = constellation.keyboardTargets
        guard !targets.isEmpty, let relationship else { return false }
        let currentIndex = constellation.highlightedID.flatMap { targets.firstIndex(of: $0) }
        let next = currentIndex.map { ($0 + step + targets.count) % targets.count } ?? 0
        let id = targets[next]
        highlightConstellationNode(id)
        if let index = relationship.markers.firstIndex(where: { $0.id == id }) {
            let kind = switch relationship.markers[index].kind {
            case .original: "Instance"
            case .translated: "Translated instance"
            case .cutter: "Cutter"
            }
            Announcements.post("\(kind) \(index + 1) of \(relationship.markers.count)")
        }
        return true
    }

    func reveal(_ range: NSRange?) {
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
    private(set) var updatingComposition = false
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
        ruleThickness = 54
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
