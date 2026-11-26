import AppKit
import Carbon.HIToolbox

/// The divider is a screen-space control. The renderer uses its normalized
/// position to cut both models against the same drawable pixel boundary.
@MainActor
final class ComparisonCutOverlay: NSView {
    var fraction: CGFloat = 0.5 {
        didSet {
            guard fraction != oldValue else { return }
            setAccessibilityValue(fraction)
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var beforeLabel = "" { didSet { updateLabels() } }
    var afterLabel = "" { didSet { updateLabels() } }
    var propertyName = "" { didSet { updateLabels() } }
    var isPinned = false {
        didSet {
            pin.title = isPinned ? "Unpin" : "Pin"
            pin.toolTip = isPinned ? "Unpin Comparison Cut" : "Keep Comparison Cut open"
        }
    }
    var onPosition: ((CGFloat) -> Void)?
    var onDismiss: (() -> Void)?
    var onTogglePin: (() -> Void)?

    private static let brass = NSColor(srgbRed: 1, green: 0.77, blue: 0.38, alpha: 1)
    private static let mint = NSColor(srgbRed: 0.55, green: 1, blue: 0.86, alpha: 1)
    private static let ink = NSColor(srgbRed: 0.05, green: 0.10, blue: 0.11, alpha: 0.98)

    private let pin = NSButton(title: "Pin", target: nil, action: nil)
    private var grabOffset: CGFloat?
    private var lineX: CGFloat { bounds.width * fraction }
    private var grip: CGRect {
        CGRect(x: min(max(lineX - 22, 3), max(3, bounds.width - 47)), y: bounds.midY - 15,
               width: 44, height: 30)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityIdentifier("comparisonDivider")
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(1)
        setAccessibilityValue(fraction)
        pin.target = self
        pin.action = #selector(togglePin(_:))
        pin.controlSize = .small
        pin.bezelStyle = .rounded
        pin.setAccessibilityIdentifier("comparisonPin")
        addSubview(pin)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        pin.frame = CGRect(x: bounds.maxX - 76, y: bounds.maxY - 38, width: 62, height: 24)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), !isHidden else { return nil }
        if pin.frame.contains(local) { return super.hitTest(point) }
        return abs(local.x - lineX) <= 11 || grip.contains(local) ? self : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let strip = CGRect(x: lineX - 11, y: bounds.minY, width: 22, height: bounds.height)
        addCursorRect(strip.intersection(bounds), cursor: .resizeLeftRight)
        addCursorRect(grip, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        grabOffset = point.x - lineX
        onPosition?(fraction)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grabOffset else { return }
        let pointer = convert(event.locationInWindow, from: nil)
        setPosition((pointer.x - grabOffset) / max(bounds.width, 1), announce: false)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        grabOffset = nil
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        grabOffset = nil
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        let step = event.modifierFlags.contains(.shift) ? 0.10 : 0.02
        switch Int(event.keyCode) {
        case kVK_LeftArrow, kVK_DownArrow: setPosition(fraction - step)
        case kVK_RightArrow, kVK_UpArrow: setPosition(fraction + step)
        case kVK_Home: setPosition(0)
        case kVK_End: setPosition(1)
        case kVK_Escape: onDismiss?()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        setPosition(fraction + 0.02)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        setPosition(fraction - 0.02)
        return true
    }

    private func setPosition(_ position: CGFloat, announce: Bool = true) {
        fraction = min(max(position, 0), 1)
        onPosition?(fraction)
        if announce { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    private func updateLabels() {
        setAccessibilityLabel("Compare \(propertyName), before \(beforeLabel), after \(afterLabel)")
        setAccessibilityHelp("Drag or use the arrow keys to move the split. Press Escape to close.")
        needsDisplay = true
    }

    @objc private func togglePin(_ sender: NSButton) { onTogglePin?() }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let x = min(max(lineX, 1), bounds.width - 1)
        Self.ink.setFill()
        CGRect(x: x - 2, y: 0, width: 4, height: bounds.height).fill()
        Self.brass.setFill()
        CGRect(x: x - 1, y: 0, width: 1, height: bounds.height).fill()
        Self.mint.setFill()
        CGRect(x: x, y: 0, width: 1, height: bounds.height).fill()

        let knob = NSBezierPath(roundedRect: grip, xRadius: 9, yRadius: 9)
        Self.ink.setFill()
        knob.fill()
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        (focused ? NSColor.keyboardFocusIndicatorColor : Self.mint).setStroke()
        knob.lineWidth = focused ? 2 : 1
        knob.stroke()
        let arrows = NSBezierPath()
        for direction: CGFloat in [-1, 1] {
            arrows.move(to: CGPoint(x: grip.midX + 7 * direction, y: grip.midY - 3))
            arrows.line(to: CGPoint(x: grip.midX + 10 * direction, y: grip.midY))
            arrows.line(to: CGPoint(x: grip.midX + 7 * direction, y: grip.midY + 3))
        }
        arrows.lineWidth = 1.5
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round
        NSColor.white.setStroke()
        arrows.stroke()
        drawLabel("Before", value: beforeLabel, color: Self.brass, trailing: false)
        drawLabel("After", value: afterLabel, color: Self.mint, trailing: true)
    }

    private func drawLabel(_ title: String, value: String, color: NSColor, trailing: Bool) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: title + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ])
        text.append(NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]))
        let width = min(text.size().width + 18, bounds.width / 2 - 18)
        guard width > 18 else { return }
        let rect = CGRect(x: trailing ? bounds.maxX - width - 12 : 12, y: 12, width: width, height: 29)
        let plate = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        Self.ink.setFill()
        plate.fill()
        let opacity: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.65
        color.withAlphaComponent(opacity).setStroke()
        plate.stroke()
        text.draw(in: rect.insetBy(dx: 9, dy: 5))
    }
}
