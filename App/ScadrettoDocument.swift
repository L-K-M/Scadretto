import AppKit
import os
import ScadrettoCore
import ScadrettoEngineClient
import ScadrettoPlanning
import ScadrettoViewport

private struct DocumentIO: Sendable {
    var pendingRead: SourceBuffer?
    var committed: Data = Data()
    var disk = DiskBaseline(acknowledged: nil)
    /// Where another program moved the file, until the user accepts or declines it.
    var movedTo: URL?
    /// Another program's coordinated write is under way.
    var otherWriter = false
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
    private var saving = false
    /// An autosave held back by composition or a pending conflict, to retry once it clears.
    private var autosaveDeferred = false
    /// A disk check waits for a running save or text composition to finish.
    private var diskCheckPending = false
    private var diskWindows: [NSWindowController] = []
    private var activation: (any NSObjectProtocol)?
    /// The source's undo history. NSDocument does not see it: when one of its own undo groups
    /// closes, NSDocument waits on the main thread for any running save or close, which hung
    /// closing with autosave in place. Changes reach AppKit through `updateChangeCount`.
    private lazy var history: UndoManager = {
        let history = UndoManager()
        history.groupsByEvent = false
        return history
    }()

    // AppKit constructs documents on its reading queue when concurrent
    // reads are enabled. The editable source model is created lazily on main.
    override nonisolated init() {
        super.init()
    }

    override class var autosavesInPlace: Bool { true }
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

    // NSDocument would adopt the new location, so Save would target another program's backup or
    // the Trash. The URL changes only when the user accepts the new location or uses Save As.
    override nonisolated func presentedItemDidMove(to newURL: URL) {
        io.withLock { $0.movedTo = newURL }
        Task { @MainActor [weak self] in await self?.checkDisk() }
    }

    // AppKit's own handling reverts an autosaving document it believes has no unsaved changes,
    // which loses text typed while another writer held the file. The disk check compares bytes.
    override nonisolated func presentedItemDidChange() {
        Task { @MainActor [weak self] in await self?.checkDisk() }
    }

    // While another program's coordinated write is under way, an autosave would wait for it and
    // then meet AppKit's date check instead of the disk check, so autosave waits for it to end.
    override nonisolated func relinquishPresentedItem(
        toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void
    ) {
        io.withLock { $0.otherWriter = true }
        super.relinquishPresentedItem(toWriter: { reacquirer in
            writer { [weak self] in
                self?.io.withLock { $0.otherWriter = false }
                reacquirer?()
                Task { @MainActor [weak self] in await self?.checkDisk() }
            }
        })
    }

