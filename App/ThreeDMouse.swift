import AppKit
import os
import ScadrettoInput
import ScadrettoViewport

/// Drives the frontmost document's viewport from a 3D mouse, and keeps its
/// settings: whether input is on and how fast it moves the view.
///
/// Motion goes to the viewport of the frontmost document window, so the
/// device keeps working while the Settings window is in front. The device
/// buttons run view commands: Fit frames the model, the view buttons of larger
/// devices pick standard views, and Menu returns to the opening view.
@MainActor
final class ThreeDMouseController {
    static let shared = ThreeDMouseController()
    static let statusDidChange = Notification.Name("ScadrettoThreeDMouseStatusDidChange")
    static let speedRange: ClosedRange<Double> = 0.25...4

    private enum Key {
        static let enabled = "threeDMouseEnabled"
        static let speed = "threeDMouseSpeed"
        /// Hidden: six numbers, translation then rotation in view axes. A constant simulated
        /// motion replaces the device, so UI tests can drive the real application.
        static let simulatedMotion = "ScadrettoSimulated3DMouse"
    }

    private static let log = Logger(subsystem: "com.lkm.Scadretto", category: "3DMouse")
    private let defaults = UserDefaults.standard
    private let input: ThreeDMouseInput
    private weak var target: ViewportView?
    private var motion = ThreeDMouseMotion.zero
    private var observers: [any NSObjectProtocol] = []

    private init() {
        defaults.register(defaults: [Key.enabled: true, Key.speed: 1.0])
        input = ThreeDMouseInput(source: Self.simulatedMotion(defaults.string(forKey: Key.simulatedMotion))
            .map { .simulated($0) } ?? .automatic)
        input.onMotion = { [weak self] motion in self?.move(motion) }
        input.onButton = { [weak self] button in self?.press(button) }
        input.onStatusChange = { _ in
            NotificationCenter.default.post(name: ThreeDMouseController.statusDidChange, object: nil)
        }
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set {
            defaults.set(newValue, forKey: Key.enabled)
            applyEnabled()
        }
    }

    var speed: Double {
        get {
            let stored = defaults.double(forKey: Key.speed)
            return stored.isFinite && stored > 0 ? min(max(stored, Self.speedRange.lowerBound), Self.speedRange.upperBound) : 1
        }
        set {
            guard newValue.isFinite else { return }
            defaults.set(min(max(newValue, Self.speedRange.lowerBound), Self.speedRange.upperBound), forKey: Key.speed)
            move(motion)
        }
    }

    var status: ThreeDMouseStatus { input.status }

