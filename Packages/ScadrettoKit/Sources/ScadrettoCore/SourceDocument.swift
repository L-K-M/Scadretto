import Foundation

public struct SourceSpan: Equatable, Sendable {
    public let fileID: UUID
    public let contentDigest: String
    public let bytes: Range<Int>

    public init(fileID: UUID, contentDigest: String, bytes: Range<Int>) {
        self.fileID = fileID
        self.contentDigest = contentDigest
        self.bytes = bytes
    }
}

public struct SourceSnapshot: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let buffer: SourceBuffer

    public func span(for bytes: Range<Int>) throws -> SourceSpan {
        _ = try buffer.textRange(for: bytes)
        return SourceSpan(fileID: documentID, contentDigest: buffer.sha256, bytes: bytes)
    }
}

public struct SourceTransaction: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let edits: [SourceEdit]
    public let label: String

    public init(documentID: UUID, revision: UInt64, edits: [SourceEdit], label: String) {
        self.documentID = documentID
        self.revision = revision
        self.edits = edits
        self.label = label
    }
}

@MainActor
public final class SourceDocument {
    public let id = UUID()
    public private(set) var revision: UInt64 = 0
    public private(set) var buffer: SourceBuffer
    public private(set) var savedBytes: Data

    public init(buffer: SourceBuffer) {
        self.buffer = buffer
        self.savedBytes = buffer.bytes
    }

    public var isEdited: Bool { buffer.bytes != savedBytes }

    public var snapshot: SourceSnapshot {
        SourceSnapshot(documentID: id, revision: revision, buffer: buffer)
    }

    public func transaction(edits: [SourceEdit], label: String) -> SourceTransaction {
        SourceTransaction(documentID: id, revision: revision, edits: edits, label: label)
    }

    @discardableResult
    public func apply(_ transaction: SourceTransaction) throws -> [SourceEdit] {
        guard transaction.documentID == id, transaction.revision == revision else {
            throw SourceError.staleRevision
        }
        let change = try buffer.applying(transaction.edits)
        guard !change.inverse.isEmpty else { return [] }
        try advanceRevision()
        buffer = change.buffer
        return change.inverse
    }

    public func reload(_ buffer: SourceBuffer) throws {
        try advanceRevision()
        self.buffer = buffer
        savedBytes = buffer.bytes
    }

    public func acknowledgeSaved(_ snapshot: SourceSnapshot) {
        guard snapshot.documentID == id else { return }
        savedBytes = snapshot.buffer.bytes
    }

    private func advanceRevision() throws {
        guard revision < UInt64.max else { throw SourceError.revisionLimit }
        revision += 1
    }
}