    // A coordinated replacement announces a deletion before its change, so look once it settles
    // rather than trusting the kind of notice. The document stays open either way.
    override nonisolated func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await self?.checkDisk()
        }
    }

    override func makeWindowControllers() {
        adoptRead()
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
        controller.onCompositionFinished = { [weak self] in
            guard let self else { return }
            if diskCheckPending { Task { await self.checkDisk() } }
            resumeDeferredAutosave()
        }
        // A plain delete sends no presenter notice; look again whenever the app comes forward.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.checkDisk() }
        }
        controller.previewWorkspace.sidebar.inspector.onCommit = { [weak self] value in self?.submitProperty(value) }
        controller.previewWorkspace.sidebar.inspector.onChoice = { [weak self] index in self?.chooseProperty(index) }
        controller.previewWorkspace.viewport?.onEditCommit = { [weak self] sceneID, handleID, value in
            self?.commitProperty(value, sceneID: sceneID, handleID: handleID)
        }
        preview.schedule(source.snapshot, fileURL: fileURL, immediate: true)
    }

    // An unresolved external change or removal leaves the text unsaved even when it matches the
    // bytes last read, so closing still asks.
    override var isDocumentEdited: Bool {
        source.isEdited || io.withLock { $0.disk.conflict != nil }
    }

    // AppKit decides from this whether closing or quitting needs an autosave. Marked text is not
    // committed yet, and comparing the text with the file covers any change count it missed.
    override var hasUnautosavedChanges: Bool {
        super.hasUnautosavedChanges || editor?.isComposing == true || hasUnwrittenText
    }

    private var hasUnwrittenText: Bool {
        fileURL != nil && io.withLock { $0.committed != $0.disk.acknowledged }
    }

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
        if saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation {
            guard state.disk.allowsWrite(over: try Self.readDisk(at: url)) else {
                guard saveOperation == .autosaveInPlaceOperation else { throw DocumentSaveError.changedOnDisk }
                // AppKit would report a failed autosave on its own. Cancel quietly and show the
                // change instead, even when it was already known and dismissed.
                Task { @MainActor [weak self] in
                    await self?.checkDisk()
                    self?.presentPendingConflict()
                }
                throw CocoaError(.userCancelled)
            }
        }
        io.withLock { $0.writing = state.committed }
        defer { io.withLock { $0.writing = nil } }
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        if Self.writesDocumentFile(saveOperation) {
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
        saving = true
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            self?.saving = false
            if error == nil, let self, Self.writesDocumentFile(saveOperation) {
                let written = self.io.withLock { state in
                    let written = state.written
                    state.written = nil
                    if let written {
                        state.disk.adopt(written)
                        state.movedTo = nil
                    }
                    return written
                }
                // An autosave moves the disk baseline but not the last explicit save, so the
                // window stays edited until Save, as in other autosaving document apps.
                if written == snapshot.buffer.bytes, saveOperation != .autosaveInPlaceOperation {
                    self.source.acknowledgeSaved(snapshot)
                    self.editor?.window?.isDocumentEdited = self.isDocumentEdited
                }
                if priorURL != self.fileURL {
                    self.preview?.schedule(self.source.snapshot, fileURL: self.fileURL, immediate: true)
                }
            }
            if let self, self.diskCheckPending { Task { await self.checkDisk() } }
            completionHandler(error)
        }
    }

    /// Save, Save As and autosave in place write the document's own file and move its baseline.
    private nonisolated static func writesDocumentFile(_ operation: NSDocument.SaveOperationType) -> Bool {
        operation == .saveOperation || operation == .saveAsOperation || operation == .autosaveInPlaceOperation
    }

    // Marked text belongs to the composing view until it is committed, and a pending external
    // change needs the user's decision before anything is written over it. AppKit's own autosave
    // compares modification dates and offers a Revert that discards the local text, so the path
    // is checked first. The read is not coordinated because AppKit's close and quit sequences
    // crashed or hung when this method finished later; `writeSafely` checks the bytes again
    // inside the coordinated write.
    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
                           completionHandler: @escaping (Error?) -> Void) {
        // Closing and quitting ask for an autosave that cannot be put off, and finish any
        // composition first. This autosave replaces any that was held back, so the disk check
        // below does not start another.
        let unavoidable = !autosavingIsImplicitlyCancellable
        autosaveDeferred = false
        if unavoidable { editor?.finishComposition() }
        guard let url = fileURL else {
            // An untitled document autosaves elsewhere; there is no file of its own to protect.
            super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable,
                           completionHandler: completionHandler)
            return
        }
        let otherWriter = io.withLock { $0.otherWriter }
        if !otherWriter, editor?.isComposing != true, io.withLock({ $0.disk.conflict == nil }),
           let disk = try? Self.readDisk(at: url) {
            applyDisk(disk, at: url, presenting: !unavoidable)
        }
        let conflict = io.withLock { $0.disk.conflict }
        if unavoidable, let conflict, hasUnwrittenText {
            // AppKit's quit sequence expects an answer before it continues.
            autosaveDeferred = true
            let choice = unsavedTextAlert(for: conflict).runModal()
            completionHandler(choice == .alertThirdButtonReturn ? nil : CocoaError(.userCancelled))
            if choice == .alertFirstButtonReturn { saveAs(nil) }
            return
        }
        if conflict != nil || otherWriter || editor?.isComposing == true {
            autosaveDeferred = true
            completionHandler(CocoaError(.userCancelled))
            return
        }
        if !hasUnwrittenText {
            // An undo back to the bytes last written leaves nothing to write.
            updateChangeCount(.changeAutosaved)
            completionHandler(nil)
            return
        }
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable,
                       completionHandler: completionHandler)
    }

    private func resumeDeferredAutosave() {
        guard autosaveDeferred, hasUnautosavedChanges else { return }
        autosave(withImplicitCancellability: true) { _ in }
    }

    // Composition ends through the input system before AppKit decides whether to save or close.
    // Autosaving in place, AppKit closes without asking and would refuse quietly while an
    // external change is pending, so closing then asks what to do with the unsaved text.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        editor?.finishComposition()
        guard let conflict = io.withLock({ $0.disk.conflict }), hasUnwrittenText,
              let window = editor?.window, window.attachedSheet == nil else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        unsavedTextAlert(for: conflict).beginSheetModal(for: window) { [weak self] choice in
            guard let self else { return }
            answer(delegate, shouldCloseSelector, contextInfo: contextInfo,
                   shouldClose: choice == .alertThirdButtonReturn)
            if choice == .alertFirstButtonReturn { saveAs(nil) }
        }
    }

    /// Asks before closing or quitting drops text that a pending external change keeps from
    /// being written: Save As…, Cancel, or Don’t Save.
    private func unsavedTextAlert(for conflict: DiskBaseline.Conflict) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Your edits to “\(fileName)” are not saved"
        switch conflict {
        case .changed:
            alert.informativeText = "Another application changed the file, so Scadretto has not written your "
                + "edits over it. Save As keeps them in a new file."
        case .removed:
            alert.informativeText = "The file is no longer at its location. Save As keeps your edits in a file."
        }
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").hasDestructiveAction = true
        return alert
    }

    /// Sends AppKit's `document:shouldClose:contextInfo:` reply to the close requester.
    private func answer(_ delegate: Any, _ selector: Selector?, contextInfo: UnsafeMutableRawPointer?,
                        shouldClose: Bool) {
        guard let selector, let target = delegate as? NSObject else { return }
        typealias ShouldClose = @convention(c) (NSObject, Selector, NSDocument, ObjCBool, UnsafeMutableRawPointer?) -> Void
        let reply = unsafeBitCast(target.method(for: selector), to: ShouldClose.self)
        reply(target, selector, self, ObjCBool(shouldClose), contextInfo)
    }

    /// Saves to the checked path. AppKit's Save would run its own move and date checks, which ask
    /// again after the user has already accepted a new location; `writeSafely` checks the bytes.
    private func saveCheckedDocument() {
        guard let url = fileURL, let type = fileType else { return }
        save(to: url, ofType: type, for: .saveOperation) { [weak self] error in
            guard let self, let error else { return }
            if let window = editor?.window {
                presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            } else {
                presentError(error)
            }
        }
    }

    override func save(_ sender: Any?) {
        editor?.finishComposition()
        guard let url = fileURL else {
            super.save(sender)
            return
        }
        // Look at the path before AppKit's own checks, which would offer to follow a move.
        Task { [weak self] in
            guard let self, let disk = await readDiskCoordinated(url), url == fileURL else { return }
            switch applyDisk(disk, at: url, presenting: false) {
            case nil: saveCheckedDocument()
            case .changed(let reviewed): askToOverwrite(reviewed)
            case .removed: present(.removed)
            }
        }
    }

    private func adoptRead() {
        guard let loaded = io.withLock({ state -> SourceBuffer? in
            let loaded = state.pendingRead
            state.pendingRead = nil
            return loaded
        }) else { return }
        do {
            try replaceSource(with: loaded)
            io.withLock {
                $0.disk.adopt(loaded.bytes)
                $0.movedTo = nil
            }
        } catch {
            presentError(error)
        }
    }

    /// Replaces the whole text as a new starting point: no undo history, selection or edit that
    /// pointed into the old text survives.
    private func replaceSource(with buffer: SourceBuffer) throws {
        try source.reload(buffer)
        featureSelection = nil
        activeEdit = nil
        sourceChange = nil
        propertyChoices = []
        propertyChoiceID = nil
        editor?.previewWorkspace.sidebar.inspector.show(nil)
        io.withLock { $0.committed = buffer.bytes }
        history.removeAllActions()
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

        do {
            let manager = history
            if !manager.isUndoing && !manager.isRedoing {
                updateChangeCount(.changeDone)
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
            if history.groupingLevel > 0 {
                history.endUndoGrouping()
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
                if !PropertyChoice.continues(propertyChoiceID, to: id, along: selection.path, in: scene,
                                             files: result.files) {
                    propertyChoiceID = Self.noChoice
                }
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
        guard let active = activeEdit,
              let shown = propertyChoices.first(where: { $0.id == active.choiceID })?.value else { return }
        guard let value = PropertyEntry.value(of: text, shown: shown) else {
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
        guard history.canUndo else { return }
        history.undo()
        updateChangeCount(.changeUndone)
    }

    @IBAction func redoSource(_ sender: Any?) {
        editor?.finishComposition()
        endTypingGroup()
        guard history.canRedo else { return }
        history.redo()
        updateChangeCount(.changeRedone)
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
                menu.title = typing ? "Undo Typing" : history.undoMenuItemTitle
            }
            return typing || history.canUndo
        }
        if item.action == #selector(redoSource(_:)) {
            if let menu = item as? NSMenuItem { menu.title = history.redoMenuItemTitle }
            return history.canRedo
        }
        if item.action == #selector(revertToLastSaved(_:)) {
            return fileURL != nil && (isDocumentEdited || hasUnautosavedChanges)
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Autosaving in place, the file holds the latest text, so Revert to Saved puts back the text
    /// last opened or saved and writes it through the checked Save. AppKit's own revert restores
    /// a version it records from undo notifications, which the private history does not send,
    /// and AppKit removes a File menu item whose action is that revert.
    @objc func revertToLastSaved(_ sender: Any?) {
        editor?.finishComposition()
        guard fileURL != nil, let window = editor?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Revert “\(fileName)” to the last saved version?"
        alert.informativeText = "Changes since you last opened or saved it are discarded, in the file as well. "
            + "You can’t undo this."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                endTypingGroup()
                try replaceSource(with: try SourceBuffer(bytes: source.savedBytes))
                editor?.show(source.snapshot, selecting: NSRange(location: 0, length: 0))
                editor?.window?.isDocumentEdited = isDocumentEdited
                preview?.schedule(source.snapshot, fileURL: fileURL, immediate: true)
                // Save looks at the path first, so an external change still gets its question.
                save(nil)
            } catch {
                presentError(error)
            }
        }
    }

    override func close() {
        endTypingGroup()
        preview?.close()
        if let activation { NotificationCenter.default.removeObserver(activation) }
        for window in diskWindows { window.close() }
        diskWindows = []
        super.close()
    }

    // MARK: - External changes

    private nonisolated static func readDisk(at url: URL) throws -> DiskBaseline.Disk {
        do {
            return .bytes(try Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        }
    }

    /// Reads the path off the main thread. Naming this document as the presenter keeps the read
    /// from asking it to save first. Nil when the path cannot be read at all.
    private func readDiskCoordinated(_ url: URL) async -> DiskBaseline.Disk? {
        let presenter = self
        return await Task.detached(priority: .userInitiated) {
            var coordination: NSError?
            var disk: DiskBaseline.Disk?
            NSFileCoordinator(filePresenter: presenter).coordinate(
                readingItemAt: url, options: .withoutChanges, error: &coordination
            ) { local in
                disk = try? Self.readDisk(at: local)
            }
            if let coordination, coordination.code == CocoaError.fileReadNoSuchFile.rawValue { return .missing }
            return disk
        }.value
    }

    private func checkDisk() async {
        guard let url = fileURL else { return }
        diskCheckPending = false
        guard !saving, editor?.isComposing != true else {
            diskCheckPending = true
            return
        }
        guard let disk = await readDiskCoordinated(url), url == fileURL else { return }
        guard !saving, editor?.isComposing != true else {
            diskCheckPending = true
            return
        }
        applyDisk(disk, at: url, presenting: true)
    }

    /// Applies an observation of the path and returns the conflict still pending.
    @discardableResult
    private func applyDisk(_ disk: DiskBaseline.Disk, at url: URL, presenting: Bool) -> DiskBaseline.Conflict? {
        let local = source.buffer.bytes
        var reaction = io.withLock { $0.disk.observe(disk, local: local) }
        if case .reload(let bytes) = reaction {
            if let buffer = try? SourceBuffer(bytes: bytes) {
                replaceContents(with: buffer)
                reaction = .none
            } else {
                reaction = io.withLock { $0.disk.decline(bytes) }
            }
        }
        let conflict = io.withLock { $0.disk.conflict }
        // AppKit compares this date on Save and would raise its own alert for a change the
        // document has already taken or settled.
        if conflict == nil {
            fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        editor?.window?.isDocumentEdited = isDocumentEdited
        if presenting, case .conflict(let raised) = reaction { present(raised) }
        if conflict == nil { resumeDeferredAutosave() }
        return conflict
    }

    private func replaceContents(with buffer: SourceBuffer) {
        endTypingGroup()
        let selection = editor?.selection ?? NSRange(location: 0, length: 0)
        io.withLock { $0.pendingRead = buffer }
        adoptRead()
        // The text now matches the file, so there is nothing for AppKit to autosave.
        updateChangeCount(.changeCleared)
        editor?.show(source.snapshot, selecting: selection)
        preview?.schedule(source.snapshot, fileURL: fileURL, immediate: true)
    }

    private func reloadFromDisk() {
        guard let url = fileURL else { return }
        Task { [weak self] in
            guard let self, let disk = await readDiskCoordinated(url), url == fileURL else { return }
            guard case .bytes(let bytes) = disk else {
                applyDisk(disk, at: url, presenting: true)
                return
            }
            do {
                replaceContents(with: try SourceBuffer(bytes: bytes))
                fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                editor?.window?.isDocumentEdited = isDocumentEdited
            } catch {
                presentError(error)
            }
        }
    }

    private var fileName: String { fileURL?.lastPathComponent ?? displayName ?? "This document" }

    private func presentPendingConflict() {
        if let conflict = io.withLock({ $0.disk.conflict }) { present(conflict) }
    }

    private func present(_ conflict: DiskBaseline.Conflict) {
        guard let window = editor?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        switch conflict {
        case .changed(let reviewed):
            alert.messageText = "“\(fileName)” changed on disk"
            alert.informativeText = "Another application changed the file. Your edits in Scadretto are not saved. "
                + "Reload from Disk discards them."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Reload from Disk")
            alert.addButton(withTitle: "Compare")
            alert.beginSheetModal(for: window) { [weak self] response in
                switch response {
                case .alertSecondButtonReturn: self?.reloadFromDisk()
                case .alertThirdButtonReturn: self?.showDiskVersion(reviewed)
                default: break
                }
            }
        case .removed:
            let moved = io.withLock { $0.movedTo }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            alert.messageText = "“\(fileName)” is no longer at its location"
            if let moved {
                alert.informativeText = "Another application moved it to “\(moved.lastPathComponent)”. Your text stays open. "
                    + "Use New Location to keep editing that file, or Save As to choose another."
            } else {
                alert.informativeText = "Your text stays open in Scadretto. Choose Save As to keep it in a file."
            }
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Save As…")
            if moved != nil { alert.addButton(withTitle: "Use New Location") }
            alert.beginSheetModal(for: window) { [weak self] response in
                switch response {
                case .alertSecondButtonReturn: self?.saveAs(nil)
                case .alertThirdButtonReturn: if let moved { self?.acceptMove(to: moved) }
                default: break
                }
            }
        }
    }

    private func askToOverwrite(_ reviewed: Data) {
        guard let window = editor?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "“\(fileName)” changed on disk"
        alert.informativeText = "Overwrite replaces the other application's version with your text. "
            + "Save As keeps both."
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                saveAs(nil)
            case .alertSecondButtonReturn:
                // The approval covers only the reviewed bytes. If the file changed again while
                // the question was open, show that version once this sheet is gone; if it went
                // back to the version last agreed with, save normally.
                guard io.withLock({ $0.disk.conflict }) == .changed(reviewed) else {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if io.withLock({ $0.disk.conflict }) == nil {
                            saveCheckedDocument()
                        } else {
                            presentPendingConflict()
                        }
                    }
                    return
                }
                io.withLock { $0.disk.approveOverwrite() }
                if let url = fileURL {
                    fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                }
                saveCheckedDocument()
            default:
                break
            }
        }
    }

    private func acceptMove(to url: URL) {
        io.withLock { $0.movedTo = nil }
        fileURL = url
        preview?.schedule(source.snapshot, fileURL: url, immediate: true)
        Task { await checkDisk() }
    }

    private func showDiskVersion(_ bytes: Data) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(fileName) (Disk Version)"
        window.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            text.string = (try? SourceBuffer(bytes: bytes))?.displayText ?? String(decoding: bytes, as: UTF8.self)
            text.setAccessibilityLabel("Disk version of \(fileName)")
        }
        window.contentView = scroll
        let controller = NSWindowController(window: window)
        diskWindows.removeAll { $0.window?.isVisible != true }
        diskWindows.append(controller)
        if let main = editor?.window { window.setFrameTopLeftPoint(NSPoint(x: main.frame.minX + 40, y: main.frame.maxY - 40)) }
        controller.showWindow(nil)
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
