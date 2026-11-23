import Foundation
import QuartzCore

/// Writes timing samples as JSON lines when the hidden default `ScadrettoTimingLog` names a file,
/// for `Scripts/benchmark-report`. Nothing is measured or written otherwise.
///
/// Every sample carries `t`, seconds on the `CACurrentMediaTime` clock, which is also the clock of
/// a Metal drawable's `presentedTime`, so commits, accepted results and presented frames line up.
@MainActor
enum TimingLog {
    private static let handle: FileHandle? = {
        guard let path = UserDefaults.standard.string(forKey: "ScadrettoTimingLog") else { return nil }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    static var isEnabled: Bool { handle != nil }

    static func record(_ kind: String, at time: CFTimeInterval = CACurrentMediaTime(), _ fields: [String: Any] = [:]) {
        guard let handle else { return }
        var sample = fields
        sample["kind"] = kind
        sample["t"] = time
        guard let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) else { return }
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
