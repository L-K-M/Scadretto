import simd

/// One triangle held by a `ViewportSurfaceIndex`: the original zero-based
/// ordinal of its row in the mesh's flat `indices` list, plus its three
/// float64 vertices in the mesh's own coordinate frame and stored winding.
public struct ViewportTriangle: Equatable, Sendable {
    /// Zero-based source ordinal; the row occupies `indices[3 * index...]`.
    public let index: Int
    public let a: SIMD3<Double>
    public let b: SIMD3<Double>
    public let c: SIMD3<Double>

    public init(index: Int, a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>) {
        self.index = index
        self.a = a
        self.b = b
        self.c = c
    }
}

/// The nearest strictly-positive surface intersection along a `ViewportRay`.
public struct ViewportSurfaceHit: Equatable, Sendable {
    /// Original zero-based triangle ordinal in `ViewportMesh.indices`.
    public let triangleIndex: Int
    /// Intersection point in the mesh's coordinate frame.
    public let point: SIMD3<Double>
    /// Unit normal following the stored winding; it is not flipped toward the
    /// ray, so a back-side hit reports its source orientation.
    public let normal: SIMD3<Double>
    /// Ray parameter of the intersection: `point = origin + distance * direction`,
    /// in the supplied ray's own units — a Euclidean distance only when
    /// `direction` is unit length.
    public let distance: Double

    public init(triangleIndex: Int, point: SIMD3<Double>, normal: SIMD3<Double>, distance: Double) {
        self.triangleIndex = triangleIndex
        self.point = point
        self.normal = normal
        self.distance = distance
    }
}

/// A CPU triangle BVH over one `ViewportMesh`, built off the main actor per
/// plan/01-Architecture.md for the surface hit testing in
/// plan/03-OpenSCAD-Worker.md. The same index serves final world-space
/// geometry and local operand meshes; all coordinates stay in the mesh's own
/// float64 frame.
///
/// Construction skips incomplete trailing rows, repeated or out-of-range
/// indices, non-finite vertices and zero-area triangles; surviving triangles
/// keep their original ordinals and winding. Meshes with more than
/// `maxTriangleCount` source rows are rejected before any allocation so a
/// corrupt count cannot force unbounded memory.
public struct ViewportSurfaceIndex: Sendable {
    /// First-release input budget, in source triangles (`indices.count / 3`).
    /// Meshes above it fail `init` and must fall back to coarser picking.
    public static let maxTriangleCount = 1_000_000

    /// Maximum triangles per leaf; small leaves keep query fan-out low.
    private static let leafTriangleCount = 4

    /// Hard recursion cap. Median splits already keep real trees near
    /// log2(n) — about 21 levels at the budget — so this only guards
    /// pathological centroid distributions.
    private static let maxDepth = 64

    /// Vertex pool shared with the source mesh's copy-on-write storage, so
    /// triangles are kept as index triples instead of duplicated positions.
    private let positions: [SIMD3<Double>]

    /// Valid primitives in leaf order.
    private let primitives: [Primitive]

    /// BVH nodes in build order; node 0 is the root.
    private let nodes: [Node]

    private struct Primitive: Sendable {
        /// Triangle bounds for the query test and the split heuristic.
        var bounds: ViewportBounds
        var i0: Int
        var i1: Int
        var i2: Int
        /// Original zero-based triangle ordinal in the source mesh.
        var index: Int
    }

    private struct Node: Sendable {
        enum Kind: Sendable {
            case branch(left: Int, right: Int)
            case leaf(start: Int, count: Int)
        }
        var bounds: ViewportBounds
        var kind: Kind
    }

