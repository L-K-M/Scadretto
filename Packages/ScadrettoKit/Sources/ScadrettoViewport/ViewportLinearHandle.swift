import CoreGraphics
import Foundation
import simd

/// A low-level linear drag handle for authored translations, dimensions and
/// loop pitches, per the motion rules in plan/02-Source-and-Edits.md.
///
/// The handle knows nothing about scenes or bindings. The caller supplies a
/// world-space `anchor`, the grip's position at the baseline value, and a
/// world `axis`: the grip's displacement for +1 authored local unit, which is
/// the writable local axis transformed by its parent chain and therefore
/// carries the parents' rotation, scale and mirroring. `value` is the model
/// scalar at baseline (a translate component, a dimension or a pitch) and
/// `valuePerUnit` is its change per +1 local unit: 1 for translations and
/// face-anchored dimensions, 2 for symmetric centered resizes, and 1/i for
/// pitch at selected occurrence i ≠ 0 (`newPitch = oldPitch + localDx / i`).
public struct ViewportLinearHandle: Equatable, Sendable {
    /// Stable identity, matched against the scene the gesture started on.
    public let id: UUID
    /// World-space grip position at the baseline value.
    public let anchor: SIMD3<Double>
    /// World displacement of the grip for +1 authored local unit.
    public let axis: SIMD3<Double>
    /// The model scalar at baseline.
    public let value: Double
    /// Change in `value` per +1 authored local unit along `axis`. Must be
    /// finite and nonzero for `point(for:)` to produce a usable position.
    public let valuePerUnit: Double
    /// A drag proposes only values above this, as a dimension requires.
    public let exclusiveMinimum: Double?

    /// View-point distance within which a press grabs the projected grip.
    private static let hitRadius: Double = 9

    public init(id: UUID = UUID(), anchor: SIMD3<Double>, axis: SIMD3<Double>,
                value: Double, valuePerUnit: Double, exclusiveMinimum: Double? = nil) {
        self.exclusiveMinimum = exclusiveMinimum
        self.id = id
        self.anchor = anchor
        self.axis = axis
        self.value = value
        self.valuePerUnit = valuePerUnit
    }

    /// The world position of the grip at a candidate model scalar.
    public func point(for value: Double) -> SIMD3<Double> {
        anchor + axis * ((value - self.value) / valuePerUnit)
    }

    /// The coordinate where the view ray through `point` passes closest to
    /// the handle axis, in authored local units: the `u` in
    /// `anchor + u * axis`. Returns `nil` when the axis is degenerate or too
    /// near the ray direction for a stable projection, when the result is
    /// not finite, or when the closest approach lies behind the ray.
    public func coordinate(at point: CGPoint, in frame: ViewportTransform) -> Double? {
        let ray = frame.ray(throughViewPoint: point)
        let axisLengthSquared = simd_length_squared(axis)
        let axisAlongRay = simd_dot(axis, ray.direction)
        // |axis|² sin²θ: vanishes for a singular transform and as the axis
        // turns edge-on to the ray, where the projected coordinate explodes.
        let denominator = axisLengthSquared - axisAlongRay * axisAlongRay
        guard denominator > axisLengthSquared * 0.01 else { return nil }
        let offset = ray.origin - anchor
        let alongRay = simd_dot(offset, ray.direction)
        let local = (simd_dot(offset, axis) - alongRay * axisAlongRay) / denominator
        guard local.isFinite, local * axisAlongRay - alongRay >= 0 else { return nil }
        return local
    }

    /// The candidate model scalar for a drag whose `coordinate` moved from
    /// `start` at mouse-down to `end`, computed against the immutable
    /// baseline `value`. A positive finite `snap` rounds the candidate to
    /// that interval in model units. Returns `nil` for non-finite results, no
    /// change and values at or below `exclusiveMinimum`.
    public func value(from start: Double, to end: Double, snap: Double) -> Double? {
        let proposal = value + valuePerUnit * (end - start)
        guard proposal.isFinite, proposal != value else { return nil }
        let candidate = draggedValue(proposal, snap: snap)
        if let exclusiveMinimum, candidate <= exclusiveMinimum { return nil }
        return candidate.isFinite && candidate != value ? candidate : nil
    }

