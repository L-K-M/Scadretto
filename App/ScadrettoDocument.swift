import AppKit
import os
import ScadrettoCore

private struct DocumentIO: Sendable {
    var pendingRead: SourceBuffer?
    var committed: Data = Data()
    var baseline: Data?
    var writing: Data?
    var written: Data?
}

@MainActor
@objc(ScadrettoDocument)
final class ScadrettoDocument: NSDocument {
    private nonisolated let io = OSAllocatedUnfairLock(initialState: DocumentIO())
    private lazy var source = SourceDocument(buffer: try! SourceBuffer())
    private weak var editor: SourceWindowController?
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
        let loaded = try SourceBuffer(bytes: data)
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
    }

    override var isDocumentEdited: Bool { source.isEdited }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        editor?.finishComposition()
        endTypingGroup()
        try super.revert(toContentsOf: url, ofType: typeName)
        adoptRead()
        editor?.show(source.snapshot, selecting: NSRange(location: 0, length: 0))
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
                do {
                    try target.commit(inverted, label: label, selection: previousSelection)
                } catch {
                    target.presentError(error)
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
        super.close()
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
