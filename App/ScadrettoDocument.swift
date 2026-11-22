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
    private nonisolated let io = OSAllocatedUnfairLock(initialState: DocumentIO())
    private lazy var source = SourceDocument(buffer: try! SourceBuffer())
    private weak var editor: SourceWindowController?
    private var preview: DocumentPreview?
    private var typingEnd: Int?
    private var typingTimer: Task<Void, Never>?

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
        let preview = DocumentPreview(engine: (NSApp.delegate as? ScadrettoApp)?.engineClient)
        self.preview = preview
        preview.onUpdate = { [weak controller] phase in controller?.previewWorkspace.update(phase) }
        controller.previewWorkspace.sidebar.onReveal = { [weak self] file, span, result in
            self?.reveal(file: file, span: span, in: result)
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
