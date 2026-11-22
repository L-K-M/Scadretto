import simd
import CoreGraphics

/// A world-space ray for future picking, per the viewport contract in
/// plan/04-macOS-Editor.md.
public struct ViewportRay: Equatable, Sendable {
    public var origin: SIMD3<Double>
    public var direction: SIMD3<Double>

    public init(origin: SIMD3<Double>, direction: SIMD3<Double>) {
        self.origin = origin
        self.direction = direction
    }
}

/// The view/projection mapping of one presented frame.
///
/// GPU vertices and the eye/center are rebased by `renderOrigin` before the
/// double-precision matrices are applied, so geometry far from the world
/// origin (for example a cube at x = 100000000) keeps full float32 precision
/// per the render-origin rule in plan/03-OpenSCAD-Worker.md. `project` and
/// `ray` take and return *world* coordinates; `gpuViewProjection` consumes
/// render-space float3 vertices.
///
/// View points use the view's coordinate space: `ViewportView` is flipped, so
/// the origin is the top-left corner and y grows downward, matching Metal's
/// viewport convention. The conversion between AppKit and Metal coordinates
/// happens exactly once, here.
public struct ViewportTransform: Sendable {
    /// Double-precision render origin subtracted from world positions before
    /// float conversion. Camera matrices are built in the same rebased frame.
    public var renderOrigin: SIMD3<Double>
    /// World-to-view matrix in the rebased render frame (double).
    public var view: simd_double4x4
    /// View-to-clip matrix for Metal's clip space (z in [0, 1]).
    public var projection: simd_double4x4
    /// Projection x view, render space.
    public var viewProjection: simd_double4x4
    /// Inverse of `viewProjection`, for unprojecting view points.
    public var inverseViewProjection: simd_double4x4
    /// View size in points (not drawable pixels).
    public var viewSize: CGSize
    /// World units per view point on the plane through the camera center,
    /// for pan and scroll-speed math.
    public var worldPerPoint: Double
    /// Camera state this transform was built from (world coordinates).
    public var camera: ViewportCamera
    /// Whether the projection is orthographic.
    public var isOrthographic: Bool

    /// Vertical field of view for the perspective projection, in radians.
    public static let fieldOfViewYRadians = 30.0 * .pi / 180.0

    /// The float matrix handed to the vertex shader. Render-space vertices
    /// keep full float32 precision because the large world translation was
    /// already removed by `renderOrigin`.
    public var gpuViewProjection: simd_float4x4 {
        func column(_ c: SIMD4<Double>) -> SIMD4<Float> {
            SIMD4<Float>(Float(c.x), Float(c.y), Float(c.z), Float(c.w))
        }
        return simd_float4x4(columns: (
            column(viewProjection.columns.0), column(viewProjection.columns.1),
            column(viewProjection.columns.2), column(viewProjection.columns.3)
        ))
    }

    /// Projects a world point into view points. Returns `nil` when the point
    /// is behind the eye. The returned z is Metal depth in [0, 1].
    public func project(_ world: SIMD3<Double>) -> SIMD3<Double>? {
        let clip = viewProjection * simd_double4(world - renderOrigin, 1)
        guard clip.w > 0 else { return nil }
        let ndc = SIMD3<Double>(clip.x, clip.y, clip.z) / clip.w
        return SIMD3(
            (ndc.x + 1) / 2 * viewSize.width,
            (1 - ndc.y) / 2 * viewSize.height,
            ndc.z
        )
    }

    /// Unprojects a view point and depth back into world coordinates.
    public func worldPoint(atViewPoint point: CGPoint, depth: Double) -> SIMD3<Double> {
        let ndc = SIMD3<Double>(
            point.x / viewSize.width * 2 - 1,
            1 - point.y / viewSize.height * 2,
            depth
        )
        let clip = inverseViewProjection * simd_double4(ndc, 1)
        return SIMD3<Double>(clip.x, clip.y, clip.z) / clip.w + renderOrigin
    }

    /// The world-space ray through a view point: origin on the near plane for
    /// orthographic projections, at the eye for perspective.
    public func ray(throughViewPoint point: CGPoint) -> ViewportRay {
        let forward = simd_normalize(camera.forward)
        if isOrthographic {
            return ViewportRay(origin: worldPoint(atViewPoint: point, depth: 0), direction: forward)
        }
        // Form the eye-space direction directly from the projection scale.
        // Subtracting unprojected world points loses precision far from zero.
        let x = (2 * point.x / viewSize.width - 1) / projection.columns.0.x
        let y = (1 - 2 * point.y / viewSize.height) / projection.columns.1.y
        let direction = forward + x * camera.right + y * camera.screenUp
        return ViewportRay(origin: camera.eye, direction: simd_normalize(direction))
    }

