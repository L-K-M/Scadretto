import Darwin
import Foundation
import os

/// One device state message from the 3Dconnexion driver.
///
/// The driver passes a 48-byte record, packed to two-byte alignment. This
/// reads only the fields Scadretto uses, by offset, so no Swift struct layout
/// has to match the driver's.
struct ConnexionMessage: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        /// Six axis readings: translation x, y, z, then rotation x, y, z.
        case axes([Int16])
        /// The pressed buttons, one bit per button.
        case buttons(UInt32)
        /// A command Scadretto does not handle.
        case other
    }

    /// The registered client the record is for. The driver sends every record
    /// to all its clients.
    let client: UInt16
    let content: Content

    init(client: UInt16, content: Content) {
        self.client = client
        self.content = content
    }

    static let size = 48
    private static let clientOffset = 2
    private static let commandOffset = 4
    private static let axesOffset = 30
    private static let buttonsOffset = 44
    private static let buttonsCommand: UInt16 = 2
    private static let axesCommand: UInt16 = 3

    /// Returns nil when `bytes` is shorter than a device state record.
    init?(bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= Self.size else { return nil }
        client = bytes.loadUnaligned(fromByteOffset: Self.clientOffset, as: UInt16.self)
        switch bytes.loadUnaligned(fromByteOffset: Self.commandOffset, as: UInt16.self) {
        case Self.axesCommand:
            content = .axes((0..<ThreeDMouseAxes.count).map {
                bytes.loadUnaligned(fromByteOffset: Self.axesOffset + 2 * $0, as: Int16.self)
            })
        case Self.buttonsCommand:
            content = .buttons(bytes.loadUnaligned(fromByteOffset: Self.buttonsOffset, as: UInt32.self))
        default:
            content = .other
        }
    }
}

/// Reads a 3D mouse through the 3Dconnexion driver (3DxWare), which takes the
/// device for itself whenever it is installed.
///
/// The driver's client framework is loaded at run time, so Scadretto neither
/// links nor ships it. Scadretto registers as a client that the driver
/// activates only on request, and requests it while Scadretto is the active
/// application, so the device keeps working in other applications. As a
/// take-over client it receives every axis and button, and the driver runs
/// none of its own button assignments meanwhile.
@MainActor
final class ConnexionDriverBackend: ThreeDMouseBackend {
    static let frameworkPath = "/Library/Frameworks/3DconnexionClient.framework/3DconnexionClient"

    /// The driver's axis readings span about this much either way at full
    /// deflection before its own speed settings scale them.
    static let fullScale = 350
    /// The driver applies the user's 3DxWare speed settings, which can exceed
    /// full scale; readings are kept proportional up to this limit.
    static let readingLimit = 4.0

    private typealias MessageHandler = @convention(c) (UInt32, UInt32, UnsafeMutableRawPointer?) -> Void
    private typealias DeviceHandler = @convention(c) (UInt32) -> Void
    private typealias SetHandlers = @convention(c) (MessageHandler?, DeviceHandler?, DeviceHandler?, Bool) -> Int16
    private typealias Cleanup = @convention(c) () -> Void
    private typealias Register = @convention(c) (UInt32, UnsafeMutablePointer<UInt8>?, UInt16, UInt32) -> UInt16
    private typealias SetButtonMask = @convention(c) (UInt16, UInt32) -> Void
    private typealias Unregister = @convention(c) (UInt16) -> Void
    private typealias Control = @convention(c) (UInt16, UInt32, Int32, UnsafeMutablePointer<Int32>?) -> Int16

    /// The client framework's entry points Scadretto calls.
    private struct API {
        let setHandlers: SetHandlers
        let cleanup: Cleanup
        let register: Register
        let setButtonMask: SetButtonMask
        let unregister: Unregister
        let control: Control
    }

    /// The four-character codes of the driver's messages and requests.
    private enum Code {
        static let deviceStateMessage: UInt32 = 0x3364_5352      // '3dSR'
        static let activateClient: UInt32 = 0x3364_6163          // '3dac'
        static let deactivateClient: UInt32 = 0x3364_6463        // '3ddc'
        /// Registers a client the driver activates only on request ('++++').
        static let manualClient: UInt32 = 0x2B2B_2B2B
    }

    private static let takeOverMode: UInt16 = 1
    private static let allControls: UInt32 = 0x3FFF
    private static let allButtons: UInt32 = 0xFFFF_FFFF
    private static let clientName = "Scadretto"
    private static let log = Logger(subsystem: "ch.lkmc.Scadretto", category: "3DMouse")

    /// The backend that receives the driver's callbacks, which carry no context.
    private static weak var current: ConnexionDriverBackend?

    weak var sink: ThreeDMouseSink?
    private let api: API
    private var clientID: UInt16 = 0
    private var clientName: UnsafeMutablePointer<UInt8>?

