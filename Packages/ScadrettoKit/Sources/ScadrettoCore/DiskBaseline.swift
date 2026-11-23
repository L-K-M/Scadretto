import Foundation

/// The file contents a document last agreed with, and any external change
/// the user has not resolved yet. Pure rules; the app supplies observations.
public struct DiskBaseline: Equatable, Sendable {
    /// What a coordinated read found at the document's path.
    public enum Disk: Equatable, Sendable {
        case bytes(Data)
        case missing
    }

    public enum Conflict: Equatable, Sendable {
        /// Another writer replaced the file while the document had unsaved edits.
        case changed(Data)
        /// The document's path holds no file.
        case removed
    }

    public enum Reaction: Equatable, Sendable {
        case none
        /// The document has no unsaved edits, so it can take the new bytes.
        /// Call `adopt` once they load, or `decline` if they cannot.
        case reload(Data)
        case conflict(Conflict)
    }

    /// The bytes last read from or written to the path. Nil for a document
    /// that has never had a file.
    public private(set) var acknowledged: Data?
    public private(set) var conflict: Conflict?
    /// The external version the user chose to overwrite. Any other version
    /// on disk needs a fresh decision.
    private var approved: Data?

    public init(acknowledged: Data?) {
        self.acknowledged = acknowledged
    }

    /// Classifies what a read of the path found, given the document's bytes.
    public mutating func observe(_ disk: Disk, local: Data) -> Reaction {
        guard let acknowledged else { return .none }
        switch disk {
        case .bytes(let bytes) where bytes == acknowledged:
            // The file is back to what the document knows, whatever happened in between.
            settle()
            return .none
        case .bytes(let bytes):
            // Reloading loses nothing; the app adopts the bytes once they load.
            if local == acknowledged { return .reload(bytes) }
            return raise(.changed(bytes))
        case .missing:
            return raise(.removed)
        }
    }

    /// Lets Save replace the changed version the user reviewed, and only that one.
    /// A removed file stays removed: Save As chooses a new location.
    public mutating func approveOverwrite() {
        guard case .changed(let reviewed) = conflict else { return }
        approved = reviewed
    }

    /// Whether Save may replace what a read inside the coordinated write found.
    public func allowsWrite(over disk: Disk) -> Bool {
        guard let acknowledged else { return disk == .missing }
        switch conflict {
        case nil: return disk == .bytes(acknowledged)
        case .changed(let reviewed): return approved == reviewed && disk == .bytes(reviewed)
        case .removed: return false
        }
    }

    /// Keeps the document's text when changed bytes cannot be reloaded, such
    /// as text that is not UTF-8.
    public mutating func decline(_ bytes: Data) -> Reaction {
        raise(.changed(bytes))
    }

    /// Records bytes the document wrote, reloaded or reverted to.
    public mutating func adopt(_ bytes: Data) {
        acknowledged = bytes
        settle()
    }

    private mutating func raise(_ next: Conflict) -> Reaction {
        guard conflict != next else { return .none }
        conflict = next
        approved = nil
        return .conflict(next)
    }

    private mutating func settle() {
        conflict = nil
        approved = nil
    }
}
