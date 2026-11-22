import Foundation
import ScadrettoCore
import ScadrettoEngineClient
import ScadrettoPlanning
import ScadrettoSyntax
import ScadrettoTestSupport
import Testing

@MainActor
private func platePlan(_ semantic: PropertyRecord.Semantic, on id: UInt32) async throws -> PropertyEditPlan {
    let plate = try await PlateGolden.load()
    let scene = try #require(plate.result.scene)
    let byID = Dictionary(uniqueKeysWithValues: scene.instances.map { ($0.id, $0) })
    let picked = try #require(byID[id])
    let choice = try #require(PropertyChoice.choices(on: picked, among: byID).first {
        if case .value(_, let property) = $0.action { property.semantic == semantic } else { false }
    })
    return try choice.plan(in: plate.result, source: plate.snapshot,
                           syntax: try await SyntaxParser().parse(plate.snapshot))
}

// MARK: - Walkthrough targets and scope

@Test @MainActor func thirdBoreDiameterIsOneSharedParameterOfFourCutters() async throws {
    let plan = try await platePlan(.cylinderDiameter, on: 13)
    #expect(plan.span.bytes == 74..<75)
    #expect(plan.scope == "Shared parameter · 4 cutters")
    #expect(plan.dragBlocker == nil)
}

@Test @MainActor func thirdBorePitchIsOneSharedParameterOfFourCutters() async throws {
    let plan = try await platePlan(.pitch, on: 13)
    #expect(plan.span.bytes == 96..<98)
    #expect(plan.scope == "Shared parameter · 4 cutters")
    #expect(plan.dragBlocker == nil)
}

@Test @MainActor func pitchAtIterationZeroKeepsNumericEntry() async throws {
    let plan = try await platePlan(.pitch, on: 7)
    #expect(plan.span.bytes == 96..<98)
    #expect(plan.dragBlocker == .iterationZero)
}

@Test @MainActor func incompleteImpactIsShownAsALowerBound() async throws {
    let plan = try await platePlan(.fragmentCount, on: 13)
    #expect(plan.scope == "Shared parameter · at least 4 cutters · other uses unknown")
}

@Test @MainActor func thirdBoreOpensOnItsDiameterAndShowsTheChain() async throws {
    let plate = try await PlateGolden.load()
    let scene = try #require(plate.result.scene)
    let byID = Dictionary(uniqueKeysWithValues: scene.instances.map { ($0.id, $0) })
    let bore = try #require(byID[13])
    let first = try #require(PropertyChoice.choices(on: bore, among: byID).first)
    #expect(first.title == "Diameter")
    #expect(first.bindingPath == "d ← hole_d")
}

// MARK: - Drag eligibility

@Test @MainActor func unverifiedDimensionHasNoHandle() async throws {
    let source = "cube(8);\n"
    let size = literal(.cubeUniformSize, "size", 8, at: span("8", in: source), drag: false)
    let cube = instance(1, "cube", at: span("cube(8)", in: source), operand: 1, properties: [size])
    let fixture = try await PlanningFixture.make(source, instances: [cube])
    let choice = try #require(PropertyChoice.choices(on: cube, among: fixture.byID).first)
    let plan = try choice.plan(in: fixture.result, source: fixture.snapshot, syntax: fixture.syntax)
    #expect(plan.dragBlocker == .unverified)
}

@Test @MainActor func offsetBelowAnUnknownPlacementHasNoHandle() async throws {
    let source = "hull() translate([w/2, 0, 0]) cube(1);\n"
    let x = expression(.translateX, "v", 3, at: span("w/2", in: source))
    let move = instance(1, "translate", at: span("translate([w/2, 0, 0])", in: source), properties: [x], opaque: true)
    let cube = instance(2, "cube", parent: 1, at: span("cube(1)", in: source), operand: 1, opaque: true)
    let fixture = try await PlanningFixture.make(source, instances: [move, cube])
    let choice = try #require(PropertyChoice.choices(on: move, among: fixture.byID).first {
        if case .offset = $0.action { true } else { false }
    })
    let plan = try choice.plan(in: fixture.result, source: fixture.snapshot, syntax: fixture.syntax)
    #expect(plan.dragBlocker == .opaqueFrame)
}

