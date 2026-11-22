import ScadrettoCore

public struct PropertyBindingTarget: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case parameter(String)
        case callSite
    }

    public let span: SourceSpan
    public let authoredValue: Double
    public let scope: Scope
    public let affectedInstances: [UInt32]
    /// False when other evaluated uses of the literal are untraced.
    public let impactComplete: Bool
}

public enum PropertyBindingError: Error, Equatable, Sendable {
    case unobserved
    case expression
    case dependency(String)
    case staleSource
}

extension EvaluationResult {
    public func target(for property: PropertyRecord, on instanceID: UInt32,
                       in source: SourceSnapshot) throws -> PropertyBindingTarget {
        guard key.documentID == source.documentID, key.sourceRevision == source.revision else {
            throw PropertyBindingError.staleSource
        }
        guard let instances = scene?.instances,
              instances.first(where: { $0.id == instanceID })?.properties?.contains(property) == true,
              property.status == .bound else { throw PropertyBindingError.unobserved }
        guard let (leaf, scope) = Self.propertyOrigin(property) else { throw PropertyBindingError.expression }
        let span = try authoringSpan(leaf, in: source)
        let affected = instances.compactMap { instance -> UInt32? in
            let consumes = instance.properties?.contains { $0.status != .invalid && $0.inputs.contains(leaf) }
            return consumes == true ? instance.id : nil
        }
        return PropertyBindingTarget(span: span, authoredValue: property.value / property.displayMultiplier,
                                     scope: scope, affectedInstances: affected,
                                     impactComplete: property.impactComplete)
    }

    /// Resolve a request-local span only for the bytes of the active main file.
    public func authoringSpan(_ span: WireSpan, in source: SourceSnapshot) throws -> SourceSpan {
        guard key.documentID == source.documentID, key.sourceRevision == source.revision,
              let file = files.first(where: { $0.id == span.fileID }) else {
            throw PropertyBindingError.staleSource
        }
        guard file.kind == .main, file.writable else { throw PropertyBindingError.dependency(file.logicalPath) }
        guard file.sha256 == source.buffer.sha256, file.byteLength == source.buffer.bytes.count,
              span.start < span.end, span.end <= file.byteLength,
              let local = try? source.span(for: Int(span.start)..<Int(span.end)) else {
            throw PropertyBindingError.staleSource
        }
        return local
    }

    /// A scoped wrapper must cover the entire terminal token. Equal values,
    /// an inner operand of arithmetic, and implicit defaults supply no target.
    private static func propertyOrigin(_ property: PropertyRecord)
        -> (span: WireSpan, scope: PropertyBindingTarget.Scope)? {
        let directLinks = ["parameter", "argument", "assignment", "lookup", "element", "default"]
        guard property.chain.dropLast().allSatisfy({ directLinks.contains($0.kind) }),
              let literal = property.chain.last, literal.kind == "literal", let span = literal.span,
              let expression = property.chain.dropLast().last, expression.span == span else { return nil }
        switch expression.kind {
        case "assignment" where !expression.name.isEmpty: return (span, .parameter(expression.name))
        case "argument", "element": return (span, .callSite)
        default: return nil
        }
    }
}
