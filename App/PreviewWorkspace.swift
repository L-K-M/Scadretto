import AppKit
import MetalKit
import ScadrettoEngineClient
import ScadrettoViewport

@MainActor
final class PreviewWorkspace {
    let panel = NSView()
    let sidebar = PreviewSidebar(frame: .zero)
    private(set) var viewport: ViewportView?
    private let status = NSTextField(labelWithString: "Evaluating…")
    private let viewportError: String?
    private var hasGeometry = false

    init() {
        let renderingView: NSView
        do {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw ViewportError.renderStateUnavailable("No Metal device is available.")
            }
            let library = try device.makeDefaultLibrary(bundle: .main)
            let viewport = try ViewportView(device: device, library: library)
            self.viewport = viewport
            viewport.swapsOrbitAndPan = UserDefaults.standard.bool(forKey: "swapsOrbitAndPan")
            viewport.showsEdges = UserDefaults.standard.bool(forKey: "showsEdges")
            viewport.showsAxes = UserDefaults.standard.bool(forKey: "showsAxes")
            viewport.setAccessibilityIdentifier("viewport")
            viewport.setAccessibilityLabel("OpenSCAD viewport")
            renderingView = viewport
            viewportError = nil
        } catch {
            renderingView = NSView()
            viewportError = error.localizedDescription
        }

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityIdentifier("renderStatus")
        for item in [renderingView, status] {
            item.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(item)
        }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            status.topAnchor.constraint(equalTo: panel.topAnchor, constant: 7),
            renderingView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 7),
            renderingView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            renderingView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            renderingView.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
    }

    func update(_ phase: DocumentPreview.Phase) {
        switch phase {
        case .evaluating:
            setPending("Evaluating…")
        case .cancelled:
            setPending("Preview canceled")
        case .failure(let reason):
            setPending(reason)
        case .outcome(let outcome, let upload):
            let result = outcome.result
            sidebar.show(result: result, instances: result.scene?.instances ?? [],
                         operations: result.scene?.operations ?? [])
            switch outcome {
            case .rendered, .empty:
                let mesh = result.scene?.mesh
                viewport?.setMesh(upload)
                viewport?.setSceneStale(false)
                hasGeometry = mesh != nil
                let message = mesh.map { "Preview ready · \($0.indices.count / 3) triangles" } ?? "Empty model"
                let warning = result.diagnostics.first { $0.severity == .warning || $0.severity == .deprecated }
                let label = viewportError ?? (warning.map { "\(message) · \($0.message)" } ?? message)
                displayStatus(label)
                viewport?.setAccessibilityHelp(mesh.map {
                    "Model bounds \($0.bounds.min) to \($0.bounds.max)."
                } ?? "This evaluation has no solid geometry.")
            case .modelError, .unsupportedDimension:
                viewport?.setSceneStale(hasGeometry)
                let reason = result.diagnostics.first { $0.severity == .error }?.message ?? "Evaluation failed"
                displayStatus(hasGeometry ? "Preview out of date · \(reason)" : reason)
            }
        }
    }

    private func setPending(_ text: String) {
        viewport?.setSceneStale(hasGeometry)
        sidebar.setCurrent(false)
        displayStatus(hasGeometry ? "Preview out of date · \(text)" : text)
    }

    private func displayStatus(_ text: String) {
        status.stringValue = text
        status.toolTip = text
    }
}
