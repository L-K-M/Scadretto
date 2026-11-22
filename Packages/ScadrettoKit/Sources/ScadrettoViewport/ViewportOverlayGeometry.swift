import simd

/// The world-space union of operands drawn as a ghost, within a size budget.
public struct ViewportGhost: Equatable, Sendable {
    /// About 800 cutters at $fn = 64.
    public static let defaultLimit = 600_000

    public let mesh: ViewportMesh?
    /// Operands that did not fit, which the caller reports.
    public let omitted: Int

    public init(operands: [ViewportOperand], meshes: [UInt32: ViewportMesh], limit: Int = Self.defaultLimit) {
        var positions: [SIMD3<Double>] = []
        var indices: [UInt32] = []
        var omitted = 0
        for operand in operands {
            guard let mesh = meshes[operand.meshID] else { continue }
            guard indices.count + mesh.indices.count <= limit,
                  positions.count + mesh.positions.count <= limit else {
                omitted += 1
                continue
            }
            let base = UInt32(positions.count)
            positions.append(contentsOf: mesh.positions.map { position in
                let world = operand.world * SIMD4(position, 1)
                return SIMD3(world.x, world.y, world.z)
            })
            indices.append(contentsOf: mesh.indices.map { base + $0 })
        }
        mesh = indices.isEmpty ? nil : ViewportMesh(positions: positions, indices: indices)
        self.omitted = omitted
    }
}

extension simd_double4x4 {
    /// Whether a handle can be placed in this frame. A singular placement
    /// cannot map a drag back to an authored value.
    public var isInvertibleFrame: Bool {
        let scale = simd_length(columns.0) * simd_length(columns.1) * simd_length(columns.2)
        return scale.isFinite && scale > 0 && abs(simd_determinant(self)) > scale * 1e-12
    }
}
