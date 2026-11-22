import ScadrettoCore

public struct DiameterBindingTarget: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case parameter(String)
        case callSite
    }

    public let span: SourceSpan
    public let scope: Scope
    public let value: Double
    public let affectedInstances: [UInt32]
}

public enum DiameterBindingError: Error, Equatable, Sendable {
    case unobserved
    case expression
    case dependency(String)
    case staleSource
}

extension EvaluationResult {
    /// Resolve request-local file IDs before the planner sees the selected
    /// literal. Equal numbers have distinct targets at different byte ranges.
    public func diameterTarget(for instanceID: UInt32, in source: SourceSnapshot) throws -> DiameterBindingTarget {
        guard key.documentID == source.documentID, key.sourceRevision == source.revision else {
            throw DiameterBindingError.staleSource
        }
        guard let instances = scene?.instances,
              let diameter = instances.first(where: { $0.id == instanceID })?.diameter else {
            throw DiameterBindingError.unobserved
        }
        guard let (leaf, scope) = Self.diameterOrigin(diameter),
              let file = files.first(where: { $0.id == leaf.fileID }) else {
            throw DiameterBindingError.expression
        }
        guard file.kind == .main, file.writable else {
            throw DiameterBindingError.dependency(file.logicalPath)
        }
        guard file.sha256 == source.buffer.sha256, file.byteLength == source.buffer.bytes.count,
              leaf.start < leaf.end, leaf.end <= file.byteLength,
              let span = try? source.span(for: Int(leaf.start)..<Int(leaf.end)) else {
            throw DiameterBindingError.staleSource
        }

        let affected = instances.compactMap { instance -> UInt32? in
            guard let diameter = instance.diameter, Self.diameterOrigin(diameter)?.span == leaf else { return nil }
            return instance.id
        }
        return DiameterBindingTarget(span: span, scope: scope, value: diameter.value, affectedInstances: affected)
    }

    private static func diameterOrigin(_ diameter: DiameterRecord)
        -> (span: WireSpan, scope: DiameterBindingTarget.Scope)? {
        guard diameter.chain.first?.kind == "parameter", diameter.chain.first?.name == "d",
              let literal = diameter.chain.last, literal.kind == "literal", let span = literal.span,
              let expression = diameter.chain.dropLast().last, expression.span == span else { return nil }
        switch expression.kind {
        case "assignment" where !expression.name.isEmpty: return (span, .parameter(expression.name))
        case "argument": return (span, .callSite)
        default: return nil
        }
    }
}
