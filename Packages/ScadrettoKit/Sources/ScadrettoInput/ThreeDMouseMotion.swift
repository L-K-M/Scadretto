import simd

/// How the model should move, from one reading of a 3D mouse.
///
/// Both vectors use view axes: x to the right, y up and z toward the viewer.
/// `translation` is the cap's displacement and `rotation` its twist,
/// right-handed about those axes. Each component is about -1...1 at full
/// deflection. The model follows the cap, the usual "object mode" of 3D mice:
/// pushing the cap right moves the model right, and pulling it toward you
/// brings the model closer.
public struct ThreeDMouseMotion: Equatable, Sendable {
    public var translation: SIMD3<Double>
    public var rotation: SIMD3<Double>

    public init(translation: SIMD3<Double> = .zero, rotation: SIMD3<Double> = .zero) {
        self.translation = translation
        self.rotation = rotation
    }

    public static let zero = ThreeDMouseMotion()

    public var isZero: Bool { translation == .zero && rotation == .zero }
}

/// Buttons in the numbering 3Dconnexion uses for both its driver messages and
/// the HID reports of its devices. Two-button devices report `menu` (left) and
/// `fit` (right); larger ones add the view buttons.
public enum ThreeDMouseButton: Int, CaseIterable, Sendable {
    case menu = 0
    case fit = 1
    case top = 2
    case left = 3
    case right = 4
    case front = 5
    case bottom = 6
    case back = 7

    /// The buttons whose bits are set in `current` but not in `previous`.
    /// Bits without a case are ignored.
    public static func newlyPressed(previous: UInt32, current: UInt32) -> [ThreeDMouseButton] {
        let pressed = current & ~previous
        return allCases.filter { pressed & (1 << UInt32($0.rawValue)) != 0 }
    }
}

/// Converts device axis readings into view motion.
public enum ThreeDMouseAxes {
    /// Readings closer to rest than this fraction of full scale count as rest,
    /// so a cap that does not quite center cannot drift the view.
    public static let deadZone = 0.04

    /// Device axes in the order devices report them: translation x, y, z,
    /// then rotation about x, y, z.
    public static let count = 6

    /// Maps six readings, each about -1...1, to view motion.
    ///
    /// 3D mice report x to the right, y toward the user and z down, with
    /// rotations right-handed about those axes. View axes put y up and z
    /// toward the viewer, so device z becomes -y and device y becomes z.
    /// Readings inside the dead zone become 0, and the rest rescale so motion
    /// starts smoothly at its edge.
    public static func motion(device axes: [Double]) -> ThreeDMouseMotion {
        guard axes.count == count else { return .zero }
        let value = axes.map(filtered)
        return ThreeDMouseMotion(
            translation: SIMD3(value[0], -value[2], value[1]),
            rotation: SIMD3(value[3], -value[5], value[4]))
    }

    /// A raw reading as a fraction of `fullScale`, limited to `limit` either way.
    public static func normalized(_ raw: Int, fullScale: Int, limit: Double = 1) -> Double {
        guard fullScale > 0 else { return 0 }
        let value = Double(raw) / Double(fullScale)
        return min(max(value, -limit), limit)
    }

    private static func filtered(_ value: Double) -> Double {
        guard value.isFinite, abs(value) > deadZone else { return 0 }
        return (abs(value) - deadZone) / (1 - deadZone) * (value < 0 ? -1 : 1)
    }
}
