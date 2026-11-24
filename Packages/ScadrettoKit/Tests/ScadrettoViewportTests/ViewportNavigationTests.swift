import XCTest
import simd
@testable import ScadrettoViewport

/// Continuous navigation, as a 3D mouse drives it: the model follows the cap,
/// so the camera moves the opposite way about the orbit center.
final class ViewportNavigationTests: XCTestCase {
    private let viewSize = CGSize(width: 800, height: 600)

    private func frontCamera() -> ViewportCamera {
        var camera = ViewportCamera()
        camera.center = SIMD3(10, 20, 30)
        camera.distance = 100
        camera.viewWidth = 80
        camera.setStandardView(.front)
        return camera
    }

    private func navigated(_ camera: ViewportCamera, _ motion: ViewportMotion, seconds: Double,
                           orthographic: Bool = false) -> ViewportCamera {
        var moved = camera
        let transform = camera.transform(viewSize: viewSize, orthographic: orthographic,
                                         renderOrigin: .zero, sceneRadius: 10)
        moved.navigate(motion, seconds: seconds, transform: transform)
        return moved
    }

    private func assertOrthonormal(_ camera: ViewportCamera, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(simd_length(camera.forward), 1, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(simd_length(camera.up), 1, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(simd_dot(camera.forward, camera.up), 0, accuracy: 1e-9, file: file, line: line)
    }

    func testRestLeavesTheCameraAlone() {
        let camera = frontCamera()
        XCTAssertEqual(navigated(camera, .zero, seconds: 0.016), camera)
        XCTAssertEqual(navigated(camera, ViewportMotion(rotation: SIMD3(0, 1, 0)), seconds: 0), camera)
    }

    func testTwistTurnsTheModelLikeTheCap() {
        // Front view: looking along +Y with +Z up, so screen right is +X.
        let camera = frontCamera()
        let moved = navigated(camera, ViewportMotion(rotation: SIMD3(0, 1, 0)), seconds: 0.05)
        let angle = ViewportCamera.navigationRotationRate * 0.05
        // The model turns counterclockwise seen from above, so the camera turns clockwise
        // about the center: it now looks a little toward +X.
        XCTAssertEqual(moved.forward.x, sin(angle), accuracy: 1e-9)
        XCTAssertEqual(moved.forward.y, cos(angle), accuracy: 1e-9)
        XCTAssertEqual(moved.center, camera.center, "Rotation is about the orbit center")
        XCTAssertEqual(moved.distance, camera.distance)
        assertOrthonormal(moved)
    }

    func testTiltAndRollFollowTheCap() {
        let camera = frontCamera()
        // Tilting the cap's top toward the viewer tips the model's top toward the viewer,
        // so the camera looks down on it from a little higher.
        let tilted = navigated(camera, ViewportMotion(rotation: SIMD3(1, 0, 0)), seconds: 0.05)
        XCTAssertLessThan(tilted.forward.z, 0)
        // Rolling counterclockwise turns the model counterclockwise on screen, so the
        // camera's up leans to the right.
        let rolled = navigated(camera, ViewportMotion(rotation: SIMD3(0, 0, 1)), seconds: 0.05)
        XCTAssertGreaterThan(rolled.up.x, 0)
        XCTAssertEqual(rolled.forward.y, 1, accuracy: 1e-9, "Roll keeps the view direction")
        assertOrthonormal(tilted)
        assertOrthonormal(rolled)
    }

    func testPanMovesTheModelWithTheCapAtViewHeightsPerSecond() {
        let camera = frontCamera()
        let transform = camera.transform(viewSize: viewSize, orthographic: false, renderOrigin: .zero, sceneRadius: 10)
        let viewHeight = transform.worldPerPoint * viewSize.height
        let moved = navigated(camera, ViewportMotion(translation: SIMD3(1, 0.5, 0)), seconds: 0.05)
        let step = viewHeight * ViewportCamera.navigationPanRate * 0.05
        // The model moves right and up, so the center moves left (-X) and down (-Z).
        XCTAssertEqual(moved.center.x, camera.center.x - step, accuracy: 1e-9)
        XCTAssertEqual(moved.center.z, camera.center.z - step / 2, accuracy: 1e-9)
        XCTAssertEqual(moved.center.y, camera.center.y, accuracy: 1e-9)
        XCTAssertEqual(moved.forward, camera.forward)
    }

    func testPullingTheCapBringsTheModelCloser() {
        let camera = frontCamera()
        let factor = exp(ViewportCamera.navigationZoomRate * 0.05)
        let closer = navigated(camera, ViewportMotion(translation: SIMD3(0, 0, 1)), seconds: 0.05)
        XCTAssertEqual(closer.distance, camera.distance / factor, accuracy: 1e-9)
        XCTAssertEqual(closer.viewWidth, camera.viewWidth / factor, accuracy: 1e-9)
        XCTAssertEqual(closer.center, camera.center, "Zoom is about the orbit center")

        let farther = navigated(camera, ViewportMotion(translation: SIMD3(0, 0, -1)), seconds: 0.05,
                                orthographic: true)
        XCTAssertEqual(farther.viewWidth, camera.viewWidth * factor, accuracy: 1e-9)
    }

    func testALongFrameGapMovesOneBoundedStep() {
        let camera = frontCamera()
        let motion = ViewportMotion(translation: SIMD3(0.3, 0, 0.2), rotation: SIMD3(0.4, -0.7, 0.1))
        XCTAssertEqual(navigated(camera, motion, seconds: 5),
                       navigated(camera, motion, seconds: ViewportCamera.maximumNavigationStep),
                       "A stalled frame must not jump the view")
    }

    func testLongNavigationKeepsTheBasisOrthonormal() {
        var camera = frontCamera()
        let motion = ViewportMotion(rotation: SIMD3(0.3, -0.8, 0.5))
        for _ in 0..<5_000 {
            camera = navigated(camera, motion, seconds: 1.0 / 120)
        }
        assertOrthonormal(camera)
        XCTAssertEqual(camera.distance, 100, accuracy: 1e-9)
    }
}
