import AppKit
import Carbon.HIToolbox
import MetalKit
import QuartzCore
import simd

/// Errors thrown when `ViewportView` cannot build its render state.
public enum ViewportError: Error, LocalizedError, Sendable {
    /// The supplied library does not export a required shader function.
    case missingShaderFunction(String)
    /// Metal rejected a pipeline or buffer.
    case renderStateUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingShaderFunction(let name):
            "The shader library does not contain the viewport function “\(name)”."
        case .renderStateUnavailable(let message):
            "The viewport renderer could not be created: \(message)"
        }
    }
}

/// Metal shader entry points the app must compile into its .metallib from
/// `App/ScadrettoShaders.metal`. The renderer receives a ready `MTLLibrary`
/// and never compiles shader source at runtime.
public enum ViewportShader {
    public static let meshVertex = "scadrettoVertex"
    public static let meshFragment = "scadrettoFragment"
    public static let edgeFragment = "scadrettoEdgeFragment"
    public static let lineVertex = "scadrettoLineVertex"
    public static let lineFragment = "scadrettoLineFragment"
}

/// A native `MTKView` showing one accepted evaluation mesh with orbit, pan and
/// zoom camera control.
///
/// Input mapping (matches the viewport contract in plan/04-macOS-Editor.md):
///
/// | Event | Default | With `swapsOrbitAndPan` |
/// |---|---|---|
/// | Left-drag on background | Orbit | Pan |
/// | Shift-left-drag | Pan | Orbit |
/// | Right-drag | Pan | Pan |
/// | Right-click without motion | Context menu via `super` | same |
/// | Middle-drag | Pan | Pan |
/// | Precise scroll (trackpad/Magic Mouse) | Orbit | Pan |
/// | Shift + precise scroll | Pan | Orbit |
/// | Imprecise scroll (mouse wheel) | Zoom about cursor | same |
/// | Pinch (`magnify`) | Zoom about cursor | same |
/// | 3D mouse (`setNavigationMotion`) | Model follows the cap: pan, zoom, rotate | same |
///
/// Orbit drags scale by view height: one viewport height of drag is one full
/// revolution. Imprecise scroll zooms by `exp(deltaY * 0.2)`. Momentum-phase
/// scroll events are ignored while a button drag is active so a finishing
/// flick cannot fight a pan or orbit already in progress. A click is
/// distinguished from a drag by a three-point threshold.
///
/// The camera survives `setMesh(_:)` revisions, per the plan's "preserve
/// camera across reevaluations"; only the first non-empty mesh auto-frames.
@MainActor
public final class ViewportView: MTKView {
    public struct Comparison {
        public let property: String
        public let before: String
        public let after: String
        public let anchor: SIMD3<Double>?

        public init(property: String, before: String, after: String, anchor: SIMD3<Double>?) {
            self.property = property
            self.before = before
            self.after = after
            self.anchor = anchor
        }
    }

    public struct PresentedFrame: Sendable {
        public let sceneID: UUID
        public let transform: ViewportTransform
        fileprivate let drawableSize: CGSize
        fileprivate let mapping: UInt64
        fileprivate let sequence: UInt64
        fileprivate let editHandle: ViewportEditHandle?
    }

    private struct HandleDrag {
        let frame: PresentedFrame
        let handle: ViewportEditHandle
        let startCoordinate: Double
        var value: Double?
    }

    /// Camera state in world coordinates. Read-only; drive it through
    /// `frameAll`, `setStandardView` or gestures.
    public private(set) var camera = ViewportCamera() {
        didSet { if camera != oldValue { projectionDidChange() } }
    }

    /// Orthographic projection when true, perspective when false.
    public var orthographic = false {
        didSet { if orthographic != oldValue { projectionDidChange() } }
    }

    /// Draws triangle edges over the shaded mesh, as upstream's Show Edges.
    public var showsEdges = false {
        didSet { needsDisplay = true }
    }

    /// Draws the world XYZ axes (red/green/blue) through the scene's render
    /// origin, scaled to the scene.
    public var showsAxes = false {
        didSet { needsDisplay = true }
    }

    /// Preference that swaps orbit and pan for left-drag, precise scroll and
    /// their Shift variants. Right-drag always pans.
    public var swapsOrbitAndPan = false

    /// Marks the shown scene as superseded by a pending evaluation; the mesh
    /// is drawn dimmed and desaturated until the next `setMesh` or
    /// `setSceneStale(false)`.
    public private(set) var isSceneStale = false

