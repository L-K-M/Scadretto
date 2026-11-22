import ScadrettoViewport
import Testing
import simd

private let triangle = ViewportMesh(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], indices: [0, 1, 2])
private let square = ViewportMesh(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
                                  indices: [0, 1, 2, 0, 2, 3])

private func operand(_ id: UInt32, mesh: UInt32, x: Double) -> ViewportOperand {
    var world = matrix_identity_double4x4
    world.columns.3.x = x
    return ViewportOperand(id: id, meshID: mesh, world: world, isSubtracted: true)
}

@Test func aGhostPlacesEachOperandInWorldSpace() {
    let ghost = ViewportGhost(operands: [operand(1, mesh: 0, x: 10), operand(2, mesh: 0, x: 20)], meshes: [0: triangle])
    #expect(ghost.omitted == 0)
    #expect(ghost.mesh?.indices == [0, 1, 2, 3, 4, 5])
    #expect(ghost.mesh?.positions.map(\.x) == [10, 11, 10, 20, 21, 20])
}

@Test func aGhostCountsWhatDoesNotFitAndKeepsWhatDoes() {
    let operands = [operand(1, mesh: 0, x: 0), operand(2, mesh: 1, x: 5), operand(3, mesh: 0, x: 9)]
    let ghost = ViewportGhost(operands: operands, meshes: [0: triangle, 1: square], limit: 6)
    #expect(ghost.omitted == 1)
    #expect(ghost.mesh?.positions.map(\.x) == [0, 1, 0, 9, 10, 9])
}

@Test func anOversizedGhostIsEmptyAndSaysSo() {
    let ghost = ViewportGhost(operands: [operand(1, mesh: 1, x: 0)], meshes: [1: square], limit: 3)
    #expect(ghost.mesh == nil)
    #expect(ghost.omitted == 1)
}

@Test func onlyAnInvertibleFrameTakesAHandle() {
    let flattened = simd_double4x4(diagonal: SIMD4(0, 1, 1, 1))
    let sheared = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
    let nonfinite = simd_double4x4(diagonal: SIMD4(.infinity, 1, 1, 1))
    #expect(matrix_identity_double4x4.isInvertibleFrame)
    #expect(simd_double4x4(diagonal: SIMD4(2, -3, 4, 1)).isInvertibleFrame)
    #expect(simd_double4x4(diagonal: SIMD4(0.001, 0.001, 0.001, 1)).isInvertibleFrame)
    #expect(!flattened.isInvertibleFrame)
    #expect(!sheared.isInvertibleFrame)
    #expect(!nonfinite.isInvertibleFrame)
}
