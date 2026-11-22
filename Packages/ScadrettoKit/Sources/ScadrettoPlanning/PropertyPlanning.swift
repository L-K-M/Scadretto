import Foundation
import ScadrettoCore
import ScadrettoEngineClient
import ScadrettoSyntax
import simd

public enum ModelAxis: String, CaseIterable, Sendable {
    case x = "X"
    case y = "Y"
    case z = "Z"

    public var index: Int {
        switch self {
        case .x: 0
        case .y: 1
        case .z: 2
        }
    }
}

public struct PropertyChoice: Sendable {
    public enum Action: Sendable {
        case value(InstanceRecord, PropertyRecord)
        case offset(InstanceRecord, PropertyRecord)
        case prefix(InstanceRecord, ModelAxis)
    }

    public let id: String
    public let title: String
    public let action: Action

    public static func choices(on selected: InstanceRecord, among instances: [UInt32: InstanceRecord]) -> [Self] {
        var choices: [Self] = []
        appendProperties(of: selected, distance: 0, to: &choices)

        var distance = 1
        var ancestorID = selected.parent
        var crossedChildren = false
        var enclosingCalls: [(distance: Int, instance: InstanceRecord)] = []
        var hasLocalTranslate = selected.properties?.contains(where: { $0.semantic.translateAxis != nil }) == true
        var reachedTranslation = false
        while let id = ancestorID, let instance = instances[id] {
            enclosingCalls.append((distance, instance))
            if instance.name == "children" || instance.name == "child" { crossedChildren = true }
            if !reachedTranslation,
               instance.properties?.contains(where: { $0.semantic.translateAxis != nil }) == true {
                if !hasLocalTranslate {
                    appendProperties(of: instance, distance: distance, wrapper: crossedChildren, to: &choices)
                    hasLocalTranslate = !crossedChildren
                }
                // The closest executed translation supplies the local move.
                reachedTranslation = true
            }
            ancestorID = instance.parent
            distance += 1
        }
        if !hasLocalTranslate, selected.span != nil,
           selected.operand != nil || selected.definitionSpan != nil {
            choices += ModelAxis.allCases.map { axis in
                Self(id: "\(prefixID)\(axis.rawValue)", title: "Move \(axis.rawValue) here",
                     action: .prefix(selected, axis))
            }
        }
        for (distance, call) in enclosingCalls {
            appendArguments(of: call, distance: distance, to: &choices)
        }
        return choices
    }

    private static let prefixID = "prefix-"
    private static let defaultReason = "The evaluator supplied a default for this property."

    private static func appendProperties(of instance: InstanceRecord, distance: Int, wrapper: Bool = false,
                                         to choices: inout [Self]) {
        let properties = instance.properties ?? []
        // A round feature opens on its diameter, the first handle users reach for.
        let ordered = properties.filter(\.semantic.isDiameter) + properties.filter { !$0.semantic.isDiameter }
        for property in ordered {
            let name = property.semantic.title(formal: property.formal, centered: property.centered)
            let title = wrapper ? "Wrapper \(name)" : name
            let id = "\(distance):\(property.semantic.rawValue):\(property.formal)"
            choices.append(Self(id: id, title: title, action: .value(instance, property)))
            if !wrapper, let axis = property.semantic.translateAxis, property.status == .bound,
               let expression = property.expression, !property.isAuthoredLiteral(at: expression) {
                choices.append(Self(id: "\(id):offset", title: "Offset \(axis.rawValue) here",
                                    action: .offset(instance, property)))
            }
        }
    }

    /// Explicit arguments of enclosing calls give a pick its call-site scope.
    private static func appendArguments(of call: InstanceRecord, distance: Int, to choices: inout [Self]) {
        for property in call.properties ?? [] where property.semantic == .moduleArgument && property.status == .bound {
            let id = "\(distance):\(property.semantic.rawValue):\(property.formal)"
            let offered = choices.contains { choice in
                guard case .value(_, let other) = choice.action else { return false }
                if choice.id == id { return true }
                guard other.status == .bound, let last = property.chain.last, last.kind == "literal" else { return false }
                // The same literal is already offered under the feature's own name.
                return other.chain.last == last
            }
            guard !offered else { continue }
            let title = "\(property.semantic.title(formal: property.formal, centered: false)) of \(call.name)"
            choices.append(Self(id: id, title: title, action: .value(call, property)))
        }
    }

