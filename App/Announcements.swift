import AppKit

/// Speaks short messages through VoiceOver: scene state changes, the selection and committed
/// edits. The hidden default `ScadrettoAnnouncementLog` names a file that receives each message
/// as a line, so UI tests can check what was announced without VoiceOver.
@MainActor
enum Announcements {
    private static let log = UserDefaults.standard.string(forKey: "ScadrettoAnnouncementLog")
        .map { URL(fileURLWithPath: $0) }

    static func post(_ text: String, priority: NSAccessibilityPriorityLevel = .medium) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: priority.rawValue,
        ])
        if let log { append(text, to: log) }
    }

    private static func append(_ text: String, to url: URL) {
        let line = Data((text + "\n").utf8)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? line.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}