    private let renderer: ViewportRenderer
    private var upload = ViewportMeshUpload(mesh: ViewportMesh(positions: [], indices: []))
    private var hasAutoFramed = false
    private var mouseDownPoint: NSPoint?
    private var lastDragPoint: NSPoint?
    private var activeButton = false
    private var sceneID: UUID?
    private var presentation: PresentedFrame?
    private var pressedFrame: PresentedFrame?
    private var mapping: UInt64 = 0
    private var sequence: UInt64 = 0
    private var presentationRetries = 0
    private var presentationRetryTask: Task<Void, Never>?
    private var occlusionObserver: (any NSObjectProtocol)?
    private var editHandle: ViewportEditHandle?
    private var diameterGuides: [ViewportDiameterGuide] = []
    private var linearGuides: [ViewportLinearGuide] = []
    private var handleDragState: HandleDrag?
    private let caliper = CaliperOverlay(frame: .zero)
    private var receiptTask: Task<Void, Never>?
    private let comparisonOverlay = ComparisonCutOverlay(frame: .zero)
    private var comparison: Comparison?
    private var comparisonBounds: ViewportBounds?
    private var comparisonOrigin = SIMD3<Double>.zero
    private var comparisonSweep: Task<Void, Never>?
    private weak var comparisonReturnFocus: NSResponder?
    private var spaceMonitor: Any?
    private var spaceHeld = false
    public var canCompare: Bool { comparison != nil && !isSceneStale }
    public private(set) var isComparisonPinned = false
    public var isComparing: Bool { canCompare && (isComparisonPinned || spaceHeld) }
    public var onComparisonChange: (() -> Void)?
    public var onOverlayGeometryChange: (() -> Void)?
    public var caliperCaption = "Dimension"
    private var navigationMotion = ViewportMotion.zero
    private var navigationLink: CADisplayLink?
    private var lastNavigationTime: CFTimeInterval?

    public var onSelection: ((PresentedFrame, CGPoint) -> Void)?
    public var onPresentationChange: (() -> Void)?
    /// Called on the main actor with the scene, if any, and the Metal presentation time of every
    /// presented frame. Measurements set it; drawing does not depend on it.
    public var onFramePresented: ((UUID?, CFTimeInterval) -> Void)?
    public var onEditPreview: ((Double?) -> Void)?
    public var onEditCommit: ((UUID, UUID, Double) -> Bool)?
    public var dragSnapIncrement: Double = 0 {
        didSet {
            if dragSnapIncrement != oldValue { cancelHandleDrag() }
        }
    }

    /// The current scene can be inspected while a new camera pose is drawing.
    public var presentedSceneID: UUID? { frameOnCurrentDrawable?.sceneID }

    /// The confirmed frame for the current camera and drawable mapping.
    public var presentedFrame: PresentedFrame? {
        guard let frame = frameOnCurrentDrawable, frame.transform.camera == camera,
              frame.transform.isOrthographic == orthographic else { return nil }
        return frame
    }

    private var frameOnCurrentDrawable: PresentedFrame? {
        guard !isSceneStale, let presentation, presentation.sceneID == sceneID,
              presentation.transform.viewSize == bounds.size,
              presentation.drawableSize == drawableSize,
              presentation.mapping == mapping else { return nil }
        return presentation
    }

    /// View-pixel distance below which a press is a click, not a drag.
    private static let dragThreshold: Double = 3