    private init(api: API) {
        self.api = api
    }

    /// The outcome of looking for the driver's client framework.
    enum Availability {
        case notInstalled
        case unusable(String)
        case available(ConnexionDriverBackend)
    }

    /// Loads the client framework. The process keeps it loaded, because the
    /// driver may still call into it.
    static func load(path: String = frameworkPath) -> Availability {
        guard FileManager.default.fileExists(atPath: path) else { return .notInstalled }
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            log.error("Could not load the 3Dconnexion client framework: \(reason, privacy: .public)")
            return .unusable(reason)
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let setHandlers = symbol("SetConnexionHandlers", as: SetHandlers.self),
              let cleanup = symbol("CleanupConnexionHandlers", as: Cleanup.self),
              let register = symbol("RegisterConnexionClient", as: Register.self),
              let setButtonMask = symbol("SetConnexionClientButtonMask", as: SetButtonMask.self),
              let unregister = symbol("UnregisterConnexionClient", as: Unregister.self),
              let control = symbol("ConnexionClientControl", as: Control.self) else {
            return .unusable("The 3Dconnexion client framework lacks a required function.")
        }
        return .available(ConnexionDriverBackend(api: API(
            setHandlers: setHandlers, cleanup: cleanup, register: register,
            setButtonMask: setButtonMask, unregister: unregister, control: control)))
    }

    func start() -> ThreeDMouseStatus {
        Self.current = self
        // Without a separate thread the driver calls back on this, the main, thread.
        let result = api.setHandlers(Self.messageHandler, Self.addedHandler, Self.removedHandler, false)
        guard result == 0 else {
            Self.current = nil
            return .failed("The 3Dconnexion driver did not accept Scadretto as a client (error \(result)).")
        }
        let name = Self.pascalString(Self.clientName)
        clientName = name
        clientID = api.register(Code.manualClient, name, Self.takeOverMode, Self.allControls)
        guard clientID != 0 else {
            stop()
            return .failed("The 3Dconnexion driver did not register Scadretto as a client.")
        }
        api.setButtonMask(clientID, Self.allButtons)
        Self.log.info("Registered with the 3Dconnexion driver as client \(self.clientID)")
        // The driver's device query names a device even when none is plugged in, so
        // presence stays unknown until the driver reports a device arriving or leaving.
        return .driver(deviceConnected: nil)
    }

    func setActive(_ active: Bool) {
        guard clientID != 0 else { return }
        var result: Int32 = 0
        _ = api.control(clientID, active ? Code.activateClient : Code.deactivateClient, 0, &result)
    }

    func stop() {
        if clientID != 0 {
            api.unregister(clientID)
            clientID = 0
        }
        if Self.current === self {
            api.cleanup()
            Self.current = nil
        }
        if let clientName {
            clientName.deallocate()
            self.clientName = nil
        }
    }

    private func receive(_ message: ConnexionMessage) {
        // Another client's record, such as a second Scadretto's, is not ours to act on.
        guard clientID != 0, message.client == clientID else { return }
        switch message.content {
        case .axes(let axes):
            sink?.axes(axes.map {
                ThreeDMouseAxes.normalized(Int($0), fullScale: Self.fullScale, limit: Self.readingLimit)
            })
        case .buttons(let buttons):
            sink?.buttons(buttons)
        case .other:
            break
        }
    }

    private func deviceChanged(connected: Bool) {
        Self.log.info("The 3Dconnexion driver reports a device \(connected ? "added" : "removed")")
        if !connected { sink?.reset() }
        sink?.status(.driver(deviceConnected: connected))
    }

    /// A length-prefixed name, as the driver expects, that outlives the
    /// registration.
    static func pascalBytes(_ name: String) -> [UInt8] {
        let bytes = Array(name.utf8.prefix(Int(UInt8.max)))
        return [UInt8(bytes.count)] + bytes
    }

    private static func pascalString(_ name: String) -> UnsafeMutablePointer<UInt8> {
        let bytes = pascalBytes(name)
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        pointer.initialize(from: bytes, count: bytes.count)
        return pointer
    }

    private static let messageHandler: MessageHandler = { _, type, argument in
        guard type == Code.deviceStateMessage, let argument,
              let message = ConnexionMessage(bytes: UnsafeRawBufferPointer(start: argument,
                                                                           count: ConnexionMessage.size))
        else { return }
        onMain { current?.receive(message) }
    }

    private static let addedHandler: DeviceHandler = { _ in onMain { current?.deviceChanged(connected: true) } }
    private static let removedHandler: DeviceHandler = { _ in onMain { current?.deviceChanged(connected: false) } }

    /// The driver calls back on the thread that installed the handlers, the
    /// main thread; anything else is moved there.
    private nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