@Test @MainActor func offsetAppliedTwiceOnOnePathHasNoHandle() async throws {
    let source = "module step(n) { translate([w/2, 0, 0]) if (n > 0) step(n - 1); else cube(1); }\nstep(1);\n"
    let x = expression(.translateX, "v", 3, at: span("w/2", in: source))
    let call = span("translate([w/2, 0, 0])", in: source)
    let outer = instance(1, "translate", at: call, properties: [x])
    let inner = instance(2, "translate", parent: 1, at: call, properties: [x])
    let cube = instance(3, "cube", parent: 2, at: span("cube(1)", in: source), operand: 1)
    let fixture = try await PlanningFixture.make(source, instances: [outer, inner, cube])
    let choice = try #require(PropertyChoice.choices(on: inner, among: fixture.byID).first {
        if case .offset = $0.action { true } else { false }
    })
    let plan = try choice.plan(in: fixture.result, source: fixture.snapshot, syntax: fixture.syntax)
    #expect(plan.dragBlocker == .sharedPath)
}

@Test @MainActor func prefixBelowAnUnknownPlacementHasNoHandle() async throws {
    let source = "hull() cube(1);\n"
    let cube = instance(1, "cube", at: span("cube(1)", in: source), operand: 1, opaque: true)
    let fixture = try await PlanningFixture.make(source, instances: [cube])
    let choice = try #require(PropertyChoice.choices(on: cube, among: fixture.byID).first)
    let plan = try choice.plan(in: fixture.result, source: fixture.snapshot, syntax: fixture.syntax)
    #expect(plan.dragBlocker == .opaqueFrame)
}

// MARK: - Prefix insertion

@Test @MainActor func omittedPropertiesWithholdPrefixInsertion() async throws {
    let source = "cube(8);\n"
    let cube = instance(1, "cube", at: span("cube(8)", in: source), operand: 1)
    let fixture = try await PlanningFixture.make(source, instances: [cube], propertiesOmitted: true)
    let choice = try #require(PropertyChoice.choices(on: cube, among: fixture.byID).first)
    #expect(throws: PropertyPlanningError.self) {
        try choice.plan(in: fixture.result, source: fixture.snapshot, syntax: fixture.syntax)
    }
}

@Test @MainActor func prefixIsWithheldWhenTheDocumentRedefinesTranslate() async throws {
    let source = "module translate(v) { }\ncube(8);\n"
    let cube = instance(1, "cube", at: span("cube(8)", in: source), operand: 1)
    let fixture = try await PlanningFixture.make(source, instances: [cube])
    let choice = try #require(PropertyChoice.choices(on: cube, among: fixture.byID).first)
    #expect(throws: PropertyPlanningError.self) {
        try choice.plan(in: fixture.result, source: fixture.snapshot, syntax: fixture.syntax)
    }
}

// MARK: - Choices

@Test @MainActor func aPickOffersTheEnclosingCallsExplicitArgument() async throws {
    let source = "module hole(d) { cylinder(d = d + 1); }\nhole(d = 4);\n"
    let argument = literal(.moduleArgument, "d", 4, at: span("hole(d = 4)", "4", in: source))
    let module = instance(1, "hole", at: span("hole(d = 4)", in: source),
                          definition: span("module hole(d) { cylinder(d = d + 1); }", in: source), properties: [argument])
    let diameter = expression(.cylinderDiameter, "d", 5, at: span("d + 1", in: source),
                              inputs: [span("hole(d = 4)", "4", in: source)])
    let cylinder = instance(2, "cylinder", parent: 1, at: span("cylinder(d = d + 1)", in: source), operand: 1,
                            properties: [diameter])
    let fixture = try await PlanningFixture.make(source, instances: [module, cylinder])
    let choice = try #require(PropertyChoice.choices(on: cylinder, among: fixture.byID).first {
        if case .value(let owner, let property) = $0.action {
            owner.id == 1 && property.semantic == .moduleArgument
        } else { false }
    })
    let plan = try choice.plan(in: fixture.result, source: fixture.snapshot, syntax: fixture.syntax)
    #expect(plan.scope == "This call site")
}

@Test @MainActor func aVanishedChoiceNeverBecomesAnotherProperty() async throws {
    let source = "cube([10, 20, 30]);\n"
    let x = literal(.cubeSizeX, "size", 10, at: span("10", in: source))
    let y = literal(.cubeSizeY, "size", 20, at: span("20", in: source))
    let cube = instance(1, "cube", operand: 1, properties: [x, y])
    let fixture = try await PlanningFixture.make(source, instances: [cube])
    let choices = PropertyChoice.choices(on: cube, among: fixture.byID)
    #expect(PropertyChoice.selectedIndex(after: nil, in: choices) == 0)
    #expect(PropertyChoice.selectedIndex(after: choices[1].id, in: choices) == 1)
    #expect(PropertyChoice.selectedIndex(after: "0:cubeSizeZ:size", in: choices) == nil)
}

