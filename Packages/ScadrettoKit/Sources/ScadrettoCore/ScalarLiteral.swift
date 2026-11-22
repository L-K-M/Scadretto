import Foundation

/// Which authored values a scalar binding accepts. The constraint applies to
/// the value written into the source, after display conversion.
public enum ScalarConstraint: Equatable, Sendable {
    /// Any finite value, including negatives and zero (e.g. translate parts).
    case finite
    /// A finite value greater than zero (e.g. direct size handles).
    case positive

    public func allows(_ value: Double) -> Bool {
        switch self {
        case .finite: value.isFinite
        case .positive: value.isFinite && value > 0
        }
    }
}

public enum ScalarEditError: LocalizedError, Equatable, Sendable {
    case unverifiedLiteral
    case staleSource
    case invalidValue(ScalarConstraint)

    public var errorDescription: String? {
        switch self {
        case .unverifiedLiteral: "The value does not resolve to a verified numeric literal."
        case .staleSource: "The value target changed. Wait for the current preview and select it again."
        case .invalidValue(.positive): "Enter a value greater than zero."
        case .invalidValue(.finite): "Enter a finite number."
        }
    }
}

/// An evaluated numeric literal in the main document, presented and edited
/// through a display multiplier for alias conversions: a source radius with
/// multiplier 2 is shown as a diameter, and a displayed 5 writes back `2.5`.
///
/// The syntax/worker adapter must verify before constructing that
/// `numericToken` is the byte range of the token actually consumed for
/// `authoredValue` (a number node, or the signed numeric token when the
/// grammar keeps the sign as syntax), that `span` is the document-scoped span
/// of the binding region used for highlight and identity, and that the digest
/// belongs to the same snapshot. `span.bytes` may equal `numericToken`, the
/// common case, or contain it; only the token bytes are ever replaced.
public struct ScalarLiteral: Equatable, Sendable {
    public let span: SourceSpan
    public let numericToken: Range<Int>
    public let authoredValue: Double
    public let displayMultiplier: Double
    public let constraint: ScalarConstraint
    private let expected: Data
    private let revision: UInt64

    /// The value shown to the user: the authored value times the multiplier.
    public var displayValue: Double { authoredValue * displayMultiplier }

    public init(source: SourceSnapshot, span: SourceSpan, numericToken: Range<Int>,
                authoredValue: Double, displayMultiplier: Double = 1,
                constraint: ScalarConstraint = .finite) throws {
        guard span.fileID == source.documentID, span.contentDigest == source.buffer.sha256 else {
            throw ScalarEditError.staleSource
        }
        guard !numericToken.isEmpty,
              numericToken.lowerBound >= span.bytes.lowerBound,
              numericToken.upperBound <= span.bytes.upperBound,
              (try? source.span(for: span.bytes)) != nil,
              (try? source.span(for: numericToken)) != nil else {
            throw ScalarEditError.unverifiedLiteral
        }
        let token = source.buffer.bytes.subdata(in: numericToken)
        guard displayMultiplier.isFinite, displayMultiplier != 0,
              constraint.allows(authoredValue),
              Double(String(decoding: token, as: UTF8.self)) == authoredValue else {
            throw ScalarEditError.unverifiedLiteral
        }
        self.span = span
        self.numericToken = numericToken
        self.authoredValue = authoredValue
        self.displayMultiplier = displayMultiplier
        self.constraint = constraint
        expected = token
        revision = source.revision
    }

    /// Plan a write of `displayValue`, converted back to authored units by the
    /// multiplier. Returns nil when the value is already current. Throws
    /// `.staleSource` when the document, revision, digest or token bytes no
    /// longer match, and `.invalidValue` when the result is not finite or
    /// violates the constraint.
    public func edit(setting displayValue: Double, in source: SourceSnapshot) throws -> SourceEdit? {
        guard source.revision == revision, source.documentID == span.fileID,
              source.buffer.sha256 == span.contentDigest,
              (try? source.span(for: numericToken)) != nil,
              source.buffer.bytes.subdata(in: numericToken) == expected else {
            throw ScalarEditError.staleSource
        }
        let authored = displayValue / displayMultiplier
        guard constraint.allows(authored) else {
            throw ScalarEditError.invalidValue(constraint)
        }
        guard authored != authoredValue else { return nil }
        return SourceEdit(range: numericToken, expected: expected,
                          replacement: Data(scadDecimalText(authored).utf8))
    }
}

/// Shortest round-trip finite decimal with a dot separator, independent of
/// the macOS locale. Integral values drop the trailing `.0`.
func scadDecimalText(_ value: Double) -> String {
    let decimal = String(value)
    return decimal.hasSuffix(".0") ? String(decimal.dropLast(2)) : decimal
}
