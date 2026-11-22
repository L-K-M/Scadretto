import AppKit
import os
import ScadrettoCore
import ScadrettoEngineClient
import ScadrettoPlanning
import ScadrettoViewport

private struct DocumentIO: Sendable {
    var pendingRead: SourceBuffer?
    var committed: Data = Data()
    var baseline: Data?
    var writing: Data?
    var written: Data?
}

@MainActor
@objc(ScadrettoDocument)
final class ScadrettoDocument: ScadrettoDocumentBase {
    private struct FeatureSelection {
        var requestID: UUID
        var instanceID: UInt32
        var path: SelectionPath
        let localPoint: SIMD3<Double>?
    }

    private struct ActiveEdit {
        let requestID: UUID
        let key: EvaluationKey
        let instanceID: UInt32
        let choiceID: String
        let label: String
        let operation: PlannedPropertyEdit
        let handle: ViewportEditHandle?
    }

    private static let guideLimit = 256
    /// A property ID no choice has. It asks for an explicit choice.
    private static let noChoice = ""

    private nonisolated let io = OSAllocatedUnfairLock(initialState: DocumentIO())
    private lazy var source = SourceDocument(buffer: try! SourceBuffer())
    private weak var editor: SourceWindowController?
    private var preview: DocumentPreview?
    private var typingEnd: Int?
    private var typingTimer: Task<Void, Never>?
    private var featureSelection: FeatureSelection?
    private var activeEdit: ActiveEdit?
    private var sourceChange: String?
    private var propertyChoices: [PropertyChoice] = []
    private var propertyChoiceID: String?

    // AppKit constructs documents on its reading queue when concurrent
    // reads are enabled. The editable source model is created lazily on main.
    override nonisolated init() {
        super.init()
    }

