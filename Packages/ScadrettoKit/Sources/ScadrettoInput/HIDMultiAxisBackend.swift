import Foundation
import IOKit.hid
import os

/// Reads 3D mice directly as HID multi-axis controllers, for Macs without the
/// 3Dconnexion driver.
///
/// Matching devices are discovered without opening them, so a Mac without a
/// 3D mouse never sees a permission request. While Scadretto is active it
/// opens each one exclusively: macOS would otherwise move the pointer with the
/// cap. When Scadretto resigns active it closes them again for other programs.
/// Opening may need the Input Monitoring permission; macOS asks once, and the
/// status explains a refusal.
@MainActor
final class HIDMultiAxisBackend: ThreeDMouseBackend {
    private enum Usage {
        static let genericDesktopPage: UInt32 = 0x01
        static let multiAxisController: UInt32 = 0x08
        static let firstAxis: UInt32 = 0x30          // X; Y, Z, Rx, Ry and Rz follow
        static let buttonPage: UInt32 = 0x09
    }

    private enum Result {
        static let success: IOReturn = 0
        static let exclusiveAccess = IOReturn(bitPattern: 0xE000_02C5)
        static let notPermitted = IOReturn(bitPattern: 0xE000_02E2)
    }

    /// How opening a device turned out.
    private enum Access: Equatable {
        case closed
        case open
        case busy
        case refused
        case failed(IOReturn)
    }

    private struct Device {
        let handle: IOHIDDevice
        let name: String
        var access = Access.closed
    }

    private static let log = Logger(subsystem: "ch.lkmc.Scadretto", category: "3DMouse")

    weak var sink: ThreeDMouseSink?
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var devices: [Device] = []
    private var axes = [Double](repeating: 0, count: ThreeDMouseAxes.count)
    private var buttons: UInt32 = 0
    private var active = false
    private var started = false

    func start() -> ThreeDMouseStatus {
        guard !started else { return status }
        started = true
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: Usage.genericDesktopPage,
            kIOHIDDeviceUsageKey: Usage.multiAxisController,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let backend = Unmanaged<HIDMultiAxisBackend>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { backend.matched(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let backend = Unmanaged<HIDMultiAxisBackend>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { backend.removed(device) }
        }, context)
        // The manager hands every device it creates this callback, so values
        // arrive from each device opened below.
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, sender, value in
            guard let context else { return }
            let backend = Unmanaged<HIDMultiAxisBackend>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { backend.received(value, from: sender) }
        }, context)
        // Common modes keep values flowing during menu and resize tracking.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        return status
    }

    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        for index in devices.indices {
            if active { open(at: index) } else { close(at: index) }
        }
        if !active { clearReadings() }
        sink?.status(status)
    }

    func stop() {
        guard started else { return }
        setActive(false)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        devices = []
        started = false
    }

    /// The most useful report wins: a working device, then the reason none works.
    private var status: ThreeDMouseStatus {
        let ranked = devices.map { device -> (rank: Int, status: ThreeDMouseStatus) in
            switch device.access {
            case .open: (0, .connected(device.name))
            case .refused: (1, .needsPermission(device.name))
            case .busy: (2, .busy(device.name))
            case .failed(let code):
                (3, .failed("Scadretto could not open \(device.name) (error 0x\(String(UInt32(bitPattern: code), radix: 16)))."))
            case .closed: (4, .connected(device.name))
            }
        }
        return ranked.min { $0.rank < $1.rank }?.status ?? .noDevice
    }

    private func matched(_ handle: IOHIDDevice) {
        guard !devices.contains(where: { $0.handle == handle }) else { return }
        let name = IOHIDDeviceGetProperty(handle, kIOHIDProductKey as CFString) as? String ?? "3D mouse"
        devices.append(Device(handle: handle, name: name))
        Self.log.info("Found the multi-axis controller \(name, privacy: .public)")
        if active { open(at: devices.count - 1) }
        sink?.status(status)
    }

    private func removed(_ handle: IOHIDDevice) {
        guard let index = devices.firstIndex(where: { $0.handle == handle }) else { return }
        devices.remove(at: index)
        clearReadings()
        sink?.status(status)
    }

    private func open(at index: Int) {
        guard devices[index].access != .open else { return }
        let result = IOHIDDeviceOpen(devices[index].handle, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        switch result {
        case Result.success:
            devices[index].access = .open
        case Result.exclusiveAccess:
            devices[index].access = .busy
        case Result.notPermitted:
            devices[index].access = .refused
            // Shows the system's Input Monitoring request the first time; later
            // it only reports the user's answer, which takes effect on relaunch.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        default:
            devices[index].access = .failed(result)
        }
        if result != Result.success {
            Self.log.error("Could not open \(self.devices[index].name, privacy: .public): \(result)")
        }
    }

    private func close(at index: Int) {
        if devices[index].access == .open {
            IOHIDDeviceClose(devices[index].handle, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        // A refusal stays on record so the status keeps explaining it.
        if devices[index].access != .refused { devices[index].access = .closed }
    }

    private func clearReadings() {
        axes = [Double](repeating: 0, count: ThreeDMouseAxes.count)
        buttons = 0
        sink?.reset()
    }

    private func received(_ value: IOHIDValue, from sender: UnsafeMutableRawPointer?) {
        guard active else { return }
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let reading = IOHIDValueGetIntegerValue(value)
        switch page {
        case Usage.genericDesktopPage where (Usage.firstAxis..<Usage.firstAxis + 6).contains(usage):
            let fullScale = max(abs(IOHIDElementGetLogicalMin(element)), abs(IOHIDElementGetLogicalMax(element)))
            axes[Int(usage - Usage.firstAxis)] = ThreeDMouseAxes.normalized(reading, fullScale: fullScale)
            sink?.axes(axes)
        case Usage.buttonPage where (1...32).contains(usage):
            let bit: UInt32 = 1 << (usage - 1)
            let pressed = reading != 0 ? buttons | bit : buttons & ~bit
            guard pressed != buttons else { return }
            buttons = pressed
            sink?.buttons(buttons)
        default:
            break
        }
    }
}
