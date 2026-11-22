import XCTest
import simd
@testable import ScadrettoViewport

/// Math tests for the M2 viewport: render-origin rebasing at x = 100000000,
/// camera framing, standard views, pan/zoom anchoring and the view-projection
/// mapping future picking depends on. All pure CPU; no GPU is created.
final class ViewportMathTests: XCTestCase {
    private let viewSize = CGSize(width: 800, height: 600)

    /// Closed unit cube with outward-facing CCW triangles.
    private func cube(at origin: SIMD3<Double>, size: Double = 1) -> ViewportMesh {
        let h = size / 2
        let positions: [SIMD3<Double>] = [
            origin + SIMD3(-h, -h, -h), origin + SIMD3(h, -h, -h),
            origin + SIMD3(-h, h, -h), origin + SIMD3(h, h, -h),
            origin + SIMD3(-h, -h, h), origin + SIMD3(h, -h, h),
            origin + SIMD3(-h, h, h), origin + SIMD3(h, h, h),
        ]
        let indices: [UInt32] = [
            1, 3, 7, 1, 7, 5,   // +X
            0, 6, 2, 0, 4, 6,   // -X
            2, 6, 7, 2, 7, 3,   // +Y
            0, 5, 4, 0, 1, 5,   // -Y
            4, 5, 7, 4, 7, 6,   // +Z
            0, 2, 1, 0, 3, 1,   // -Z
        ]
        return ViewportMesh(positions: positions, indices: indices)
    }

    private func transform(for camera: ViewportCamera, upload: ViewportMeshUpload,
                           orthographic: Bool = false) -> ViewportTransform {
        camera.transform(
            viewSize: viewSize,
            orthographic: orthographic,
            renderOrigin: upload.renderOrigin,
            sceneRadius: upload.sceneRadius
        )
    }

    // MARK: Render origin and precision (plan/03 round-trip requirement)

    func testRebaseKeepsUnitWidthAtHundredMillion() {
        let mesh = cube(at: SIMD3(100000000.5, 0, 0))
        let bounds = mesh.bounds
        // Double-precision bounds stay distinct at 1e8.
        XCTAssertEqual(bounds?.min.x, 100000000.0)
        XCTAssertEqual(bounds?.max.x, 100000001.0)

        let upload = ViewportMeshUpload(mesh: mesh)
        XCTAssertEqual(upload.renderOrigin.x, 100000000.5, accuracy: 1e-9)
        // Float vertices retain exactly unit width after rebasing.
        let xs = upload.vertexData.map(\.x)
        XCTAssertEqual(xs.max()! - xs.min()!, 1, accuracy: 1e-6)
    }

