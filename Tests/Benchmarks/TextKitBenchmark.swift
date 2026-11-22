import AppKit

@main
struct EditorBench {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let fixture = (0..<20_000).map { "// line \($0) 🔧\r\n" }.joined()
        let baseline = try SourceBuffer(bytes: Data(("// 0\r\n" + fixture).utf8))
        print("fixture bytes \(baseline.bytes.count) SHA-256 \(baseline.sha256)")
        for textKit2 in [false, true] {
            let text = NSTextView(usingTextLayoutManager: textKit2)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 550))
            text.frame = NSRect(x: 0, y: 0, width: 800, height: 380_000)
            scroll.documentView = text
            text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            text.string = baseline.displayText
            var buffer = baseline
            var typing: [Double] = []
            for index in 0..<35 {
                let start = DispatchTime.now().uptimeNanoseconds
                let scope = NSRange(location: 3, length: 1)
                let replacement = index.isMultiple(of: 2) ? "1" : "0"
                let change = try buffer.textEdit(range: scope, replacement: replacement)
                buffer = try buffer.applying([change]).buffer
                text.textStorage?.replaceCharacters(in: scope, with: replacement)
                text.didChangeText()
                if index >= 5 { typing.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) }
            }
            var scrolling: [Double] = []
            for index in 0..<120 {
                let start = DispatchTime.now().uptimeNanoseconds
                scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(index * 2_800)))
                scroll.reflectScrolledClipView(scroll.contentView)
                scroll.layoutSubtreeIfNeeded()
                scrolling.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            func summary(_ samples: [Double]) -> String {
                let sorted = samples.sorted()
                func percentile(_ p: Double) -> Double { sorted[Int(ceil(Double(sorted.count) * p)) - 1] }
                return String(format: "n=%d p50=%.3f p95=%.3f ms", samples.count, percentile(0.5), percentile(0.95))
            }
            print("TextKit \(textKit2 ? 2 : 1) type \(summary(typing)) scroll \(summary(scrolling))")
        }
    }
}
