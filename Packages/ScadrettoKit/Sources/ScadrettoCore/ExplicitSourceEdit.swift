import Foundation

public enum ExplicitEditError: LocalizedError, Equatable, Sendable {
    case staleSource
    case unverifiedTarget
    case invalidValue

    public var errorDescription: String? {
        switch self {
        case .staleSource: "The edit target changed. Wait for the current preview and select it again."
        case .unverifiedTarget: "The target does not resolve to verified expression syntax."
        case .invalidValue: "Enter finite numbers."
        }
    }
}

/// Verified rewrites that leave the authored expression intact: an explicit
/// local arithmetic offset, and a transform prefix inserted at a statement
/// boundary. The syntax/worker adapter verifies each target before
/// construction; the planner never folds or reinterprets user text.
public enum ExplicitSourceEdit {

    /// An expression that can receive an explicit local offset: `wall/2`
    /// becomes `(wall/2) + 3`. The original bytes are wrapped verbatim and a
    /// finite signed constant is appended, never folded into an existing
    /// `+ c`, so repeated offsets nest as `((wall/2) + 3) + 2`.
    ///
    /// The adapter must verify in the syntax tree that `expression` is the
    /// byte range of a complete expression node supplying the value, inside
    /// the document-scoped `span` of the binding. Expressions whose bytes end
    /// inside a line comment, an unterminated block comment or an
    /// unterminated string are rejected because the appended `)` would be
    /// swallowed.
    public struct Offset: Equatable, Sendable {
        public let span: SourceSpan
        public let expression: Range<Int>
        private let expected: Data
        private let revision: UInt64

        public init(source: SourceSnapshot, span: SourceSpan, expression: Range<Int>) throws {
            guard span.fileID == source.documentID,
                  span.contentDigest == source.buffer.sha256 else {
                throw ExplicitEditError.staleSource
            }
            guard !expression.isEmpty,
                  expression.lowerBound >= span.bytes.lowerBound,
                  expression.upperBound <= span.bytes.upperBound,
                  (try? source.span(for: span.bytes)) != nil,
                  (try? source.span(for: expression)) != nil else {
                throw ExplicitEditError.unverifiedTarget
            }
            let bytes = source.buffer.bytes.subdata(in: expression)
            guard Self.wrappable(bytes) else { throw ExplicitEditError.unverifiedTarget }
            self.span = span
            self.expression = expression
            expected = bytes
            revision = source.revision
        }

        /// Plan `(<expression>) + delta`, or `- delta` for a negative amount.
        /// Returns nil for a zero delta. Throws `.staleSource` when the
        /// document, revision, digest or expression bytes no longer match,
        /// and `.invalidValue` when delta is not finite.
        public func edit(adding delta: Double, in source: SourceSnapshot) throws -> SourceEdit? {
            guard source.revision == revision, source.documentID == span.fileID,
                  source.buffer.sha256 == span.contentDigest,
                  (try? source.span(for: expression)) != nil,
                  source.buffer.bytes.subdata(in: expression) == expected else {
                throw ExplicitEditError.staleSource
            }
            guard delta.isFinite else { throw ExplicitEditError.invalidValue }
            guard delta != 0 else { return nil }
            var replacement = Data("(".utf8)
            replacement.append(expected)
            if delta < 0 {
                replacement.append(contentsOf: ") - ".utf8)
                replacement.append(contentsOf: scadDecimalText(-delta).utf8)
            } else {
                replacement.append(contentsOf: ") + ".utf8)
                replacement.append(contentsOf: scadDecimalText(delta).utf8)
            }
            return SourceEdit(range: expression, expected: expected, replacement: replacement)
        }