    func testGpuAndDoubleProjectionAgreeAtHundredMillion() {
        let mesh = cube(at: SIMD3(100000000.5, 0.25, -0.5))
        let upload = ViewportMeshUpload(mesh: mesh)
        var camera = ViewportCamera()
        camera.frameAll(mesh.bounds!, aspect: 800 / 600)
        let transform = transform(for: camera, upload: upload)

        // The float GPU matrix must produce the same view point as the double
        // path, proving camera and vertices share the render origin.
        for position in mesh.positions {
            guard let expected = transform.project(position) else {
                return XCTFail("corner behind camera")
            }
            let rebased = SIMD3<Float>(position - upload.renderOrigin)
            let clip = transform.gpuViewProjection * simd_float4(rebased, 1)
            let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
            let actual = CGPoint(x: Double((ndc.x + 1) / 2) * viewSize.width,
                                 y: Double((1 - ndc.y) / 2) * viewSize.height)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.05)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.05)
        }
    }

    func testRayHitOnFarCubeMatchesSpikeCase() {
        // plan/03: a ray from (100000002, 0.5, 0.5) along -X meets the
        // x = 100000001 wall. The viewport equivalent: project that wall's
        // center, ray back through it, and land within millimeters.
        let mesh = cube(at: SIMD3(100000000.5, 0.5, 0.5))
        let upload = ViewportMeshUpload(mesh: mesh)
        var camera = ViewportCamera()
        camera.setStandardView(.right) // looks along -X
        camera.frameAll(mesh.bounds!, aspect: 800 / 600)
        let transform = transform(for: camera, upload: upload)

        let wall = SIMD3<Double>(100000001, 0.5, 0.5)
        guard let point = transform.project(wall) else {
            return XCTFail("wall not on screen")
        }
        let ray = transform.ray(throughViewPoint: CGPoint(x: point.x, y: point.y))
        let t = simd_dot(wall - ray.origin, ray.direction)
        let hit = ray.origin + ray.direction * t
        XCTAssertEqual(hit.x, wall.x, accuracy: 1e-6)
        XCTAssertEqual(hit.y, wall.y, accuracy: 1e-6)
        XCTAssertEqual(hit.z, wall.z, accuracy: 1e-6)
    }

    // MARK: Framing

    func testFrameAllFitsEveryCorner() {
        let mesh = cube(at: SIMD3(12, -40, 300), size: 30)
        let upload = ViewportMeshUpload(mesh: mesh)
        var camera = ViewportCamera()
        camera.frameAll(mesh.bounds!, aspect: 800 / 600)
        XCTAssertEqual(camera.center, mesh.bounds!.center)

        for ortho in [false, true] {
            let transform = transform(for: camera, upload: upload, orthographic: ortho)
            for position in mesh.positions {
                guard let point = transform.project(position) else {
                    return XCTFail("corner behind camera")
                }
                XCTAssertGreaterThanOrEqual(point.x, 0)
                XCTAssertLessThanOrEqual(point.x, viewSize.width)
                XCTAssertGreaterThanOrEqual(point.y, 0)
                XCTAssertLessThanOrEqual(point.y, viewSize.height)
            }
        }
    }

    // MARK: Standard views

    func testStandardViewDirections() {
        var camera = ViewportCamera()
        let cases: [(ViewportStandardView, SIMD3<Double>, SIMD3<Double>)] = [
            (.top, SIMD3(0, 0, -1), SIMD3(0, 1, 0)),
            (.bottom, SIMD3(0, 0, 1), SIMD3(0, -1, 0)),
            (.front, SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
            (.back, SIMD3(0, -1, 0), SIMD3(0, 0, 1)),
            (.right, SIMD3(-1, 0, 0), SIMD3(0, 0, 1)),
            (.left, SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
        ]
        for (view, forward, up) in cases {
            camera.setStandardView(view)
            XCTAssertEqual(camera.forward.x, forward.x, accuracy: 1e-12, "\(view)")
            XCTAssertEqual(camera.forward.y, forward.y, accuracy: 1e-12, "\(view)")
            XCTAssertEqual(camera.forward.z, forward.z, accuracy: 1e-12, "\(view)")
            XCTAssertEqual(camera.up.x, up.x, accuracy: 1e-12, "\(view)")
            XCTAssertEqual(camera.up.y, up.y, accuracy: 1e-12, "\(view)")
            XCTAssertEqual(camera.up.z, up.z, accuracy: 1e-12, "\(view)")
        }
        camera.setStandardView(.diagonal)
        let expectedForward = simd_normalize(SIMD3<Double>(-1, 1, -1))
        XCTAssertEqual(camera.forward.x, expectedForward.x, accuracy: 1e-12)
        XCTAssertEqual(camera.forward.y, expectedForward.y, accuracy: 1e-12)
        XCTAssertEqual(camera.forward.z, expectedForward.z, accuracy: 1e-12)
        XCTAssertEqual(camera.up.x, 0, accuracy: 1e-12)
        XCTAssertEqual(camera.up.y, 0, accuracy: 1e-12)
        XCTAssertEqual(camera.up.z, 1, accuracy: 1e-12)
    }

    // MARK: Orbit

    func testOrbitStaysOrthonormalAndWraps() {
        var camera = ViewportCamera()
        camera.setStandardView(.front)
        camera.orbit(yaw: .pi, pitch: 0)
        XCTAssertEqual(camera.forward.x, 0, accuracy: 1e-12)
        XCTAssertEqual(camera.forward.y, -1, accuracy: 1e-12)

        for _ in 0..<40 {
            camera.orbit(yaw: .pi / 20, pitch: .pi / 40)
        }
        XCTAssertEqual(simd_length(camera.forward), 1, accuracy: 1e-12)
        XCTAssertEqual(simd_length(camera.up), 1, accuracy: 1e-12)
        XCTAssertEqual(simd_dot(camera.forward, camera.up), 0, accuracy: 1e-12)

        camera.setStandardView(.front)
        camera.orbit(yaw: 2 * .pi, pitch: 0)
        XCTAssertEqual(camera.forward.x, 0, accuracy: 1e-9)
        XCTAssertEqual(camera.forward.y, 1, accuracy: 1e-9)
    }

    // MARK: Pan

    func testPanMovesSceneWithCursor() {
        let mesh = cube(at: .zero, size: 10)
        let upload = ViewportMeshUpload(mesh: mesh)
        var camera = ViewportCamera()
        camera.setStandardView(.front)
        camera.frameAll(mesh.bounds!, aspect: 800 / 600)

        let before = transform(for: camera, upload: upload, orthographic: true)
        let oldCenter = camera.center
        camera.panByScreenDelta(SIMD2(10, 5), transform: before)
        let after = transform(for: camera, upload: upload, orthographic: true)

        // The world point that was at view center moves with the drag.
        guard let moved = after.project(oldCenter) else {
            return XCTFail("old center behind camera")
        }
        XCTAssertEqual(moved.x, 400 + 10, accuracy: 1e-6)
        XCTAssertEqual(moved.y, 300 + 5, accuracy: 1e-6)
    }

    // MARK: Anchored zoom

    func testZoomKeepsCursorAnchor() {
        let mesh = cube(at: SIMD3(3, -2, 7), size: 12)
        let upload = ViewportMeshUpload(mesh: mesh)
        let anchor = CGPoint(x: 220, y: 140)

        for ortho in [false, true] {
            var camera = ViewportCamera()
            camera.setStandardView(.diagonal)
            camera.frameAll(mesh.bounds!, aspect: 800 / 600)
            let factory: (ViewportCamera) -> ViewportTransform = {
                self.transform(for: $0, upload: upload, orthographic: ortho)
            }
            guard let before = factory(camera).worldPointOnFocusPlane(throughViewPoint: anchor) else {
                return XCTFail("no focus-plane point")
            }
            camera.zoom(factor: 1.5, anchoredAt: anchor, transform: factory)
            guard let after = factory(camera).worldPointOnFocusPlane(throughViewPoint: anchor) else {
                return XCTFail("no focus-plane point after zoom")
            }
            XCTAssertEqual(after.x, before.x, accuracy: 1e-6, ortho ? "ortho" : "perspective")
            XCTAssertEqual(after.y, before.y, accuracy: 1e-6, ortho ? "ortho" : "perspective")
            XCTAssertEqual(after.z, before.z, accuracy: 1e-6, ortho ? "ortho" : "perspective")
        }
    }

    // MARK: Projection round-trip

    func testProjectUnprojectRoundTrip() {
        let mesh = cube(at: SIMD3(-9, 4, 2), size: 8)
        let upload = ViewportMeshUpload(mesh: mesh)
        var camera = ViewportCamera()
        camera.setStandardView(.diagonal)
        camera.frameAll(mesh.bounds!, aspect: 800 / 600)
        let transform = transform(for: camera, upload: upload)

        for position in mesh.positions {
            guard let point = transform.project(position) else {
                return XCTFail("corner behind camera")
            }
            let world = transform.worldPoint(atViewPoint: CGPoint(x: point.x, y: point.y),
                                             depth: point.z)
            XCTAssertEqual(world.x, position.x, accuracy: 1e-6)
            XCTAssertEqual(world.y, position.y, accuracy: 1e-6)
            XCTAssertEqual(world.z, position.z, accuracy: 1e-6)
        }
    }

    func testViewCenterRayReachesFocusPlaneAtCenter() {
        let mesh = cube(at: SIMD3(5, 5, 5), size: 4)
        let upload = ViewportMeshUpload(mesh: mesh)
        var camera = ViewportCamera()
        camera.setStandardView(.top)
        camera.frameAll(mesh.bounds!, aspect: 800 / 600)
        let transform = transform(for: camera, upload: upload)

        guard let point = transform.worldPointOnFocusPlane(
            throughViewPoint: CGPoint(x: 400, y: 300)) else {
            return XCTFail("center ray missed the focus plane")
        }
        XCTAssertEqual(point.x, camera.center.x, accuracy: 1e-9)
        XCTAssertEqual(point.y, camera.center.y, accuracy: 1e-9)
        XCTAssertEqual(point.z, camera.center.z, accuracy: 1e-9)
    }

    // MARK: Normals and degenerate input

    func testDerivedNormalsPointOutward() {
        let mesh = cube(at: .zero)
        let upload = ViewportMeshUpload(mesh: mesh)
        // Corner vertex 7 at (+1,+1,+1) gathers the +X/+Y/+Z face normals.
        let vertex = upload.vertexData[7]
        XCTAssertEqual(vertex.a, 1 / Float(3).squareRoot(), accuracy: 1e-5)
        XCTAssertEqual(vertex.b, 1 / Float(3).squareRoot(), accuracy: 1e-5)
        XCTAssertEqual(vertex.c, 1 / Float(3).squareRoot(), accuracy: 1e-5)
    }

    func testEmptyAndDegenerateMeshesAreSafe() {
        let empty = ViewportMeshUpload(mesh: ViewportMesh(positions: [], indices: []))
        XCTAssertNil(empty.bounds)
        XCTAssertEqual(empty.vertexCount, 0)

        // Out-of-range and degenerate indices are skipped, never crash.
        let mesh = ViewportMesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            indices: [0, 1, 2, 0, 0, 0, 0, 9, 2]
        )
        let upload = ViewportMeshUpload(mesh: mesh)
        XCTAssertEqual(upload.vertexCount, 3)
        // The degenerate and out-of-range triples are dropped from the GPU
        // index buffer; the valid triangle is kept.
        XCTAssertEqual(upload.indices, [0, 1, 2])
        XCTAssertEqual(upload.vertexData[0].c, 1, accuracy: 1e-6)

        var camera = ViewportCamera()
        camera.frameAll(mesh.bounds!, aspect: 800 / 600)
        XCTAssertNotNil(transform(for: camera, upload: upload).project(mesh.positions[0]))
    }
}
