import CryptoKit
import Foundation

public enum SourceError: Error, Equatable, LocalizedError, Sendable {
    case invalidUTF8(byte: Int)
    case invalidRange
    case overlappingEdits
    case staleRevision
    case changedBytes
    case revisionLimit

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8(let byte): "The file is not valid UTF-8 at byte \(byte)."
        case .invalidRange: "The edit does not align with a source character boundary."
        case .overlappingEdits: "The source edits overlap."
        case .staleRevision: "The source changed before the edit could be applied."
        case .changedBytes: "The source no longer contains the text expected by the edit."
        case .revisionLimit: "The source revision limit has been reached."
        }
    }
}

public struct SourceEdit: Equatable, Sendable {
    public let range: Range<Int>
    public let expected: Data
    public let replacement: Data

    public init(range: Range<Int>, expected: Data, replacement: Data) {
        self.range = range
        self.expected = expected
        self.replacement = replacement
    }
}

public struct SourceBuffer: Equatable, Sendable {
    private struct Boundary: Sendable {
        let byte: Int
        let utf16: Int
    }

    private enum Newline: Sendable {
        case lf
        case crlf
        case cr

        var bytes: [UInt8] {
            switch self {
            case .lf: [0x0A]
            case .crlf: [0x0D, 0x0A]
            case .cr: [0x0D]
            }
        }
    }

    private struct LineEnd: Sendable {
        let offset: Int
        let convention: Newline
    }

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    public let bytes: Data
    public let displayText: String
    public let bomLength: Int
    private let boundaries: [Boundary]
    private let lineEnds: [LineEnd]

    public init(bytes: Data = Data()) throws {
        let raw = Array(bytes)
        let bomLength = raw.starts(with: Self.bom) ? Self.bom.count : 0
        var boundaries = [Boundary(byte: bomLength, utf16: 0)]
        var lineEnds: [LineEnd] = []
        var display: [UInt8] = []
        display.reserveCapacity(raw.count - bomLength)

        var byte = bomLength
        var utf16 = 0
        while byte < raw.count {
            let length = try Self.scalarLength(raw, at: byte)
            if let separator = Self.separator(raw, at: byte, length: length) {
                lineEnds.append(LineEnd(offset: utf16, convention: separator.convention))
                display.append(0x0A)
                byte += separator.width
                utf16 += 1
            } else {
                display.append(contentsOf: raw[byte..<(byte + length)])
                byte += length
                utf16 += length == 4 ? 2 : 1
            }
            boundaries.append(Boundary(byte: byte, utf16: utf16))
        }

        self.bytes = Data(raw)
        self.bomLength = bomLength
        self.displayText = String(decoding: display, as: UTF8.self)
        self.boundaries = boundaries
        self.lineEnds = lineEnds
    }

    public static func == (lhs: SourceBuffer, rhs: SourceBuffer) -> Bool {
        lhs.bytes == rhs.bytes
    }

    public var utf16Length: Int { boundaries.last!.utf16 }

    public func lineNumber(atUTF16Offset offset: Int) -> Int {
        lowerBound(in: lineEnds, for: offset, by: \.offset) + 1
    }

    public var sha256: String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public func byteRange(for range: NSRange) throws -> Range<Int> {
        guard range.location >= 0, range.location <= utf16Length,
              range.length >= 0, range.length <= utf16Length - range.location,
              let start = boundary(at: range.location, by: \.utf16),
              let end = boundary(at: range.location + range.length, by: \.utf16) else {
            throw SourceError.invalidRange
        }
        return start.byte..<end.byte
    }

    public func textRange(for range: Range<Int>) throws -> NSRange {
        guard let start = boundary(at: range.lowerBound, by: \.byte),
              let end = boundary(at: range.upperBound, by: \.byte) else {
            throw SourceError.invalidRange
        }
        return NSRange(location: start.utf16, length: end.utf16 - start.utf16)
    }

    public func textEdit(range: NSRange, replacement: String) throws -> SourceEdit {
        let span = try byteRange(for: range)
        let line = lowerBound(in: lineEnds, for: range.location, by: \.offset)
        let convention = line < lineEnds.count ? lineEnds[line].convention : lineEnds.last?.convention ?? .lf
        return SourceEdit(
            range: span,
            expected: bytes.subdata(in: span),
            replacement: Self.normalizedInsertion(replacement, convention: convention)
        )
    }

