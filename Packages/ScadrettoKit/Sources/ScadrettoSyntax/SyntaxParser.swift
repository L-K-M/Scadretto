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
    /// Byte range of the callee identifier.
    public let name: Range<Int>
    /// Byte range of the call (name and argument list), matching the span
    /// the worker reports for an executed module instance.
    public let call: Range<Int>
    /// Byte range of the statement this call heads: the transform chain from
    /// its first modifier through its tail (`;`, block or nested statement).
    public let statement: Range<Int>
    /// Byte range of the statement's terminating `;` when the tail is a lone
    /// semicolon. Nil when the tail is a block, a nested statement or a
    /// missing or erroneous token: the cases a prefix anchor must reject.
    public let terminator: Range<Int>?
    /// The statement's modifier bytes in source order: `!` root, `#`
    /// highlight, `%` background and `*` disable.
    public let modifiers: Data
}

public struct SyntaxSnapshot: Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let ranges: [SyntaxRange]
    public let calls: [SyntaxCall]
    /// Exact byte span of every expression node in the parsed tree, in source
    /// order. Identifiers and special variables appear only in expression
    /// position, never as a module, assignment or parameter name or a
    /// `dot_index` member. Collected during the single parse walk so an edit
    /// planner can verify worker expression spans without a second tree.
    public let expressions: [Range<Int>]
    /// The name of every module declaration, at any depth.
    public let moduleNames: [Range<Int>]
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
    private var lastExpressions: [Range<Int>] = []
    private var lastModuleNames: [Range<Int>] = []

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
            lastExpressions = records.expressions
            lastModuleNames = records.moduleNames
        }
        return SyntaxSnapshot(documentID: source.documentID, revision: source.revision,
                              ranges: lastRanges, calls: lastCalls, expressions: lastExpressions,
                              moduleNames: lastModuleNames)
    }

    private static func collect(_ root: TSNode, bomLength: Int) throws
        -> (ranges: [SyntaxRange], calls: [SyntaxCall], expressions: [Range<Int>], moduleNames: [Range<Int>]) {
        var ranges: [SyntaxRange] = []
        var calls: [SyntaxCall] = []
        var expressions: [Range<Int>] = []
        var moduleNames: [Range<Int>] = []
        var stack = [root]
        while let node = stack.popLast() {
            try Task.checkCancellation()
            let span = byteRange(node, adding: bomLength)
            if ts_node_is_error(node) || ts_node_is_missing(node) {
                ranges.append(SyntaxRange(range: span, kind: .error))
                continue
            }
            let type = String(cString: ts_node_type(node))
            if expressionTypes.contains(type) || isVariableExpression(node, type: type) {
                expressions.append(span)
            }
            if let kind = classification(type) {
                ranges.append(SyntaxRange(range: span, kind: kind))
                continue
            }
            if type == "module_call", let call = moduleCall(node, callSpan: span, bomLength: bomLength) {
                calls.append(call)
            }
            if type == "module_item" {
                let name = ts_node_child_by_field_name(node, "name", 4)
                if !ts_node_is_null(name) { moduleNames.append(byteRange(name, adding: bomLength)) }
            }
            for child in (0..<ts_node_child_count(node)).reversed() {
                stack.append(ts_node_child(node, child))
            }
        }
        return (ranges, calls, expressions, moduleNames)
    }

    // Every module_call heads exactly one transform_chain: modifiers and
    // comments before it, one statement tail after. Record that context so
    // prefix insertion can verify the boundary without a second tree.
    private static func moduleCall(_ node: TSNode, callSpan: Range<Int>, bomLength: Int) -> SyntaxCall? {
        let nameNode = ts_node_child_by_field_name(node, "name", 4)
        guard !ts_node_is_null(nameNode) else { return nil }

        var statement = callSpan
        var terminator: Range<Int>?
        var modifiers = Data()
        let chain = ts_node_parent(node)
        if !ts_node_is_null(chain), String(cString: ts_node_type(chain)) == "transform_chain" {
            statement = byteRange(chain, adding: bomLength)
            var sawCall = false
            for index in 0..<ts_node_child_count(chain) {
                let child = ts_node_child(chain, index)
                if ts_node_eq(child, node) {
                    sawCall = true
                    continue
                }
                let childType = String(cString: ts_node_type(child))
                if sawCall {
                    // The first non-comment child after the call is its tail.
                    guard childType != "line_comment", childType != "block_comment" else { continue }
                    if childType == ";", !ts_node_is_error(child), !ts_node_is_missing(child) {
                        terminator = byteRange(child, adding: bomLength)
                    }
                    break
                }
                if childType == "modifier", let byte = modifierByte(child) {
                    modifiers.append(byte)
                }
            }
        }
        return SyntaxCall(name: byteRange(nameNode, adding: bomLength), call: callSpan,
                          statement: statement, terminator: terminator, modifiers: modifiers)
    }

    // A modifier node wraps one anonymous `!`, `#`, `%` or `*` token. Return
    // the token's byte; a malformed token leaves the modifier unverified.
    private static func modifierByte(_ modifier: TSNode) -> UInt8? {
        guard ts_node_child_count(modifier) == 1 else { return nil }
        let token = ts_node_child(modifier, 0)
        guard !ts_node_is_error(token), !ts_node_is_missing(token),
              ts_node_start_byte(token) + 1 == ts_node_end_byte(token) else { return nil }
        let byte = ts_node_type(token)[0]
        return byte == 0 ? nil : UInt8(bitPattern: byte)
    }

    // `identifier` and `special_variable` double as declaration names
    // (module, assignment, parameter, dot-index member) and as expression
    // variables. Only expression positions may be wrapped by an offset.
    private static func isVariableExpression(_ node: TSNode, type: String) -> Bool {
        guard type == "identifier" || type == "special_variable" else { return false }
        let parent = ts_node_parent(node)
        guard !ts_node_is_null(parent) else { return false }
        switch String(cString: ts_node_type(parent)) {
        case "parameter", "special_variable":
            return false
        case "assignment", "module_call", "module_item", "function_item":
            return !ts_node_eq(node, ts_node_child_by_field_name(parent, "name", 4))
        case "dot_index_expression":
            return !ts_node_eq(node, ts_node_child_by_field_name(parent, "index", 5))
        default:
            return true
        }
    }

    // Concrete members of the grammar's expression supertype. Identifiers and
    // special variables join through isVariableExpression; every other
    // expression member appears only in expression position.
    private static let expressionTypes: Set<String> = [
        "assert_expression", "binary_expression", "boolean", "dot_index_expression",
        "echo_expression", "float", "function_call", "function_lit",
        "index_expression", "integer", "let_expression", "list",
        "parenthesized_expression", "range", "string", "ternary_expression",
        "unary_expression", "undef",
    ]

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
