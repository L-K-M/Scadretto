import AppKit
import MetalKit
import ScadrettoEngineClient
import ScadrettoViewport

@MainActor
final class PreviewWorkspace {
    let panel = NSView()
    let sidebar = PreviewSidebar(frame: .zero)
    private(set) var viewport: ViewportView?
    private(set) var result: EvaluationResult?
    private(set) var geometry: PreviewGeometry?
    private let status = NSTextField(labelWithString: "Evaluating…")
    private let viewportError: String?
    private var hasGeometry = false
    private var renderedStatus: String?
    var onSelection: ((UInt32?, SIMD3<Double>?) -> Void)?
    var onPresentationChange: (() -> Void)?

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
            viewport.dragSnapIncrement = UserDefaults.standard.double(forKey: "dragSnapIncrement")
            viewport.setAccessibilityElement(true)
            viewport.setAccessibilityRole(.group)
            viewport.setAccessibilityIdentifier("viewport")
            viewport.setAccessibilityLabel("OpenSCAD viewport")
            let menu = NSMenu(title: "Viewport")
            menu.addItem(withTitle: "Frame Model", action: #selector(ScadrettoDocument.frameModel(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Orthographic Projection", action: #selector(ScadrettoDocument.toggleOrthographic(_:)),
                         keyEquivalent: "")
            menu.addItem(withTitle: "Show Edges", action: #selector(ScadrettoDocument.toggleEdges(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Show Axes", action: #selector(ScadrettoDocument.toggleAxes(_:)), keyEquivalent: "")
            viewport.menu = menu
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
        viewport?.onSelection = { [weak self] frame, point in self?.pick(frame: frame, at: point) }
        viewport?.onPresentationChange = { [weak self] in
            self?.updateFrameStatus()
            self?.onPresentationChange?()
        }
        viewport?.onDiameterPreview = { [weak sidebar = self.sidebar] value in sidebar?.inspector.showPreview(value) }
        sidebar.onOccurrence = { [weak self] id in self?.onSelection?(id, nil) }
    }

    func update(_ phase: DocumentPreview.Phase) {
        switch phase {
        case .evaluating:
            setPending("Evaluating…")
        case .cancelled:
            setPending("Preview canceled")
        case .failure(let reason):
            setPending(reason)
        case .outcome(let outcome, let geometry):
            let result = outcome.result
            sidebar.show(result: result, instances: result.scene?.instances ?? [],
                         operations: result.scene?.operations ?? [])
            switch outcome {
            case .rendered, .empty:
                let mesh = result.scene?.mesh
                self.result = result
                self.geometry = geometry
                hasGeometry = mesh != nil
                let message = mesh.map { "Preview ready · \($0.indices.count / 3) triangles" } ?? "Empty model"
                let warning = result.diagnostics.first { $0.severity == .warning || $0.severity == .deprecated }
                let label = viewportError ?? (warning.map { "\(message) · \($0.message)" } ?? message)
                renderedStatus = label
                viewport?.setMesh(geometry?.upload, sceneID: result.requestID)
                viewport?.setSceneStale(false)
                updateFrameStatus()
                viewport?.setAccessibilityHelp(mesh.map {
                    "Model bounds \($0.bounds.min) to \($0.bounds.max)."
                } ?? "This evaluation has no solid geometry.")
            case .modelError, .unsupportedDimension:
                self.result = nil
                self.geometry = nil
                renderedStatus = nil
                sidebar.inspector.disableEditing()
                viewport?.setSceneStale(hasGeometry)
                let reason = result.diagnostics.first { $0.severity == .error }?.message ?? "Evaluation failed"
                displayStatus(hasGeometry ? "Preview out of date · \(reason)" : reason)
            }
        }
    }

    private func setPending(_ text: String) {
        result = nil
        geometry = nil
        renderedStatus = nil
        viewport?.showDiameter(handle: nil, guides: [])
        viewport?.setSceneStale(hasGeometry)
        sidebar.setCurrent(false)
        displayStatus(hasGeometry ? "Preview out of date · \(text)" : text)
    }

    private func displayStatus(_ text: String) {
        status.stringValue = text
        status.toolTip = text
    }

    private func updateFrameStatus() {
        guard let renderedStatus else { return }
        if geometry != nil, let viewport, viewport.presentedFrame?.sceneID != result?.requestID {
            displayStatus("Presenting preview…")
        } else {
            displayStatus(renderedStatus)
        }
    }

    private func pick(frame: ViewportView.PresentedFrame, at point: CGPoint) {
        guard result?.requestID == frame.sceneID else { return }
        sidebar.showCandidates([])
        guard let picker = geometry?.picker else {
            onSelection?(nil, nil)
            sidebar.inspector.show(DiameterInspection(title: "Choose an instance in the outline",
                                                       detail: "Surface picking is unavailable for this scene."))
            return
        }
        guard let pick = picker.pick(along: frame.transform.ray(throughViewPoint: point)) else {
            sidebar.selectOccurrence(nil)
            onSelection?(nil, nil)
            return
        }
        if pick.candidates.count == 1, let selected = pick.candidates.first {
            sidebar.selectOccurrence(selected)
            onSelection?(selected, pick.hit.point)
        } else {
            sidebar.selectOccurrence(nil)
            onSelection?(nil, nil)
            sidebar.showCandidates(pick.candidates)
            sidebar.inspector.show(DiameterInspection(
                title: "Final surface", detail: pick.candidates.isEmpty
                    ? "Choose an instance in the outline to inspect this surface."
                    : "Choose which matching instance to inspect."
            ))
        }
    }
}