@Test @MainActor func anInsertedMoveContinuesAsItsTranslation() async throws {
    let source = "translate([0, 2, 0]) cube(8);\n"
    let components: [PropertyRecord] = [
        literal(.translateX, "v", 0, at: span("[0,", "0", in: source)),
        literal(.translateY, "v", 2, at: span("2", in: source)),
        literal(.translateZ, "v", 0, at: span(" 0]", "0", in: source)),
    ]
    let move = instance(1, "translate", at: span("translate([0, 2, 0])", in: source), properties: components)
    let size = literal(.cubeUniformSize, "size", 8, at: span("8", in: source))
    let cube = instance(2, "cube", parent: 1, at: span("cube(8)", in: source), operand: 1, properties: [size])
    let fixture = try await PlanningFixture.make(source, instances: [move, cube])
    let choices = PropertyChoice.choices(on: cube, among: fixture.byID)
    let index = try #require(PropertyChoice.selectedIndex(after: "prefix-Y", in: choices))
    guard case .value(_, let property) = choices[index].action else {
        Issue.record("The inserted move lost its translation")
        return
    }
    #expect(property.semantic == .translateY)
}

// MARK: - Impact and selection

@Test @MainActor func aModuleIsRepresentedByEveryRenderedOperand() async throws {
    let instances = [instance(1, "post"), instance(2, "cube", parent: 1, operand: 1),
                     instance(3, "sphere", parent: 1, operand: 2)]
    let fixture = try await PlanningFixture.make("post();\n", instances: instances)
    #expect(fixture.scene.renderedOperands(below: [1]) == [2, 3])
    #expect(fixture.scene.renderedOperands(below: [1, 2]) == [2, 3])
}

@Test @MainActor func aRemovedChildFallsBackToItsAncestor() async throws {
    let source = "post();\nmodule post() { cube(1); }\n"
    let post = instance(1, "post", at: span("post()", in: source))
    let cube = instance(2, "cube", parent: 1, at: span("cube(1)", in: source), operand: 1)
    let before = try await PlanningFixture.make(source, instances: [post, cube])
    let after = try await PlanningFixture.make(source, instances: [post])
    let path = SelectionPath(to: 2, in: before.scene, files: before.result.files)
    #expect(path.resolve(in: after.scene, files: after.result.files) == .ancestor(1))
}

@Test @MainActor func aRemovedTopLevelSelectionNeverMovesToAnEqualSibling() async throws {
    let source = "cube(1);\ncube(1);\n"
    let root = instance(1, "group")
    let first = instance(2, "cube", parent: 1, at: span("cube(1)", in: source), operand: 1)
    let length = UInt64("cube(1);\n".utf8.count)
    let second = instance(3, "cube", parent: 1,
                          at: WireSpan(fileID: 0, start: length, end: length + 7), operand: 1)
    let before = try await PlanningFixture.make(source, instances: [root, first, second])
    let after = try await PlanningFixture.make(source, instances: [root, second])
    let path = SelectionPath(to: 2, in: before.scene, files: before.result.files)
    #expect(path.resolve(in: after.scene, files: after.result.files) == nil)
}

@Test @MainActor func deletingTheSelectedChildsStatementSelectsItsParent() async throws {
    let source = "post();\nmodule post() { cube(1); }\n"
    let post = instance(1, "post", at: span("post()", in: source))
    let call = span("cube(1)", in: source)
    let cube = instance(2, "cube", parent: 1, at: call, operand: 1)
    let before = try await PlanningFixture.make(source, instances: [post, cube])

    let removed = Int(call.start)..<(Int(call.end) + 1)
    let edit = SourceEdit(range: removed, expected: Data("cube(1);".utf8), replacement: Data())
    var path = SelectionPath(to: 2, in: before.scene, files: before.result.files)
    let kept = path.follow([edit])
    #expect(kept)

    let after = try await PlanningFixture.make("post();\nmodule post() {  }\n", instances: [post])
    #expect(path.resolve(in: after.scene, files: after.result.files) == .ancestor(1))
}

private struct WrapperEdit: Sendable {
    let before: String
    let after: String
    let removed: String
    let inserted: String
    /// The edited text's position is that of this first occurrence.
    let at: String
    let keeps: Bool
}

