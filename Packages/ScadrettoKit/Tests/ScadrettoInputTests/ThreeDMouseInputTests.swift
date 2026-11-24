import Foundation
import XCTest
@testable import ScadrettoInput

/// Device decoding, axis mapping and the activation rules of 3D mouse input.
/// No device is needed: a fake backend stands in for the driver and HID paths.
@MainActor
final class ThreeDMouseInputTests: XCTestCase {
    // MARK: Axis mapping

    func testDeviceAxesMapToViewAxes() {
        // Device: x right, y toward the user, z down; rotations right-handed about those.
        XCTAssertEqual(ThreeDMouseAxes.motion(device: [1, 0, 0, 0, 0, 0]).translation, SIMD3(1, 0, 0))
        XCTAssertEqual(ThreeDMouseAxes.motion(device: [0, 0, -1, 0, 0, 0]).translation, SIMD3(0, 1, 0),
                       "Lifting the cap moves the model up")
        XCTAssertEqual(ThreeDMouseAxes.motion(device: [0, 1, 0, 0, 0, 0]).translation, SIMD3(0, 0, 1),
                       "Pulling the cap toward the user brings the model closer")
        XCTAssertEqual(ThreeDMouseAxes.motion(device: [0, 0, 0, 1, 0, 0]).rotation, SIMD3(1, 0, 0))
        XCTAssertEqual(ThreeDMouseAxes.motion(device: [0, 0, 0, 0, 0, -1]).rotation, SIMD3(0, 1, 0),
                       "Twisting the cap counterclockwise from above turns the model the same way")
        XCTAssertEqual(ThreeDMouseAxes.motion(device: [0, 0, 0, 0, 1, 0]).rotation, SIMD3(0, 0, 1))
    }

    func testDeadZoneRestsAndRescales() {
        let rest = ThreeDMouseAxes.motion(device: [0.03, -0.04, 0.02, 0, -0.01, 0.039])
        XCTAssertTrue(rest.isZero, "Readings inside the dead zone must not move the view")
        let half = ThreeDMouseAxes.motion(device: [0.52, 0, 0, 0, 0, 0]).translation.x
        XCTAssertEqual(half, 0.5, accuracy: 1e-12)
        XCTAssertEqual(ThreeDMouseAxes.motion(device: [-1, 0, 0, 0, 0, 0]).translation.x, -1)
    }

    func testMalformedReadingsDoNotMove() {
        XCTAssertTrue(ThreeDMouseAxes.motion(device: [1, 1, 1]).isZero)
        XCTAssertTrue(ThreeDMouseAxes.motion(device: [.nan, .infinity, 0, 0, 0, 0]).isZero)
    }

    func testNormalizationClampsToTheLimit() {
        XCTAssertEqual(ThreeDMouseAxes.normalized(350, fullScale: 350), 1)
        XCTAssertEqual(ThreeDMouseAxes.normalized(-175, fullScale: 350), -0.5)
        XCTAssertEqual(ThreeDMouseAxes.normalized(512, fullScale: 350), 1, "HID readings past full scale clamp")
        XCTAssertEqual(ThreeDMouseAxes.normalized(700, fullScale: 350, limit: 4), 2)
        XCTAssertEqual(ThreeDMouseAxes.normalized(10, fullScale: 0), 0)
    }

    // MARK: Buttons

    func testOnlyNewlyPressedButtonsReport() {
        XCTAssertEqual(ThreeDMouseButton.newlyPressed(previous: 0b01, current: 0b11), [.fit])
        XCTAssertEqual(ThreeDMouseButton.newlyPressed(previous: 0b11, current: 0b01), [])
        XCTAssertEqual(ThreeDMouseButton.newlyPressed(previous: 0, current: 0b10_0100), [.top, .front])
        XCTAssertEqual(ThreeDMouseButton.newlyPressed(previous: 0, current: 1 << 20), [],
                       "Buttons without an action are ignored")
    }

    // MARK: Driver messages