    /// The choice to show after the choices were rebuilt. Nil requires an
    /// explicit choice, so typing never reaches a different target. An inserted
    /// move continues as the translation it created.
    public static func selectedIndex(after previousID: String?, in choices: [Self]) -> Int? {
        guard !choices.isEmpty else { return nil }
        guard let previousID else { return 0 }
        if let index = choices.firstIndex(where: { $0.id == previousID }) { return index }
        guard previousID.hasPrefix(prefixID),
              let axis = ModelAxis(rawValue: String(previousID.dropFirst(prefixID.count))) else { return nil }
        return choices.firstIndex { choice in
            guard case .value(_, let property) = choice.action else { return false }
            return property.semantic.translateAxis == axis
        }
    }

    /// Whether a choice still names the same owner after the selection was
    /// found again. Its ID starts with the owner's distance above the selection.
    public static func continues(_ previousID: String?, to instanceID: UInt32, along path: SelectionPath,
                                 in scene: SceneSnapshot, files: [FileRecord]) -> Bool {
        guard let previousID, let distance = previousID.split(separator: ":").first.flatMap({ Int($0) }),
              distance > 0,
              let changed = path.changedDistance(to: instanceID, in: scene, files: files) else { return true }
        return distance < changed
    }

    public var value: Double? {
        switch action {
        case .value(_, let property): property.value
        case .offset, .prefix: 0
        }
    }

    public var label: String {
        switch action {
        case .value: "Change \(title)"
        case .offset, .prefix: title
        }
    }

    /// The names the evaluated value passed through, such as `d ← hole_d`.
    /// Nil when the authored expression itself is the best description.
    public var bindingPath: String? {
        guard case .value(_, let property) = action else { return nil }
        let names = property.chain.filter { ($0.kind == "lookup" || $0.kind == "assignment") && !$0.name.isEmpty }
            .map(\.name)
        guard !names.isEmpty else { return nil }
        let head = property.semantic.translateAxis?.rawValue
            ?? (property.semantic.isDiameter ? "d" : property.formal)
        var path = [head]
        for name in names where path.last != name { path.append(name) }
        return path.joined(separator: " ← ")
    }

    public var expression: WireSpan? {
        switch action {
        case .value(_, let property), .offset(_, let property): property.expression
        case .prefix(let instance, _): instance.span
        }
    }
}

extension PropertyRecord.Semantic {
    public var translateAxis: ModelAxis? {
        switch self {
        case .translateX: .x
        case .translateY: .y
        case .translateZ: .z
        default: nil
        }
    }

    var isDiameter: Bool {
        self == .cylinderDiameter || self == .sphereDiameter
    }

    var requiresPositiveValue: Bool {
        switch self {
        case .cubeUniformSize, .cubeSizeX, .cubeSizeY, .cubeSizeZ, .sphereDiameter,
             .cylinderHeight, .cylinderDiameter, .cylinderBottomRadius, .cylinderTopRadius: true
        default: false
        }
    }

    func title(formal: String, centered: Bool) -> String {
        switch self {
        case .cubeUniformSize: centered ? "Uniform size (centered)" : "Uniform size"
        case .cubeSizeX: centered ? "Size X (centered)" : "Size X"
        case .cubeSizeY: centered ? "Size Y (centered)" : "Size Y"
        case .cubeSizeZ: centered ? "Size Z (centered)" : "Size Z"
        case .sphereDiameter, .cylinderDiameter: "Diameter"
        case .cylinderHeight: centered ? "Height (centered)" : "Height"
        case .cylinderBottomRadius: "Bottom radius"
        case .cylinderTopRadius: "Top radius"
        case .fragmentCount: "Fragments ($fn)"
        case .translateX: "Translate X"
        case .translateY: "Translate Y"
        case .translateZ: "Translate Z"
        case .moduleArgument: "Argument \(formal)"
        case .pitch: "Pitch"
        }
    }
}

extension PropertyRecord {
    /// Whether the expression is itself the numeric literal it evaluated to.
    /// Any other expression can take an explicit local offset.
    func isAuthoredLiteral(at expression: WireSpan) -> Bool {
        chain.last.map { $0.kind == "literal" && $0.span == expression } ?? false
    }
}

