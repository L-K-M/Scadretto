import XCTest
import simd
@testable import ScadrettoViewport

/// Math tests for the M4 linear handle: the pitch rule from
/// plan/02-Source-and-Edits.md (`newPitch = oldPitch + localDx / i`),
/// rotated, mirrored and nonuniform parent frames, the centered-resize
/// factor, both projections, degenerate axes and snapping. All pure CPU;
/// no GPU is created.
final class ViewportLinearHandleTests: XCTestCase {
    private let viewSize = CGSize(width: 800, height: 600)

    /// Column-major affine: columns are the images of the basis vectors plus
    /// a translation, matching the worker's world-matrix convention.
    private func linear(_ c0: SIMD3<Double>, _ c1: SIMD3<Double>, _ c2: SIMD3<Double>,
                        translation: SIMD3<Double> = .zero) -> simd_double4x4 {
        simd_double4x4(columns: (SIMD4(c0, 0), SIMD4(c1, 0), SIMD4(c2, 0), SIMD4(translation, 1)))
    }

    private func transform(lookingAt center: SIMD3<Double>,
                           view: ViewportStandardView = .diagonal,
                           orthographic: Bool = false) -> ViewportTransform {
        var camera = ViewportCamera()
        camera.setStandardView(view)
        camera.center = center
        return camera.transform(viewSize: viewSize, orthographic: orthographic,
                                renderOrigin: .zero, sceneRadius: 50)
    }

    /// Projects `world` and reads the handle coordinate at that view point,
    /// as a drag event would. `nil` when the point or the projection fails.
    private func coordinate(of world: SIMD3<Double>, on handle: ViewportLinearHandle,
                            in transform: ViewportTransform) -> Double? {
        transform.project(world).flatMap {
            handle.coordinate(at: CGPoint(x: $0.x, y: $0.y), in: transform)
        }
    }

    private func xyz(_ v: SIMD4<Double>) -> SIMD3<Double> { SIMD3(v.x, v.y, v.z) }

    // MARK: Pitch (plan/02: newPitch = oldPitch + localDx / i)

    func testPitchDragLocalFourBecomesPitchTwoAtIterationTwo() throws {
        // Canonical fixture, third cutter (i = 2) at X = 15 + 2 * 20 = 55.
        // Walkthrough step 6: a +4 local drag moves it to 59 and writes
        // pitch = 22.
        let handle = ViewportLinearHandle(anchor: SIMD3(55, 20, 3), axis: SIMD3(1, 0, 0),
                                          value: 20, valuePerUnit: 0.5)
        let transform = transform(lookingAt: SIMD3(55, 20, 3))

        let start = try XCTUnwrap(coordinate(of: SIMD3(55, 20, 3), on: handle, in: transform))
        XCTAssertEqual(start, 0, accuracy: 1e-10)
        let end = try XCTUnwrap(coordinate(of: SIMD3(59, 20, 3), on: handle, in: transform))
        XCTAssertEqual(end - start, 4, accuracy: 1e-10)
        XCTAssertEqual(handle.value(from: start, to: end, snap: 0), 22)
        // The grip follows the occurrence: pitch 22 puts i = 2 at X = 59.
        XCTAssertEqual(simd_distance(handle.point(for: 22), SIMD3(59, 20, 3)), 0, accuracy: 1e-12)
        XCTAssertNil(handle.value(from: start, to: start, snap: 0))
    }

    func testDragMeasuresDeltaFromMouseDownNotAnchor() throws {
        // A press inside the hit radius need not land exactly on the grip;
        // only the coordinate delta over the gesture matters.
        let handle = ViewportLinearHandle(anchor: SIMD3(55, 20, 3), axis: SIMD3(1, 0, 0),
                                          value: 20, valuePerUnit: 0.5)
        let transform = transform(lookingAt: SIMD3(55, 20, 3))

        let start = try XCTUnwrap(coordinate(of: SIMD3(55.5, 20, 3), on: handle, in: transform))
        XCTAssertEqual(start, 0.5, accuracy: 1e-10)
        let end = try XCTUnwrap(coordinate(of: SIMD3(59.5, 20, 3), on: handle, in: transform))
        XCTAssertEqual(handle.value(from: start, to: end, snap: 0), 22)
    }

    // MARK: Parent frames

