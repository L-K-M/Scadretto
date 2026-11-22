import Foundation

/// A verified insertion point for a transform prefix such as
/// `translate([dx, 0, 0]) ` in front of a standalone module statement.
public struct SyntaxPrefixAnchor: Equatable, Sendable {
    /// Byte offset at which the prefix is inserted: the call's first byte,
    /// after every verified `!` or `#` modifier and any whitespace or comment
    /// between it and the call. The modifier bytes keep their source order.
    public let insertionPoint: Int
    /// Byte span of the whole statement (modifiers, trivia, call and
    /// terminating `;`) wrapping the insertion point. The prefix planner
    /// keeps adjacent bytes inside it as a nonempty expected-bytes guard.
    public let statement: Range<Int>
}

/// Why a worker call span cannot accept a transform prefix.
public enum PrefixAnchorRejection: Error, Equatable, Sendable {
    /// No recorded module call occupies the span.
    case unknownCall
    /// More than one recorded call occupies the span.
    case ambiguousCall
    /// The call at the span names a different callee.
    case nameMismatch
    /// A parse error or missing token crosses the statement.
    case parseError
    /// A `%` background or `*` disable modifier suppresses the transform.
    case disabledOrBackground
    /// A modifier slot holds a byte other than `!`, `#`, `%` or `*`.
    case ambiguousModifier
    /// The call's tail is not a lone `;`, so the boundary is ambiguous.
    case notStandalone
}

extension SyntaxSnapshot {
    /// Whether a parse error or missing token crosses `span`: strictly
    /// overlapping it, or a missing token sitting at either boundary.
    public func hasError(crossing span: Range<Int>) -> Bool {
        ranges.contains { entry in
            guard entry.kind == .error else { return false }
            if entry.range.isEmpty {
                return entry.range.lowerBound >= span.lowerBound
                    && entry.range.lowerBound <= span.upperBound
            }
            return entry.range.lowerBound < span.upperBound
                && entry.range.upperBound > span.lowerBound
        }
    }

    /// Whether `span` is exactly one expression node's byte range with no
    /// parse error crossing it. This is the check a worker-reported
    /// expression span passes before an explicit offset wraps it as
    /// `(expr) + delta`.
    public func containsExpression(_ span: Range<Int>) -> Bool {
        expressions.contains(span) && !hasError(crossing: span)
    }

    /// Resolves the checked insertion anchor for a `translate([...])`-style
    /// prefix on the standalone module statement whose call occupies `call`
    /// and names `name`. Fails when no call matches, a parse error crosses
    /// the statement, the modifiers are not all verified `!`/`#`, or the
    /// call's tail is not a lone `;`. `bytes` are the source bytes this
    /// snapshot was parsed from; they confirm the callee name.
    public func translatePrefixAnchor(
        call: Range<Int>,
        name: String,
        in bytes: Data
    ) -> Result<SyntaxPrefixAnchor, PrefixAnchorRejection> {
        let matches = calls.filter { $0.call == call }
        guard let match = matches.first else {
            return .failure(hasError(crossing: call) ? .parseError : .unknownCall)
        }
        guard matches.count == 1 else { return .failure(.ambiguousCall) }
        guard match.name.lowerBound >= 0, match.name.upperBound <= bytes.count,
              bytes.subdata(in: match.name) == Data(name.utf8) else {
            return .failure(.nameMismatch)
        }
        guard !hasError(crossing: match.statement) else { return .failure(.parseError) }
        for byte in match.modifiers {
            switch byte {
            case UInt8(ascii: "!"), UInt8(ascii: "#"): continue
            case UInt8(ascii: "%"), UInt8(ascii: "*"): return .failure(.disabledOrBackground)
            default: return .failure(.ambiguousModifier)
            }
        }
        guard match.terminator != nil else { return .failure(.notStandalone) }
        return .success(SyntaxPrefixAnchor(insertionPoint: match.call.lowerBound,
                                           statement: match.statement))
    }
}