public enum PlannedPropertyEdit: Equatable, Sendable {
    case scalar(ScalarLiteral, positive: Bool)
    case offset(ExplicitSourceEdit.Offset)
    case prefix(ExplicitSourceEdit.Prefix, ModelAxis)

    public func edit(setting value: Double, in source: SourceSnapshot) throws -> SourceEdit? {
        switch self {
        case .scalar(let literal, let positive):
            if positive && !(value > 0) { throw PropertyPlanningError.positiveDimension }
            return try literal.edit(setting: value, in: source)
        case .offset(let expression):
            return try expression.edit(adding: value, in: source)
        case .prefix(let prefix, let axis):
            var vector = SIMD3<Double>.zero
            vector[axis.index] = value
            return try prefix.edit(translateByX: vector.x, y: vector.y, z: vector.z, in: source)
        }
    }
}

public enum PropertyPlanningError: LocalizedError {
    case readOnly(String)
    case positiveDimension
    case verifyingSyntax

    public var errorDescription: String? {
        switch self {
        case .readOnly(let message): message
        case .positiveDimension: "Enter a dimension greater than zero."
        case .verifyingSyntax: "Checking the source expression…"
        }
    }
}

/// Why a planned edit offers numeric entry without a spatial handle.
public enum DragBlocker: Equatable, Sendable {
    case iterationZero
    case unverified
    case opaqueFrame
    case sharedPath
}

public struct PropertyEditPlan: Sendable {
    public let operation: PlannedPropertyEdit
    public let affected: [UInt32]
    public let scope: String
    public let span: SourceSpan
    /// Nil when a drag preview of this edit matches reevaluation.
    public let dragBlocker: DragBlocker?
}

extension PropertyChoice {
    public func plan(in result: EvaluationResult, source: SourceSnapshot,
              syntax: SyntaxSnapshot?) throws -> PropertyEditPlan {
        guard let syntax, syntax.documentID == source.documentID, syntax.revision == source.revision else {
            throw PropertyPlanningError.verifyingSyntax
        }
        guard let scene = result.scene else { throw PropertyBindingError.unobserved }
        switch action {
        case .value(let owner, let property):
            switch property.status {
            case .default: throw PropertyPlanningError.readOnly(Self.defaultReason)
            case .invalid: throw PropertyPlanningError.readOnly("The supplied argument could not define this property.")
            case .computedVector: throw PropertyPlanningError.readOnly("This vector was computed during evaluation.")
            case .bound: break
            }
            if let origin = property.chain.last, origin.kind == "literal", origin.span == nil {
                // Built-in values such as $fn = 0 have no source bytes.
                throw PropertyPlanningError.readOnly(Self.defaultReason)
            }
            let target = try result.target(for: property, on: owner.id, in: source)
            guard let token = syntax.ranges.first(where: { $0.kind == .number && $0.range == target.span.bytes }),
                  !syntax.hasError(crossing: target.span.bytes) else {
                throw PropertyPlanningError.readOnly("The evaluated value has no verified numeric token here.")
            }
            let literal = try ScalarLiteral(source: source, span: target.span, numericToken: token.range,
                                            authoredValue: target.authoredValue,
                                            displayMultiplier: property.displayMultiplier)
            let scope = scope(of: target, editedAt: owner, in: scene)
            let blocker: DragBlocker? = if property.pitch?.iteration == 0 {
                .iterationZero
            } else if !property.dragVerified {
                .unverified
            } else {
                nil
            }
            return PropertyEditPlan(operation: .scalar(literal, positive: property.semantic.requiresPositiveValue),
                                    affected: target.affectedInstances, scope: scope, span: target.span,
                                    dragBlocker: blocker)
        case .offset(let owner, let property):
            guard let expression = property.expression, property.status == .bound else { throw PropertyBindingError.expression }
            let span = try result.authoringSpan(expression, in: source)
            guard syntax.containsExpression(span.bytes) else { throw PropertyBindingError.expression }
            let rewrite = try ExplicitSourceEdit.Offset(source: source, span: span, expression: span.bytes)
            let consumers = scene.instances.filter { instance in
                instance.properties?.contains(where: { $0.semantic == property.semantic && $0.expression == expression }) == true
            }
            let affected = consumers.isEmpty ? [owner.id] : consumers.map(\.id)
            let scope = affected.count == 1 ? "Offset here" : "Offset at shared call · \(occurrenceCount(affected.count))"
            let blocker: DragBlocker? = if owner.opaqueFrame || consumers.contains(where: \.opaqueFrame) {
                .opaqueFrame
            } else if Self.nests(affected, in: scene) {
                .sharedPath
            } else {
                nil
            }
            return PropertyEditPlan(operation: .offset(rewrite), affected: affected, scope: scope, span: span,
                                    dragBlocker: blocker)
        case .prefix(let instance, let axis):
            guard let call = instance.span else { throw PropertyBindingError.expression }
            guard !scene.propertiesOmitted else {
                throw PropertyPlanningError.readOnly(
                    "Property detail was omitted for this large model, so it can only be inspected."
                )
            }
            let affected = scene.instances.filter { $0.span == call }.map(\.id)
            guard affected.count == 1, instance.iteration.isEmpty else {
                throw PropertyPlanningError.readOnly("This statement generates repeated instances. Choose a shared property or edit the source.")
            }
            guard !Self.redefinesTranslate(scene: scene, syntax: syntax, source: source) else {
                throw PropertyPlanningError.readOnly(
                    "A module named translate replaces the built-in here, so a move cannot be inserted."
                )
            }
            let span = try result.authoringSpan(call, in: source)
            guard case .success(let anchor) = syntax.translatePrefixAnchor(call: span.bytes,
                                                                          name: instance.name, in: source.buffer.bytes) else {
                throw PropertyPlanningError.readOnly("A standalone call boundary could not be verified for this move.")
            }
            let statement = try source.span(for: anchor.statement)
            let rewrite = try ExplicitSourceEdit.Prefix(source: source, span: statement,
                                                        insertionPoint: anchor.insertionPoint)
            return PropertyEditPlan(operation: .prefix(rewrite, axis), affected: affected,
                                    scope: "This call site", span: span,
                                    dragBlocker: instance.opaqueFrame ? .opaqueFrame : nil)
        }
    }

