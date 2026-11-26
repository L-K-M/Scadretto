import AppKit
import MetalKit
import ScadrettoEngineClient
import ScadrettoViewport

@MainActor
final class PreviewWorkspace {
    private struct PendingComparison {
        let request: UUID
        let key: EvaluationKey
        let revision: UInt64
        let change: ViewportView.Comparison

        func matches(_ result: EvaluationResult) -> Bool {
            result.requestID == request && result.key.documentID == key.documentID
                && result.key.sourceRevision == revision && result.key.dependencyGeneration == key.dependencyGeneration
                && result.key.resolutionDigest == key.resolutionDigest
                && result.key.optionsDigest == key.optionsDigest && result.key.workerBuild == key.workerBuild
        }
    }

    let panel = NSView()
    let sidebar = PreviewSidebar(frame: .zero)
    private(set) var viewport: ViewportView?
    private(set) var result: EvaluationResult?
    private(set) var geometry: PreviewGeometry?
    private let status = NSTextField(labelWithString: "Evaluating…")
    private let snap = NSTextField(labelWithString: "")
    private let notice = NSTextField(labelWithString: "")
    private let compare = NSButton(title: "Compare", target: nil, action: #selector(ScadrettoDocument.toggleComparison(_:)))
    private let viewportError: String?
    private var hasGeometry = false
    private var renderedStatus: String?
    private var ghostIDs: [UInt32] = []
    private var selectionGhostIDs: [UInt32] = []
    private var hoverGhostID: UInt32?
    private var pendingComparison: PendingComparison?
    private(set) var ghostOmitted = 0
    private var candidateHit: SIMD3<Double>?
    private var announcedState: SceneState?
    /// The last scene whose first presented frame went to the timing log.
    private var loggedScene: UUID?
    private var evaluatingAnnouncement: Task<Void, Never>?
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
            menu.addItem(.separator())
            menu.addItem(withTitle: "Shared-Source Constellation",
                         action: #selector(ScadrettoDocument.toggleConstellation(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Pin Comparison Cut",
                         action: #selector(ScadrettoDocument.toggleComparison(_:)), keyEquivalent: "")
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
        compare.controlSize = .small
        compare.bezelStyle = .inline
        compare.setAccessibilityIdentifier("comparePreview")
        let indicators = NSStackView(views: [snap, compare])
        indicators.spacing = 6
        indicators.alignment = .firstBaseline
        indicators.detachesHiddenViews = true
        for item in [renderingView, status, notice, indicators] {
            item.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(item)
        }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(lessThanOrEqualTo: notice.leadingAnchor, constant: -12),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: indicators.leadingAnchor, constant: -8),
            notice.firstBaselineAnchor.constraint(equalTo: status.firstBaselineAnchor),
            indicators.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
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
        viewport?.onComparisonChange = { [weak self] in self?.updateComparisonButton() }
        if TimingLog.isEnabled {
            viewport?.onFramePresented = { [weak self] scene, time in self?.logFrame(scene: scene, at: time) }
        }
        showSnap()
        updateComparisonButton()
        sidebar.onOccurrence = { [weak self] id in self?.onSelection?(id, nil) }
        sidebar.onCandidate = { [weak self] id in
            guard let self else { return }
            let point = candidateHit
            candidateHit = nil
            onSelection?(id, point)
        }
    }

    /// What VoiceOver last heard about the scene. Evaluations that end the way the last one did
    /// stay quiet, so typing does not repeat "Preview ready".
    private enum SceneState: Equatable {
        case evaluating
        case ready
        case canceled
        case failed(String)
    }

    /// Seconds an evaluation runs before VoiceOver hears that it is still evaluating.
    private static let evaluatingAnnouncementDelay = 1.5

    func expectComparison(_ change: ViewportView.Comparison, request: UUID, after key: EvaluationKey, revision: UInt64) {
        pendingComparison = PendingComparison(request: request, key: key, revision: revision, change: change)
    }

    func discardPendingComparison() {
        pendingComparison = nil
    }

