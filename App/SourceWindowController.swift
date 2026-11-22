import AppKit
import ScadrettoCore
import ScadrettoSyntax

final class SourceWindowController: NSWindowController, NSTextViewDelegate {
    private weak var sourceDocument: ScadrettoDocument?
    private let editor = SourceTextView(usingTextLayoutManager: false)
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let parser = SyntaxParser()
    private var parseTask: Task<Void, Never>?
    private var snapshot: SourceSnapshot?
    private var mirroring = false
    private var ruler: LineRuler?

    var selection: NSRange { editor.selectedRange() }

    init(document: ScadrettoDocument) {
        self.sourceDocument = document
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.minSize = NSSize(width: 380, height: 260)
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
        scroll.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 5),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
        ])
        window.initialFirstResponder = editor
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func configureEditor() {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.font = font
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
        editor.onCompositionEnd = { [weak self] in self?.commitComposedText() }
    }

    func show(_ snapshot: SourceSnapshot, selecting selection: NSRange) {
        self.snapshot = snapshot
        mirroring = true
        if !editor.string.utf16.elementsEqual(snapshot.buffer.displayText.utf16) {
            let change = TextDelta.between(editor.string, snapshot.buffer.displayText)
            editor.textStorage?.replaceCharacters(in: change.range, with: change.replacement)
            editor.didChangeText()
        }
        let length = snapshot.buffer.utf16Length
        let location = min(selection.location, length)
        editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        mirroring = false
        ruler?.needsDisplay = true
        scheduleSyntax(snapshot)
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
                                  replacements: replacementStrings, coalescing: true)
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

    private func commitComposedText() {
        guard let snapshot, !editor.string.utf16.elementsEqual(snapshot.buffer.displayText.utf16) else { return }
        let change = TextDelta.between(snapshot.buffer.displayText, editor.string)
        sourceDocument?.changeText([change.range], replacements: [change.replacement], coalescing: false)
    }

    private func scheduleSyntax(_ snapshot: SourceSnapshot) {
        parseTask?.cancel()
        let parser = self.parser
        parseTask = Task { [weak self] in
            do {
                let syntax = try await parser.parse(snapshot)
                guard !Task.isCancelled, self?.snapshot?.revision == syntax.revision else { return }
                self?.paint(syntax, with: snapshot.buffer)
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