    /// Creates the view and its Metal state.
    ///
    /// - Parameters:
    ///   - device: the `MTLDevice` rendering the view.
    ///   - library: the app's default metallib containing the `ViewportShader`
    ///     entry points; passing it keeps runtime shader compilation off the
    ///     launch path.
    ///   - frame: initial frame rectangle in points.
    public init(device: MTLDevice, library: MTLLibrary, frame: CGRect = .zero) throws {
        renderer = try ViewportRenderer(device: device, library: library)
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColor(red: 0.15, green: 0.16, blue: 0.19, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        caliper.frame = bounds
        caliper.autoresizingMask = [.width, .height]
        caliper.isHidden = true
        caliper.setAccessibilityElement(true)
        caliper.setAccessibilityRole(.staticText)
        caliper.setAccessibilityLabel("Caliper")
        caliper.setAccessibilityIdentifier("caliperReading")
        addSubview(caliper)
        comparisonOverlay.frame = bounds
        comparisonOverlay.autoresizingMask = [.width, .height]
        comparisonOverlay.isHidden = true
        comparisonOverlay.onPosition = { [weak self] _ in
            self?.stopComparisonSweep()
            self?.needsDisplay = true
        }
        comparisonOverlay.onTogglePin = { [weak self] in self?.toggleComparisonPin() }
        comparisonOverlay.onDismiss = { [weak self] in self?.dismissComparison() }
        addSubview(comparisonOverlay)
    }

    @available(*, unavailable, message: "Create ViewportView with init(device:library:frame:)")
    required init(coder: NSCoder) {
        fatalError("ViewportView does not support Interface Builder archiving")
    }

    /// Flipped so view points are top-left origin, matching Metal's viewport
    /// convention; the coordinate conversion lives in `ViewportTransform`.
    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        if !hasAutoFramed { frameAll() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeSpaceMonitor()
        if spaceHeld { endTemporaryComparison() }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        // A display link follows one window's screen; the motion carries over to the new window.
        navigationLink?.invalidate()
        navigationLink = nil
        updateNavigationLink()
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowOcclusionDidChange() }
        }
    }

    /// A covered window presents nothing, and the bounded retries run out while it stays
    /// covered. Draw again once part of it shows, so a scene that arrived meanwhile is presented.
    private func windowOcclusionDidChange() {
        guard window?.occlusionState.contains(.visible) == true, !presentationIsCurrent else { return }
        resetPresentationRetry()
        needsDisplay = true
    }

    /// Replaces the displayed scene. `nil` clears the mesh but keeps the
    /// camera and axes so navigation still works on a failed evaluation.
    /// The camera is preserved across revisions; the first non-empty mesh
    /// frames itself so a model is visible without a `frameAll` call.
    public func setMesh(_ prepared: ViewportMeshUpload?, sceneID: UUID? = nil, comparison: Comparison? = nil) {
        dismissComparison()
        self.comparison = comparison
        comparisonBounds = comparison == nil ? nil : upload.bounds
        comparisonOrigin = upload.renderOrigin
        upload = prepared ?? ViewportMeshUpload(mesh: ViewportMesh(positions: [], indices: []))
        self.sceneID = sceneID
        invalidatePresentation()
        renderer.upload(upload, retainPrevious: comparison != nil)
        renderer.uploadGhost(nil)
        if !hasAutoFramed { frameAll() }
        isSceneStale = false
        needsDisplay = true
        onComparisonChange?()
        onOverlayGeometryChange?()
    }

    /// Frames the whole scene in the current view, keeping the camera's
    /// orientation and projection mode.
    public func frameAll() {
        guard bounds.width > 0, bounds.height > 0,
              let meshBounds = upload.bounds, meshBounds.radius > 0 else { return }
        camera.frameAll(meshBounds, aspect: boundsAspect)
        hasAutoFramed = true
    }

    /// Aims the camera along a standard view direction, keeping the current
    /// center and zoom.
    public func setStandardView(_ view: ViewportStandardView) {
        camera.setStandardView(view)
    }

    /// Marks or clears the stale-scene styling.
    public func setSceneStale(_ stale: Bool) {
        guard stale != isSceneStale else { return }
        if stale { dismissComparison() }
        isSceneStale = stale
        if stale {
            comparison = nil
            comparisonBounds = nil
            renderer.clearComparison()
            invalidatePresentation()
        }
        needsDisplay = true
        onComparisonChange?()
        onOverlayGeometryChange?()
    }

    private func invalidatePresentation() {
        mapping &+= 1
        resetPresentationRetry()
        let wasPresented = presentation != nil
        presentation = nil
        cancelHandleDrag()
        if wasPresented { onPresentationChange?() }
    }

    private func projectionDidChange() {
        clearCaliper()
        pressedFrame = nil
        cancelHandleDrag()
        resetPresentationRetry()
        needsDisplay = true
        onOverlayGeometryChange?()
    }

    @discardableResult
    public func toggleComparisonPin() -> Bool {
        guard canCompare, handleDragState == nil else { return false }
        let wasComparing = isComparing
        isComparisonPinned.toggle()
        updateComparisonVisibility(wasComparing: wasComparing)
        if isComparing { window?.makeFirstResponder(comparisonOverlay) }
        return true
    }

    public func endTemporaryComparison() {
        guard spaceHeld else { return }
        let wasComparing = isComparing
        spaceHeld = false
        removeSpaceMonitor()
        updateComparisonVisibility(wasComparing: wasComparing)
    }

    private func beginTemporaryComparison() {
        guard canCompare, !spaceHeld, handleDragState == nil, !activeButton else { return }
        let wasComparing = isComparing
        spaceHeld = true
        // The divider can take focus while Space is held. Track its release even then.
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, event.keyCode == kVK_Space else { return event }
            endTemporaryComparison()
            return nil
        }
        updateComparisonVisibility(wasComparing: wasComparing)
        window?.makeFirstResponder(comparisonOverlay)
    }

    private func removeSpaceMonitor() {
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        spaceMonitor = nil
    }

    private func dismissComparison() {
        let wasComparing = isComparing
        isComparisonPinned = false
        spaceHeld = false
        removeSpaceMonitor()
        updateComparisonVisibility(wasComparing: wasComparing)
    }

    private func updateComparisonVisibility(wasComparing: Bool) {
        comparisonOverlay.isPinned = isComparisonPinned
        comparisonOverlay.isHidden = !isComparing
        onComparisonChange?()
        guard wasComparing != isComparing else { return }
        if isComparing, let comparison {
            comparisonReturnFocus = window?.firstResponder
            clearCaliper()
            cancelHandleDrag()
            pressedFrame = nil
            comparisonOverlay.propertyName = comparison.property
            comparisonOverlay.beforeLabel = comparison.before
            comparisonOverlay.afterLabel = comparison.after
            comparisonOverlay.toolTip = "Compare \(comparison.property). Drag the divider or use the arrow keys."
            let projected = comparison.anchor.flatMap { viewportTransform().project($0) }
            let position = projected.flatMap { (0...1).contains($0.z) ? $0.x : nil }
            let target = min(max((position ?? bounds.midX) / max(bounds.width, 1), 0.10), 0.90)
            revealComparison(at: target)
        } else {
            stopComparisonSweep()
            if let responder = window?.firstResponder as? NSView,
               responder === comparisonOverlay || responder.isDescendant(of: comparisonOverlay) {
                let previous = comparisonReturnFocus as? NSView
                if let previous, previous.window === window, !previous.isHiddenOrHasHiddenAncestor {
                    if window?.makeFirstResponder(previous) != true { window?.makeFirstResponder(self) }
                } else {
                    window?.makeFirstResponder(self)
                }
            }
            comparisonReturnFocus = nil
        }
        needsDisplay = true
        onOverlayGeometryChange?()
    }

    private func revealComparison(at target: CGFloat) {
        stopComparisonSweep()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            comparisonOverlay.fraction = target
            return
        }
        comparisonOverlay.fraction = 0
        let start = CACurrentMediaTime()
        comparisonSweep = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = min((CACurrentMediaTime() - start) / 0.18, 1)
                comparisonOverlay.fraction = target * (1 - pow(1 - elapsed, 3))
                needsDisplay = true
                if elapsed == 1 { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopComparisonSweep() {
        comparisonSweep?.cancel()
        comparisonSweep = nil
    }

    public func showDiameter(handle: ViewportDiameterHandle?, guides: [ViewportDiameterGuide]) {
        diameterGuides = guides
        linearGuides = []
        showHandle(handle.map(ViewportEditHandle.diameter))
    }

    public func showLinear(handle: ViewportLinearHandle?, guides: [ViewportLinearGuide]) {
        linearGuides = guides
        diameterGuides = []
        showHandle(handle.map(ViewportEditHandle.linear))
    }

    public func showGhost(_ mesh: ViewportMesh?) {
        renderer.uploadGhost(mesh.map { ViewportMeshUpload(mesh: $0, renderOrigin: upload.renderOrigin) })
        needsDisplay = true
    }

    private func showHandle(_ handle: ViewportEditHandle?) {
        if editHandle?.id != handle?.id {
            cancelHandleDrag()
            resetPresentationRetry()
        }
        editHandle = handle
        needsDisplay = true
    }

    private func didPresent(_ frame: PresentedFrame) {
        guard frame.sceneID == sceneID, !isSceneStale, frame.mapping == mapping,
              frame.transform.viewSize == bounds.size, frame.drawableSize == drawableSize,
              presentation.map({ $0.sequence < frame.sequence }) ?? true else { return }
        let wasPresented = presentation != nil
        presentation = frame
        if presentationIsCurrent { resetPresentationRetry() }
        if !wasPresented { onPresentationChange?() }
    }

    private var presentationIsCurrent: Bool {
        guard let frame = presentedFrame else { return false }
        return frame.editHandle?.id == editHandle?.id
    }

    private func resetPresentationRetry() {
        presentationRetryTask?.cancel()
        presentationRetryTask = nil
        presentationRetries = 0
    }

    /// An on-demand frame can be skipped or fail to acquire a drawable, and the window server
    /// drops the frames of a window it is still recomposing, for example for a few hundred
    /// milliseconds after another window closes over it. Retry quickly first, then back off to
    /// one frame a second, for about twelve seconds in all.
    private static let quickPresentationRetries = 5
    private static let maximumPresentationRetries = 20

    private static func presentationRetryDelay(after retries: Int) -> Duration {
        let quickDelay = 40
        guard retries >= quickPresentationRetries else { return .milliseconds(quickDelay) }
        let doublings = min(retries - quickPresentationRetries + 1, 5)
        return .milliseconds(min(quickDelay << doublings, 1_000))
    }

    private func retryUnconfirmedFrame() {
        guard presentationRetryTask == nil, !presentationIsCurrent, !isSceneStale, sceneID != nil,
              window?.isVisible == true, presentationRetries < Self.maximumPresentationRetries else { return }
        let mapping = self.mapping
        let delay = Self.presentationRetryDelay(after: presentationRetries)
        presentationRetryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, self.mapping == mapping else { return }
            presentationRetryTask = nil
            guard !presentationIsCurrent, !isSceneStale, window?.isVisible == true else { return }
            presentationRetries += 1
            draw()
        }
    }

    /// The view/projection mapping of the next frame, for hit testing and
    /// overlay code that must agree with the presented frame. View points are
    /// top-left origin; use `project`/`ray` on the result rather than the raw
    /// matrices.
    public func viewportTransform() -> ViewportTransform {
        camera.transform(
            viewSize: bounds.size,
            orthographic: orthographic,
            renderOrigin: upload.renderOrigin,
            sceneRadius: upload.sceneRadius
        )
    }

    private var boundsAspect: Double {
        max(bounds.width / max(bounds.height, 1), 1e-6)
    }

    private func viewPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: - Gestures

    public override func mouseDown(with event: NSEvent) {
        // A drag still held here lost its release, and only a release commits.
        clearCaliper()
        cancelHandleDrag()
        pressedFrame = isComparing ? nil : presentedFrame
        mouseDownPoint = viewPoint(for: event)
        lastDragPoint = mouseDownPoint
        activeButton = true
        if isComparing {
            window?.makeFirstResponder(comparisonOverlay)
            return
        }
        window?.makeFirstResponder(self)
        guard presentationIsCurrent, let frame = pressedFrame, let handle = frame.editHandle,
              let point = mouseDownPoint, handle.contains(point, in: frame.transform),
              let start = handle.coordinate(at: point, in: frame.transform) else { return }
        handleDragState = HandleDrag(frame: frame, handle: handle, startCoordinate: start)
        updateCaliper(for: handle, in: frame.transform, value: nil)
        onOverlayGeometryChange?()
    }

    public override func rightMouseDown(with event: NSEvent) {
        // Held back from `super` so a right-drag pans; delivered on mouse-up
        // when the press turns out to be a motionless right-click.
        mouseDownPoint = viewPoint(for: event)
        lastDragPoint = mouseDownPoint
        activeButton = true
    }

    public override func otherMouseDown(with event: NSEvent) {
        mouseDownPoint = viewPoint(for: event)
        lastDragPoint = mouseDownPoint
        activeButton = true
    }

    public override func mouseDragged(with event: NSEvent) {
        if handleDragState != nil {
            updateHandleDrag(at: viewPoint(for: event))
            return
        }
        handleDrag(event, role: dragRole(shift: event.modifierFlags.contains(.shift)))
    }

    public override func rightMouseDragged(with event: NSEvent) {
        handleDrag(event, role: .pan)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        handleDrag(event, role: .pan)
    }

    public override func mouseUp(with event: NSEvent) {
        if handleDragState != nil {
            updateHandleDrag(at: viewPoint(for: event))
            if let drag = handleDragState, let value = drag.value,
               let current = presentedFrame, current.sceneID == drag.frame.sceneID,
               current.mapping == drag.frame.mapping, editHandle?.id == drag.handle.id {
                let reading = caliper.reading
                cancelHandleDrag()
                if onEditCommit?(current.sceneID, drag.handle.id, value) == true, var reading {
                    reading.recorded = true
                    caliper.reading = reading
                    receiptTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(750))
                        guard !Task.isCancelled else { return }
                        self?.clearCaliper()
                    }
                }
            } else {
                cancelHandleDrag()
            }
        } else if activeButton, dragDistance(event) < Self.dragThreshold, let frame = pressedFrame,
                  frame.sequence == presentedFrame?.sequence {
            onSelection?(frame, viewPoint(for: event))
        }
        pressedFrame = nil
        mouseDownPoint = nil
        lastDragPoint = nil
        activeButton = false
    }

    public override func rightMouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            lastDragPoint = nil
            activeButton = false
        }
        guard let menu, dragDistance(event) < Self.dragThreshold else { return }
        menu.popUp(positioning: nil, at: viewPoint(for: event), in: self)
    }

    public override func otherMouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        lastDragPoint = nil
        activeButton = false
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\u{1b}" {
            if handleDragState != nil {
                cancelHandleDrag()
                return
            }
            if isComparing {
                dismissComparison()
                return
            }
        }
        if event.keyCode == kVK_Space, canCompare, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if !event.isARepeat { beginTemporaryComparison() }
            return
        }
        super.keyDown(with: event)
    }

    private func updateHandleDrag(at point: CGPoint) {
        guard var drag = handleDragState else { return }
        let previousValue = drag.value
        drag.value = drag.handle.coordinate(at: point, in: drag.frame.transform).flatMap { end in
            drag.handle.value(from: drag.startCoordinate, to: end, snap: dragSnapIncrement)
        }
        handleDragState = drag
        if dragSnapIncrement > 0, let value = drag.value, value != previousValue {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        updateCaliper(for: drag.handle, in: drag.frame.transform, value: drag.value)
        onEditPreview?(drag.value)
        needsDisplay = true
        onOverlayGeometryChange?()
    }

    private func cancelHandleDrag() {
        guard handleDragState != nil else { return }
        handleDragState = nil
        clearCaliper()
        pressedFrame = nil
        mouseDownPoint = nil
        lastDragPoint = nil
        activeButton = false
        onEditPreview?(nil)
        needsDisplay = true
        onOverlayGeometryChange?()
    }

    public var handleDragValue: Double? { handleDragState?.value }
    public var isDraggingHandle: Bool { handleDragState != nil }

    private func clearCaliper() {
        receiptTask?.cancel()
        receiptTask = nil
        caliper.reading = nil
    }

    private func updateCaliper(for handle: ViewportEditHandle, in transform: ViewportTransform, value: Double?) {
        let baseline: Double
        let before: SIMD3<Double>
        let after: SIMD3<Double>
        switch handle {
        case .diameter(let radial):
            baseline = radial.diameter
            before = radial.rim(at: baseline)
            after = radial.rim(at: value ?? baseline)
        case .linear(let linear):
            baseline = linear.value
            before = linear.anchor
            after = linear.point(for: value ?? baseline)
        }
        guard let origin = transform.project(before), let tip = transform.project(after),
              (0...1).contains(origin.z), (0...1).contains(tip.z),
              origin.x.isFinite, origin.y.isFinite, tip.x.isFinite, tip.y.isFinite else {
            caliper.reading = nil
            return
        }
        let inset = bounds.insetBy(dx: 5, dy: 5)
        let visibleTip = CGPoint(x: min(max(tip.x, inset.minX), inset.maxX),
                                 y: min(max(tip.y, inset.minY), inset.maxY))
        caliper.reading = CaliperOverlay.Reading(origin: CGPoint(x: origin.x, y: origin.y),
                                                 tip: visibleTip,
                                                 baseline: baseline, proposal: value ?? baseline,
                                                 caption: caliperCaption)
    }

    /// Scroll mapping per the contract: imprecise deltas (mouse wheel) zoom
    /// about the cursor; precise deltas (trackpad, Magic Mouse) orbit, or pan
    /// with Shift. `swapsOrbitAndPan` exchanges the two precise-scroll roles.
    public override func scrollWheel(with event: NSEvent) {
        guard handleDragState == nil else { return }
        if event.momentumPhase != [] && activeButton { return }
        let point = viewPoint(for: event)
        if event.hasPreciseScrollingDeltas {
            let pans = event.modifierFlags.contains(.shift) != swapsOrbitAndPan
            if pans {
                // Two-finger scroll moves the scene with the fingers under
                // natural scrolling: delta up moves the scene up.
                camera.panByScreenDelta(
                    SIMD2(event.scrollingDeltaX, -event.scrollingDeltaY),
                    transform: viewportTransform())
            } else {
                camera.orbitByDrag(
                    deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                    viewSize: bounds.size)
            }
        } else {
            zoomBy(factor: exp(event.scrollingDeltaY * 0.2), anchoredAt: point)
        }
    }

    /// Continuous navigation velocity, as a 3D mouse reports it. The camera
    /// moves every display frame until the motion returns to zero; see
    /// `ViewportCamera.navigate`. Like scrolling, it leaves the camera alone
    /// while a handle drag is in progress.
    public func setNavigationMotion(_ motion: ViewportMotion) {
        navigationMotion = motion
        updateNavigationLink()
    }

    /// Runs a display link while there is motion and a window to draw in.
    private func updateNavigationLink() {
        if navigationMotion.isZero || window == nil {
            navigationLink?.invalidate()
            navigationLink = nil
            lastNavigationTime = nil
        } else if navigationLink == nil {
            let link = displayLink(target: self, selector: #selector(advanceNavigation(_:)))
            link.add(to: .main, forMode: .common)
            navigationLink = link
            lastNavigationTime = nil
        }
    }

    @objc private func advanceNavigation(_ link: CADisplayLink) {
        let time = link.targetTimestamp
        let seconds = lastNavigationTime.map { time - $0 } ?? link.duration
        lastNavigationTime = time
        guard handleDragState == nil, bounds.width > 0, bounds.height > 0 else { return }
        camera.navigate(navigationMotion, seconds: seconds, transform: viewportTransform())
    }

    /// Pinch zoom about the cursor.
    public override func magnify(with event: NSEvent) {
        guard handleDragState == nil else { return }
        zoomBy(factor: 1 + event.magnification, anchoredAt: viewPoint(for: event))
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidatePresentation()
        needsDisplay = true
    }

    // MARK: - Camera actions

    private enum DragRole {
        case orbit, pan
    }

    /// Left-drag role: orbit, or pan with Shift; `swapsOrbitAndPan` inverts.
    private func dragRole(shift: Bool) -> DragRole {
        (shift != swapsOrbitAndPan) ? .pan : .orbit
    }

    private func dragDistance(_ event: NSEvent) -> Double {
        guard let start = mouseDownPoint else { return .infinity }
        let point = viewPoint(for: event)
        return hypot(point.x - start.x, point.y - start.y)
    }

    private func handleDrag(_ event: NSEvent, role: DragRole) {
        guard dragDistance(event) >= Self.dragThreshold else { return }
        // Per-event deltas come from tracked view points rather than
        // event.deltaX/Y so the flipped coordinate system stays unambiguous.
        let point = viewPoint(for: event)
        let delta = SIMD2<Double>(Double(point.x - (lastDragPoint?.x ?? point.x)),
                                  Double(point.y - (lastDragPoint?.y ?? point.y)))
        lastDragPoint = point
        switch role {
        case .orbit:
            camera.orbitByDrag(deltaX: delta.x, deltaY: delta.y, viewSize: bounds.size)
        case .pan:
            camera.panByScreenDelta(delta, transform: viewportTransform())
        }
    }

    private func zoomBy(factor: Double, anchoredAt point: CGPoint) {
        camera.zoom(factor: factor, anchoredAt: point) { camera in
            camera.transform(
                viewSize: bounds.size,
                orthographic: orthographic,
                renderOrigin: upload.renderOrigin,
                sceneRadius: upload.sceneRadius
            )
        }
    }
}

extension ViewportView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        clearCaliper()
        invalidatePresentation()
        view.needsDisplay = true
        onOverlayGeometryChange?()
    }

    public func draw(in view: MTKView) {
        defer { retryUnconfirmedFrame() }
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              bounds.width > 0, bounds.height > 0 else { return }
        let transform = viewportTransform()
        let cut: ViewportRenderer.Cut?
        if isComparing {
            let projection = ViewportComparisonProjection(camera: camera, viewSize: bounds.size,
                                                          orthographic: orthographic, beforeOrigin: comparisonOrigin,
                                                          beforeBounds: comparisonBounds, after: upload)
            cut = ViewportRenderer.Cut(fraction: comparisonOverlay.fraction, projection: projection)
        } else {
            cut = nil
        }
        let handle = isSceneStale ? nil : editHandle
        let overlay: [ViewportVertex]
        switch isComparing ? nil : handle {
        case .diameter(let radial):
            overlay = diameterOverlay(handle: radial, guides: diameterGuides,
                                      diameter: handleDragState?.value ?? radial.diameter, transform: transform)
        case .linear(let linear):
            overlay = linearOverlay(handle: linear, guides: linearGuides,
                                    value: handleDragState?.value ?? linear.value, transform: transform)
        case nil:
            overlay = []
        }
        if let sceneID, !isSceneStale {
            sequence &+= 1
            let pixels = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            let frame = PresentedFrame(sceneID: sceneID, transform: transform, drawableSize: pixels,
                                       mapping: mapping, sequence: sequence, editHandle: handle)
            drawable.addPresentedHandler { [weak self] drawable in
                guard drawable.presentedTime > 0 else { return }
                Task { @MainActor in self?.didPresent(frame) }
            }
        }
        if onFramePresented != nil {
            let scene = isSceneStale ? nil : sceneID
            drawable.addPresentedHandler { [weak self] drawable in
                let time = drawable.presentedTime
                guard time > 0 else { return }
                Task { @MainActor in self?.onFramePresented?(scene, time) }
            }
        }
        renderer.draw(
            in: descriptor,
            drawable: drawable,
            transform: transform,
            showsEdges: showsEdges,
            showsAxes: showsAxes,
            stale: isSceneStale,
            overlay: overlay,
            cut: cut
        )
    }
}