    func update(_ phase: DocumentPreview.Phase) {
        evaluatingAnnouncement?.cancel()
        evaluatingAnnouncement = nil
        switch phase {
        case .evaluating:
            setPending("Evaluating…")
            evaluatingAnnouncement = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.evaluatingAnnouncementDelay))
                guard !Task.isCancelled else { return }
                self?.announce(.evaluating, "Evaluating", priority: .low)
            }
        case .cancelled:
            discardPendingComparison()
            setPending("Preview canceled")
            announce(.canceled, "Preview canceled")
        case .failure(let reason):
            discardPendingComparison()
            setPending(reason)
            announce(.failed(reason), status.stringValue, priority: .high)
        case .outcome(let outcome, let geometry):
            let result = outcome.result
            let change = pendingComparison.flatMap { $0.matches(result) ? $0.change : nil }
            discardPendingComparison()
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
                selectionGhostIDs = []
                hoverGhostID = nil
                ghostOmitted = 0
                // The last scene's handle must not be drawn or presented over this one.
                viewport?.showLinear(handle: nil, guides: [])
                viewport?.setMesh(geometry?.upload, sceneID: result.requestID, comparison: change)
                viewport?.setSceneStale(false)
                updateFrameStatus()
                viewport?.setAccessibilityHelp(mesh.map {
                    "Model bounds \($0.bounds.min) to \($0.bounds.max)."
                } ?? "This evaluation has no solid geometry.")
                announce(.ready, label)
            case .modelError, .unsupportedDimension:
                self.result = nil
                self.geometry = nil
                renderedStatus = nil
                showGhost([])
                sidebar.inspector.disableEditing()
                viewport?.setSceneStale(hasGeometry)
                let reason = result.diagnostics.first { $0.severity == .error }?.message ?? "Evaluation failed"
                displayStatus(hasGeometry ? "Preview out of date · \(reason)" : reason)
                announce(.failed(reason), status.stringValue, priority: .high)
            }
        }
    }

    private func setPending(_ text: String) {
        result = nil
        geometry = nil
        renderedStatus = nil
        candidateHit = nil
        hoverGhostID = nil
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
        if let text { Announcements.post(text) }
    }

    private func announce(_ state: SceneState, _ text: String, priority: NSAccessibilityPriorityLevel = .medium) {
        guard state != announcedState else { return }
        announcedState = state
        Announcements.post(text, priority: priority)
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

    private func logFrame(scene: UUID?, at time: CFTimeInterval) {
        TimingLog.record("frame", at: time, scene.map { ["scene": $0.uuidString] } ?? [:])
        guard let scene, scene != loggedScene, scene == result?.requestID else { return }
        loggedScene = scene
        TimingLog.record("presented", at: time, ["requestID": scene.uuidString])
    }

    /// Drops this window's selection display when the selection moves to another window.
    func clearSelection() {
        candidateHit = nil
        sidebar.showCandidates([])
        sidebar.selectOccurrence(nil)
        sidebar.inspector.show(nil)
        viewport?.showDiameter(handle: nil, guides: [])
        hoverGhostID = nil
        showGhost([])
    }

    func showGhost(_ ids: [UInt32]) {
        selectionGhostIDs = ids
        updateGhost()
    }

    func previewRelatedOccurrence(_ id: UInt32?) {
        guard hoverGhostID != id else { return }
        hoverGhostID = id
        updateGhost()
    }

    private func updateGhost() {
        let ids = hoverGhostID.map { [$0] } ?? selectionGhostIDs
        guard ghostIDs != ids else { return }
        ghostIDs = ids
        let ghost = geometry?.ghost(for: ids)
        if hoverGhostID == nil { ghostOmitted = ghost?.omitted ?? 0 }
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

    private func updateComparisonButton() {
        compare.isHidden = viewport?.canCompare != true
        let pinned = viewport?.isComparisonPinned == true
        compare.title = pinned ? "Close Compare" : "Compare"
        compare.toolTip = pinned ? "Close Comparison Cut" : "Pin Comparison Cut. Hold Space in the model for a quick look."
        compare.setAccessibilityHelp(compare.toolTip)
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
