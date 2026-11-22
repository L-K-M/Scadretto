import simd

public struct ViewportOperand: Sendable {
    public let id: UInt32
    public let meshID: UInt32
    public let world: simd_double4x4
    public let isSubtracted: Bool

    public init(id: UInt32, meshID: UInt32, world: simd_double4x4, isSubtracted: Bool) {
        self.id = id
        self.meshID = meshID
        self.world = world
        self.isSubtracted = isSubtracted
    }
}

public struct ViewportPick: Sendable {
    public let hit: ViewportSurfaceHit
    public let candidates: [UInt32]
}

/// Surface picks start with the visible solid. Candidate operands must cover
/// that same world-space point and own its final normal, including cutter
/// orientation. A local index serves every occurrence of an identical mesh.
public struct ViewportPicker: Sendable {
    private struct IndexedOperand: Sendable {
        let occurrence: ViewportOperand
        let inverse: simd_double4x4
        let bounds: ViewportBounds
        let index: ViewportSurfaceIndex
        let normalSign: Double
    }

    private let final: ViewportSurfaceIndex
    private let owners: [UInt32]?
    private let operands: [IndexedOperand]
    private let tolerance: Double

    public init?(mesh: ViewportMesh, owners: [UInt32]?, operandMeshes: [UInt32: ViewportMesh],
                 occurrences: [ViewportOperand]) {
        guard let final = ViewportSurfaceIndex(mesh: mesh), let bounds = mesh.bounds else { return nil }
        self.final = final
        self.owners = owners
        // Scale to the scene diagonal with a floor for tiny solids and a cap
        // so large scenes do not merge otherwise distinct nearby walls.
        tolerance = max(1e-9, min(1e-5, simd_length(bounds.size) * 1e-8))
        guard operandMeshes.values.reduce(0, { $0 + $1.triangleCount }) <= ViewportSurfaceIndex.maxTriangleCount else {
            operands = []
            return
        }
        let indexes = operandMeshes.compactMapValues { mesh -> (ViewportSurfaceIndex, ViewportBounds)? in
            guard let index = ViewportSurfaceIndex(mesh: mesh), let bounds = mesh.bounds else { return nil }
            return (index, bounds)
        }
        operands = occurrences.compactMap { occurrence in
            guard let (index, localBounds) = indexes[occurrence.meshID] else { return nil }
            let world = occurrence.world
            let determinant = simd_determinant(world)
            let scale = simd_length(world.columns.0) * simd_length(world.columns.1) * simd_length(world.columns.2)
            guard scale.isFinite, scale > 0, abs(determinant) > scale * 1e-12 else { return nil }
            let normalSign = (determinant < 0) == occurrence.isSubtracted ? 1.0 : -1.0
            return IndexedOperand(occurrence: occurrence, inverse: world.inverse,
                                  bounds: Self.transform(localBounds, by: world), index: index,
                                  normalSign: normalSign)
        }
    }

    public func pick(along ray: ViewportRay) -> ViewportPick? {
        guard let hit = final.hit(along: ray) else { return nil }
        if let owners, owners.indices.contains(hit.triangleIndex), owners[hit.triangleIndex] != UInt32.max {
            return ViewportPick(hit: hit, candidates: [owners[hit.triangleIndex]])
        }
        let offset = SIMD3<Double>(repeating: tolerance)
        let bounds = ViewportBounds(min: hit.point - offset, max: hit.point + offset)
        let normals = final.triangles(overlapping: bounds).compactMap { triangle in
            coveringNormal(triangle.a, triangle.b, triangle.c, point: hit.point)
        }
        let candidates = operands.compactMap { operand -> UInt32? in
            guard Self.overlaps(operand.bounds, bounds) else { return nil }
            let localBounds = Self.transform(bounds, by: operand.inverse)
            for triangle in operand.index.triangles(overlapping: localBounds) {
                let world = operand.occurrence.world
                guard let normal = coveringNormal(Self.transform(triangle.a, by: world),
                                                  Self.transform(triangle.b, by: world),
                                                  Self.transform(triangle.c, by: world), point: hit.point) else { continue }
                if normals.contains(where: { simd_dot($0, normal) * operand.normalSign >= 0.99999 }) {
                    return operand.occurrence.id
                }
            }
            return nil
        }
        return ViewportPick(hit: hit, candidates: candidates.sorted())
    }

    private func coveringNormal(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
                                point: SIMD3<Double>) -> SIMD3<Double>? {
        let area = simd_cross(b - a, c - a)
        let length = simd_length(area)
        guard length > 0, length.isFinite else { return nil }
        let normal = area / length
        guard abs(simd_dot(point - a, normal)) <= tolerance else { return nil }
        for (start, end) in [(a, b), (b, c), (c, a)] {
            let edge = end - start
            let distance = simd_dot(simd_cross(edge, point - start), normal) / simd_length(edge)
            guard distance >= -tolerance else { return nil }
        }
        return normal
    }

    private static func transform(_ point: SIMD3<Double>, by matrix: simd_double4x4) -> SIMD3<Double> {
        let position = matrix * SIMD4(point, 1)
        return SIMD3(position.x, position.y, position.z)
    }

    private static func transform(_ bounds: ViewportBounds, by matrix: simd_double4x4) -> ViewportBounds {
        let start = transform(bounds.min, by: matrix)
        var result = ViewportBounds(min: start, max: start)
        for x in [bounds.min.x, bounds.max.x] {
            for y in [bounds.min.y, bounds.max.y] {
                for z in [bounds.min.z, bounds.max.z] {
                    result = result.including(transform(SIMD3(x, y, z), by: matrix))
                }
            }
        }
        return result
    }

    private static func overlaps(_ lhs: ViewportBounds, _ rhs: ViewportBounds) -> Bool {
        for axis in 0..<3 where lhs.max[axis] < rhs.min[axis] || rhs.max[axis] < lhs.min[axis] {
            return false
        }
        return true
    }
}
