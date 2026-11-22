import XCTest
import simd
@testable import ScadrettoViewport

/// Tests for the M3 surface index: BVH ray hits, parallel-slab handling,
/// deterministic tie breaks, bounds queries and malformed-row skipping.
/// All pure CPU; no GPU is created.
final class ViewportSurfaceIndexTests: XCTestCase {
    func testDiameterDragUsesTwoUnitsOfDiameterPerLocalRadius() throws {
        let center = SIMD3(55.0, 20.0, 3.0)
        var camera = ViewportCamera()
        camera.center = center
        let transform = camera.transform(viewSize: CGSize(width: 608, height: 638), orthographic: false,
                                         renderOrigin: center, sceneRadius: 20)
        let handle = ViewportDiameterHandle(center: center, radialUnit: SIMD3(1, 0, 0), diameter: 4)
        let start = try XCTUnwrap(transform.project(handle.rim(at: 4)))
        let end = try XCTUnwrap(transform.project(handle.rim(at: 5)))
        let r0 = try XCTUnwrap(handle.radiusCoordinate(at: CGPoint(x: start.x, y: start.y), in: transform))
        let r1 = try XCTUnwrap(handle.radiusCoordinate(at: CGPoint(x: end.x, y: end.y), in: transform))
        XCTAssertEqual(r0, 2, accuracy: 1e-10)
        XCTAssertEqual(r1 - r0, 0.5, accuracy: 1e-10)
        XCTAssertEqual(handle.resized(from: r0, to: r1, snap: 0), 5)
        XCTAssertNil(handle.resized(from: r0, to: r0, snap: 0))
        let betweenTicks = ViewportDiameterHandle(center: center, radialUnit: SIMD3(1, 0, 0), diameter: 4.3)
        XCTAssertNil(betweenTicks.resized(from: r0, to: r0, snap: 0.5))
    }

    /// Closed unit cube with outward-facing CCW triangles, matching the
    /// ViewportMathTests fixture.
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

    // MARK: Ray hits

    func testHitPicksNearestTriangle() throws {
        // Triangle 0 at x = 2 faces +X; triangle 1 at x = 5 faces -X.
        let mesh = ViewportMesh(
            positions: [
                SIMD3(2, 0, 0), SIMD3(2, 1, 0), SIMD3(2, 0, 1),
                SIMD3(5, 0, 0), SIMD3(5, 0, 1), SIMD3(5, 1, 0),
            ],
            indices: [0, 1, 2, 3, 4, 5]
        )
        let index = try XCTUnwrap(ViewportSurfaceIndex(mesh: mesh))
        let hit = try XCTUnwrap(index.hit(along: ViewportRay(
            origin: SIMD3(0, 0.25, 0.25), direction: SIMD3(1, 0, 0))))
        XCTAssertEqual(hit.triangleIndex, 0)
        XCTAssertEqual(hit.distance, 2, accuracy: 1e-12)
        XCTAssertEqual(hit.point.x, 2, accuracy: 1e-12)
        XCTAssertEqual(hit.point.y, 0.25, accuracy: 1e-12)
        XCTAssertEqual(hit.point.z, 0.25, accuracy: 1e-12)
        XCTAssertEqual(hit.normal.x, 1, accuracy: 1e-12)
        XCTAssertEqual(hit.normal.y, 0, accuracy: 1e-12)
        XCTAssertEqual(hit.normal.z, 0, accuracy: 1e-12)
    }