    func testRotatedParentMapsWorldDragOntoLocalAxis() throws {
        // rotate([0,0,90]) maps authored +X onto world +Y. Acceptance case:
        // dragging +2 along world Y moves local X 10 → 12.
        let rotation = linear(SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1))
        let anchor = xyz(rotation * SIMD4(10, 0, 0, 1))
        let axis = xyz(rotation * SIMD4(1, 0, 0, 0))
        XCTAssertEqual(axis, SIMD3(0, 1, 0))
        let handle = ViewportLinearHandle(anchor: anchor, axis: axis, value: 10, valuePerUnit: 1)
        let transform = transform(lookingAt: anchor)

        let start = try XCTUnwrap(coordinate(of: anchor, on: handle, in: transform))
        let end = try XCTUnwrap(coordinate(of: anchor + 2 * axis, on: handle, in: transform))
        XCTAssertEqual(handle.value(from: start, to: end, snap: 0), 12)
        XCTAssertEqual(simd_distance(handle.point(for: 12), SIMD3(0, 12, 0)), 0, accuracy: 1e-12)
    }

    func testMirroredParentKeepsPositiveLocalUnits() throws {
        // scale([-1,1,1]): authored +X travels world -X. Dragging toward -X
        // still reads as positive local units.
        let mirror = linear(SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        let anchor = xyz(mirror * SIMD4(10, 0, 0, 1))
        let axis = xyz(mirror * SIMD4(1, 0, 0, 0))
        XCTAssertEqual(axis, SIMD3(-1, 0, 0))
        let handle = ViewportLinearHandle(anchor: anchor, axis: axis, value: 10, valuePerUnit: 1)
        let transform = transform(lookingAt: anchor)

        let start = try XCTUnwrap(coordinate(of: anchor, on: handle, in: transform))
        let end = try XCTUnwrap(coordinate(of: anchor + 3 * axis, on: handle, in: transform))
        XCTAssertEqual(end - start, 3, accuracy: 1e-10)
        XCTAssertEqual(handle.value(from: start, to: end, snap: 0), 13)
    }

    func testComposedFrameMeasuresAuthoredUnits() throws {
        // translate([4,-2,7]) rotate([0,0,90]) scale([-2,1,3]): rotation,
        // mirroring and nonuniform scale together. One authored +X unit
        // spans two world units toward -Y.
        let frame = linear(SIMD3(0, -2, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 3),
                           translation: SIMD3(4, -2, 7))
        let anchor = xyz(frame * SIMD4(10, 0, 0, 1))
        let axis = xyz(frame * SIMD4(1, 0, 0, 0))
        XCTAssertEqual(axis, SIMD3(0, -2, 0))
        let handle = ViewportLinearHandle(anchor: anchor, axis: axis, value: 10, valuePerUnit: 1)
        let transform = transform(lookingAt: anchor)

        let start = try XCTUnwrap(coordinate(of: anchor, on: handle, in: transform))
        let end = try XCTUnwrap(coordinate(of: anchor + 3 * axis, on: handle, in: transform))
        XCTAssertEqual(end - start, 3, accuracy: 1e-10)
        XCTAssertEqual(handle.value(from: start, to: end, snap: 0), 13)
        XCTAssertEqual(simd_distance(handle.point(for: 13), anchor + 3 * axis), 0, accuracy: 1e-12)
    }

    // MARK: Dimension factors

    func testCenteredResizeChangesDimensionByTwiceLocalTravel() throws {
        // Symmetric resize about the center of a 10-wide cube: the +X face
        // travels u while the dimension grows 2u.
        let handle = ViewportLinearHandle(anchor: SIMD3(5, 0, 0), axis: SIMD3(1, 0, 0),
                                          value: 10, valuePerUnit: 2)
        let transform = transform(lookingAt: SIMD3(5, 0, 0))

        let start = try XCTUnwrap(coordinate(of: handle.anchor, on: handle, in: transform))
        let end = try XCTUnwrap(coordinate(of: SIMD3(6.25, 0, 0), on: handle, in: transform))
        XCTAssertEqual(end - start, 1.25, accuracy: 1e-10)
        XCTAssertEqual(handle.value(from: start, to: end, snap: 0), 12.5)
        // The grip tracks face travel, not the dimension change.
        XCTAssertEqual(simd_distance(handle.point(for: 12.5), SIMD3(6.25, 0, 0)), 0, accuracy: 1e-12)
    }

    func testFaceAnchoredResizeChangesDimensionByLocalTravel() throws {
        // A non-centered cube keeps its lower face: the moving face travels
        // the whole dimension change (plan/02 "original lower face").
        let handle = ViewportLinearHandle(anchor: SIMD3(10, 0, 0), axis: SIMD3(1, 0, 0),
                                          value: 10, valuePerUnit: 1)
        let transform = transform(lookingAt: SIMD3(10, 0, 0))

        let start = try XCTUnwrap(coordinate(of: handle.anchor, on: handle, in: transform))
        let end = try XCTUnwrap(coordinate(of: SIMD3(11.25, 0, 0), on: handle, in: transform))
        XCTAssertEqual(handle.value(from: start, to: end, snap: 0), 11.25)
        XCTAssertEqual(simd_distance(handle.point(for: 11.25), SIMD3(11.25, 0, 0)), 0,
                       accuracy: 1e-12)
    }

    // MARK: Projections

    func testOrthographicAndPerspectiveReportSameLocalDelta() throws {
        let handle = ViewportLinearHandle(anchor: SIMD3(55, 20, 3), axis: SIMD3(1, 0, 0),
                                          value: 20, valuePerUnit: 0.5)
        for ortho in [false, true] {
            let transform = transform(lookingAt: SIMD3(55, 20, 3), orthographic: ortho)
            let start = try XCTUnwrap(coordinate(of: handle.anchor, on: handle, in: transform))
            let end = try XCTUnwrap(coordinate(of: SIMD3(59, 20, 3), on: handle, in: transform))
            XCTAssertEqual(end - start, 4, accuracy: 1e-10, ortho ? "ortho" : "perspective")
            XCTAssertEqual(handle.value(from: start, to: end, snap: 0), 22,
                           ortho ? "ortho" : "perspective")
        }
    }

    // MARK: Degenerate and edge-on axes

    func testSingularAxisRejectsEveryViewPoint() throws {
        // A zero-scale parent collapses the writable axis; so does an axis
        // whose squared length underflows. `coordinate` is what disables
        // the handle, so it must fail everywhere.
        let transform = transform(lookingAt: .zero)
        for axis in [SIMD3<Double>.zero, SIMD3(1e-300, 0, 0)] {
            let handle = ViewportLinearHandle(anchor: .zero, axis: axis,
                                              value: 1, valuePerUnit: 1)
            for point in [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 300), CGPoint(x: 799, y: 599)] {
                XCTAssertNil(handle.coordinate(at: point, in: transform))
            }
        }
    }

    func testEdgeOnAxisRejectsUnstableProjection() throws {
        // The top view looks down -Z, so the +Z axis is exactly edge-on and
        // a 0.05 slope still fails the conditioning bound; 0.5 clears it.
        let transform = transform(lookingAt: .zero, view: .top)
        for axis in [SIMD3(0, 0, 1), simd_normalize(SIMD3(0.05, 0, 1))] {
            let handle = ViewportLinearHandle(anchor: .zero, axis: axis,
                                              value: 1, valuePerUnit: 1)
            XCTAssertNil(coordinate(of: 2 * axis, on: handle, in: transform))
        }
        let usable = simd_normalize(SIMD3(0.5, 0, 1))
        let handle = ViewportLinearHandle(anchor: .zero, axis: usable, value: 1, valuePerUnit: 1)
        let coordinate = try XCTUnwrap(coordinate(of: 2 * usable, on: handle, in: transform))
        XCTAssertEqual(coordinate, 2, accuracy: 1e-10)
    }

    func testNonFiniteInputsReject() throws {
        let transform = transform(lookingAt: .zero)
        for (anchor, axis) in [(SIMD3<Double>.zero, SIMD3(.nan, 0, 0)),
                               (SIMD3(.nan, 0, 0), SIMD3(1, 0, 0)),
                               (SIMD3<Double>.zero, SIMD3(.infinity, 0, 0))] {
            let handle = ViewportLinearHandle(anchor: anchor, axis: axis,
                                              value: 1, valuePerUnit: 1)
            XCTAssertNil(handle.coordinate(at: CGPoint(x: 400, y: 300), in: transform))
        }

        let handle = ViewportLinearHandle(anchor: .zero, axis: SIMD3(1, 0, 0),
                                          value: 20, valuePerUnit: 0.5)
        XCTAssertNil(handle.value(from: 0, to: .nan, snap: 0))
        XCTAssertNil(handle.value(from: 0, to: .infinity, snap: 0))
        let overflow = ViewportLinearHandle(anchor: .zero, axis: SIMD3(1, 0, 0),
                                            value: 20, valuePerUnit: 10)
        XCTAssertNil(overflow.value(from: 0, to: .greatestFiniteMagnitude, snap: 0))
    }

    // MARK: Snap and hit test

    func testSnappedCandidatesCarryNoArithmeticNoise() throws {
        let offset = ViewportLinearHandle(anchor: .zero, axis: SIMD3(1, 0, 0), value: 0, valuePerUnit: 1)
        XCTAssertEqual(offset.value(from: 0, to: 0.31, snap: 0.1), 0.3)
        let diameter = ViewportDiameterHandle(center: .zero, radialUnit: SIMD3(1, 0, 0), diameter: 10)
        XCTAssertEqual(diameter.resized(from: 5, to: 5.051, snap: 0.1), 10.1)
        let one = ViewportLinearHandle(anchor: .zero, axis: SIMD3(1, 0, 0), value: 1, valuePerUnit: 1)
        let zero = try XCTUnwrap(one.value(from: 0, to: -1.2, snap: 1))
        XCTAssertEqual(zero, 0)
        XCTAssertEqual(zero.sign, .plus, "A drag to zero must not write -0")
    }

    func testADimensionPreviewsOnlyValuesItCanCommit() throws {
        let size = ViewportLinearHandle(anchor: .zero, axis: SIMD3(1, 0, 0), value: 10, valuePerUnit: 1,
                                        exclusiveMinimum: 0)
        XCTAssertEqual(size.value(from: 0, to: -4, snap: 0), 6)
        XCTAssertNil(size.value(from: 0, to: -12, snap: 0))
        XCTAssertNil(size.value(from: 0, to: -9.8, snap: 1), "Snapping must not reach zero either")
    }

    func testSnapRoundsCandidateInModelUnits() throws {
        let handle = ViewportLinearHandle(anchor: .zero, axis: SIMD3(1, 0, 0),
                                          value: 20, valuePerUnit: 0.5)
        // Proposal 21.95: a positive snap interval rounds it in model units.
        XCTAssertEqual(handle.value(from: 0, to: 3.9, snap: 0.5), 22)
        XCTAssertEqual(handle.value(from: 0, to: 3.9, snap: 1), 22)
        // Snap off, non-positive or non-finite keeps the raw proposal.
        for snap in [0.0, -0.5, Double.infinity] {
            XCTAssertEqual(handle.value(from: 0, to: 3.9, snap: snap)!, 21.95, accuracy: 1e-12)
        }
        // A snap that lands back on the baseline is no edit.
        XCTAssertNil(handle.value(from: 0, to: 0.2, snap: 0.5))
    }

    func testContainsGrabsOnlyTheProjectedGrip() throws {
        let handle = ViewportLinearHandle(anchor: SIMD3(55, 20, 3), axis: SIMD3(1, 0, 0),
                                          value: 20, valuePerUnit: 0.5)
        let transform = transform(lookingAt: SIMD3(55, 20, 3))
        let grip = try XCTUnwrap(transform.project(handle.anchor))
        XCTAssertTrue(handle.contains(CGPoint(x: grip.x, y: grip.y), in: transform))
        XCTAssertTrue(handle.contains(CGPoint(x: grip.x + 8, y: grip.y), in: transform))
        XCTAssertFalse(handle.contains(CGPoint(x: grip.x + 10, y: grip.y), in: transform))

        // A grip behind the eye never hits.
        let behind = ViewportLinearHandle(anchor: transform.camera.eye - transform.camera.forward * 10,
                                          axis: SIMD3(1, 0, 0), value: 0, valuePerUnit: 1)
        XCTAssertFalse(behind.contains(CGPoint(x: 400, y: 300), in: transform))

        // The baseline grip reproduces the anchor exactly.
        XCTAssertEqual(handle.point(for: handle.value), handle.anchor)
    }
}