    /// Returns the settings to their defaults, for UI tests.
    static func resetSettings() {
        for key in [Key.enabled, Key.speed] { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Starts input and follows the application's activation and window order.
    func start() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name,
                     _ action: @escaping @MainActor (ThreeDMouseController, NSWindow?) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated { action(ThreeDMouseController.shared, window) }
            })
        }
        observe(NSApplication.didBecomeActiveNotification) { controller, _ in controller.input.setActive(true) }
        observe(NSApplication.didResignActiveNotification) { controller, _ in controller.input.setActive(false) }
        // A held cap keeps reporting the same reading, so the current motion moves to a
        // document window that comes to the front, and leaves one that closes.
        observe(NSWindow.didBecomeMainNotification) { controller, window in
            controller.move(controller.motion, preferring: window)
        }
        observe(NSWindow.willCloseNotification) { controller, window in
            guard let window, controller.target?.window === window else { return }
            controller.target?.setNavigationMotion(.zero)
            controller.target = nil
            // The window is still listed until it has closed.
            DispatchQueue.main.async { MainActor.assumeIsolated { controller.move(controller.motion) } }
        }
        applyEnabled()
    }

    /// Releases the device and the driver registration.
    func stop() {
        input.stop()
    }

    private func applyEnabled() {
        if isEnabled {
            input.start()
            input.setActive(NSApp.isActive)
        } else {
            input.stop()
        }
    }

    private func move(_ motion: ThreeDMouseMotion, preferring window: NSWindow? = nil) {
        self.motion = motion
        let viewport = viewport(of: window) ?? frontmostViewport()
        if target !== viewport {
            target?.setNavigationMotion(.zero)
            Self.log.debug("3D mouse moves \(viewport?.window?.title ?? "no window", privacy: .public)")
        }
        target = viewport
        let speed = self.speed
        viewport?.setNavigationMotion(ViewportMotion(translation: motion.translation * speed,
                                                     rotation: motion.rotation * speed))
    }

    private func press(_ button: ThreeDMouseButton) {
        guard let viewport = frontmostViewport() else { return }
        switch button {
        case .menu:
            viewport.setStandardView(.diagonal)
            viewport.frameAll()
        case .fit: viewport.frameAll()
        case .top: viewport.setStandardView(.top)
        case .left: viewport.setStandardView(.left)
        case .right: viewport.setStandardView(.right)
        case .front: viewport.setStandardView(.front)
        case .bottom: viewport.setStandardView(.bottom)
        case .back: viewport.setStandardView(.back)
        }
    }

    private func frontmostViewport() -> ViewportView? {
        NSApp.orderedWindows.lazy
            .filter { $0.isVisible && !$0.isMiniaturized }
            .compactMap { self.viewport(of: $0) }
            .first
    }

    private func viewport(of window: NSWindow?) -> ViewportView? {
        (window?.windowController as? SourceWindowController)?.previewWorkspace.viewport
    }

    /// Parses six space-separated numbers, or returns nil.
    static func simulatedMotion(_ text: String?) -> ThreeDMouseMotion? {
        guard let values = text?.split(separator: " ").compactMap({ Double($0) }), values.count == 6,
              values.allSatisfy(\.isFinite) else { return nil }
        return ThreeDMouseMotion(translation: SIMD3(values[0], values[1], values[2]),
                                 rotation: SIMD3(values[3], values[4], values[5]))
    }

    /// A sentence for the settings window.
    static func describe(_ status: ThreeDMouseStatus) -> String {
        switch status {
        case .off:
            "3D mouse input is off."
        case .driver(deviceConnected: nil):
            "Using the 3Dconnexion driver."
        case .driver(deviceConnected: true):
            "A 3D mouse is connected through the 3Dconnexion driver."
        case .driver(deviceConnected: false):
            "The 3Dconnexion driver reports no 3D mouse."
        case .noDevice:
            "No 3D mouse is connected."
        case .connected(let name):
            "\(name) is connected."
        case .needsPermission(let name):
            "macOS has not allowed Scadretto to read \(name). Allow Scadretto in System Settings under "
                + "Privacy & Security > Input Monitoring, then reopen Scadretto."
        case .busy(let name):
            "Another program is using \(name). Quit it, then switch back to Scadretto."
        case .failed(let reason):
            reason
        case .simulated:
            "A simulated 3D mouse is moving the view."
        }
    }
}

/// The Settings window's 3D mouse controls: on or off, speed and status.
@MainActor
final class ThreeDMouseSettingsSection: NSStackView {
    private let controller: ThreeDMouseController
    private let enabled = NSButton(checkboxWithTitle: "Move the view with a 3D mouse", target: nil, action: nil)
    private let slider = NSSlider()
    private let speedLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var statusObserver: (any NSObjectProtocol)?

    init(controller: ThreeDMouseController = .shared) {
        self.controller = controller
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: "3D mouse")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        enabled.target = self
        enabled.action = #selector(enabledChanged(_:))
        enabled.setAccessibilityIdentifier("threeDMouseEnabled")

        // The slider runs over powers of two, so each step doubles or halves the speed.
        slider.minValue = log2(ThreeDMouseController.speedRange.lowerBound)
        slider.maxValue = log2(ThreeDMouseController.speedRange.upperBound)
        slider.target = self
        slider.action = #selector(speedChanged(_:))
        slider.setAccessibilityIdentifier("threeDMouseSpeed")
        slider.setAccessibilityLabel("3D mouse speed")
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        speedLabel.setAccessibilityIdentifier("threeDMouseSpeedValue")
        let speedRow = NSStackView(views: [NSTextField(labelWithString: "Speed:"), slider, speedLabel])

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("threeDMouseStatus")

        for view in [heading, enabled, speedRow, statusLabel] { addArrangedSubview(view) }
        orientation = .vertical
        alignment = .leading
        spacing = 8
        reload()
        statusObserver = NotificationCenter.default.addObserver(
            forName: ThreeDMouseController.statusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func reload() {
        enabled.state = controller.isEnabled ? .on : .off
        slider.doubleValue = log2(controller.speed)
        slider.isEnabled = controller.isEnabled
        speedLabel.stringValue = Self.format(controller.speed)
        slider.setAccessibilityValueDescription(speedLabel.stringValue)
        statusLabel.stringValue = ThreeDMouseController.describe(controller.status)
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        controller.isEnabled = sender.state == .on
        reload()
    }

    @objc private func speedChanged(_ sender: NSSlider) {
        controller.speed = pow(2, sender.doubleValue)
        reload()
    }

    private static func format(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
