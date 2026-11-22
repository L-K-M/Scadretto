import AppKit
import os
import ScadrettoCore
import ScadrettoEngineClient
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
    private struct FeatureAnchor: Equatable {
        let name: String
        let iteration: [String: Double]
        let dependency: String?
        var start: Int?
    }

    private struct FeatureSelection {
        var requestID: UUID
        var instanceID: UInt32
        var path: [FeatureAnchor]
        let localPoint: SIMD3<Double>?
    }

    private struct ActiveDiameter {
        let requestID: UUID
        let key: EvaluationKey
        let instanceID: UInt32
        let literal: DiameterLiteral
        let handle: ViewportDiameterHandle?
    }

    private nonisolated let io = OSAllocatedUnfairLock(initialState: DocumentIO())
    private lazy var source = SourceDocument(buffer: try! SourceBuffer())
    private weak var editor: SourceWindowController?
    private var preview: DocumentPreview?
    private var typingEnd: Int?
    private var typingTimer: Task<Void, Never>?
    private var featureSelection: FeatureSelection?
    private var activeDiameter: ActiveDiameter?
    private var diameterChange: String?

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
        controller.previewWorkspace.sidebar.inspector.onCommit = { [weak self] value in self?.submitDiameter(value) }
        controller.previewWorkspace.viewport?.onDiameterCommit = { [weak self] sceneID, handleID, value in
            self?.commitDiameter(value, sceneID: sceneID, handleID: handleID)
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
            activeDiameter = nil
            diameterChange = nil
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
        activeDiameter = nil
        diameterChange = nil
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
        diameterChange = nil
        activeDiameter = nil
        guard let id, let result = workspace.result, preview?.acceptsNavigation(from: result) == true,
              let scene = result.scene else {
            featureSelection = nil
            workspace.sidebar.inspector.show(nil)
            workspace.viewport?.showDiameter(handle: nil, guides: [])
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: scene.instances.map { ($0.id, $0) })
        featureSelection = FeatureSelection(requestID: result.requestID, instanceID: id,
                                            path: featurePath(id, in: byID, files: result.files),
                                            localPoint: point.flatMap { workspace.geometry?.localPoint($0, on: id) })
        refreshInspector(highlight: true)
    }

    private func refreshInspector(highlight: Bool = false) {
        guard let controller = editor, var selection = featureSelection else { return }
        let workspace = controller.previewWorkspace
        let inspector = workspace.sidebar.inspector
        guard let result = workspace.result, preview?.acceptsNavigation(from: result) == true,
              let scene = result.scene else {
            activeDiameter = nil
            inspector.disableEditing()
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: scene.instances.map { ($0.id, $0) })
        if selection.requestID != result.requestID {
            let last = selection.path.last
            let matches = scene.instances.filter { instance in
                instance.name == last?.name && instance.iteration == last?.iteration
                    && featurePath(instance.id, in: byID, files: result.files) == selection.path
            }
            guard matches.count == 1, let match = matches.first else {
                selectFeature(nil, at: nil)
                return
            }
            selection.instanceID = match.id
            selection.requestID = result.requestID
            featureSelection = selection
            workspace.sidebar.selectOccurrence(match.id)
        }

        let iterations = selection.path.last?.iteration.sorted(by: { $0.key < $1.key }).map {
            "\($0.key) = \($0.value.formatted(.number.grouping(.never)))"
        } ?? []
        let breadcrumb = (iterations + selection.path.suffix(2).map(\.name)).joined(separator: " · ")
        var inspection = DiameterInspection(title: breadcrumb)
        if let diameter = byID[selection.instanceID]?.diameter {
            inspection.value = diameter.value
            var names = ["d"]
            for link in diameter.chain where link.kind == "lookup" || link.kind == "assignment" {
                if !link.name.isEmpty, names.last != link.name { names.append(link.name) }
            }
            inspection.binding = names.joined(separator: " ← ")
        }

        do {
            let snapshot = source.snapshot
            let target = try result.diameterTarget(for: selection.instanceID, in: snapshot)
            let count = target.affectedInstances.count
            let cutters = "\(count) \(count == 1 ? "cutter" : "cutters")"
            switch target.scope {
            case .parameter: inspection.scope = "Shared parameter · \(cutters)"
            case .callSite: inspection.scope = count == 1 ? "This call site" : "Shared call site · \(cutters)"
            }
            let sourceRange = try snapshot.buffer.textRange(for: target.span.bytes)
            if highlight { controller.highlightSource(sourceRange) }
            guard let syntax = controller.currentSyntax, syntax.documentID == snapshot.documentID,
                  syntax.revision == snapshot.revision else {
                inspection.detail = "Checking the source token…"
                inspector.show(inspection)
                return
            }
            guard let token = syntax.ranges.first(where: { $0.kind == .number && $0.range == target.span.bytes }) else {
                throw DiameterEditError.unverifiedLiteral
            }
            let literal = try DiameterLiteral(source: snapshot, span: target.span, numericToken: token.range,
                                              value: target.value)
            guard workspace.viewport?.presentedSceneID == result.requestID else {
                inspection.detail = "Waiting for this preview to appear."
                inspector.show(inspection)
                return
            }
            let handle: ViewportDiameterHandle?
            if let active = activeDiameter, active.requestID == result.requestID,
               active.instanceID == selection.instanceID, active.literal == literal {
                handle = active.handle
            } else {
                handle = workspace.geometry?.handle(for: selection.instanceID, localPoint: selection.localPoint,
                                                    diameter: literal.value)
            }
            activeDiameter = ActiveDiameter(requestID: result.requestID, key: result.key, instanceID: selection.instanceID,
                                            literal: literal, handle: handle)
            let guideLimit = 256
            let guides = target.affectedInstances.prefix(guideLimit).compactMap { workspace.geometry?.guide(for: $0) }
            workspace.viewport?.showDiameter(handle: handle, guides: guides)
            inspection.writable = !controller.isComposing
            if let diameterChange {
                inspection.detail = diameterChange
            } else if count > guideLimit {
                inspection.detail = "Showing the first \(guideLimit) traced cutters."
            }
        } catch {
            activeDiameter = nil
            workspace.viewport?.showDiameter(handle: nil, guides: [])
            inspection.detail = diameterMessage(for: error)
            if highlight, let span = byID[selection.instanceID]?.span { reveal(file: span.fileID, span: span, in: result) }
        }
        inspector.show(inspection)
    }

    private func diameterMessage(for error: any Error) -> String {
        switch error {
        case DiameterBindingError.unobserved: "This occurrence has no observed uniform diameter binding."
        case DiameterBindingError.expression: "The diameter comes from an expression without a verified literal target."
        case DiameterBindingError.dependency(let path): "The diameter is authored in \(URL(fileURLWithPath: path).lastPathComponent)."
        case DiameterBindingError.staleSource: DiameterEditError.staleSource.localizedDescription
        default: error.localizedDescription
        }
    }

    private func featurePath(_ id: UInt32, in instances: [UInt32: InstanceRecord], files: [FileRecord]) -> [FeatureAnchor] {
        var path: [FeatureAnchor] = []
        var next: UInt32? = id
        while let id = next, let instance = instances[id] {
            let file = instance.span.flatMap { span in files.first { $0.id == span.fileID } }
            let dependency = file.flatMap { $0.kind == .main ? nil : $0.resolvedPath ?? $0.logicalPath }
            path.append(FeatureAnchor(name: instance.name, iteration: instance.iteration, dependency: dependency,
                                      start: instance.span.flatMap { Int(exactly: $0.start) }))
            next = instance.parent
        }
        return path.reversed()
    }

    private func adjustFeatureAnchors(for edits: [SourceEdit]) {
        guard var selection = featureSelection else { return }
        for index in selection.path.indices {
            let anchor = selection.path[index]
            guard anchor.dependency == nil, let start = anchor.start else { continue }
            var offset = 0
            for edit in edits {
                if edit.range.contains(start) {
                    selectFeature(nil, at: nil)
                    return
                }
                if edit.range.upperBound <= start { offset += edit.replacement.count - edit.range.count }
            }
            selection.path[index].start = start + offset
        }
        featureSelection = selection
    }

    private func submitDiameter(_ text: String) {
        guard let active = activeDiameter else { return }
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decimal = Locale.current.decimalSeparator, decimal != ".", !input.contains(".") {
            input = input.replacingOccurrences(of: decimal, with: ".")
        }
        guard let value = Double(input) else {
            editor?.previewWorkspace.sidebar.inspector.showMessage(DiameterEditError.invalidDiameter.localizedDescription)
            return
        }
        commitDiameter(value, sceneID: active.requestID, handleID: nil)
    }

    private func commitDiameter(_ value: Double, sceneID: UUID, handleID: UUID?) {
        guard let controller = editor else { return }
        let workspace = controller.previewWorkspace
        let inspector = workspace.sidebar.inspector
        guard !controller.isComposing else {
            inspector.showMessage("Finish composing text before editing the diameter.")
            return
        }
        guard let active = activeDiameter, active.requestID == sceneID,
              let result = workspace.result, result.requestID == sceneID, result.key == active.key,
              preview?.acceptsWriteBack(from: result) == true,
              workspace.viewport?.presentedSceneID == sceneID,
              active.instanceID == featureSelection?.instanceID,
              handleID == nil || handleID == active.handle?.id else {
            inspector.showMessage(DiameterEditError.staleSource.localizedDescription)
            return
        }
        do {
            guard let edit = try active.literal.edit(setting: value, in: source.snapshot) else {
                refreshInspector()
                return
            }
            let editedRange = try source.buffer.textRange(for: edit.range)
            let oldToken = String(decoding: edit.expected, as: UTF8.self)
            let newToken = String(decoding: edit.replacement, as: UTF8.self)
            try commit([edit], label: "Change Diameter",
                       selection: NSRange(location: editedRange.location, length: newToken.utf16.count))
            diameterChange = "Source change · \(oldToken) → \(newToken)"
            inspector.showMessage(diameterChange ?? "")
        } catch {
            inspector.showMessage(diameterMessage(for: error))
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
