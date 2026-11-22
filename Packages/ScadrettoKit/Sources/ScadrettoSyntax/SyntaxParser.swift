import Foundation
import ScadrettoCore
import TreeSitter
import TreeSitterOpenscad

public enum SyntaxKind: Sendable {
    case comment, string, number, keyword, identifier, error
}

public struct SyntaxRange: Sendable {
    public let range: Range<Int>
    public let kind: SyntaxKind
}

public struct SyntaxCall: Sendable {
    public let name: Range<Int>
    public let call: Range<Int>
}

public struct SyntaxSnapshot: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let ranges: [SyntaxRange]
    public let calls: [SyntaxCall]
}

public enum SyntaxError: Error, Sendable {
    case unavailable
    case sourceTooLarge
    case parseFailed
}

// A Tree-sitter pointer never escapes its actor. The wrapper owns destruction
// because Swift actor deinitialization itself is nonisolated.
private final class ParserHandle {
    let pointer: OpaquePointer

    init?() {
        guard let pointer = ts_parser_new() else { return nil }
        guard ts_parser_set_language(pointer, tree_sitter_openscad()) else {
            ts_parser_delete(pointer)
            return nil
        }
        self.pointer = pointer
    }

    deinit {
        ts_parser_delete(pointer)
    }
}

public actor SyntaxParser {
    private let parser = ParserHandle()
    private var lastBytes: Data?
    private var lastRanges: [SyntaxRange] = []
    private var lastCalls: [SyntaxCall] = []

    public init() {}

    public func parse(_ source: SourceSnapshot) throws -> SyntaxSnapshot {
        try Task.checkCancellation()
        let raw = source.buffer.bytes
        if raw != lastBytes {
            guard let parser else { throw SyntaxError.unavailable }
            let start = source.buffer.bomLength
            let length = raw.count - start
            guard length <= UInt32.max else { throw SyntaxError.sourceTooLarge }
            let tree = raw.withUnsafeBytes { bytes in
                if let base = bytes.bindMemory(to: CChar.self).baseAddress {
                    return ts_parser_parse_string(parser.pointer, nil, base + start, UInt32(length))
                }
                return "".withCString { ts_parser_parse_string(parser.pointer, nil, $0, 0) }
            }
            guard let tree else { throw SyntaxError.parseFailed }
            defer { ts_tree_delete(tree) }
            let records = try Self.collect(ts_tree_root_node(tree), bomLength: start)
            lastBytes = raw
            lastRanges = records.ranges
            lastCalls = records.calls
        }
        return SyntaxSnapshot(documentID: source.documentID, revision: source.revision,
                              ranges: lastRanges, calls: lastCalls)
    }

    private static func collect(_ root: TSNode, bomLength: Int) throws
        -> (ranges: [SyntaxRange], calls: [SyntaxCall]) {
        var ranges: [SyntaxRange] = []
        var calls: [SyntaxCall] = []
        var stack = [root]
        while let node = stack.popLast() {
            try Task.checkCancellation()
            let span = byteRange(node, adding: bomLength)
            if ts_node_is_error(node) || ts_node_is_missing(node) {
                ranges.append(SyntaxRange(range: span, kind: .error))
                continue
            }
            let type = String(cString: ts_node_type(node))
            if let kind = classification(type) {
                ranges.append(SyntaxRange(range: span, kind: kind))
                continue
            }
            if type == "module_call" {
                let name = ts_node_child_by_field_name(node, "name", 4)
                if !ts_node_is_null(name) {
                    calls.append(SyntaxCall(name: byteRange(name, adding: bomLength), call: span))
                }
            }
            for child in (0..<ts_node_child_count(node)).reversed() {
                stack.append(ts_node_child(node, child))
            }
        }
        return (ranges, calls)
    }

    private static func byteRange(_ node: TSNode, adding shift: Int) -> Range<Int> {
        (Int(ts_node_start_byte(node)) + shift)..<(Int(ts_node_end_byte(node)) + shift)
    }

    private static func classification(_ type: String) -> SyntaxKind? {
        switch type {
        case "line_comment", "block_comment": .comment
        case "string", "include_path": .string
        case "integer", "float": .number
        case "identifier": .identifier
        case "include", "use", "module", "function", "let", "each", "assert",
             "if", "else", "for", "intersection_for", "true", "false", "undef", "boolean": .keyword
        default: nil
        }
    }
}
