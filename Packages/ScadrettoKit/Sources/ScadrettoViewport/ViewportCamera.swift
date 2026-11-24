import simd
import CoreGraphics

/// Named camera orientations offered by the View menu and `setStandardView`.
///
/// Each case is an eye direction (the direction the camera looks, from the
/// camera toward the model) plus an up reference, in the Z-up world space of
/// plan/04-macOS-Editor.md: front looks along +Y with +Z up, top looks along
/// -Z with +Y up.
public enum ViewportStandardView: String, CaseIterable, Sendable {
    case top, bottom, left, right, front, back, diagonal

    /// Unit direction the camera looks along, in world coordinates.
    public var forward: SIMD3<Double> {
        switch self {
        case .top: SIMD3(0, 0, -1)
        case .bottom: SIMD3(0, 0, 1)
        case .front: SIMD3(0, 1, 0)
        case .back: SIMD3(0, -1, 0)
        case .right: SIMD3(-1, 0, 0)
        case .left: SIMD3(1, 0, 0)
        case .diagonal: simd_normalize(SIMD3(-1, 1, -1))
        }
    }

    /// Unit up reference, in world coordinates.
    public var up: SIMD3<Double> {
        switch self {
        case .top: SIMD3(0, 1, 0)
        case .bottom: SIMD3(0, -1, 0)
        default: SIMD3(0, 0, 1)
        }
    }
}

/// Continuous navigation velocity, such as a 3D mouse reports.
///
/// Both vectors use view axes: x to the right, y up and z toward the viewer.
/// `translation` moves the model across the view and toward the viewer;
/// `rotation` turns it right-handed about those axes through the orbit center.
/// Components are about -1...1 at full deflection, before any speed scaling.
public struct ViewportMotion: Equatable, Sendable {
    public var translation: SIMD3<Double>
    public var rotation: SIMD3<Double>

    public init(translation: SIMD3<Double> = .zero, rotation: SIMD3<Double> = .zero) {
        self.translation = translation
        self.rotation = rotation
    }

    public static let zero = ViewportMotion()

    public var isZero: Bool { translation == .zero && rotation == .zero }

    var isFinite: Bool {
        (0..<3).allSatisfy { translation[$0].isFinite && rotation[$0].isFinite }
    }
}

/// Orbit camera state in double-precision world coordinates.
///
/// The camera looks at `center` from `distance` along `-forward`, with `up`
/// selecting the screen-up direction. All view, pan and zoom math goes
/// through `screenUp`, the perpendicular projection of `up`, so the effective
/// basis always stays orthonormal even for non-orthogonal spec vectors.
/// `viewWidth` is the orthographic view width in model units. World space is
/// right-handed with +Z up, matching the worker wire contract.
public struct ViewportCamera: Equatable, Sendable {
    /// Look-at target and orbit/pan pivot, in world coordinates.
    public var center: SIMD3<Double> = .zero
    /// Unit direction the camera looks along, in world coordinates.
    public var forward: SIMD3<Double> = ViewportStandardView.diagonal.forward
    /// Screen-up reference in world coordinates. The effective screen up,
    /// `screenUp`, is this projected perpendicular to `forward`; the two
    /// differ for views like `.diagonal` whose spec up vector is not
    /// perpendicular to the eye direction.
    public var up: SIMD3<Double> = SIMD3(0, 0, 1)
    /// Eye-to-target distance in model units. Also positions the eye in
    /// orthographic mode so near/far planes bracket the scene.
    public var distance: Double = 50
    /// Full orthographic view width in model units; kept current in
    /// perspective mode so toggling projection preserves the framing.
    public var viewWidth: Double = 50

    public init() {}

    /// Camera position in world coordinates.
    public var eye: SIMD3<Double> { center - forward * distance }

    /// Unit screen-right direction, in world coordinates.
    public var right: SIMD3<Double> { simd_normalize(simd_cross(forward, screenUp)) }

    /// `up` projected perpendicular to `forward`, or a sensible replacement
    /// when `up` is degenerate or parallel to `forward`. View, pan and zoom
    /// math always uses this so a non-orthogonal `up` assigned from outside
    /// cannot shear the basis.
    public var screenUp: SIMD3<Double> {
        let f = simd_normalize(forward)
        let lateral = up - f * simd_dot(f, up)
        if simd_length(lateral) > 1e-9 { return simd_normalize(lateral) }
        let zUp = SIMD3<Double>(0, 0, 1)
        let candidate = zUp - f * simd_dot(f, zUp)
        return simd_length(candidate) > 1e-9 ? simd_normalize(candidate) : SIMD3(0, 1, 0)
    }

    /// Re-orthonormalizes `up` against `forward` after a rotation.
    private mutating func orthonormalize() {
        forward = simd_normalize(forward)
        let lateral = up - forward * simd_dot(forward, up)
        up = simd_length(lateral) > 1e-12 ? simd_normalize(lateral) : screenUp
    }