    /// Builds the index, or returns `nil` when the mesh exceeds
    /// `maxTriangleCount` or yields no usable triangle.
    public init?(mesh: ViewportMesh) {
        guard mesh.indices.count / 3 <= Self.maxTriangleCount else { return nil }

        var primitives: [Primitive] = []
        primitives.reserveCapacity(mesh.indices.count / 3)
        var index = 0
        var cursor = 0
        while cursor + 2 < mesh.indices.count {
            let i0 = Int(mesh.indices[cursor])
            let i1 = Int(mesh.indices[cursor + 1])
            let i2 = Int(mesh.indices[cursor + 2])
            cursor += 3
            defer { index += 1 }
            guard i0 != i1, i1 != i2, i2 != i0,
                  i0 < mesh.positions.count, i1 < mesh.positions.count, i2 < mesh.positions.count
            else { continue }
            let a = mesh.positions[i0]
            let b = mesh.positions[i1]
            let c = mesh.positions[i2]
            guard Self.isFinite(a), Self.isFinite(b), Self.isFinite(c) else { continue }
            let area = simd_length(simd_cross(b - a, c - a))
            guard area.isFinite, area > 0 else { continue }
            primitives.append(Primitive(
                bounds: ViewportBounds(min: simd_min(a, simd_min(b, c)),
                                       max: simd_max(a, simd_max(b, c))),
                i0: i0, i1: i1, i2: i2, index: index))
        }
        guard !primitives.isEmpty else { return nil }

        var nodes: [Node] = []
        nodes.reserveCapacity(2 * primitives.count / Self.leafTriangleCount)
        _ = Self.build(&primitives, into: &nodes, lo: 0, hi: primitives.count, depth: 0)

        self.positions = mesh.positions
        self.primitives = primitives
        self.nodes = nodes
    }

    /// The nearest strictly-positive intersection along `ray`, or `nil`.
    /// `distance` is in the ray's parameter units. Both triangle sides count;
    /// equal distances resolve to the lower original ordinal.
    public func hit(along ray: ViewportRay) -> ViewportSurfaceHit? {
        guard Self.isFinite(ray.origin), Self.isFinite(ray.direction) else { return nil }
        guard Self.slabEntry(nodes[0].bounds, ray: ray, limit: .infinity) != nil else { return nil }

        var bestDistance = Double.infinity
        var bestIndex = Int.max
        var bestNormal = SIMD3<Double>()
        var stack = [0]
        while let nodeIndex = stack.popLast() {
            switch nodes[nodeIndex].kind {
            case .branch(let left, let right):
                // The nearer child is pushed last so it pops first and its
                // hits can prune the farther side. Entry at exactly
                // `bestDistance` is kept so equal-depth ties still resolve by
                // original index.
                let entryLeft = Self.slabEntry(nodes[left].bounds, ray: ray, limit: bestDistance)
                let entryRight = Self.slabEntry(nodes[right].bounds, ray: ray, limit: bestDistance)
                switch (entryLeft, entryRight) {
                case let (l?, r?) where l <= r:
                    stack.append(right)
                    stack.append(left)
                case (_?, _?):
                    stack.append(left)
                    stack.append(right)
                case (_?, nil):
                    stack.append(left)
                case (nil, _?):
                    stack.append(right)
                case (nil, nil):
                    break
                }
            case .leaf(let start, let count):
                for primitive in primitives[start..<start + count] {
                    guard let (distance, normal) = Self.intersect(
                        ray: ray,
                        a: positions[primitive.i0],
                        b: positions[primitive.i1],
                        c: positions[primitive.i2]
                    ) else { continue }
                    if distance < bestDistance || (distance == bestDistance && primitive.index < bestIndex) {
                        bestDistance = distance
                        bestIndex = primitive.index
                        bestNormal = normal
                    }
                }
            }
        }
        guard bestIndex != Int.max else { return nil }
        return ViewportSurfaceHit(
            triangleIndex: bestIndex,
            point: ray.origin + ray.direction * bestDistance,
            normal: bestNormal,
            distance: bestDistance)
    }

    /// Every triangle whose bounds overlap `bounds`, sorted by original
    /// ordinal. The overlap test is on triangle bounds, an over-approximation
    /// of the triangle itself.
    public func triangles(overlapping bounds: ViewportBounds) -> [ViewportTriangle] {
        var result: [ViewportTriangle] = []
        var stack = [0]
        while let nodeIndex = stack.popLast() {
            let node = nodes[nodeIndex]
            guard Self.overlaps(node.bounds, bounds) else { continue }
            switch node.kind {
            case .branch(let left, let right):
                stack.append(left)
                stack.append(right)
            case .leaf(let start, let count):
                for primitive in primitives[start..<start + count] where Self.overlaps(primitive.bounds, bounds) {
                    result.append(ViewportTriangle(
                        index: primitive.index,
                        a: positions[primitive.i0],
                        b: positions[primitive.i1],
                        c: positions[primitive.i2]))
                }
            }
        }
        result.sort { $0.index < $1.index }
        return result
    }

