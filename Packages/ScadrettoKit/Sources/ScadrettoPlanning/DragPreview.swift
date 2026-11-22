import ScadrettoEngineClient
import simd

/// How one affected occurrence moves while a value is dragged.
public struct PreviewMotion: Equatable, Sendable {
    public let instance: UInt32
    /// Travel in that occurrence's own frame for +1 of the dragged, displayed value.
    public let localUnitsPerValue: SIMD3<Double>
}

extension PropertyChoice {
    /// A guide needs the worker's proof for that occurrence and the same literal.
    /// Any other affected use, such as `-d` or `2 * d`, is only highlighted.
    public func previewMotions(affected: [UInt32], instances: [UInt32: InstanceRecord]) -> [PreviewMotion] {
        switch action {
        case .value(_, let edited):
            guard let literal = edited.literalOrigin else { return [] }
            return affected.compactMap { id in
                var travel = SIMD3<Double>.zero
                for use in instances[id]?.properties ?? [] where use.dragVerified && use.literalOrigin == literal {
                    if let pitch = use.pitch {
                        travel.x += pitch.iteration / edited.displayMultiplier
                    } else if let axis = use.semantic.translateAxis {
                        travel[axis.index] += use.displayMultiplier / edited.displayMultiplier
                    }
                }
                return travel == .zero ? nil : PreviewMotion(instance: id, localUnitsPerValue: travel)
            }
        case .offset(_, let edited):
            guard let axis = edited.semantic.translateAxis else { return [] }
            var travel = SIMD3<Double>.zero
            travel[axis.index] = 1
            // An offset's affected set is exactly the executions of that expression.
            return affected.map { PreviewMotion(instance: $0, localUnitsPerValue: travel) }
        case .prefix(_, let axis):
            var travel = SIMD3<Double>.zero
            travel[axis.index] = 1
            return affected.map { PreviewMotion(instance: $0, localUnitsPerValue: travel) }
        }
    }

    /// The occurrences whose rim follows a dragged diameter exactly.
    public func previewRims(affected: [UInt32], instances: [UInt32: InstanceRecord]) -> [UInt32] {
        guard case .value(_, let edited) = action, let literal = edited.literalOrigin else { return [] }
        return affected.filter { id in
            instances[id]?.properties?.contains {
                $0.semantic == .cylinderDiameter && $0.dragVerified && $0.literalOrigin == literal
                    && $0.displayMultiplier == edited.displayMultiplier
            } == true
        }
    }
}