    private func scope(of target: PropertyBindingTarget, editedAt owner: InstanceRecord,
                       in scene: SceneSnapshot) -> String {
        let affected = Set(target.affectedInstances)
        let rendered = scene.renderedOperands(below: target.affectedInstances)
        let count = rendered.isEmpty ? affected.count : rendered.count
        let subtracted = scene.subtractedInstances
        let areCutters = !rendered.isEmpty && rendered.allSatisfy(subtracted.contains)
        let effects = areCutters ? "\(count) \(count == 1 ? "cutter" : "cutters")" : occurrenceCount(count)
        let bound = target.impactComplete ? effects : "at least \(effects) · other uses unknown"

        switch target.scope {
        case .parameter:
            return "Shared parameter · \(bound)"
        case .callSite:
            let executions = scene.instances.filter { affected.contains($0.id) && $0.span == owner.span }.count
            guard executions <= 1 else { return "Shared call site · \(bound)" }
            return target.impactComplete && count <= 1 ? "This call site" : "This call site · \(bound)"
        }
    }

    /// Whether one path applies the edit more than once, so a preview that
    /// moves each occurrence once would differ from reevaluation.
    private static func nests(_ ids: [UInt32], in scene: SceneSnapshot) -> Bool {
        let edited = Set(ids)
        var below: Set<UInt32> = []
        for instance in scene.instances {
            guard let parent = instance.parent, edited.contains(parent) || below.contains(parent) else { continue }
            if edited.contains(instance.id) { return true }
            below.insert(instance.id)
        }
        return false
    }

    /// An inserted `translate` would call the user's module. A definition in a
    /// dependency is only visible here once that module has executed.
    private static func redefinesTranslate(scene: SceneSnapshot, syntax: SyntaxSnapshot,
                                           source: SourceSnapshot) -> Bool {
        let name = Data("translate".utf8)
        let bytes = source.buffer.bytes
        return syntax.moduleNames.contains { $0.upperBound <= bytes.count && bytes.subdata(in: $0) == name }
            || scene.instances.contains { $0.name == "translate" && $0.definitionSpan != nil }
    }

    private func occurrenceCount(_ count: Int) -> String {
        count == 1 ? "1 occurrence" : "\(count) occurrences"
    }
}