    // Sort and verify every original slice before mutating a copy of the bytes.
    // Merge adjacent edits so their inverse cannot contain coincident insertions.
    public func applying(_ edits: [SourceEdit]) throws -> (buffer: SourceBuffer, inverse: [SourceEdit]) {
        var checked: [SourceEdit] = []
        var lastRange: Range<Int>?
        for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard isEditBoundary(edit.range.lowerBound), isEditBoundary(edit.range.upperBound) else {
                throw SourceError.invalidRange
            }
            guard bytes.subdata(in: edit.range) == edit.expected else { throw SourceError.changedBytes }
            if let lastRange {
                guard lastRange.lowerBound != edit.range.lowerBound,
                      lastRange.upperBound <= edit.range.lowerBound else {
                    throw SourceError.overlappingEdits
                }
            }
            lastRange = edit.range
            if edit.expected == edit.replacement { continue }

            if let previous = checked.last, previous.range.upperBound == edit.range.lowerBound {
                checked[checked.count - 1] = SourceEdit(
                    range: previous.range.lowerBound..<edit.range.upperBound,
                    expected: previous.expected + edit.expected,
                    replacement: previous.replacement + edit.replacement
                )
            } else {
                checked.append(edit)
            }
        }

        if checked.isEmpty { return (self, []) }
        var changed = bytes
        for edit in checked.reversed() {
            changed.replaceSubrange(edit.range, with: edit.replacement)
        }

        let result = try SourceBuffer(bytes: changed)
        var shift = 0
        var inverse: [SourceEdit] = []
        for edit in checked {
            let start = edit.range.lowerBound + shift
            let end = start + edit.replacement.count
            let range = start..<end
            guard result.isEditBoundary(start), result.isEditBoundary(end) else {
                throw SourceError.invalidRange
            }
            inverse.append(SourceEdit(range: range, expected: edit.replacement, replacement: edit.expected))
            shift += edit.replacement.count - edit.expected.count
        }
        return (result, inverse)
    }

    private func isEditBoundary(_ offset: Int) -> Bool {
        if offset == 0 || boundary(at: offset, by: \.byte) != nil { return true }
        // An edit can join two original separators into a CRLF pair. Its
        // inverse can then insert bytes between CR and LF, outside display coordinates.
        return offset > 0 && offset < bytes.count &&
            bytes[offset - 1] == 0x0D && bytes[offset] == 0x0A
    }

    private func boundary(at offset: Int, by key: KeyPath<Boundary, Int>) -> Boundary? {
        let index = lowerBound(in: boundaries, for: offset, by: key)
        guard index < boundaries.count, boundaries[index][keyPath: key] == offset else { return nil }
        return boundaries[index]
    }

    private func lowerBound<Element>(in values: [Element], for offset: Int, by key: KeyPath<Element, Int>) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = low + (high - low) / 2
            if values[middle][keyPath: key] < offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func scalarLength(_ bytes: [UInt8], at index: Int) throws -> Int {
        let first = bytes[index]
        let length: Int
        switch first {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF4: length = 4
        default: throw SourceError.invalidUTF8(byte: index)
        }
        guard length <= bytes.count - index else { throw SourceError.invalidUTF8(byte: index) }

        let second = bytes[index + 1]
        let secondRange: ClosedRange<UInt8>
        switch first {
        case 0xE0: secondRange = 0xA0...0xBF
        case 0xED: secondRange = 0x80...0x9F
        case 0xF0: secondRange = 0x90...0xBF
        case 0xF4: secondRange = 0x80...0x8F
        default: secondRange = 0x80...0xBF
        }
        guard secondRange.contains(second) else { throw SourceError.invalidUTF8(byte: index) }
        for continuation in (index + 2)..<(index + length) {
            guard (0x80...0xBF).contains(bytes[continuation]) else {
                throw SourceError.invalidUTF8(byte: index)
            }
        }
        return length
    }

    private static func separator(_ raw: [UInt8], at index: Int, length: Int) -> (width: Int, convention: Newline)? {
        switch raw[index] {
        case 0x0D:
            if index + 1 < raw.count, raw[index + 1] == 0x0A { return (2, .crlf) }
            return (1, .cr)
        case 0x0A: return (1, .lf)
        case 0xE2 where length == 3 && raw[index + 1] == 0x80 && (0xA8...0xA9).contains(raw[index + 2]):
            return (3, .lf)
        default: return nil
        }
    }

    private static func normalizedInsertion(_ string: String, convention: Newline) -> Data {
        let raw = Array(string.utf8)
        var result = Data()
        result.reserveCapacity(raw.count)
        var index = 0
        while index < raw.count {
            let length = min(3, raw.count - index)
            if let separator = separator(raw, at: index, length: length) {
                result.append(contentsOf: convention.bytes)
                index += separator.width
            } else {
                result.append(raw[index])
                index += 1
            }
        }
        return result
    }
}