    func testHitAcceptsBackSideAndKeepsWindingNormal() throws {
        // A lone triangle wound toward -X still stops a +X ray; the reported
        // normal follows the stored winding rather than the ray.
        let mesh = ViewportMesh(
            positions: [SIMD3(5, 0, 0), SIMD3(5, 0, 1), SIMD3(5, 1, 0)],
            indices: [0, 1, 2]
        )
        let index = try XCTUnwrap(ViewportSurfaceIndex(mesh: mesh))
        let hit = try XCTUnwrap(index.hit(along: ViewportRay(
            origin: SIMD3(0, 0.25, 0.25), direction: SIMD3(1, 0, 0))))
        XCTAssertEqual(hit.triangleIndex, 0)
        XCTAssertEqual(hit.distance, 5, accuracy: 1e-12)
        XCTAssertEqual(hit.normal.x, -1, accuracy: 1e-12)

        // Strictly positive: a triangle containing the origin does not hit.
        let coplanar = ViewportMesh(
            positions: [SIMD3(0, -1, -1), SIMD3(0, 1, -1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2]
        )
        let coplanarIndex = try XCTUnwrap(ViewportSurfaceIndex(mesh: coplanar))
        XCTAssertNil(coplanarIndex.hit(along: ViewportRay(
            origin: SIMD3(0, 0, 0), direction: SIMD3(1, 0, 0))))
    }

    func testRayParallelToSlabAxes() throws {
        let index = try XCTUnwrap(ViewportSurfaceIndex(mesh: cube(at: .zero, size: 2)))
        // Direction (1,0,0) is parallel to the Y and Z slab planes.
        let hit = try XCTUnwrap(index.hit(along: ViewportRay(
            origin: SIMD3(-5, 0.25, -0.5), direction: SIMD3(1, 0, 0))))
        XCTAssertEqual(hit.distance, 4, accuracy: 1e-12)
        XCTAssertEqual(hit.point.x, -1, accuracy: 1e-12)
        XCTAssertEqual(hit.normal.x, -1, accuracy: 1e-12)

        // A parallel ray whose origin sits outside a slab misses entirely.
        XCTAssertNil(index.hit(along: ViewportRay(
            origin: SIMD3(-5, 5, -0.5), direction: SIMD3(1, 0, 0))))
        // A ray pointing away misses too.
        XCTAssertNil(index.hit(along: ViewportRay(
            origin: SIMD3(-5, 0.25, -0.5), direction: SIMD3(-1, 0, 0))))
    }

    func testEqualDepthBreaksTieByOrdinal() throws {
        // A unit square split along its diagonal: a ray through the shared
        // edge gives both triangles exactly the same distance.
        let positions: [SIMD3<Double>] = [
            SIMD3(3, 0, 0), SIMD3(3, 1, 0), SIMD3(3, 1, 1), SIMD3(3, 0, 1),
        ]
        let index = try XCTUnwrap(ViewportSurfaceIndex(mesh: ViewportMesh(
            positions: positions, indices: [0, 1, 2, 0, 2, 3])))
        let hit = try XCTUnwrap(index.hit(along: ViewportRay(
            origin: SIMD3(0, 0.5, 0.5), direction: SIMD3(1, 0, 0))))
        XCTAssertEqual(hit.distance, 3, accuracy: 1e-12)
        XCTAssertEqual(hit.triangleIndex, 0)

        // The same tie with the rows swapped still reports ordinal 0.
        let swapped = try XCTUnwrap(ViewportSurfaceIndex(mesh: ViewportMesh(
            positions: positions, indices: [0, 2, 3, 0, 1, 2])))
        let swappedHit = try XCTUnwrap(swapped.hit(along: ViewportRay(
            origin: SIMD3(0, 0.5, 0.5), direction: SIMD3(1, 0, 0))))
        XCTAssertEqual(swappedHit.triangleIndex, 0)

        // A ray through triangle 1's own interior reports it alone.
        let inner = try XCTUnwrap(index.hit(along: ViewportRay(
            origin: SIMD3(0, 0.5, 0.75), direction: SIMD3(1, 0, 0))))
        XCTAssertEqual(inner.triangleIndex, 1)
    }

    func testHitAtLargeWorldX() throws {
        // plan/03 spike case: a ray from x = 100000002 along -X meets the
        // x = 100000001 wall one unit away, in double precision.
        let index = try XCTUnwrap(ViewportSurfaceIndex(
            mesh: cube(at: SIMD3(100000000.5, 0.5, 0.5))))
        let hit = try XCTUnwrap(index.hit(along: ViewportRay(
            origin: SIMD3(100000002, 0.5, 0.5), direction: SIMD3(-1, 0, 0))))
        XCTAssertEqual(hit.distance, 1, accuracy: 1e-9)
        XCTAssertEqual(hit.point.x, 100000001, accuracy: 1e-9)
        XCTAssertEqual(hit.point.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(hit.point.z, 0.5, accuracy: 1e-9)
        XCTAssertEqual(hit.normal.x, 1, accuracy: 1e-9)
        // The wall's two triangles tie on the shared diagonal; ordinal 0 wins.
        XCTAssertEqual(hit.triangleIndex, 0)
    }

    // MARK: Bounds queries and malformed rows

    func testBoundsQuerySkipsInvalidRowsAndKeepsOrdinals() throws {
        let mesh = ViewportMesh(
            positions: [
                SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0),
                SIMD3(2, 0, 0),
                SIMD3(5, 5, 5), SIMD3(6, 5, 5), SIMD3(5, 6, 5),
                SIMD3(.nan, 0, 0),
            ],
            indices: [
                0, 1, 2,   // 0: valid
                0, 0, 0,   // 1: repeated index
                0, 1, 3,   // 2: collinear, zero area
                0, 1, 9,   // 3: out of range
                0, 1, 7,   // 4: non-finite vertex
                4, 5, 6,   // 5: valid
                0, 1,      // trailing partial row, ignored
            ]
        )
        let index = try XCTUnwrap(ViewportSurfaceIndex(mesh: mesh))

        // Only the two valid triangles exist, with original ordinals kept.
        let all = index.triangles(overlapping: ViewportBounds(
            min: SIMD3(-1, -1, -1), max: SIMD3(10, 10, 10)))
        XCTAssertEqual(all.map(\.index), [0, 5])

        // A tight box selects only the overlapping triangle, winding intact.
        let near = index.triangles(overlapping: ViewportBounds(
            min: SIMD3(4.9, 4.9, 4.9), max: SIMD3(5.1, 5.1, 5.1)))
        XCTAssertEqual(near.map(\.index), [5])
        let triangle = try XCTUnwrap(near.first)
        XCTAssertEqual(triangle.a, SIMD3(5, 5, 5))
        XCTAssertEqual(triangle.b, SIMD3(6, 5, 5))
        XCTAssertEqual(triangle.c, SIMD3(5, 6, 5))

        // A disjoint box reports nothing.
        XCTAssertTrue(index.triangles(overlapping: ViewportBounds(
            min: SIMD3(-10, -10, -10), max: SIMD3(-9, -9, -9))).isEmpty)
    }

    func testGridRayAndBoundsQueryAcrossLevels() throws {
        // A 10x10 quad grid on z = 0: 200 triangles force several BVH levels.
        var positions: [SIMD3<Double>] = []
        var indices: [UInt32] = []
        for y in 0...10 {
            for x in 0...10 {
                positions.append(SIMD3(Double(x), Double(y), 0))
            }
        }
        for y in 0..<10 {
            for x in 0..<10 {
                let v = UInt32(y * 11 + x)
                indices += [v, v + 1, v + 12, v, v + 12, v + 11]
            }
        }
        let index = try XCTUnwrap(ViewportSurfaceIndex(
            mesh: ViewportMesh(positions: positions, indices: indices)))

        // A box strictly inside cell (2,3) returns exactly its two triangles.
        let cell = 3 * 10 + 2
        let inside = index.triangles(overlapping: ViewportBounds(
            min: SIMD3(2.2, 3.2, -0.5), max: SIMD3(2.8, 3.8, 0.5)))
        XCTAssertEqual(inside.map(\.index), [2 * cell, 2 * cell + 1])

        // A ray straight down into that cell reports the first of its
        // triangles, on the grid surface.
        let hit = try XCTUnwrap(index.hit(along: ViewportRay(
            origin: SIMD3(2.5, 3.4, 5), direction: SIMD3(0, 0, -1))))
        XCTAssertEqual(hit.triangleIndex, 2 * cell)
        XCTAssertEqual(hit.distance, 5, accuracy: 1e-12)
        XCTAssertEqual(hit.point.x, 2.5, accuracy: 1e-12)
        XCTAssertEqual(hit.point.y, 3.4, accuracy: 1e-12)
        XCTAssertEqual(hit.point.z, 0, accuracy: 1e-12)
        XCTAssertEqual(hit.normal.z, 1, accuracy: 1e-12)

        // The whole-grid box returns every triangle.
        XCTAssertEqual(index.triangles(overlapping: ViewportBounds(
            min: SIMD3(-1, -1, -1), max: SIMD3(11, 11, 1))).count, 200)
    }

    // MARK: Budget and empty input

    func testInitRejectsEmptyInvalidAndOverBudgetMeshes() {
        XCTAssertNil(ViewportSurfaceIndex(mesh: ViewportMesh(positions: [], indices: [])))

        // Every row invalid: repeated and out of range.
        XCTAssertNil(ViewportSurfaceIndex(mesh: ViewportMesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            indices: [0, 0, 0, 1, 1, 9])))

        // Above the documented budget the mesh is rejected before building.
        let overBudget = ViewportMesh(
            positions: [SIMD3(0, 0, 0)],
            indices: [UInt32](repeating: 0, count: 3 * (ViewportSurfaceIndex.maxTriangleCount + 1)))
        XCTAssertNil(ViewportSurfaceIndex(mesh: overBudget))
    }
}