/// Uniform block shared with `App/ScadrettoShaders.metal`. Layout must match
/// `ViewportUniforms` there.
struct ViewportUniforms {
    var viewProjection: simd_float4x4
    var baseColor: simd_float4
    var edgeColor: simd_float4
    var lightDirection: simd_float4
    var staleDim: Float
    var padding = SIMD3<Float>.zero
}

/// Metal state and draw calls for `ViewportView`. Created once per view;
/// every call site is on the main actor.
@MainActor
final class ViewportRenderer {
    struct Cut {
        let fraction: CGFloat
        let projection: ViewportComparisonProjection
    }

    private struct MeshBuffers {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let count: Int
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let shadedPipeline: MTLRenderPipelineState
    private let ghostPipeline: MTLRenderPipelineState
    private let edgePipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let overlayDepthState: MTLDepthStencilState
    private var mesh: MeshBuffers?
    private var previousMesh: MeshBuffers?
    private var ghost: MeshBuffers?
    private var axesBuffer: MTLBuffer?

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        func function(_ name: String) throws -> MTLFunction {
            guard let function = library.makeFunction(name: name) else {
                throw ViewportError.missingShaderFunction(name)
            }
            return function
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<ViewportVertex>.offset(of: \.a)!
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<ViewportVertex>.stride

        do {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try function(ViewportShader.meshVertex)
            descriptor.fragmentFunction = try function(ViewportShader.meshFragment)
            descriptor.vertexDescriptor = vertexDescriptor
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            shadedPipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            let blend = descriptor.colorAttachments[0]!
            blend.isBlendingEnabled = true
            blend.sourceRGBBlendFactor = .sourceAlpha
            blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ghostPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            blend.isBlendingEnabled = false

            descriptor.fragmentFunction = try function(ViewportShader.edgeFragment)
            edgePipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            descriptor.vertexFunction = try function(ViewportShader.lineVertex)
            descriptor.fragmentFunction = try function(ViewportShader.lineFragment)
            linePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch let error as ViewportError {
            throw error
        } catch {
            throw ViewportError.renderStateUnavailable(error.localizedDescription)
        }

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        let overlayDepth = MTLDepthStencilDescriptor()
        overlayDepth.depthCompareFunction = .always
        guard let depthState = device.makeDepthStencilState(descriptor: depth),
              let overlayDepthState = device.makeDepthStencilState(descriptor: overlayDepth),
              let queue = device.makeCommandQueue() else {
            throw ViewportError.renderStateUnavailable("depth stencil state or command queue")
        }
        self.depthState = depthState
        self.overlayDepthState = overlayDepthState
        self.queue = queue
    }

    /// Rebuilds GPU buffers for an accepted mesh revision. An empty upload
    /// clears the scene. Also sizes the axis overlay to the scene.
    func upload(_ upload: ViewportMeshUpload, retainPrevious: Bool) {
        previousMesh = retainPrevious ? mesh : nil
        mesh = makeBuffers(upload)

        let axesLength = max(upload.sceneRadius * 1.25, 1)
        axesBuffer = ViewportMeshUpload.axesVertexData(length: axesLength, renderOrigin: upload.renderOrigin).withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
    }

    func uploadGhost(_ upload: ViewportMeshUpload?) {
        ghost = upload.flatMap(makeBuffers)
    }

    func clearComparison() {
        previousMesh = nil
    }

    private func makeBuffers(_ upload: ViewportMeshUpload) -> MeshBuffers? {
        guard !upload.vertexData.isEmpty, !upload.indices.isEmpty,
              let vertices = upload.vertexData.withUnsafeBytes({ bytes in
                  bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
              }),
              let indices = upload.indices.withUnsafeBytes({ bytes in
                  bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
              }) else {
            return nil
        }
        return MeshBuffers(vertices: vertices, indices: indices, count: upload.indices.count)
    }

    func draw(in descriptor: MTLRenderPassDescriptor, drawable: CAMetalDrawable,
              transform: ViewportTransform, showsEdges: Bool, showsAxes: Bool, stale: Bool,
              overlay: [ViewportVertex], cut: Cut?) {
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let dim: Float = stale ? 0.55 : 1
        var uniforms = ViewportUniforms(
            viewProjection: transform.gpuViewProjection,
            baseColor: simd_float4(0.78, 0.66, 0.38, 1),
            edgeColor: simd_float4(0.06, 0.06, 0.08, 1),
            lightDirection: simd_float4(SIMD3<Float>(-0.45, -0.55, 0.7), 0),
            staleDim: dim
        )

        func drawMesh(_ buffers: MeshBuffers?, using transform: ViewportTransform) {
            guard let buffers else { return }
            var uniforms = uniforms
            uniforms.viewProjection = transform.gpuViewProjection
            encoder.setDepthStencilState(depthState)
            // Push the fill slightly back so the edge pass wins equal depth.
            encoder.setDepthBias(showsEdges ? 1 : 0, slopeScale: showsEdges ? 1 : 0, clamp: 0)
            encoder.setRenderPipelineState(shadedPipeline)
            encoder.setVertexBuffer(buffers.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: buffers.count, indexType: .uint32,
                indexBuffer: buffers.indices, indexBufferOffset: 0)

            if showsEdges {
                encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
                encoder.setTriangleFillMode(.lines)
                encoder.setRenderPipelineState(edgePipeline)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: buffers.count, indexType: .uint32,
                    indexBuffer: buffers.indices, indexBufferOffset: 0)
                encoder.setTriangleFillMode(.fill)
            }
        }

        if let cut {
            let width = drawable.texture.width
            let height = drawable.texture.height
            let split = ViewportComparisonProjection.splitPixel(at: cut.fraction, drawableWidth: width)
            if split > 0 {
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: split, height: height))
                drawMesh(previousMesh, using: cut.projection.before)
            }
            if split < width {
                encoder.setScissorRect(MTLScissorRect(x: split, y: 0, width: width - split, height: height))
                drawMesh(mesh, using: cut.projection.after)
            }
            encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: height))
            uniforms.viewProjection = cut.projection.after.gpuViewProjection
        } else {
            drawMesh(mesh, using: transform)
        }

        if showsAxes, let axesBuffer {
            encoder.setDepthStencilState(depthState)
            encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(axesBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 6)
        }

        if !stale, cut == nil, let ghost {
            var translucent = uniforms
            translucent.baseColor = SIMD4(0.31, 0.79, 0.94, 0.21)
            encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
            encoder.setDepthStencilState(overlayDepthState)
            encoder.setRenderPipelineState(ghostPipeline)
            encoder.setVertexBuffer(ghost.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&translucent, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&translucent, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: ghost.count, indexType: .uint32,
                                          indexBuffer: ghost.indices, indexBufferOffset: 0)
        }

        if !overlay.isEmpty, let buffer = overlay.withUnsafeBytes({ bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
        }) {
            encoder.setDepthStencilState(overlayDepthState)
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: overlay.count)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