    /// Intersects the view ray through `point` with the plane through the
    /// camera center perpendicular to `forward`. This is the "model point
    /// under the cursor" anchor used by zoom-to-cursor and future picking.
    public func worldPointOnFocusPlane(throughViewPoint point: CGPoint) -> SIMD3<Double>? {
        let r = ray(throughViewPoint: point)
        let denominator = simd_dot(r.direction, camera.forward)
        guard abs(denominator) > 1e-9 else { return nil }
        let t = simd_dot(camera.center - r.origin, camera.forward) / denominator
        guard t > 0 else { return nil }
        return r.origin + r.direction * t
    }
}

extension ViewportCamera {
    /// Builds the frame transform for a view of `viewSize` points.
    ///
    /// `renderOrigin` must equal the origin subtracted from the GPU vertex
    /// buffer, and `sceneRadius` bounds the rendered scene for near/far
    /// placement; both come from the same mesh upload that filled the buffer.
    public func transform(viewSize: CGSize, orthographic: Bool, renderOrigin: SIMD3<Double>,
                          sceneRadius: Double) -> ViewportTransform {
        let aspect = max(viewSize.width / max(viewSize.height, 1), 1e-6)
        let radius = max(sceneRadius, 1e-3)
        let near = max(distance - 4 * radius, distance * 1e-4, 1e-3)
        let far = distance + 4 * radius

        let eye = self.eye - renderOrigin
        let up = screenUp
        let right = simd_normalize(simd_cross(forward, up))
        let view = Self.viewMatrix(eye: eye, right: right, up: up, forward: simd_normalize(forward))

        let projection: simd_double4x4
        let worldPerPoint: Double
        if orthographic {
            let width = viewWidth
            let height = width / aspect
            projection = Self.orthographicMatrix(width: width, height: height, near: near, far: far)
            worldPerPoint = height / max(viewSize.height, 1)
        } else {
            projection = Self.perspectiveMatrix(
                fovY: ViewportTransform.fieldOfViewYRadians, aspect: aspect, near: near, far: far)
            worldPerPoint = 2 * distance * tan(ViewportTransform.fieldOfViewYRadians / 2)
                / max(viewSize.height, 1)
        }
        let viewProjection = projection * view
        return ViewportTransform(
            renderOrigin: renderOrigin,
            view: view,
            projection: projection,
            viewProjection: viewProjection,
            inverseViewProjection: simd_inverse(viewProjection),
            viewSize: viewSize,
            worldPerPoint: worldPerPoint,
            camera: self,
            isOrthographic: orthographic
        )
    }

    /// World-to-view for a camera at `eye` looking along `forward` with screen
    /// right/up `right`/`up`. Column-major, column vectors: p_view = V * p.
    private static func viewMatrix(eye: SIMD3<Double>, right: SIMD3<Double>,
                                   up: SIMD3<Double>, forward: SIMD3<Double>) -> simd_double4x4 {
        simd_double4x4(columns: (
            SIMD4(right.x, up.x, -forward.x, 0),
            SIMD4(right.y, up.y, -forward.y, 0),
            SIMD4(right.z, up.z, -forward.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1)
        ))
    }

    /// Perspective projection for Metal clip space: right-handed view space
    /// looking down -Z, NDC z in [0, 1].
    private static func perspectiveMatrix(fovY: Double, aspect: Double,
                                          near: Double, far: Double) -> simd_double4x4 {
        let f = 1 / tan(fovY / 2)
        return simd_double4x4(columns: (
            SIMD4(f / aspect, 0, 0, 0),
            SIMD4(0, f, 0, 0),
            SIMD4(0, 0, far / (near - far), -1),
            SIMD4(0, 0, far * near / (near - far), 0)
        ))
    }

    /// Orthographic projection for Metal clip space, `width` x `height` in
    /// model units, NDC z in [0, 1].
    private static func orthographicMatrix(width: Double, height: Double,
                                           near: Double, far: Double) -> simd_double4x4 {
        simd_double4x4(columns: (
            SIMD4(2 / width, 0, 0, 0),
            SIMD4(0, 2 / height, 0, 0),
            SIMD4(0, 0, 1 / (near - far), 0),
            SIMD4(0, 0, near / (near - far), 1)
        ))
    }
}