@MainActor
private func translatedCube(_ source: String) async throws -> (PlanningFixture, cube: InstanceRecord) {
    let bytes = Data(source.utf8)
    var instances = [instance(1, "group")]
    var start = 0
    while let found = bytes.range(of: Data("translate([".utf8), in: start..<bytes.count) {
        let close = try #require(bytes.range(of: Data(")".utf8), in: found.upperBound..<bytes.count))
        let comma = try #require(bytes.range(of: Data(",".utf8), in: found.upperBound..<bytes.count))
        let token = WireSpan(fileID: 0, start: UInt64(found.upperBound), end: UInt64(comma.lowerBound))
        let value = try #require(Double(String(decoding: bytes[found.upperBound..<comma.lowerBound], as: UTF8.self)))
        instances.append(instance(UInt32(instances.count + 1), "translate", parent: UInt32(instances.count),
                                  at: WireSpan(fileID: 0, start: UInt64(found.lowerBound), end: UInt64(close.upperBound)),
                                  properties: [literal(.translateX, "v", value, at: token)]))
        start = close.upperBound
    }
    let cube = instance(UInt32(instances.count + 1), "cube", parent: UInt32(instances.count),
                        at: span("cube(8)", in: source), operand: 1)
    return (try await PlanningFixture.make(source, instances: instances + [cube]), cube)
}

@Test(arguments: [
    WrapperEdit(before: "translate([3, 0, 0]) cube(8);", after: "translate([3, 0, 0]) translate([7, 0, 0]) cube(8);",
                removed: "", inserted: "translate([7, 0, 0]) ", at: "cube", keeps: false),
    WrapperEdit(before: "translate([7, 0, 0]) translate([3, 0, 0]) cube(8);", after: "translate([7, 0, 0]) cube(8);",
                removed: "translate([3, 0, 0]) ", inserted: "", at: "translate([3", keeps: false),
    WrapperEdit(before: "translate([3, 0, 0]) cube(8);", after: "translate([7, 0, 0]) translate([3, 0, 0]) cube(8);",
                removed: "", inserted: "translate([7, 0, 0]) ", at: "translate", keeps: true),
    WrapperEdit(before: "translate([3, 0, 0]) cube(8);", after: "translate([12, 0, 0]) cube(8);",
                removed: "3", inserted: "12", at: "3", keeps: true),
])
@MainActor private func aChoiceNeverMovesToAnotherWrapper(_ change: WrapperEdit) async throws {
    let (before, cube) = try await translatedCube(change.before)
    let chosen = try #require(PropertyChoice.choices(on: cube, among: before.byID).first { $0.title == "Translate X" })
    var path = SelectionPath(to: cube.id, in: before.scene, files: before.result.files)
    let position = Int(span(change.at, in: change.before).start)
    let removed = Data(change.removed.utf8)
    let followed = path.follow([SourceEdit(range: position..<(position + removed.count), expected: removed,
                                           replacement: Data(change.inserted.utf8))])
    #expect(followed)

    let (after, moved) = try await translatedCube(change.after)
    #expect(path.resolve(in: after.scene, files: after.result.files) == .exact(moved.id))
    #expect(PropertyChoice.continues(chosen.id, to: moved.id, along: path, in: after.scene,
                                     files: after.result.files) == change.keeps)
}

@Test @MainActor func losingADeepRecursiveSelectionIsLinear() async throws {
    let source = "module r(n) { if (n > 0) r(n - 1); else cube(1); }\nr(300);\n"
    let call = span("r(n - 1)", in: source)
    func recursion(_ depth: UInt32) -> [InstanceRecord] {
        var instances = [instance(1, "group")]
        for id in 2...(depth + 1) { instances.append(instance(id, "r", parent: id - 1, at: call)) }
        instances.append(instance(depth + 2, "cube", parent: depth + 1, at: span("cube(1)", in: source), operand: 1))
        return instances
    }
    let before = try await PlanningFixture.make(source, instances: recursion(300))
    let after = try await PlanningFixture.make(source, instances: recursion(150))
    let path = SelectionPath(to: 302, in: before.scene, files: before.result.files)
    let clock = ContinuousClock()
    let started = clock.now
    #expect(path.resolve(in: after.scene, files: after.result.files) == .ancestor(151))
    let elapsed = started.duration(to: clock.now)
    #expect(elapsed < .milliseconds(250), "Resolving took \(elapsed)")
}
