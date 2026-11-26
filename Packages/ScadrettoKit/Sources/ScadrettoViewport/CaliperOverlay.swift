import AppKit

/// A screen-space instrument over the Metal guides. Its jaws use the same projected
/// handle and proposed scalar as the preview, including when a parent is mirrored.
@MainActor
final class CaliperOverlay: NSView {
    struct Reading {
        let origin: CGPoint
        let tip: CGPoint
        let baseline: Double
        let proposal: Double
        let caption: String
        var recorded = false

        var values: String { "\(Self.number(baseline)) → \(Self.number(proposal))" }

        static func number(_ value: Double) -> String {
            value.formatted(.number.precision(.significantDigits(1...12)).grouping(.never))
        }
    }

    var reading: Reading? {
        didSet {
            isHidden = reading == nil
            setAccessibilityValue(reading.map { "\($0.recorded ? "Source updated, " : "")\($0.caption), \($0.values)" })
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let reading else { return }
        let origin = reading.origin
        let tip = reading.tip
        let dx = tip.x - origin.x
        let dy = tip.y - origin.y
        let travel = hypot(dx, dy)
        let direction = travel >= 1 ? CGPoint(x: dx / travel, y: dy / travel) : CGPoint(x: 1, y: 0)
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let brass = NSColor(srgbRed: 1, green: 0.77, blue: 0.38, alpha: 1)
        let mint = NSColor(srgbRed: 0.55, green: 1, blue: 0.86, alpha: 1)
        let ink = NSColor(srgbRed: 0.05, green: 0.10, blue: 0.11, alpha: 0.98)

        stroke(from: origin, to: tip, color: ink, width: 5)
        stroke(from: origin, to: tip, color: mint, width: 1.5)
        for (point, color) in [(origin, brass), (tip, mint)] {
            let a = CGPoint(x: point.x - normal.x * 9, y: point.y - normal.y * 9)
            let b = CGPoint(x: point.x + normal.x * 9, y: point.y + normal.y * 9)
            stroke(from: a, to: b, color: ink, width: 5)
            stroke(from: a, to: b, color: color, width: 2)
        }

        let heading = reading.recorded ? "✓  Source updated" : reading.caption
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: heading, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: mint,
            .paragraphStyle: titleStyle,
        ])
        func readout(fontSize: CGFloat) -> NSAttributedString {
            let values = NSMutableAttributedString()
            let digits = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
            for (segment, color) in [(Reading.number(reading.baseline), brass),
                                     ("  →  ", NSColor.white), (Reading.number(reading.proposal), mint)] {
                values.append(NSAttributedString(string: segment, attributes: [
                    .font: digits, .foregroundColor: color, .paragraphStyle: titleStyle,
                ]))
            }
            return values
        }
        let fullReadout = readout(fontSize: 19)
        let available = max(1, bounds.width - 40)
        let values = fullReadout.size().width <= available ? fullReadout
            : readout(fontSize: max(10, 19 * available / fullReadout.size().width))
        let width = min(max(title.size().width, values.size().width) + 24, max(1, bounds.width - 16))
        let height: CGFloat = 53
        let x = min(max(tip.x + 28, 8), max(8, bounds.width - width - 8))
        let above = tip.y - height - 17
        let y = max(8, min(above >= 8 ? above : tip.y + 17, bounds.height - height - 8))
        let plate = CGRect(x: x, y: y, width: width, height: height)
        let leader = CGPoint(x: min(max(tip.x, plate.minX + 8), plate.maxX - 8),
                             y: tip.y > plate.midY ? plate.maxY : plate.minY)
        stroke(from: tip, to: leader, color: ink, width: 3)
        stroke(from: tip, to: leader, color: mint, width: 1)
        let outline = NSBezierPath(roundedRect: plate, xRadius: 8, yRadius: 8)
        ink.setFill()
        outline.fill()
        mint.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.65).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        title.draw(in: CGRect(x: x + 12, y: y + 6, width: max(0, width - 24), height: 15))
        values.draw(in: CGRect(x: x + 12, y: y + 21, width: max(0, width - 24), height: 29))
    }

    private func stroke(from a: CGPoint, to b: CGPoint, color: NSColor, width: CGFloat) {
        let line = NSBezierPath()
        line.move(to: a)
        line.line(to: b)
        line.lineWidth = width
        line.lineCapStyle = .round
        color.setStroke()
        line.stroke()
    }
}
