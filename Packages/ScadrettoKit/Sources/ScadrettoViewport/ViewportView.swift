import AppKit
import MetalKit
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
///
/// Orbit drags scale by view height: one viewport height of drag is one full
/// revolution. Imprecise scroll zooms by `exp(deltaY * 0.2)`. Momentum-phase
/// scroll events are ignored while a button drag is active so a finishing
/// flick cannot fight a pan or orbit already in progress. A click is
/// distinguished from a drag by a three-point threshold; click selection is
/// out of scope for M2.
///
/// The camera survives `setMesh(_:)` revisions, per the plan's "preserve
/// camera across reevaluations"; only the first non-empty mesh auto-frames.
@MainActor
public final class ViewportView: MTKView {
    /// Camera state in world coordinates. Read-only; drive it through
    /// `frameAll`, `setStandardView` or gestures.
    public private(set) var camera = ViewportCamera()

    /// Orthographic projection when true, perspective when false.
    public var orthographic = false {
        didSet { needsDisplay = true }
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
    private var rightDownEvent: NSEvent?
    private var activeButton = false

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
    }

    @available(*, unavailable, message: "Create ViewportView with init(device:library:frame:)")
    required init(coder: NSCoder) {
        fatalError("ViewportView does not support Interface Builder archiving")
    }

    /// Flipped so view points are top-left origin, matching Metal's viewport
    /// convention; the coordinate conversion lives in `ViewportTransform`.
    public override var isFlipped: Bool { true }

    /// Replaces the displayed scene. `nil` clears the mesh but keeps the
    /// camera and axes so navigation still works on a failed evaluation.
    /// The camera is preserved across revisions; the first non-empty mesh
    /// frames itself so a model is visible without a `frameAll` call.
    public func setMesh(_ prepared: ViewportMeshUpload?) {
        upload = prepared ?? ViewportMeshUpload(mesh: ViewportMesh(positions: [], indices: []))
        renderer.upload(upload)
        if !hasAutoFramed, let bounds = upload.bounds, bounds.radius > 0 {
            camera.frameAll(bounds, aspect: boundsAspect)
            hasAutoFramed = true
        }
        isSceneStale = false
        needsDisplay = true
    }

    /// Frames the whole scene in the current view, keeping the camera's
    /// orientation and projection mode.
    public func frameAll() {
        guard let bounds = upload.bounds, bounds.radius > 0 else { return }
        camera.frameAll(bounds, aspect: boundsAspect)
        needsDisplay = true
    }

    /// Aims the camera along a standard view direction, keeping the current
    /// center and zoom.
    public func setStandardView(_ view: ViewportStandardView) {
        camera.setStandardView(view)
        needsDisplay = true
    }

    /// Marks or clears the stale-scene styling.
    public func setSceneStale(_ stale: Bool) {
        guard stale != isSceneStale else { return }
        isSceneStale = stale
        needsDisplay = true
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
        mouseDownPoint = viewPoint(for: event)
        lastDragPoint = mouseDownPoint
        activeButton = true
    }

    public override func rightMouseDown(with event: NSEvent) {
        // Held back from `super` so a right-drag pans; delivered on mouse-up
        // when the press turns out to be a motionless right-click.
        rightDownEvent = event
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
        handleDrag(event, role: dragRole(shift: event.modifierFlags.contains(.shift)))
    }

    public override func rightMouseDragged(with event: NSEvent) {
        handleDrag(event, role: .pan)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        handleDrag(event, role: .pan)
    }

    public override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        lastDragPoint = nil
        activeButton = false
    }

    public override func rightMouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            lastDragPoint = nil
            rightDownEvent = nil
            activeButton = false
        }
        guard let down = rightDownEvent,
              dragDistance(event) < Self.dragThreshold else { return }
        // Motionless right-click: replay through the default path so a context
        // menu still opens as upstream offers.
        super.rightMouseDown(with: down)
        super.rightMouseUp(with: event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        lastDragPoint = nil
        activeButton = false
    }

    /// Scroll mapping per the contract: imprecise deltas (mouse wheel) zoom
    /// about the cursor; precise deltas (trackpad, Magic Mouse) orbit, or pan
    /// with Shift. `swapsOrbitAndPan` exchanges the two precise-scroll roles.
    public override func scrollWheel(with event: NSEvent) {
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
                needsDisplay = true
            } else {
                camera.orbitByDrag(
                    deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                    viewSize: bounds.size)
                needsDisplay = true
            }
        } else {
            zoomBy(factor: exp(event.scrollingDeltaY * 0.2), anchoredAt: point)
        }
    }

    /// Pinch zoom about the cursor.
    public override func magnify(with event: NSEvent) {
        zoomBy(factor: 1 + event.magnification, anchoredAt: viewPoint(for: event))
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // The drawable size and with it the pick/projection mapping change on
        // backing-scale moves; rebuild it on the next frame.
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
        needsDisplay = true
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
        needsDisplay = true
    }
}

extension ViewportView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Projection rebuilds from the current size on every frame, so only
        // schedule a redraw under the new mapping.
        view.needsDisplay = true
    }

    public func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              bounds.width > 0, bounds.height > 0 else { return }
        renderer.draw(
            in: descriptor,
            drawable: drawable,
            transform: viewportTransform(),
            showsEdges: showsEdges,
            showsAxes: showsAxes,
            stale: isSceneStale
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
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let shadedPipeline: MTLRenderPipelineState
    private let edgePipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var axesBuffer: MTLBuffer?
    private var axesLength = 0.0

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
        guard let depthState = device.makeDepthStencilState(descriptor: depth),
              let queue = device.makeCommandQueue() else {
            throw ViewportError.renderStateUnavailable("depth stencil state or command queue")
        }
        self.depthState = depthState
        self.queue = queue
    }

    /// Rebuilds GPU buffers for an accepted mesh revision. An empty upload
    /// clears the scene. Also sizes the axis overlay to the scene.
    func upload(_ upload: ViewportMeshUpload) {
        indexCount = upload.indices.count
        if upload.vertexData.isEmpty || upload.indices.isEmpty {
            vertexBuffer = nil
            indexBuffer = nil
            indexCount = 0
        } else {
            vertexBuffer = upload.vertexData.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }
            indexBuffer = upload.indices.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }
        }

        axesLength = max(upload.sceneRadius * 1.25, 1)
        axesBuffer = ViewportMeshUpload.axesVertexData(length: axesLength, renderOrigin: upload.renderOrigin).withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
    }

    func draw(in descriptor: MTLRenderPassDescriptor, drawable: CAMetalDrawable,
              transform: ViewportTransform, showsEdges: Bool, showsAxes: Bool, stale: Bool) {
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

        encoder.setDepthStencilState(depthState)
        if let vertexBuffer, let indexBuffer, indexCount > 0 {
            // Push the fill slightly back so the edge pass wins equal depth.
            encoder.setDepthBias(showsEdges ? 1 : 0, slopeScale: showsEdges ? 1 : 0, clamp: 0)
            encoder.setRenderPipelineState(shadedPipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: indexCount, indexType: .uint32,
                indexBuffer: indexBuffer, indexBufferOffset: 0)

            if showsEdges {
                encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
                encoder.setTriangleFillMode(.lines)
                encoder.setRenderPipelineState(edgePipeline)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: indexCount, indexType: .uint32,
                    indexBuffer: indexBuffer, indexBufferOffset: 0)
                encoder.setTriangleFillMode(.fill)
            }
        }

        if showsAxes, let axesBuffer {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(axesBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 6)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