    override class var autosavesInPlace: Bool { false }
    override class var autosavesDrafts: Bool { false }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        let loaded: SourceBuffer
        do {
            loaded = try SourceBuffer(bytes: data)
        } catch let error as SourceError {
            // AppKit supplies the file name in its open error and displays the
            // failure reason below it.
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [
                NSLocalizedFailureReasonErrorKey: error.localizedDescription,
            ])
        }
        io.withLock { $0.pendingRead = loaded }
    }

    override nonisolated func data(ofType typeName: String) throws -> Data {
        io.withLock { $0.writing ?? $0.committed }
    }

    override func makeWindowControllers() {
        adoptRead()
        undoManager?.groupsByEvent = false
        let controller = SourceWindowController(document: self)
        addWindowController(controller)
        editor = controller
        controller.show(source.snapshot, selecting: NSRange(location: 0, length: 0))
        let app = NSApp.delegate as? ScadrettoApp
        let preview = DocumentPreview(engine: app?.engineClient, startupError: app?.engineStartupError)
        self.preview = preview
        preview.onUpdate = { [weak self, weak controller] phase in
            controller?.previewWorkspace.update(phase)
            self?.refreshInspector()
        }
        controller.previewWorkspace.sidebar.onReveal = { [weak self] file, span, result in
            self?.reveal(file: file, span: span, in: result)
        }
        controller.previewWorkspace.onSelection = { [weak self] id, point in self?.selectFeature(id, at: point) }
        controller.previewWorkspace.onPresentationChange = { [weak self] in self?.refreshInspector() }
        controller.onSyntaxReady = { [weak self] in self?.refreshInspector() }
        controller.previewWorkspace.sidebar.inspector.onCommit = { [weak self] value in self?.submitProperty(value) }
        controller.previewWorkspace.sidebar.inspector.onChoice = { [weak self] index in self?.chooseProperty(index) }
        controller.previewWorkspace.viewport?.onEditCommit = { [weak self] sceneID, handleID, value in
            self?.commitProperty(value, sceneID: sceneID, handleID: handleID)
        }
        preview.schedule(source.snapshot, fileURL: fileURL, immediate: true)
    }

    override var isDocumentEdited: Bool { source.isEdited }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        editor?.finishComposition()
        endTypingGroup()
        try super.revert(toContentsOf: url, ofType: typeName)
        adoptRead()
        editor?.show(source.snapshot, selecting: NSRange(location: 0, length: 0))
        preview?.schedule(source.snapshot, fileURL: fileURL, immediate: true)
    }

    // AppKit coordinates safe writes and provides the prepared destination.
    // Read the old disk contents here, while the coordinated write is active.
    override nonisolated func writeSafely(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) throws {
        let state = io.withLock { $0 }
        if saveOperation == .saveOperation, let baseline = state.baseline {
            let onDisk = try? Data(contentsOf: url)
            guard onDisk == baseline else { throw DocumentSaveError.changedOnDisk }
        }
        io.withLock { $0.writing = state.committed }
        defer { io.withLock { $0.writing = nil } }
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        if saveOperation == .saveOperation || saveOperation == .saveAsOperation {
            io.withLock { $0.written = state.committed }
        }
    }

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        endTypingGroup()
        let snapshot = source.snapshot
        let priorURL = fileURL
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, let self,
               saveOperation == .saveOperation || saveOperation == .saveAsOperation {
                let written = self.io.withLock { state in
                    let written = state.written
                    state.written = nil
                    if let written { state.baseline = written }
                    return written
                }
                if written == snapshot.buffer.bytes {
                    self.source.acknowledgeSaved(snapshot)
                    self.editor?.window?.isDocumentEdited = self.source.isEdited
                }
                if priorURL != self.fileURL {
                    self.preview?.schedule(self.source.snapshot, fileURL: self.fileURL, immediate: true)
                }
            }
            completionHandler(error)
        }
    }

    private func adoptRead() {
        guard let loaded = io.withLock({ state -> SourceBuffer? in
            let loaded = state.pendingRead
            state.pendingRead = nil
            return loaded
        }) else { return }
        do {
            try source.reload(loaded)
            featureSelection = nil
            activeEdit = nil
            sourceChange = nil
            propertyChoices = []
            propertyChoiceID = nil
            editor?.previewWorkspace.sidebar.inspector.show(nil)
            io.withLock {
                $0.committed = loaded.bytes
                $0.baseline = loaded.bytes
            }
            undoManager?.removeAllActions()
        } catch {
            presentError(error)
        }
    }

    func changeText(_ ranges: [NSRange], replacements: [String], coalescing: Bool) {
        guard ranges.count == replacements.count, let first = ranges.first else { return }
        do {
            let edits = try zip(ranges, replacements).map {
                try source.buffer.textEdit(range: $0.0, replacement: $0.1)
            }
            let groupsTyping = coalescing && ranges.count == 1 && !replacements[0].contains(where: \.isNewline)
            let insertedLength = replacements[0].normalizedEditorSeparators.utf16.count
            let selection = NSRange(location: first.location + insertedLength, length: 0)
            try commit(edits, label: groupsTyping ? "Typing" : "Edit Source",
                       selection: selection, coalescingFrom: groupsTyping ? first.location : nil)
        } catch {
            presentError(error)
        }
    }

    private func commit(
        _ edits: [SourceEdit],
        label: String,
        selection: NSRange,
        coalescingFrom location: Int? = nil
    ) throws {
        let previousSelection = editor?.selection ?? NSRange(location: 0, length: 0)
        let inverted = try source.apply(source.transaction(edits: edits, label: label))
        if inverted.isEmpty { return }
        adjustFeatureAnchors(for: edits)
        activeEdit = nil
        sourceChange = nil
        let snapshot = source.snapshot
        io.withLock { $0.committed = snapshot.buffer.bytes }

        if let manager = undoManager {
            if !manager.isUndoing && !manager.isRedoing {
                if location == nil || typingEnd != location {
                    endTypingGroup()
                    manager.beginUndoGrouping()
                } else if manager.groupingLevel == 0 {
                    manager.beginUndoGrouping()
                }
            }
            manager.registerUndo(withTarget: self) { target in
                // This manager is replayed by the main-actor document actions.
                MainActor.assumeIsolated {
                    do {
                        try target.commit(inverted, label: label, selection: previousSelection)
                    } catch {
                        target.presentError(error)
                    }
                }
            }
            manager.setActionName(label)
            if location == nil {
                if !manager.isUndoing && !manager.isRedoing {
                    manager.endUndoGrouping()
                }
            } else {
                typingEnd = selection.location
                typingTimer?.cancel()
                typingTimer = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    if !Task.isCancelled { self?.endTypingGroup() }
                }
            }
        }

        editor?.show(snapshot, selecting: selection)
        editor?.window?.isDocumentEdited = source.isEdited
        preview?.schedule(snapshot, fileURL: fileURL, immediate: location == nil)
    }

    func endTypingGroup() {
        typingTimer?.cancel()
        typingTimer = nil
        if typingEnd != nil {
            typingEnd = nil
            if let undoManager, undoManager.groupingLevel > 0 {
                undoManager.endUndoGrouping()
            }
        }
    }

    private func selectFeature(_ id: UInt32?, at point: SIMD3<Double>?) {
        guard let workspace = editor?.previewWorkspace else { return }
        sourceChange = nil
        activeEdit = nil
        propertyChoices = []
        propertyChoiceID = nil
        guard let id, let result = workspace.result, preview?.acceptsNavigation(from: result) == true,
              let scene = result.scene else {
            featureSelection = nil
            workspace.sidebar.inspector.show(nil)
            workspace.viewport?.showDiameter(handle: nil, guides: [])
            workspace.showGhost([])
            return
        }
        featureSelection = FeatureSelection(requestID: result.requestID, instanceID: id,
                                            path: SelectionPath(to: id, in: scene, files: result.files),
                                            localPoint: point.flatMap { workspace.geometry?.localPoint($0, on: id) })
        refreshInspector(highlight: true)
    }

    private func chooseProperty(_ index: Int) {
        guard propertyChoices.indices.contains(index) else { return }
        propertyChoiceID = propertyChoices[index].id
        activeEdit = nil
        sourceChange = nil
        refreshInspector(highlight: true)
    }

    private func refreshInspector(highlight: Bool = false) {
        guard let controller = editor, var selection = featureSelection else { return }
        let workspace = controller.previewWorkspace
        let inspector = workspace.sidebar.inspector
        guard let result = workspace.result, preview?.acceptsNavigation(from: result) == true,
              let scene = result.scene else {
            activeEdit = nil
            inspector.disableEditing()
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: scene.instances.map { ($0.id, $0) })
        if selection.requestID != result.requestID {
            switch selection.path.resolve(in: scene, files: result.files) {
            case .exact(let id):
                selection.instanceID = id
                selection.requestID = result.requestID
                // The path now includes any wrapper inserted since the last evaluation.
                selection.path = SelectionPath(to: id, in: scene, files: result.files)
            case .ancestor(let id):
                // The ancestor has other properties, so typing waits for a choice.
                selection = FeatureSelection(requestID: result.requestID, instanceID: id,
                                             path: SelectionPath(to: id, in: scene, files: result.files),
                                             localPoint: nil)
                propertyChoiceID = Self.noChoice
            case nil:
                selectFeature(nil, at: nil)
                return
            }
            featureSelection = selection
            workspace.sidebar.selectOccurrence(selection.instanceID)
        }

        let anchors = selection.path.anchors
        let iterations = anchors.last?.iteration.sorted(by: { $0.key < $1.key }).map {
            "\($0.key) = \($0.value.formatted(.number.grouping(.never)))"
        } ?? []
        let breadcrumb = (iterations + anchors.suffix(2).map(\.name)).joined(separator: " · ")
        guard let instance = byID[selection.instanceID] else { return }
        propertyChoices = PropertyChoice.choices(on: instance, among: byID)
        let selectedIndex = PropertyChoice.selectedIndex(after: propertyChoiceID, in: propertyChoices)
        var inspection = DiameterInspection(title: breadcrumb, choices: propertyChoices.map(\.title),
                                            selectedChoice: selectedIndex)
        guard let selectedIndex else {
            activeEdit = nil
            workspace.viewport?.showLinear(handle: nil, guides: [])
            workspace.showGhost([instance.id])
            if !propertyChoices.isEmpty {
                inspection.detail = "Choose a property to edit."
            } else if scene.propertiesOmitted {
                inspection.value = instance.diameter?.value
                inspection.detail = "Property detail was omitted for this large model, so it can only be inspected."
            } else {
                inspection.detail = "This occurrence has no observed numeric property."
            }
            inspector.show(inspection)
            if highlight, let span = instance.span { reveal(file: span.fileID, span: span, in: result) }
            return
        }
        let choice = propertyChoices[selectedIndex]
        propertyChoiceID = choice.id
        inspection.property = choice.title
        inspection.fieldIdentifier = choice.fieldIdentifier
        showProperty(choice, selection: selection, result: result, instances: byID,
                     inspection: inspection, highlight: highlight, controller: controller)
    }

    private func showProperty(_ choice: PropertyChoice, selection: FeatureSelection, result: EvaluationResult,
                              instances: [UInt32: InstanceRecord], inspection initial: DiameterInspection,
                              highlight: Bool, controller: SourceWindowController) {
        var inspection = initial
        let workspace = controller.previewWorkspace
        let snapshot = source.snapshot
        inspection.value = choice.value
        if let expression = choice.expression, let span = try? result.authoringSpan(expression, in: snapshot) {
            let authored = String(decoding: snapshot.buffer.bytes.subdata(in: span.bytes), as: UTF8.self)
            inspection.binding = choice.bindingPath ?? authored
        } else {
            inspection.binding = choice.bindingPath ?? ""
        }

        do {
            let plan = try choice.plan(in: result, source: snapshot, syntax: controller.currentSyntax)
            inspection.scope = plan.scope
            let line = Self.line(of: plan.span.bytes.lowerBound, in: snapshot.buffer.bytes)
            inspection.binding += inspection.binding.isEmpty ? "Line \(line)" : " · line \(line)"
            if highlight, let range = try? snapshot.buffer.textRange(for: plan.span.bytes) {
                controller.highlightSource(range)
            }
            guard workspace.viewport?.presentedSceneID == result.requestID else {
                inspection.detail = "Waiting for this preview to appear."
                workspace.sidebar.inspector.show(inspection)
                return
            }
            let handle: ViewportEditHandle?
            if plan.dragBlocker != nil {
                handle = nil
            } else if let activeEdit, activeEdit.requestID == result.requestID,
                      activeEdit.instanceID == selection.instanceID,
                      activeEdit.choiceID == choice.id, activeEdit.operation == plan.operation {
                handle = activeEdit.handle
            } else {
                handle = workspace.geometry.flatMap { makeHandle(for: choice, selection: selection, geometry: $0) }
            }
            activeEdit = ActiveEdit(requestID: result.requestID, key: result.key, instanceID: selection.instanceID,
                                    choiceID: choice.id, label: choice.label, operation: plan.operation, handle: handle)
            var guidesTruncated = false
            switch handle {
            case .diameter(let radial):
                let cutters = choice.previewRims(affected: plan.affected, instances: instances)
                guidesTruncated = cutters.count > Self.guideLimit
                let guides = cutters.prefix(Self.guideLimit).compactMap { workspace.geometry?.guide(for: $0) }
                workspace.viewport?.showDiameter(handle: radial, guides: guides)
            case .linear(let linear):
                let motions = choice.previewMotions(affected: plan.affected, instances: instances)
                guidesTruncated = motions.count > Self.guideLimit
                let guides = motions.prefix(Self.guideLimit).compactMap { motion in
                    instances[motion.instance].flatMap {
                        workspace.geometry?.moveGuide(for: $0, localUnitsPerValue: motion.localUnitsPerValue)
                    }
                }
                workspace.viewport?.showLinear(handle: linear, guides: guides)
            case nil:
                workspace.viewport?.showLinear(handle: nil, guides: [])
            }
            workspace.showGhost(plan.affected)
            inspection.writable = !controller.isComposing

            var notes: [String] = []
            if let sourceChange {
                notes.append(sourceChange)
            } else if handle == nil, choice.hasSpatialHandle {
                notes.append(Self.explanation(for: plan.dragBlocker))
            }
            if guidesTruncated { notes.append("Showing the first \(Self.guideLimit) moving outlines.") }
            if workspace.ghostOmitted > 0 {
                notes.append("\(workspace.ghostOmitted) affected occurrences are too detailed to highlight.")
            }
            if handle != nil, let snap = workspace.snapDescription { notes.append(snap) }
            inspection.detail = notes.joined(separator: "\n")
        } catch {
            activeEdit = nil
            workspace.viewport?.showLinear(handle: nil, guides: [])
            workspace.showGhost([selection.instanceID])
            inspection.detail = propertyMessage(for: error)
            if highlight, let span = choice.expression { reveal(file: span.fileID, span: span, in: result) }
        }
        workspace.sidebar.inspector.show(inspection)
    }

    private static func line(of offset: Int, in bytes: Data) -> Int {
        1 + String(decoding: bytes.prefix(offset), as: UTF8.self).filter(\.isNewline).count
    }

    private static func explanation(for blocker: DragBlocker?) -> String {
        switch blocker {
        case .iterationZero: "Iteration zero keeps its position. Enter pitch or choose another occurrence."
        case .unverified: "Other uses of this value could move the result, so dragging is off. Enter a value."
        case .opaqueFrame: "An enclosing operation hides this feature's placement, so dragging is off. Enter a value."
        case .sharedPath: "This expression applies more than once along the same path. Enter a value."
        case nil: "A stable drag frame could not be verified. Enter a value."
        }
    }

    private func makeHandle(for choice: PropertyChoice, selection: FeatureSelection,
                            geometry: PreviewGeometry) -> ViewportEditHandle? {
        switch choice.action {
        case .value(let owner, let property):
            if let pitch = property.pitch {
                return geometry.moveHandle(shape: selection.instanceID, in: owner, axis: .x,
                                           value: property.value, valuePerUnit: 1 / pitch.iteration)
                    .map(ViewportEditHandle.linear)
            }
            if let axis = property.semantic.translateAxis {
                return geometry.moveHandle(shape: selection.instanceID, in: owner, axis: axis, value: property.value)
                    .map(ViewportEditHandle.linear)
            }
            if property.semantic == .cylinderDiameter {
                return geometry.handle(for: owner.id, localPoint: selection.localPoint, diameter: property.value)
                    .map(ViewportEditHandle.diameter)
            }
            return geometry.sizeHandle(for: owner.id, property: property, localPoint: selection.localPoint)
                .map(ViewportEditHandle.linear)
        case .offset(let owner, let property):
            guard let axis = property.semantic.translateAxis else { return nil }
            return geometry.moveHandle(shape: selection.instanceID, in: owner, axis: axis, value: 0)
                .map(ViewportEditHandle.linear)
        case .prefix(let owner, let axis):
            return geometry.moveHandle(shape: selection.instanceID, in: owner, axis: axis, value: 0)
                .map(ViewportEditHandle.linear)
        }
    }

    private func propertyMessage(for error: any Error) -> String {
        switch error {
        case PropertyBindingError.unobserved: "The evaluator did not establish a writable binding."
        case PropertyBindingError.expression: "This expression has no verified literal target."
        case PropertyBindingError.dependency(let path): "The target is authored in \(URL(fileURLWithPath: path).lastPathComponent)."
        case PropertyBindingError.staleSource: ExplicitEditError.staleSource.localizedDescription
        default: error.localizedDescription
        }
    }

    private func adjustFeatureAnchors(for edits: [SourceEdit]) {
        guard var selection = featureSelection else { return }
        guard selection.path.follow(edits) else {
            selectFeature(nil, at: nil)
            return
        }
        featureSelection = selection
    }

    private func submitProperty(_ text: String) {
        guard let active = activeEdit else { return }
        guard let value = PropertyEntry.value(of: text) else {
            editor?.previewWorkspace.sidebar.inspector.showMessage("Enter a finite number.")
            return
        }
        commitProperty(value, sceneID: active.requestID, handleID: nil)
    }

    private func commitProperty(_ value: Double, sceneID: UUID, handleID: UUID?) {
        guard let controller = editor else { return }
        let workspace = controller.previewWorkspace
        let inspector = workspace.sidebar.inspector
        guard !controller.isComposing else {
            inspector.showMessage("Finish composing text before editing this property.")
            return
        }
        guard let active = activeEdit, active.requestID == sceneID,
              let result = workspace.result, result.requestID == sceneID, result.key == active.key,
              preview?.acceptsWriteBack(from: result) == true,
              workspace.viewport?.presentedSceneID == sceneID,
              active.instanceID == featureSelection?.instanceID,
              active.choiceID == propertyChoiceID,
              handleID == nil || handleID == active.handle?.id else {
            inspector.showMessage(ExplicitEditError.staleSource.localizedDescription)
            return
        }
        do {
            guard let edit = try active.operation.edit(setting: value, in: source.snapshot) else {
                refreshInspector()
                return
            }
            let editedRange = try source.buffer.textRange(for: edit.range)
            let oldToken = String(decoding: edit.expected, as: UTF8.self)
            let newToken = String(decoding: edit.replacement, as: UTF8.self)
            try commit([edit], label: active.label,
                       selection: NSRange(location: editedRange.location, length: newToken.utf16.count))
            sourceChange = "Source change · \(oldToken) → \(newToken)"
            inspector.showMessage(sourceChange ?? "")
        } catch {
            inspector.showMessage(propertyMessage(for: error))
        }
    }

    @IBAction func undoSource(_ sender: Any?) {
        editor?.finishComposition()
        endTypingGroup()
        undoManager?.undo()
    }

    @IBAction func redoSource(_ sender: Any?) {
        editor?.finishComposition()
        endTypingGroup()
        undoManager?.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let menu = item as? NSMenuItem, let viewport = editor?.previewWorkspace.viewport {
            switch menu.action {
            case #selector(toggleOrthographic(_:)): menu.state = viewport.orthographic ? .on : .off
            case #selector(toggleEdges(_:)): menu.state = viewport.showsEdges ? .on : .off
            case #selector(toggleAxes(_:)): menu.state = viewport.showsAxes ? .on : .off
            case #selector(toggleOrbitPan(_:)): menu.state = viewport.swapsOrbitAndPan ? .on : .off
            case #selector(setDragSnap(_:)): menu.state = (menu.representedObject as? Double) == viewport.dragSnapIncrement ? .on : .off
            default: break
            }
        }
        if item.action == #selector(revealSelectedInstance(_:)) {
            return editor?.previewWorkspace.sidebar.canRevealOccurrence == true
        }
        if item.action == #selector(undoSource(_:)) {
            let typing = typingEnd != nil
            if let menu = item as? NSMenuItem {
                menu.title = typing ? "Undo Typing" : undoManager?.undoMenuItemTitle ?? "Undo"
            }
            return typing || undoManager?.canUndo == true
        }
        if item.action == #selector(redoSource(_:)) {
            if let menu = item as? NSMenuItem { menu.title = undoManager?.redoMenuItemTitle ?? "Redo" }
            return undoManager?.canRedo == true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func close() {
        endTypingGroup()
        preview?.close()
        super.close()
    }

    @IBAction func retryPreview(_ sender: Any?) { preview?.retry() }
    @IBAction func cancelPreview(_ sender: Any?) { preview?.cancel() }
    @IBAction func revealSelectedInstance(_ sender: Any?) {
        editor?.previewWorkspace.sidebar.revealOccurrence()
    }

    @IBAction func frameModel(_ sender: Any?) { editor?.previewWorkspace.viewport?.frameAll() }

    @IBAction func standardView(_ sender: NSMenuItem) {
        let views = ViewportStandardView.allCases
        guard views.indices.contains(sender.tag) else { return }
        editor?.previewWorkspace.viewport?.setStandardView(views[sender.tag])
    }

    @IBAction func toggleOrthographic(_ sender: NSMenuItem) {
        guard let viewport = editor?.previewWorkspace.viewport else { return }
        viewport.orthographic.toggle()
        sender.state = viewport.orthographic ? .on : .off
    }

    @IBAction func toggleEdges(_ sender: NSMenuItem) {
        guard let viewport = editor?.previewWorkspace.viewport else { return }
        viewport.showsEdges.toggle()
        sender.state = viewport.showsEdges ? .on : .off
        UserDefaults.standard.set(viewport.showsEdges, forKey: "showsEdges")
    }

    @IBAction func toggleAxes(_ sender: NSMenuItem) {
        guard let viewport = editor?.previewWorkspace.viewport else { return }
        viewport.showsAxes.toggle()
        sender.state = viewport.showsAxes ? .on : .off
        UserDefaults.standard.set(viewport.showsAxes, forKey: "showsAxes")
    }

    @IBAction func toggleOrbitPan(_ sender: NSMenuItem) {
        guard let viewport = editor?.previewWorkspace.viewport else { return }
        viewport.swapsOrbitAndPan.toggle()
        sender.state = viewport.swapsOrbitAndPan ? .on : .off
        UserDefaults.standard.set(viewport.swapsOrbitAndPan, forKey: "swapsOrbitAndPan")
    }

    @IBAction func setDragSnap(_ sender: NSMenuItem) {
        guard let step = sender.representedObject as? Double, let viewport = editor?.previewWorkspace.viewport else { return }
        viewport.dragSnapIncrement = step
        UserDefaults.standard.set(step, forKey: "dragSnapIncrement")
        editor?.previewWorkspace.showSnap()
        refreshInspector()
    }

    @IBAction func showWorkerLog(_ sender: Any?) {
        guard let window = editor?.window else { return }
        let alert = NSAlert()
        alert.messageText = "OpenSCAD Worker Log"
        let details = preview?.log ?? ""
        alert.informativeText = details.isEmpty ? "The worker has no process log for this evaluation." : String(details.prefix(4096))
        alert.beginSheetModal(for: window)
    }

    private func reveal(file: UInt32, span: WireSpan?, in result: EvaluationResult) {
        guard let preview, preview.acceptsNavigation(from: result),
              let record = result.files.first(where: { $0.id == file }) else { return }
        if record.kind == .main {
            reveal(span, ifDigest: record.sha256)
        } else if [.include, .use].contains(record.kind) {
            let url = URL(fileURLWithPath: record.resolvedPath ?? record.logicalPath)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                if let document = document as? ScadrettoDocument {
                    document.reveal(span, ifDigest: record.sha256)
                } else if let error {
                    NSApp.presentError(error)
                }
            }
        }
    }

    private func reveal(_ span: WireSpan?, ifDigest digest: String) {
        let buffer = source.buffer
        guard buffer.sha256 == digest else { return }
        let range = span.flatMap { span in
            let length = UInt64(buffer.bytes.count)
            guard span.start <= span.end, span.end <= length else { return nil as NSRange? }
            return try? buffer.textRange(for: Int(span.start)..<Int(span.end))
        }
        editor?.reveal(range)
    }
}

private enum DocumentSaveError: LocalizedError {
    case changedOnDisk

    var errorDescription: String? {
        "The file changed on disk. Choose Save As to keep your edits in a separate file, or Revert to reload the disk version."
    }
}

extension String {
    var normalizedEditorSeparators: String {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }
}

private extension PropertyChoice {
    var hasSpatialHandle: Bool {
        guard case .value(_, let property) = action else { return true }
        return property.semantic != .fragmentCount && property.semantic != .moduleArgument
    }

    var fieldIdentifier: String {
        switch action {
        case .value(_, let property) where property.semantic == .cylinderDiameter: "diameterField"
        case .value(_, let property) where property.semantic == .pitch: "pitchField"
        default: "propertyValue"
        }
    }
}
