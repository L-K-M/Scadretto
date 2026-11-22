import CoreGraphics
import Foundation
import simd

public struct ViewportDiameterHandle: Equatable, Sendable {
    public let id: UUID
    public let center: SIMD3<Double>
    /// A transformed unit step along the authored cylinder's local radius.
    public let radialUnit: SIMD3<Double>
    public let diameter: Double

    public init(id: UUID = UUID(), center: SIMD3<Double>, radialUnit: SIMD3<Double>, diameter: Double) {
        self.id = id
        self.center = center
        self.radialUnit = radialUnit
        self.diameter = diameter
    }

    public func rim(at diameter: Double) -> SIMD3<Double> { center + radialUnit * (diameter / 2) }

    func resized(from start: Double, to end: Double, snap: Double) -> Double? {
        let proposal = diameter + 2 * (end - start)
        guard proposal.isFinite, proposal > 0, proposal != diameter else { return nil }
        // Remove arithmetic noise from projection and unprojection. The
        // numeric field can still accept a user's full-precision input.
        let value: Double
        if snap.isFinite, snap > 0 {
            value = (proposal / snap).rounded() * snap
        } else {
            let decimal = String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), proposal)
            value = Double(decimal) ?? proposal
        }
        return value.isFinite && value > 0 && value != diameter ? value : nil
    }

    func radiusCoordinate(at point: CGPoint, in frame: ViewportTransform) -> Double? {
        let ray = frame.ray(throughViewPoint: point)
        let axisLengthSquared = simd_length_squared(radialUnit)
        let axisAlongRay = simd_dot(radialUnit, ray.direction)
        let denominator = axisLengthSquared - axisAlongRay * axisAlongRay
        guard denominator > axisLengthSquared * 0.01 else { return nil }
        let offset = ray.origin - center
        let alongRay = simd_dot(offset, ray.direction)
        let radius = (simd_dot(offset, radialUnit) - alongRay * axisAlongRay) / denominator
        guard radius.isFinite, radius * axisAlongRay - alongRay >= 0 else { return nil }
        return radius
    }

    func contains(_ point: CGPoint, in frame: ViewportTransform) -> Bool {
        guard let tip = frame.project(rim(at: diameter)), (0...1).contains(tip.z) else { return false }
        return hypot(point.x - tip.x, point.y - tip.y) <= 9
    }
}

/// The cylinder preview uses authored local radial axes at the two ends.
public struct ViewportDiameterGuide: Sendable {
    public let bottom: SIMD3<Double>
    public let top: SIMD3<Double>
    public let radialX: SIMD3<Double>
    public let radialY: SIMD3<Double>

    public init(bottom: SIMD3<Double>, top: SIMD3<Double>, radialX: SIMD3<Double>, radialY: SIMD3<Double>) {
        self.bottom = bottom
        self.top = top
        self.radialX = radialX
        self.radialY = radialY
    }
}

func diameterOverlay(handle: ViewportDiameterHandle, guides: [ViewportDiameterGuide], diameter: Double,
                     transform: ViewportTransform) -> [ViewportVertex] {
    var vertices: [ViewportVertex] = []
    let ghost = SIMD3<Float>(0.31, 0.79, 0.94)
    let grip = SIMD3<Float>(0.80, 0.98, 1)
    func line(_ start: SIMD3<Double>, _ end: SIMD3<Double>, color: SIMD3<Float>) {
        for position in [start, end] {
            let rebased = SIMD3<Float>(position - transform.renderOrigin)
            vertices.append(ViewportVertex(x: rebased.x, y: rebased.y, z: rebased.z,
                                           a: color.x, b: color.y, c: color.z))
        }
    }
    func ring(center: SIMD3<Double>, x: SIMD3<Double>, y: SIMD3<Double>, segments: Int,
              color: SIMD3<Float>) {
        var previous = center + x
        for index in 1...segments {
            let angle = 2 * Double.pi * Double(index) / Double(segments)
            let next = center + x * cos(angle) + y * sin(angle)
            line(previous, next, color: color)
            previous = next
        }
    }

    let radius = diameter / 2
    for guide in guides {
        let x = guide.radialX * radius
        let y = guide.radialY * radius
        ring(center: guide.bottom, x: x, y: y, segments: 32, color: ghost)
        ring(center: guide.top, x: x, y: y, segments: 32, color: ghost)
        for side in [x, -x, y, -y] { line(guide.bottom + side, guide.top + side, color: ghost) }
    }

    let tip = handle.rim(at: diameter)
    guard let screenTip = transform.project(tip), (0...1).contains(screenTip.z),
          handle.radiusCoordinate(at: CGPoint(x: screenTip.x, y: screenTip.y), in: transform) != nil else {
        return vertices
    }
    line(handle.center, tip, color: grip)
    let markerRadius = transform.worldPerPoint * 5
    ring(center: tip, x: transform.camera.right * markerRadius,
         y: transform.camera.screenUp * markerRadius, segments: 16, color: grip)
    return vertices
}
