import Foundation

public enum DiameterEditError: LocalizedError, Equatable, Sendable {
    case unverifiedLiteral
    case staleSource
    case invalidDiameter

    public var errorDescription: String? {
        switch self {
        case .unverifiedLiteral: "The diameter does not resolve to a verified numeric literal."
        case .staleSource: "The diameter target changed. Wait for the current preview and select it again."
        case .invalidDiameter: "Enter a diameter greater than zero."
        }
    }
}

/// A positive diameter backed by one exact, syntax-verified token in the main
/// document. The worker adapter supplies the target span from the binding.
public struct DiameterLiteral: Equatable, Sendable {
    public let span: SourceSpan
    public let value: Double
    private let expected: Data
    private let revision: UInt64

    public init(source: SourceSnapshot, span: SourceSpan, numericToken: Range<Int>, value: Double) throws {
        guard span == (try? source.span(for: numericToken)) else { throw DiameterEditError.staleSource }
        let token = source.buffer.bytes.subdata(in: span.bytes)
        guard value.isFinite, value > 0, Double(String(decoding: token, as: UTF8.self)) == value else {
            throw DiameterEditError.unverifiedLiteral
        }
        self.span = span
        self.value = value
        expected = token
        revision = source.revision
    }

    public func edit(setting diameter: Double, in source: SourceSnapshot) throws -> SourceEdit? {
        guard source.revision == revision, span == (try? source.span(for: span.bytes)),
              source.buffer.bytes.subdata(in: span.bytes) == expected else {
            throw DiameterEditError.staleSource
        }
        guard diameter.isFinite, diameter > 0 else { throw DiameterEditError.invalidDiameter }
        guard diameter != value else { return nil }
        let decimal = String(diameter)
        let token = decimal.hasSuffix(".0") ? String(decimal.dropLast(2)) : decimal
        return SourceEdit(range: span.bytes, expected: expected, replacement: Data(token.utf8))
    }
}
