import AppKit

/// A screen-space constellation that ties one authored expression to every
/// instance it controls, drawn over the whole editor/viewport split.
///
/// The view is flipped, so every point and rectangle it consumes uses the
/// top-left origin with y growing downward, matching `ViewportTransform`'s view
/// points and the overlay it covers. It is transparent and passes mouse events
/// through (`hitTest` returns nil); the owning controller converts event
/// locations into this space and asks `target(at:)` and `isSocket(at:)` for hit
/// results. `Layout.source` is the controlling token in the editor pane,
/// `Layout.viewport` is the 3D pane inside this overlay, and each `Node.point`
/// is an instance already projected into the same space.
///
/// A node whose point is not finite (`.infinity` or `.nan`) is a behind-camera
/// instance: `ViewportTransform.project` returns nil for it, so the caller sends
/// it out of bounds. The overlay counts those in a dedicated marker on the
/// viewport edge nearest the source rather than inventing a screen position.
@MainActor
public final class ConstellationOverlay: NSView {
    /// How an instance relates to the controlling expression.
    public enum Kind: Sendable {
        /// The occurrence the family is anchored to.
        case original
        /// A placed copy reached through a transform.
        case translated
        /// A subtractive operand sharing the parameter.
        case cutter
    }

    /// One reachable instance at a projected view point.
    public struct Node: Sendable {
        public let id: UInt32
        public let point: CGPoint
        public let kind: Kind

        public init(id: UInt32, point: CGPoint, kind: Kind) {
            self.id = id
            self.point = point
            self.kind = kind
        }
    }

    /// The immutable inputs for one presented constellation.
    public struct Layout: Sendable {
        /// The controlling token in the editor pane.
        public let source: CGPoint
        /// The 3D viewport rectangle within the overlay.
        public let viewport: CGRect
        /// Every reachable instance, on screen or not.
        public let nodes: [Node]
        /// Compact mode only projects the selected socket.
        public let instanceCount: Int
        /// The instance currently selected in the scene.
        public let selectedID: UInt32
        /// A short name for the controlling expression, used for accessibility.
        public let title: String
        /// The badge starts clear of the source token.
        public let badgeMinX: CGFloat

        public init(source: CGPoint, viewport: CGRect, nodes: [Node], instanceCount: Int,
                    selectedID: UInt32, title: String, badgeMinX: CGFloat) {
            self.source = source
            self.viewport = viewport
            self.nodes = nodes
            self.instanceCount = instanceCount
            self.selectedID = selectedID
            self.title = title
            self.badgeMinX = badgeMinX
        }
    }

    /// A viewport border an offscreen instance escapes through.
    private enum Edge {
        case top, right, bottom, left

        /// Unit vector pointing away from the viewport across this edge.
        var outward: CGVector {
            switch self {
            case .top: return CGVector(dx: 0, dy: -1)
            case .right: return CGVector(dx: 1, dy: 0)
            case .bottom: return CGVector(dx: 0, dy: 1)
            case .left: return CGVector(dx: -1, dy: 0)
            }
        }
    }

    /// Named drawing and hit-test measurements.
    private enum Metric {
        static let rayLimit = 12
        static let endpointRadius: CGFloat = 4.5
        static let endpointHoverRadius: CGFloat = 6.5
        static let socketRadius: CGFloat = 6
        static let socketHitRadius: CGFloat = 14
        static let endpointHitRadius: CGFloat = 13
        static let visibleInset: CGFloat = 2
        static let chevronSize: CGFloat = 4.5
        static let beyondRadius: CGFloat = 4.5
        static let bowFactor: CGFloat = 0.12
        static let bowMax: CGFloat = 28
        static let margin: CGFloat = 6
    }

    private static let brass = NSColor(srgbRed: 1.00, green: 0.77, blue: 0.38, alpha: 1)
    private static let mint = NSColor(srgbRed: 0.55, green: 1.00, blue: 0.86, alpha: 1)
    private static let mintLight = NSColor(srgbRed: 0.74, green: 1.00, blue: 0.92, alpha: 1)
    private static let ink = NSColor(srgbRed: 0.05, green: 0.10, blue: 0.11, alpha: 0.98)

