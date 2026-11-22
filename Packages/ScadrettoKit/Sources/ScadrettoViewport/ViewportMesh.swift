import Foundation
import simd

/// An accepted evaluation mesh handed to the viewport.
///
/// Positions are final world coordinates in a right-handed, Z-up model space,
/// carried in double precision per the worker wire contract in
/// plan/03-OpenSCAD-Worker.md. `indices` is a flat triangle list; every triple
/// forms one triangle.
public struct ViewportMesh: Equatable, Sendable {
    public let positions: [SIMD3<Double>]
    public let indices: [UInt32]

    public init(positions: [SIMD3<Double>], indices: [UInt32]) {
        self.positions = positions
        self.indices = indices
    }

    public var triangleCount: Int { indices.count / 3 }

    /// World-space axis-aligned bounds, or `nil` for an empty or non-finite mesh.
    public var bounds: ViewportBounds? {
        var bounds: ViewportBounds?
        for position in positions where position.x.isFinite && position.y.isFinite && position.z.isFinite {
            if let current = bounds {
                bounds = current.including(position)
            } else {
                bounds = ViewportBounds(min: position, max: position)
            }
        }
        return bounds
    }
}

/// World-space axis-aligned bounds of a mesh.
public struct ViewportBounds: Equatable, Sendable {
    public var min: SIMD3<Double>
    public var max: SIMD3<Double>

    public init(min: SIMD3<Double>, max: SIMD3<Double>) {
        self.min = min
        self.max = max
    }

    public var center: SIMD3<Double> { (min + max) / 2 }
    public var size: SIMD3<Double> { max - min }

    /// Radius of the enclosing sphere centered at `center`.
    public var radius: Double { simd_length(size) / 2 }

    public func including(_ point: SIMD3<Double>) -> ViewportBounds {
        ViewportBounds(min: simd_min(min, point), max: simd_max(max, point))
    }
}