    /// Rotates the camera about `center`. `yaw` turns `forward` around world
    /// +Z; `pitch` turns `forward` and `up` around the current view-right axis.
    /// Both are in radians. The basis is re-orthonormalized so long orbit
    /// chains do not accumulate roll or scale drift.
    public mutating func orbit(yaw: Double, pitch: Double) {
        guard yaw != 0 || pitch != 0 else { return }
        var f = forward, u = screenUp
        if yaw != 0 {
            let q = simd_quaternion(yaw, SIMD3<Double>(0, 0, 1))
            f = q.act(f)
            u = q.act(u)
        }
        if pitch != 0 {
            let axis = simd_normalize(simd_cross(f, u))
            let q = simd_quaternion(pitch, axis)
            f = q.act(f)
            u = q.act(u)
        }
        forward = f
        up = u
        orthonormalize()
    }

    /// Applies a drag in view points: `yaw`/`pitch` scale so that dragging
    /// across one viewport height turns the camera a full revolution.
    public mutating func orbitByDrag(deltaX: Double, deltaY: Double, viewSize: CGSize) {
        let scale = 2 * .pi / max(viewSize.height, 1)
        // Dragging right reveals the model's left side; dragging down tilts the
        // camera over the top of the model.
        orbit(yaw: -deltaX * scale, pitch: -deltaY * scale)
    }

    /// Translates `center` in the view plane so the scene follows the cursor.
    /// `delta` is the drag in view points; the scene moves with it.
    public mutating func panByScreenDelta(_ delta: SIMD2<Double>, transform: ViewportTransform) {
        let scale = transform.worldPerPoint
        center += (right * (-delta.x) + screenUp * delta.y) * scale
    }

    /// Scales `distance` and `viewWidth` by `1 / factor` (factor > 1 zooms in).
    /// When `anchor` is non-nil, `center` shifts afterward so the world point
    /// on the view plane through the cursor stays under the cursor.
    public mutating func zoom(factor: Double, anchoredAt anchor: CGPoint?,
                            transform: (ViewportCamera) -> ViewportTransform) {
        let clamped = min(max(factor, 0.01), 100)
        let before = anchor.flatMap { transform(self).worldPointOnFocusPlane(throughViewPoint: $0) }
        distance = max(distance / clamped, 1e-4)
        viewWidth = max(viewWidth / clamped, 1e-4)
        if let before, let anchor,
           let after = transform(self).worldPointOnFocusPlane(throughViewPoint: anchor) {
            center += before - after
        }
    }

    /// Full-deflection rotation speed of continuous navigation, in radians a second.
    public static let navigationRotationRate = 2.0
    /// Full-deflection pan speed of continuous navigation, in view heights a second.
    public static let navigationPanRate = 1.0
    /// Full-deflection zoom speed of continuous navigation: the view scales by
    /// `exp(rate)` a second.
    public static let navigationZoomRate = 1.2
    /// The longest time one navigation step covers, so a stalled frame cannot jump the view.
    public static let maximumNavigationStep = 0.1

    /// Advances continuous navigation, such as from a 3D mouse, by `seconds`.
    ///
    /// The model follows `motion`: it turns about `center` around the view axes
    /// and slides across the view plane, and moving it toward the viewer zooms
    /// in. The camera makes the opposite move. Pan speed scales with the visible
    /// height at the focus plane, from `transform`, so it feels the same at any
    /// zoom.
    public mutating func navigate(_ motion: ViewportMotion, seconds: Double, transform: ViewportTransform) {
        let step = min(max(seconds, 0), Self.maximumNavigationStep)
        guard step > 0, motion.isFinite, !motion.isZero else { return }
        let right = self.right, screenUp = self.screenUp, back = -simd_normalize(forward)

        let turn = motion.rotation * Self.navigationRotationRate * step
        let angle = simd_length(turn)
        if angle > 0 {
            let axis = simd_normalize(right * turn.x + screenUp * turn.y + back * turn.z)
            let inverse = simd_quaternion(-angle, axis)
            forward = inverse.act(forward)
            up = inverse.act(screenUp)
            orthonormalize()
        }

        let viewHeight = transform.worldPerPoint * Double(transform.viewSize.height)
        let slide = motion.translation * Self.navigationPanRate * viewHeight * step
        center -= right * slide.x + screenUp * slide.y

        if motion.translation.z != 0 {
            zoom(factor: exp(motion.translation.z * Self.navigationZoomRate * step), anchoredAt: nil) { _ in transform }
        }
    }

    /// Aims the camera along the standard view's eye direction and up vector.
    /// `center`, `distance` and `viewWidth` are preserved.
    public mutating func setStandardView(_ view: ViewportStandardView) {
        forward = view.forward
        up = view.up
    }

    /// Centers `bounds` and sets `distance`/`viewWidth` so its enclosing
    /// sphere fits the view with a 10% margin, for the current projection.
    public mutating func frameAll(_ bounds: ViewportBounds, aspect: Double) {
        let radius = max(bounds.radius, 1e-3)
        center = bounds.center
        let halfVertical = ViewportTransform.fieldOfViewYRadians / 2
        let halfHorizontal = atan(tan(halfVertical) * max(aspect, 1e-6))
        distance = radius / sin(min(halfVertical, halfHorizontal)) * 1.1
        viewWidth = 2 * radius * max(aspect, 1) * 1.1
    }
}