        /// True when the appended `)` cannot land inside a line comment,
        /// block comment or string still open at the end of the expression.
        private static func wrappable(_ bytes: Data) -> Bool {
            enum State { case code, string, lineComment, blockComment }
            let raw = Array(bytes)
            var state = State.code
            var index = 0
            while index < raw.count {
                let byte = raw[index]
                let next = index + 1 < raw.count ? raw[index + 1] : 0
                switch state {
                case .code:
                    if byte == 0x22 {
                        state = .string
                    } else if byte == 0x2F, next == 0x2F {
                        state = .lineComment
                        index += 1
                    } else if byte == 0x2F, next == 0x2A {
                        state = .blockComment
                        index += 1
                    }
                case .string:
                    if byte == 0x5C {
                        index += 1
                    } else if byte == 0x22 {
                        state = .code
                    }
                case .lineComment:
                    if byte == 0x0A || byte == 0x0D { state = .code }
                case .blockComment:
                    if byte == 0x2A, next == 0x2F {
                        state = .code
                        index += 1
                    }
                }
                index += 1
            }
            return state == .code
        }
    }

    /// A verified statement boundary where an explicit move inserts
    /// `translate([x, y, z]) `. The insertion point sits after the
    /// statement's modifier characters, so `!cube(8);` becomes
    /// `!translate([2, 0, 0]) cube(8);` and the root modifier keeps dropping
    /// the transforms above its subtree.
    ///
    /// The adapter must verify that `insertionPoint` is a character boundary
    /// inside `span`, the statement's document-scoped span, positioned
    /// after any `!`, `#`, `%` or `*` modifiers and before the statement
    /// keyword, and that the statement is a standalone supported call. At
    /// least one adjacent single byte is kept as an expected-bytes guard.
    public struct Prefix: Equatable, Sendable {
        public let span: SourceSpan
        public let insertionPoint: Int
        private let leading: Data
        private let trailing: Data
        private let revision: UInt64

        public init(source: SourceSnapshot, span: SourceSpan, insertionPoint: Int) throws {
            guard span.fileID == source.documentID,
                  span.contentDigest == source.buffer.sha256 else {
                throw ExplicitEditError.staleSource
            }
            guard span.bytes.contains(insertionPoint),
                  (try? source.span(for: insertionPoint..<insertionPoint)) != nil else {
                throw ExplicitEditError.unverifiedTarget
            }
            let bytes = source.buffer.bytes
            var leading = Data()
            var trailing = Data()
            if insertionPoint > 0,
               (try? source.span(for: (insertionPoint - 1)..<insertionPoint)) != nil {
                leading = bytes.subdata(in: (insertionPoint - 1)..<insertionPoint)
            }
            if insertionPoint < bytes.count,
               (try? source.span(for: insertionPoint..<(insertionPoint + 1))) != nil {
                trailing = bytes.subdata(in: insertionPoint..<(insertionPoint + 1))
            }
            guard !leading.isEmpty || !trailing.isEmpty else {
                throw ExplicitEditError.unverifiedTarget
            }
            self.span = span
            self.insertionPoint = insertionPoint
            self.leading = leading
            self.trailing = trailing
            revision = source.revision
        }

        /// Plan an insertion of `translate([x, y, z]) ` at the boundary.
        /// Returns nil for a zero vector. Throws `.staleSource` when the
        /// document, revision, digest or guard bytes no longer match, and
        /// `.invalidValue` when any component is not finite.
        public func edit(translateByX x: Double, y: Double, z: Double,
                         in source: SourceSnapshot) throws -> SourceEdit? {
            let range = (insertionPoint - leading.count)..<(insertionPoint + trailing.count)
            guard source.revision == revision, source.documentID == span.fileID,
                  source.buffer.sha256 == span.contentDigest,
                  (try? source.span(for: range)) != nil,
                  source.buffer.bytes.subdata(in: range) == leading + trailing else {
                throw ExplicitEditError.staleSource
            }
            guard x.isFinite, y.isFinite, z.isFinite else {
                throw ExplicitEditError.invalidValue
            }
            guard x != 0 || y != 0 || z != 0 else { return nil }
            var replacement = leading
            replacement.append(contentsOf:
                "translate([\(scadDecimalText(x)), \(scadDecimalText(y)), \(scadDecimalText(z))]) ".utf8)
            replacement.append(trailing)
            return SourceEdit(range: range, expected: leading + trailing, replacement: replacement)
        }
    }
}