    /// Whether the view point grabs the projected baseline grip.
    public func contains(_ point: CGPoint, in frame: ViewportTransform) -> Bool {
        guard let grip = frame.project(anchor), (0...1).contains(grip.z) else { return false }
        return hypot(point.x - grip.x, point.y - grip.y) <= Self.hitRadius
    }
}

/// The value a drag proposes, at the snap increment when there is one.
/// Twelve digits drop projection and multiplication noise, and zero has no sign.
func draggedValue(_ proposal: Double, snap: Double) -> Double {
    let stepped = snap.isFinite && snap > 0 ? (proposal / snap).rounded() * snap : proposal
    let decimal = String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), stepped)
    let value = Double(decimal) ?? stepped
    return value == 0 ? 0 : value
}

/// A draft marker for another occurrence affected by a scalar edit.
public struct ViewportLinearGuide: Equatable, Sendable {
    public let anchor: SIMD3<Double>
    public let worldUnitsPerValue: SIMD3<Double>

    public init(anchor: SIMD3<Double>, worldUnitsPerValue: SIMD3<Double>) {
        self.anchor = anchor
        self.worldUnitsPerValue = worldUnitsPerValue
    }
}

public enum ViewportEditHandle: Equatable, Sendable {
    case diameter(ViewportDiameterHandle)
    case linear(ViewportLinearHandle)

    public var id: UUID {
        switch self {
        case .diameter(let handle): handle.id
        case .linear(let handle): handle.id
        }
    }

    func contains(_ point: CGPoint, in frame: ViewportTransform) -> Bool {
        switch self {
        case .diameter(let handle): handle.contains(point, in: frame)
        case .linear(let handle): handle.contains(point, in: frame)
        }
    }

    func coordinate(at point: CGPoint, in frame: ViewportTransform) -> Double? {
        switch self {
        case .diameter(let handle): handle.radiusCoordinate(at: point, in: frame)
        case .linear(let handle): handle.coordinate(at: point, in: frame)
        }
    }

    func value(from start: Double, to end: Double, snap: Double) -> Double? {
        switch self {
        case .diameter(let handle): handle.resized(from: start, to: end, snap: snap)
        case .linear(let handle): handle.value(from: start, to: end, snap: snap)
        }
    }
}

func linearOverlay(handle: ViewportLinearHandle, guides: [ViewportLinearGuide], value: Double,
                   transform: ViewportTransform) -> [ViewportVertex] {
    let tip = handle.point(for: value)
    guard let point = transform.project(tip) else { return [] }
    let right = transform.worldPoint(atViewPoint: CGPoint(x: point.x + 6, y: point.y), depth: point.z) - tip
    let up = transform.worldPoint(atViewPoint: CGPoint(x: point.x, y: point.y - 6), depth: point.z) - tip
    let displacement = value - handle.value
    let accent = SIMD3<Float>(0.81, 0.97, 1)
    let guideColor = SIMD3<Float>(0.31, 0.79, 0.94)
    var vertices: [ViewportVertex] = []
    func line(_ a: SIMD3<Double>, _ b: SIMD3<Double>, color: SIMD3<Float>) {
        for world in [a, b] {
            let position = SIMD3<Float>(world - transform.renderOrigin)
            vertices.append(ViewportVertex(x: position.x, y: position.y, z: position.z,
                                           a: color.x, b: color.y, c: color.z))
        }
    }
    for guide in guides {
        let moved = guide.anchor + guide.worldUnitsPerValue * displacement
        line(guide.anchor, moved, color: guideColor)
        line(moved - right * 0.5, moved + right * 0.5, color: guideColor)
        line(moved - up * 0.5, moved + up * 0.5, color: guideColor)
    }
    if let local = handle.coordinate(at: CGPoint(x: point.x, y: point.y), in: transform), local.isFinite {
        let along = simd_normalize(handle.axis) * simd_length(right)
        line(tip - along * 2, tip + along, color: accent)
        let corners = [tip + right, tip + up, tip - right, tip - up, tip + right]
        for index in 0..<4 { line(corners[index], corners[index + 1], color: accent) }
    }
    return vertices
}
