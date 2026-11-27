import os

/// What the 3D mouse input is doing, for the settings window.
public enum ThreeDMouseStatus: Equatable, Sendable {
    /// Input is switched off.
    case off
    /// The 3Dconnexion driver delivers the input. Whether a device is connected is
    /// nil until the driver reports one arriving or leaving.
    case driver(deviceConnected: Bool?)
    /// No 3D mouse is connected, and the driver is not installed.
    case noDevice
    /// Scadretto reads the named device directly.
    case connected(String)
    /// macOS refused access to the named device; Input Monitoring must allow Scadretto.
    case needsPermission(String)
    /// Another program holds the named device exclusively.
    case busy(String)
    /// Input failed for the stated reason.
    case failed(String)
    /// A constant simulated motion stands in for a device, for tests.
    case simulated
}

/// Receives readings from a backend on the main actor.
@MainActor
protocol ThreeDMouseSink: AnyObject {
    /// Six device readings, each about -1...1, in device axes.
    func axes(_ readings: [Double])
    /// The pressed buttons, one bit per button.
    func buttons(_ pressed: UInt32)
    /// Motion already in view axes, from a simulated device.
    func motion(_ motion: ThreeDMouseMotion)
    /// The device stopped reporting; its readings return to rest.
    func reset()
    func status(_ status: ThreeDMouseStatus)
}

/// One way of reading a 3D mouse.
@MainActor
protocol ThreeDMouseBackend: AnyObject {
    /// The input that owns this backend; hold it weakly.
    var sink: ThreeDMouseSink? { get set }
    func start() -> ThreeDMouseStatus
    /// Called with true while Scadretto is the active application.
    func setActive(_ active: Bool)
    func stop()
}

/// Reads a 3D mouse and reports view motion and button presses while the
/// application is active.
///
/// The 3Dconnexion driver is used when it is installed, because it then holds
/// the device; otherwise multi-axis HID controllers are read directly. Motion
/// returns to zero whenever input stops arriving: on deactivation, on stop and
/// when a device goes away.
@MainActor
public final class ThreeDMouseInput {
    public enum Source: Sendable {
        /// The 3Dconnexion driver when installed, otherwise direct HID.
        case automatic
        /// A constant motion while active, for tests.
        case simulated(ThreeDMouseMotion)
    }

    public var onMotion: ((ThreeDMouseMotion) -> Void)?
    public var onButton: ((ThreeDMouseButton) -> Void)?
    public var onStatusChange: ((ThreeDMouseStatus) -> Void)?
    public private(set) var status = ThreeDMouseStatus.off {
        didSet {
            guard status != oldValue else { return }
            Self.log.info("3D mouse status: \(String(describing: self.status), privacy: .public)")
            onStatusChange?(status)
        }
    }

    private let source: Source
    private let makeBackend: (() -> ThreeDMouseBackend?)?
    private var backend: ThreeDMouseBackend?
    private var active = false
    private var buttons: UInt32 = 0
    private var lastMotion = ThreeDMouseMotion.zero
    private static let log = Logger(subsystem: "ch.lkmc.Scadretto", category: "3DMouse")

    public init(source: Source = .automatic) {
        self.source = source
        makeBackend = nil
    }

    /// Uses `backend` in place of the device backends, for tests.
    init(backend: @escaping () -> ThreeDMouseBackend?) {
        source = .automatic
        makeBackend = backend
    }

    public var isRunning: Bool { backend != nil }

    public func start() {
        guard backend == nil else { return }
        let backend: ThreeDMouseBackend
        if let made = makeBackend?() {
            backend = made
        } else {
            switch chooseBackend() {
            case .success(let chosen): backend = chosen
            case .failure(let error):
                status = error.status
                return
            }
        }
        self.backend = backend
        backend.sink = self
        status = backend.start()
        backend.setActive(active)
    }

    public func stop() {
        backend?.setActive(false)
        backend?.stop()
        backend = nil
        reset()
        status = .off
    }

    /// Call with true while the application is active; input is ignored otherwise.
    public func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        if !active { reset() }
        backend?.setActive(active)
    }

    private func chooseBackend() -> Result<ThreeDMouseBackend, ThreeDMouseStatusError> {
        switch source {
        case .simulated(let motion):
            return .success(SimulatedBackend(motion: motion))
        case .automatic:
            switch ConnexionDriverBackend.load() {
            case .available(let driver):
                return .success(driver)
            case .unusable:
                // The installed driver holds the device, so reading it directly would fail too.
                // The log has the loader's reason.
                return .failure(ThreeDMouseStatusError(.failed(
                    "The 3Dconnexion driver is installed, but Scadretto could not load its client library.")))
            case .notInstalled:
                return .success(HIDMultiAxisBackend())
            }
        }
    }

    private func emit(_ motion: ThreeDMouseMotion) {
        guard motion != lastMotion else { return }
        lastMotion = motion
        onMotion?(motion)
    }
}

/// A status carried as an error, for a backend that cannot start.
struct ThreeDMouseStatusError: Error {
    let status: ThreeDMouseStatus
    init(_ status: ThreeDMouseStatus) { self.status = status }
}

extension ThreeDMouseInput: ThreeDMouseSink {
    func axes(_ readings: [Double]) {
        guard active else { return }
        emit(ThreeDMouseAxes.motion(device: readings))
    }

    func buttons(_ pressed: UInt32) {
        let previous = buttons
        buttons = pressed
        guard active else { return }
        for button in ThreeDMouseButton.newlyPressed(previous: previous, current: pressed) {
            onButton?(button)
        }
    }

    func motion(_ motion: ThreeDMouseMotion) {
        guard active else { return }
        emit(motion)
    }

    func reset() {
        buttons = 0
        emit(.zero)
    }

    func status(_ status: ThreeDMouseStatus) {
        self.status = status
    }
}

/// Reports a constant motion while active, so tests can drive the real
/// application without a device.
@MainActor
final class SimulatedBackend: ThreeDMouseBackend {
    weak var sink: ThreeDMouseSink?
    private let motion: ThreeDMouseMotion

    init(motion: ThreeDMouseMotion) {
        self.motion = motion
    }

    func start() -> ThreeDMouseStatus { .simulated }

    func setActive(_ active: Bool) {
        sink?.motion(active ? motion : .zero)
    }

    func stop() {}
}
