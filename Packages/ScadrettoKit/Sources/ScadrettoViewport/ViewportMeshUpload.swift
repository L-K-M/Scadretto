import simd

/// One GPU vertex: float3 position then float3 normal or RGB color, packed to
/// 24 bytes. Plain Float fields keep the stride tight; `SIMD3<Float>` would
/// pad every lane triple to 16 bytes.
struct ViewportVertex: Sendable {
    var x: Float
    var y: Float
    var z: Float
    var a: Float
    var b: Float
    var c: Float
}

/// CPU-side mesh preparation shared by the Metal renderer and tests.
///
/// Per the render-origin rule in plan/03-OpenSCAD-Worker.md, world float64
/// positions are rebased by a double-precision origin before conversion to
/// float32, so a mesh at x = 100000000 keeps its unit width on the GPU. The
/// same origin is passed to `ViewportCamera.transform` so camera and geometry
/// stay in one frame. Face normals are derived from triangles for the first
/// release, area-weighted into per-vertex normals.
public struct ViewportMeshUpload: Sendable {
    /// Interleaved vertices: position (render space) + normal.
    var vertexData: [ViewportVertex]
    var indices: [UInt32]
    /// World-space bounds of the mesh, or nil when empty.
    var bounds: ViewportBounds?
    /// Double-precision origin subtracted from `positions`.
    var renderOrigin: SIMD3<Double>
    /// World-space enclosing-sphere radius, for near/far and framing.
    var sceneRadius: Double

    var vertexCount: Int { vertexData.count }

    public init(mesh: ViewportMesh) {
        let bounds = mesh.bounds
        // Bounds center keeps rebased coordinates symmetric and small. The
        // camera keeps world coordinates; the origin is reapplied per frame.
        let origin = bounds?.center ?? .zero
        renderOrigin = origin
        sceneRadius = bounds?.radius ?? 1
        self.bounds = bounds

        var positions = [SIMD3<Float>](repeating: .zero, count: mesh.positions.count)
        for (index, position) in mesh.positions.enumerated() {
            let rebased = position - origin
            positions[index] = SIMD3(Float(rebased.x), Float(rebased.y), Float(rebased.z))
        }

        // Drop out-of-range and degenerate triangles: the worker contract
        // validates indices, but the GPU index buffer must never read outside
        // the vertex buffer even on malformed input.
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.positions.count)
        var cleanIndices: [UInt32] = []
        cleanIndices.reserveCapacity(mesh.indices.count)
        var cursor = 0
        while cursor + 2 < mesh.indices.count {
            let i0 = Int(mesh.indices[cursor])
            let i1 = Int(mesh.indices[cursor + 1])
            let i2 = Int(mesh.indices[cursor + 2])
            cursor += 3
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count,
                  i0 != i1, i1 != i2, i2 != i0 else { continue }
            cleanIndices.append(contentsOf: [UInt32(i0), UInt32(i1), UInt32(i2)])
            // Unnormalized cross product weights by triangle area.
            let face = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            normals[i0] += face
            normals[i1] += face
            normals[i2] += face
        }
        indices = cleanIndices

        vertexData = mesh.positions.indices.map { index in
            let position = positions[index]
            let normal = normals[index]
            let unit = simd_length(normal) > 1e-12 ? simd_normalize(normal) : SIMD3<Float>(0, 0, 1)
            return ViewportVertex(
                x: position.x, y: position.y, z: position.z,
                a: unit.x, b: unit.y, c: unit.z
            )
        }
    }

    /// The axes start at the world origin in the same rebased coordinates
    /// as the geometry. The color slots reuse the normal fields.
    static func axesVertexData(length: Double, renderOrigin: SIMD3<Double>) -> [ViewportVertex] {
        let l = Float(length)
        let origin = SIMD3<Float>(-renderOrigin)
        func line(_ axis: SIMD3<Float>, _ color: SIMD3<Float>) -> [ViewportVertex] {
            [
                ViewportVertex(x: origin.x, y: origin.y, z: origin.z, a: color.x, b: color.y, c: color.z),
                ViewportVertex(x: origin.x + axis.x * l, y: origin.y + axis.y * l, z: origin.z + axis.z * l,
                               a: color.x, b: color.y, c: color.z),
            ]
        }
        return line(SIMD3(1, 0, 0), SIMD3(0.85, 0.22, 0.22))
            + line(SIMD3(0, 1, 0), SIMD3(0.25, 0.75, 0.25))
            + line(SIMD3(0, 0, 1), SIMD3(0.28, 0.42, 0.95))
    }
}
