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
    private let snap = NSTextField(labelWithString: "")
    private let notice = NSTextField(labelWithString: "")
    private let viewportError: String?
    private var hasGeometry = false
    private var renderedStatus: String?
    private var ghostIDs: [UInt32] = []
    private(set) var ghostOmitted = 0
    private var candidateHit: SIMD3<Double>?
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
        snap.font = status.font
        snap.textColor = .secondaryLabelColor
        snap.setAccessibilityIdentifier("dragSnap")
        snap.setContentCompressionResistancePriority(.required, for: .horizontal)
        notice.font = status.font
        notice.textColor = .systemOrange
        notice.lineBreakMode = .byTruncatingTail
        // The status names the scene; the notice truncates first and keeps its full text in a tooltip.
        notice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        notice.isHidden = true
        notice.setAccessibilityIdentifier("dependencyNotice")
        for item in [renderingView, status, notice, snap] {
            item.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(item)
        }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(lessThanOrEqualTo: notice.leadingAnchor, constant: -12),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: snap.leadingAnchor, constant: -8),
            notice.firstBaselineAnchor.constraint(equalTo: status.firstBaselineAnchor),
            snap.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            snap.firstBaselineAnchor.constraint(equalTo: status.firstBaselineAnchor),
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
        viewport?.onEditPreview = { [weak sidebar = self.sidebar] value in sidebar?.inspector.showPreview(value) }
        showSnap()
        sidebar.onOccurrence = { [weak self] id in self?.onSelection?(id, nil) }
        sidebar.onCandidate = { [weak self] id in
            guard let self else { return }
            let point = candidateHit
            candidateHit = nil
            onSelection?(id, point)
        }
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
                ghostIDs = []
                ghostOmitted = 0
                // The last scene's handle must not be drawn or presented over this one.
                viewport?.showLinear(handle: nil, guides: [])
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
                showGhost([])
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
        candidateHit = nil
        showGhost([])
        viewport?.showDiameter(handle: nil, guides: [])
        viewport?.setSceneStale(hasGeometry)
        sidebar.showCandidates([])
        sidebar.setCurrent(false)
        displayStatus(hasGeometry ? "Preview out of date · \(text)" : text)
    }

    /// Says which open documents hold text that this preview's included files do not have yet.
    func showDependencyNotice(_ text: String?) {
        guard notice.stringValue != (text ?? "") else { return }
        notice.stringValue = text ?? ""
        notice.toolTip = text
        notice.isHidden = text == nil
        guard let text else { return }
        NSAccessibility.post(element: notice, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    private func displayStatus(_ text: String) {
        status.stringValue = text
        status.toolTip = text
    }

    private func updateFrameStatus() {
        guard let renderedStatus else { return }
        if geometry != nil, let viewport, viewport.presentedSceneID != result?.requestID {
            displayStatus("Presenting preview…")
        } else {
            displayStatus(renderedStatus)
        }
    }

    func showGhost(_ ids: [UInt32]) {
        guard ghostIDs != ids else { return }
        ghostIDs = ids
        let ghost = geometry?.ghost(for: ids)
        ghostOmitted = ghost?.omitted ?? 0
        viewport?.showGhost(ghost?.mesh)
    }

    /// The snap increment applies to every handle, so it stays in view.
    var snapDescription: String? {
        guard let step = viewport?.dragSnapIncrement, step > 0 else { return nil }
        return "Snap \(step.formatted(.number.grouping(.never)))"
    }

    func showSnap() {
        snap.stringValue = snapDescription ?? ""
    }

    private func pick(frame: ViewportView.PresentedFrame, at point: CGPoint) {
        guard result?.requestID == frame.sceneID else { return }
        candidateHit = nil
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
            candidateHit = pick.hit.point
            sidebar.showCandidates(pick.candidates)
            sidebar.inspector.show(DiameterInspection(
                title: "Final surface", detail: pick.candidates.isEmpty
                    ? "Choose an instance in the outline to inspect this surface."
                    : "Choose which matching instance to inspect."
            ))
        }
    }
}