    private func driverRecord(client: UInt16 = 7, command: UInt16, axes: [Int16] = [], buttons: UInt32 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 48)
        func store<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(offset..<offset + $0.count, with: $0) }
        }
        store(UInt16(0x6D33), at: 0)
        store(client, at: 2)
        store(command, at: 4)
        for (index, axis) in axes.enumerated() { store(axis, at: 30 + 2 * index) }
        store(buttons, at: 44)
        return bytes
    }

    func testDriverAxisRecordDecodes() {
        let bytes = driverRecord(command: 3, axes: [10, -20, 350, -350, 1, -1])
        let message = bytes.withUnsafeBytes { ConnexionMessage(bytes: $0) }
        XCTAssertEqual(message, ConnexionMessage(client: 7, content: .axes([10, -20, 350, -350, 1, -1])))
    }

    func testDriverButtonRecordDecodes() {
        let bytes = driverRecord(client: 4096, command: 2, buttons: 0x8000_0002)
        XCTAssertEqual(bytes.withUnsafeBytes { ConnexionMessage(bytes: $0) },
                       ConnexionMessage(client: 4096, content: .buttons(0x8000_0002)))
    }

    func testDriverRecordsOfOtherKindsOrSizesAreIgnored() {
        XCTAssertEqual(driverRecord(command: 10).withUnsafeBytes { ConnexionMessage(bytes: $0) }?.content, .other)
        let short = Array(driverRecord(command: 3, axes: [1, 2, 3, 4, 5, 6]).prefix(47))
        XCTAssertNil(short.withUnsafeBytes { ConnexionMessage(bytes: $0) })
    }

    func testDriverClientNameIsLengthPrefixed() {
        XCTAssertEqual(ConnexionDriverBackend.pascalBytes("Scadretto"), [9] + Array("Scadretto".utf8))
        XCTAssertEqual(ConnexionDriverBackend.pascalBytes(String(repeating: "a", count: 300)).count, 256)
    }

    func testDriverFrameworkIsOptional() throws {
        guard case .notInstalled = ConnexionDriverBackend.load(path: "/nonexistent/3DconnexionClient") else {
            return XCTFail("A missing framework must leave the HID path available")
        }
        let notLibrary = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-framework-\(UUID())")
        try Data("text".utf8).write(to: notLibrary)
        defer { try? FileManager.default.removeItem(at: notLibrary) }
        guard case .unusable = ConnexionDriverBackend.load(path: notLibrary.path) else {
            return XCTFail("A framework that fails to load must say why")
        }
    }

    /// Resolves the client functions in the installed 3DxWare framework.
    /// Skipped on Macs without the driver, such as CI runners.
    func testInstalledDriverFrameworkProvidesTheClientFunctions() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ConnexionDriverBackend.frameworkPath),
                          "3DxWare is not installed")
        switch ConnexionDriverBackend.load() {
        case .available: break
        case .unusable(let reason): XCTFail(reason)
        case .notInstalled: XCTFail("The framework vanished")
        }
    }

    // MARK: Activation

    private final class FakeBackend: ThreeDMouseBackend {
        var sink: ThreeDMouseSink?
        var activeCalls: [Bool] = []
        var stopped = false
        func start() -> ThreeDMouseStatus { .connected("Fake") }
        func setActive(_ active: Bool) { activeCalls.append(active) }
        func stop() { stopped = true }
    }

    private struct Recording {
        var motions: [ThreeDMouseMotion] = []
        var buttons: [ThreeDMouseButton] = []
    }

    private func makeInput() -> (ThreeDMouseInput, FakeBackend, () -> Recording) {
        let backend = FakeBackend()
        let input = ThreeDMouseInput(backend: { backend })
        var recording = Recording()
        input.onMotion = { recording.motions.append($0) }
        input.onButton = { recording.buttons.append($0) }
        input.start()
        return (input, backend, { recording })
    }

    func testInputIsIgnoredWhileInactive() {
        let (input, backend, recorded) = makeInput()
        XCTAssertEqual(input.status, .connected("Fake"))
        backend.sink?.axes([1, 0, 0, 0, 0, 0])
        backend.sink?.buttons(0b10)
        XCTAssertTrue(recorded().motions.isEmpty)
        XCTAssertTrue(recorded().buttons.isEmpty)

        input.setActive(true)
        XCTAssertEqual(backend.activeCalls.last, true)
        XCTAssertTrue(recorded().buttons.isEmpty, "A button held while inactive must not fire on activation")
        backend.sink?.buttons(0b11)
        XCTAssertEqual(recorded().buttons, [.menu])
    }

    func testMotionReportsChangesAndStopsOnDeactivation() {
        let (input, backend, recorded) = makeInput()
        input.setActive(true)
        backend.sink?.axes([1, 0, 0, 0, 0, 0])
        backend.sink?.axes([1, 0, 0, 0, 0, 0])
        XCTAssertEqual(recorded().motions, [ThreeDMouseMotion(translation: SIMD3(1, 0, 0))],
                       "An unchanged reading must not be reported again")

        input.setActive(false)
        XCTAssertEqual(recorded().motions.last, .zero, "Deactivation must stop the motion")
        XCTAssertEqual(backend.activeCalls, [false, true, false], "Start passes the inactive state, then each change follows")
    }

    func testDeviceResetAndStopReturnMotionToRest() {
        let (input, backend, recorded) = makeInput()
        input.setActive(true)
        backend.sink?.axes([0, 0, 0, 0, 1, 0])
        backend.sink?.reset()
        XCTAssertEqual(recorded().motions.last, .zero)

        backend.sink?.axes([0, 0, 0, 0, 1, 0])
        input.stop()
        XCTAssertEqual(recorded().motions.last, .zero)
        XCTAssertTrue(backend.stopped)
        XCTAssertEqual(input.status, .off)
        XCTAssertFalse(input.isRunning)
    }

    func testSimulatedSourceMovesOnlyWhileActive() {
        let input = ThreeDMouseInput(source: .simulated(ThreeDMouseMotion(rotation: SIMD3(0, 0.5, 0))))
        var motions: [ThreeDMouseMotion] = []
        input.onMotion = { motions.append($0) }
        input.start()
        XCTAssertEqual(input.status, .simulated)
        XCTAssertTrue(motions.isEmpty)
        input.setActive(true)
        XCTAssertEqual(motions, [ThreeDMouseMotion(rotation: SIMD3(0, 0.5, 0))])
        input.setActive(false)
        XCTAssertEqual(motions.last, .zero)
    }

    func testDroppingARunningInputReleasesItAndItsBackend() {
        weak var droppedInput: ThreeDMouseInput?
        weak var droppedBackend: SimulatedBackend?
        do {
            let backend = SimulatedBackend(motion: ThreeDMouseMotion(rotation: SIMD3(0, 0.5, 0)))
            let input = ThreeDMouseInput(backend: { backend })
            input.start()
            input.setActive(true)
            droppedInput = input
            droppedBackend = backend
        }
        XCTAssertNil(droppedInput, "A backend must not keep its input alive")
        XCTAssertNil(droppedBackend)
    }
}