    /// Appends one subtree covering `primitives[lo..<hi]` and returns its node
    /// index. Primitives are sorted on the widest axis of their bounds centers
    /// — with ordinal tie breaks for a stable layout — and split at the median,
    /// which bounds depth by log2(n) apart from the explicit `maxDepth` cap.
    private static func build(_ primitives: inout [Primitive], into nodes: inout [Node],
                              lo: Int, hi: Int, depth: Int) -> Int {
        var lower = primitives[lo].bounds.min
        var upper = primitives[lo].bounds.max
        var centerLo = lower
        var centerHi = upper
        for i in lo + 1..<hi {
            let bounds = primitives[i].bounds
            lower = simd_min(lower, bounds.min)
            upper = simd_max(upper, bounds.max)
            centerLo = simd_min(centerLo, bounds.center)
            centerHi = simd_max(centerHi, bounds.center)
        }

        let nodeIndex = nodes.count
        nodes.append(Node(bounds: ViewportBounds(min: lower, max: upper),
                          kind: .leaf(start: lo, count: hi - lo)))

        let count = hi - lo
        let extent = centerHi - centerLo
        let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2)
        guard count > Self.leafTriangleCount, depth < Self.maxDepth, extent[axis] > 0 else {
            return nodeIndex
        }

        primitives[lo..<hi].sort {
            ($0.bounds.center[axis], $0.index) < ($1.bounds.center[axis], $1.index)
        }
        let mid = lo + count / 2
        let left = build(&primitives, into: &nodes, lo: lo, hi: mid, depth: depth + 1)
        let right = build(&primitives, into: &nodes, lo: mid, hi: hi, depth: depth + 1)
        nodes[nodeIndex].kind = .branch(left: left, right: right)
        return nodeIndex
    }

    /// Entry parameter of `ray` into `bounds` clipped to `[0, limit]`, or `nil`
    /// when the interval does not reach the box. A ray parallel to a slab axis
    /// is accepted only while its origin sits inside that slab.
    private static func slabEntry(_ bounds: ViewportBounds, ray: ViewportRay, limit: Double) -> Double? {
        var enter = 0.0
        var exit = limit
        for axis in 0..<3 {
            let origin = ray.origin[axis]
            let direction = ray.direction[axis]
            if direction == 0 {
                guard origin >= bounds.min[axis], origin <= bounds.max[axis] else { return nil }
                continue
            }
            let inverse = 1 / direction
            var near = (bounds.min[axis] - origin) * inverse
            var far = (bounds.max[axis] - origin) * inverse
            if near > far { swap(&near, &far) }
            enter = max(enter, near)
            exit = min(exit, far)
            guard enter <= exit else { return nil }
        }
        return enter
    }

    /// Möller–Trumbore intersection, accepting both triangle sides. The ray
    /// must cross the plane inside the triangle's edges at a strictly positive
    /// parameter; a zero determinant means ray and triangle plane are parallel.
    private static func intersect(ray: ViewportRay, a: SIMD3<Double>, b: SIMD3<Double>,
                                  c: SIMD3<Double>) -> (distance: Double, normal: SIMD3<Double>)? {
        let edge1 = b - a
        let edge2 = c - a
        let p = simd_cross(ray.direction, edge2)
        let determinant = simd_dot(edge1, p)
        guard determinant != 0 else { return nil }
        let inverse = 1 / determinant
        let offset = ray.origin - a
        let u = simd_dot(offset, p) * inverse
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(offset, edge1)
        let v = simd_dot(ray.direction, q) * inverse
        guard v >= 0, u + v <= 1 else { return nil }
        let distance = simd_dot(edge2, q) * inverse
        guard distance > 0, distance.isFinite else { return nil }
        return (distance, simd_normalize(simd_cross(edge1, edge2)))
    }

    private static func overlaps(_ a: ViewportBounds, _ b: ViewportBounds) -> Bool {
        for axis in 0..<3 where a.min[axis] > b.max[axis] || a.max[axis] < b.min[axis] {
            return false
        }
        return true
    }

    private static func isFinite(_ vector: SIMD3<Double>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}