    /// The constellation to draw, or nil to hide the overlay.
    public var diagram: Layout? {
        didSet {
            rebuildEndpoints()
            isHidden = diagram == nil
            updateAccessibility()
            needsDisplay = true
        }
    }

    /// Whether the dependency view is unfolded. Compact shows only the source
    /// and selected sockets; expanded adds rays, endpoints, offscreen counts and
    /// the attached total.
    public var isExpanded: Bool = false {
        didSet {
            guard isExpanded != oldValue else { return }
            rebuildEndpoints()
            updateAccessibility()
            needsDisplay = true
        }
    }

    /// The endpoint under the cursor, emphasized while set.
    public var highlightedID: UInt32? {
        didSet { if highlightedID != oldValue { needsDisplay = true } }
    }

    private var endpoints: [Node] = []
    private var visibleCount = 0
    private var beyondCount = 0
    public var keyboardTargets: [UInt32] { endpoints.map(\.id) }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyDefaults()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyDefaults()
    }

    private func applyDefaults() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("constellationOverlay")
        isHidden = true
    }

    override public var isFlipped: Bool { true }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The visible endpoint under `point`, nearest when several overlap, or nil.
    /// Only expanded mode draws endpoints, so this reports nothing otherwise.
    public func target(at point: CGPoint) -> UInt32? {
        guard isExpanded else { return nil }
        var best: (id: UInt32, distance: CGFloat)?
        for node in endpoints {
            let distance = hypot(node.point.x - point.x, node.point.y - point.y)
            if distance <= Metric.endpointHitRadius, best?.distance ?? .infinity > distance {
                best = (node.id, distance)
            }
        }
        return best?.id
    }

    /// Whether `point` is on the source socket or the selected socket. The
    /// sockets are present in both modes, so this works either way.
    public func isSocket(at point: CGPoint) -> Bool {
        guard let diagram else { return false }
        if hypot(diagram.source.x - point.x, diagram.source.y - point.y) <= Metric.socketHitRadius {
            return true
        }
        if let selected = diagram.nodes.first(where: { $0.id == diagram.selectedID }),
           nodeVisible(selected, in: diagram.viewport),
           hypot(selected.point.x - point.x, selected.point.y - point.y) <= Metric.socketHitRadius {
            return true
        }
        return false
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let diagram, bounds.width > 0, bounds.height > 0 else { return }
        let source = diagram.source.x.isFinite && diagram.source.y.isFinite
            ? diagram.source
            : CGPoint(x: bounds.midX, y: bounds.midY)

        if isExpanded {
            drawEdgeMarkers(viewport: diagram.viewport, nodes: diagram.nodes)
            drawBeyondMarker(viewport: diagram.viewport, source: source)
            drawRays(source: source, nodes: endpoints, selectedID: diagram.selectedID)
            drawEndpoints(nodes: endpoints, selectedID: diagram.selectedID)
            drawTotalBadge(total: diagram.instanceCount, at: source, minimumX: diagram.badgeMinX)
        } else if let selected = diagram.nodes.first(where: { $0.id == diagram.selectedID }),
                  nodeVisible(selected, in: diagram.viewport) {
            drawEndpoint(selected, emphasized: true, highlighted: highlightedID == selected.id)
        }

        drawSourceSocket(at: source)
    }

    // MARK: Layout classification

    /// Whether a node has a real, on-screen projected point.
    private func nodeVisible(_ node: Node, in viewport: CGRect) -> Bool {
        guard node.point.x.isFinite, node.point.y.isFinite else { return false }
        return viewport.insetBy(dx: -Metric.visibleInset, dy: -Metric.visibleInset).contains(node.point)
    }

    /// Whether a node is a behind-camera instance sent out of bounds.
    private func isBeyond(_ node: Node) -> Bool {
        !node.point.x.isFinite || !node.point.y.isFinite
    }

    /// The up-to-twelve visible endpoints the rays reach, nearest the source
    /// first and always including the selected instance when it is visible.
    private func rebuildEndpoints() {
        endpoints = []
        visibleCount = 0
        beyondCount = 0
        guard let diagram else { return }
        var nearest: [(node: Node, distance: CGFloat)] = []
        for node in diagram.nodes {
            if isBeyond(node) { beyondCount += 1 }
            guard nodeVisible(node, in: diagram.viewport) else { continue }
            visibleCount += 1
            guard isExpanded else { continue }
            let distance = node.id == diagram.selectedID ? -1 : self.distance(from: diagram.source, to: node.point)
            let index = nearest.firstIndex { $0.distance > distance } ?? nearest.count
            guard index < Metric.rayLimit else { continue }
            nearest.insert((node, distance), at: index)
            if nearest.count > Metric.rayLimit { nearest.removeLast() }
        }
        endpoints = nearest.map(\.node)
    }

    private func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    /// The viewport edge an offscreen point most clearly escapes through, by the
    /// greatest penetration normalized against the extent so a thin or empty
    /// viewport still classifies without dividing by zero.
    private func nearestEdge(to point: CGPoint, in rect: CGRect) -> Edge {
        guard point.x.isFinite, point.y.isFinite else { return .top }
        let width = max(rect.width, 1)
        let height = max(rect.height, 1)
        let measures: [(Edge, CGFloat)] = [
            (.top, (rect.minY - point.y) / height),
            (.right, (point.x - rect.maxX) / width),
            (.bottom, (point.y - rect.maxY) / height),
            (.left, (rect.minX - point.x) / width),
        ]
        var best = measures[0]
        for measure in measures where measure.1 > best.1 { best = measure }
        return best.0
    }

    private func clamped(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, min(low, high)), max(low, high))
    }

    /// A point inside `edge`. The arrow points outward and the count
    /// sits inside the viewport so even bottom and right markers fit.
    private func edgeAnchor(_ edge: Edge, for point: CGPoint, in rect: CGRect, offset: CGFloat) -> CGPoint {
        let comfortable = rect.insetBy(dx: 28, dy: 28)
        switch edge {
        case .top:
            return CGPoint(x: clamped(point.x, comfortable.minX, comfortable.maxX), y: rect.minY + offset)
        case .bottom:
            return CGPoint(x: clamped(point.x, comfortable.minX, comfortable.maxX), y: rect.maxY - offset)
        case .left:
            return CGPoint(x: rect.minX + offset, y: clamped(point.y, comfortable.minY, comfortable.maxY))
        case .right:
            return CGPoint(x: rect.maxX - offset, y: clamped(point.y, comfortable.minY, comfortable.maxY))
        }
    }

    // MARK: Expanded overlays

    private func drawRays(source: CGPoint, nodes: [Node], selectedID: UInt32) {
        for node in nodes {
            let path = Self.rayPath(from: source, to: node.point)
            let emphasized = node.id == selectedID || node.id == highlightedID
            if emphasized {
                Self.stroke(path, color: Self.ink.withAlphaComponent(0.4), width: 3)
                Self.stroke(path, color: Self.mint, width: 1.5)
            } else {
                Self.stroke(path, color: Self.mint.withAlphaComponent(0.4), width: 1, dash: [2.5, 3.5])
            }
        }
    }

    private func drawEndpoints(nodes: [Node], selectedID: UInt32) {
        for node in nodes {
            drawEndpoint(node, emphasized: node.id == selectedID, highlighted: node.id == highlightedID)
        }
    }

    private func drawEdgeMarkers(viewport: CGRect, nodes: [Node]) {
        var grouped: [Edge: [CGPoint]] = [:]
        for node in nodes where !isBeyond(node) && !nodeVisible(node, in: viewport) {
            grouped[nearestEdge(to: node.point, in: viewport), default: []].append(node.point)
        }
        for (edge, points) in grouped {
            let centroid = CGPoint(
                x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
            let anchor = edgeAnchor(edge, for: centroid, in: viewport, offset: 9)
            let color = Self.mint.withAlphaComponent(0.75)
            Self.drawChevron(edge, at: anchor, color: color, size: Metric.chevronSize)
            let countCenter = outward(anchor, edge: edge, by: -(Metric.chevronSize + 10))
            Self.drawCount("\(points.count)", center: clampToBounds(countCenter), color: color)
        }
    }

    private func drawBeyondMarker(viewport: CGRect, source: CGPoint) {
        let beyond = beyondCount
        guard beyond > 0 else { return }
        let edge = nearestEdge(to: source, in: viewport)
        let anchor = edgeAnchor(edge, for: source, in: viewport, offset: 36)
        let color = Self.mint.withAlphaComponent(0.5)
        Self.drawBeyond(at: anchor, color: color, radius: Metric.beyondRadius)
        let countCenter = outward(anchor, edge: edge, by: -(Metric.beyondRadius + 10))
        Self.drawCount("\(beyond)", center: clampToBounds(countCenter), color: color)
    }

    private func drawTotalBadge(total: Int, at source: CGPoint, minimumX: CGFloat) {
        guard total > 0 else { return }
        let label = NSMutableAttributedString()
        label.append(NSAttributedString(string: "\(total)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: Self.brass,
        ]))
        label.append(NSAttributedString(string: total == 1 ? " site" : " sites", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: Self.mint,
        ]))
        let textSize = label.size()
        let width = textSize.width + 18
        let height = textSize.height + 11
        let x = clamped(max(minimumX, source.x + Metric.socketRadius + 8),
                        Metric.margin, bounds.width - width - Metric.margin)
        let y = clamped(source.y - height / 2, Metric.margin, bounds.height - height - Metric.margin)
        let plate = CGRect(x: x, y: y, width: width, height: height)
        let rounded = NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6)
        Self.ink.setFill()
        rounded.fill()
        Self.mint.withAlphaComponent(0.5).setStroke()
        rounded.lineWidth = 1
        rounded.stroke()
        label.draw(at: CGPoint(x: plate.minX + 9, y: plate.minY + (height - textSize.height) / 2 + 1))
    }

    private func clampToBounds(_ point: CGPoint) -> CGPoint {
        CGPoint(x: clamped(point.x, Metric.margin, bounds.width - Metric.margin),
                y: clamped(point.y, Metric.margin, bounds.height - Metric.margin))
    }

    private func outward(_ point: CGPoint, edge: Edge, by distance: CGFloat) -> CGPoint {
        CGPoint(x: point.x + edge.outward.dx * distance, y: point.y + edge.outward.dy * distance)
    }

    // MARK: Sockets and endpoints

    private func drawSourceSocket(at source: CGPoint) {
        Self.strokeRing(center: source, radius: Metric.socketRadius, color: Self.brass, width: 2,
                        under: Self.ink.withAlphaComponent(0.5))
        Self.fillDisk(center: source, radius: 2, color: Self.brass, rim: nil)
    }

    private func drawEndpoint(_ node: Node, emphasized: Bool, highlighted: Bool) {
        let radius = emphasized || highlighted ? Metric.endpointHoverRadius : Metric.endpointRadius
        let color = Self.color(for: node.kind)
        switch node.kind {
        case .original:
            Self.fillDisk(center: node.point, radius: radius, color: color, rim: Self.ink)
        case .translated:
            Self.fillSquare(center: node.point, radius: radius, color: color, rim: Self.ink)
        case .cutter:
            Self.strokeRing(center: node.point, radius: radius, color: color,
                            width: emphasized || highlighted ? 2.5 : 2, under: Self.ink.withAlphaComponent(0.6))
        }
        if emphasized {
            Self.strokeRing(center: node.point, radius: radius + 4, color: Self.brass.withAlphaComponent(0.55), width: 1.25)
        } else if highlighted {
            Self.strokeRing(center: node.point, radius: radius + 4.5, color: Self.mint.withAlphaComponent(0.5), width: 1)
        }
    }

    private static func color(for kind: Kind) -> NSColor {
        switch kind {
        case .original: return brass
        case .translated: return mint
        case .cutter: return mintLight
        }
    }

    // MARK: Primitive drawing

    private static func rayPath(from a: CGPoint, to b: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: a)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 1 else {
            path.line(to: b)
            return path
        }
        let bow = min(length * Metric.bowFactor, Metric.bowMax)
        let cx = (a.x + b.x) / 2 - dy / length * bow
        let cy = (a.y + b.y) / 2 + dx / length * bow
        let c1 = CGPoint(x: a.x + 2.0 / 3.0 * (cx - a.x), y: a.y + 2.0 / 3.0 * (cy - a.y))
        let c2 = CGPoint(x: b.x + 2.0 / 3.0 * (cx - b.x), y: b.y + 2.0 / 3.0 * (cy - b.y))
        path.curve(to: b, controlPoint1: c1, controlPoint2: c2)
        return path
    }

    private static func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat, dash: [CGFloat]? = nil) {
        path.lineWidth = width
        path.lineCapStyle = .round
        if let dash, !dash.isEmpty {
            dash.withUnsafeBufferPointer { path.setLineDash($0.baseAddress, count: $0.count, phase: 0) }
        } else {
            path.setLineDash(nil, count: 0, phase: 0)
        }
        color.setStroke()
        path.stroke()
    }

    private static func fillDisk(center: CGPoint, radius: CGFloat, color: NSColor, rim: NSColor?) {
        let path = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        color.setFill()
        path.fill()
        if let rim {
            rim.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private static func fillSquare(center: CGPoint, radius: CGFloat, color: NSColor, rim: NSColor?) {
        let path = NSBezierPath(roundedRect: CGRect(x: center.x - radius, y: center.y - radius,
                                                    width: radius * 2, height: radius * 2),
                                xRadius: radius * 0.25, yRadius: radius * 0.25)
        color.setFill()
        path.fill()
        if let rim {
            rim.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private static func strokeRing(center: CGPoint, radius: CGFloat, color: NSColor, width: CGFloat,
                                   under: NSColor? = nil) {
        let path = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        if let under {
            under.setStroke()
            path.lineWidth = width + 1.5
            path.stroke()
        }
        color.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    private static func drawChevron(_ edge: Edge, at anchor: CGPoint, color: NSColor, size: CGFloat) {
        let outward = edge.outward
        let tangent = CGVector(dx: -outward.dy, dy: outward.dx)
        let tip = CGPoint(x: anchor.x + outward.dx * size, y: anchor.y + outward.dy * size)
        let baseA = CGPoint(x: anchor.x + tangent.dx * size * 0.6, y: anchor.y + tangent.dy * size * 0.6)
        let baseB = CGPoint(x: anchor.x - tangent.dx * size * 0.6, y: anchor.y - tangent.dy * size * 0.6)
        let triangle = NSBezierPath()
        triangle.move(to: tip)
        triangle.line(to: baseA)
        triangle.line(to: baseB)
        triangle.close()
        color.setFill()
        triangle.fill()
    }

    private static func drawBeyond(at anchor: CGPoint, color: NSColor, radius: CGFloat) {
        let circle = NSBezierPath(ovalIn: CGRect(x: anchor.x - radius, y: anchor.y - radius,
                                                 width: radius * 2, height: radius * 2))
        color.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
        let d = radius * 0.7
        let slash = NSBezierPath()
        slash.move(to: CGPoint(x: anchor.x - d, y: anchor.y - d))
        slash.line(to: CGPoint(x: anchor.x + d, y: anchor.y + d))
        slash.lineWidth = 1.5
        slash.lineCapStyle = .round
        color.setStroke()
        slash.stroke()
    }

    private static func drawCount(_ text: String, center: CGPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: center.x - size.width / 2 - 4, y: center.y - size.height / 2 - 2,
                          width: size.width + 8, height: size.height + 4)
        let plate = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        ink.withAlphaComponent(0.62).setFill()
        plate.fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 4, y: center.y - size.height * 0.32),
                                withAttributes: attributes)
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        guard let diagram else {
            setAccessibilityLabel("")
            setAccessibilityValue("")
            return
        }
        setAccessibilityLabel(diagram.title)
        let count = "\(diagram.instanceCount) instances"
        if isExpanded {
            let offscreen = diagram.nodes.count - visibleCount - beyondCount
            let unlocated = diagram.instanceCount - diagram.nodes.count
            setAccessibilityValue("Expanded, \(count), \(visibleCount) on screen, "
                + "\(offscreen) off screen, \(beyondCount) beyond the view"
                + (unlocated > 0 ? ", \(unlocated) without a verified position" : ""))
            setAccessibilityHelp("Use the arrow keys from the viewport to inspect highlighted instances.")
        } else {
            setAccessibilityValue("Collapsed, \(count)")
            setAccessibilityHelp("Hold Option over either socket, or use Shared-Source Constellation in the Model menu.")
        }
    }
}
