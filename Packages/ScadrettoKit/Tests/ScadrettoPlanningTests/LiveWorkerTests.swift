import Foundation
import ScadrettoCore
import ScadrettoEngineClient
import ScadrettoPlanning
import ScadrettoSyntax
import ScadrettoViewport
import Testing
import simd

private let repository: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
}()

private let workerProduct = repository.appending(path: ".build/engine/worker")
private let hasWorker = FileManager.default.isExecutableFile(
    atPath: workerProduct.appending(path: "bin/scadretto-engine").path
)

/// One row of the regression matrix: pick, choose, type, then check the bytes.
struct EditCase: Sendable, CustomTestStringConvertible {
    let name: String
    let source: String
    /// The executed instance to pick: its name and its ordinal among that name.
    let pick: (name: String, ordinal: Int)
    let choice: String
    let value: Double
    let edited: String
    /// The expected world translation of the picked instance after the edit.
    var position: SIMD3<Double>?

    var testDescription: String { name }
}

private let matrix: [EditCase] = [
    // Scope
    EditCase(name: "module-local d shadows the top level",
             source: "d = 4;\nmodule m() { d = 4; cylinder(h = 2, d = d); }\nm();\n",
             pick: ("cylinder", 0), choice: "Diameter", value: 5,
             edited: "d = 4;\nmodule m() { d = 5; cylinder(h = 2, d = d); }\nm();\n"),
    EditCase(name: "equal literals at two calls",
             source: "cube(4);\ntranslate([9, 0, 0]) cube(4);\n",
             pick: ("cube", 1), choice: "Uniform size", value: 5,
             edited: "cube(4);\ntranslate([9, 0, 0]) cube(5);\n"),
    EditCase(name: "positional module argument",
             source: "module hole(d) { cylinder(h = 2, d = d); }\nhole(4);\ntranslate([9, 0, 0]) hole(d = 4);\n",
             pick: ("cylinder", 0), choice: "Diameter", value: 5,
             edited: "module hole(d) { cylinder(h = 2, d = d); }\nhole(5);\ntranslate([9, 0, 0]) hole(d = 4);\n"),
    EditCase(name: "named module argument",
             source: "module hole(d) { cylinder(h = 2, d = d); }\nhole(4);\ntranslate([9, 0, 0]) hole(d = 4);\n",
             pick: ("cylinder", 1), choice: "Diameter", value: 5,
             edited: "module hole(d) { cylinder(h = 2, d = d); }\nhole(4);\ntranslate([9, 0, 0]) hole(d = 5);\n"),
    EditCase(name: "enclosing call's argument",
             source: "module hole(d) { cylinder(h = 2, d = d + 1); }\nhole(d = 4);\n",
             pick: ("cylinder", 0), choice: "Argument d of hole", value: 6,
             edited: "module hole(d) { cylinder(h = 2, d = d + 1); }\nhole(d = 6);\n"),
    EditCase(name: "overwriting assignment",
             source: "d = 4;\nd = 4;\ncylinder(h = 2, d = d);\n",
             pick: ("cylinder", 0), choice: "Diameter", value: 5,
             edited: "d = 4;\nd = 5;\ncylinder(h = 2, d = d);\n"),

    // Expressions
    EditCase(name: "offset keeps wall/2",
             source: "wall = 4;\ntranslate([wall/2, 0, 0]) cube(1);\n",
             pick: ("cube", 0), choice: "Offset X here", value: 3,
             edited: "wall = 4;\ntranslate([(wall/2) + 3, 0, 0]) cube(1);\n", position: SIMD3(5, 0, 0)),
    EditCase(name: "negative offset beside a block comment",
             source: "wall = 4;\ntranslate([0, (wall + 2) * 3 /* keep */, 0]) cube(1);\n",
             pick: ("cube", 0), choice: "Offset Y here", value: -1.5,
             edited: "wall = 4;\ntranslate([0, ((wall + 2) * 3) - 1.5 /* keep */, 0]) cube(1);\n",
             position: SIMD3(0, 16.5, 0)),
    EditCase(name: "offset before a line comment",
             source: "wall = 4;\ntranslate([wall/2 // half\n, 0, 0]) cube(1);\n",
             pick: ("cube", 0), choice: "Offset X here", value: 3,
             edited: "wall = 4;\ntranslate([(wall/2) + 3 // half\n, 0, 0]) cube(1);\n", position: SIMD3(5, 0, 0)),
    EditCase(name: "offset on a variable",
             source: "x0 = 3;\ntranslate([x0, 0, 0]) cube(1);\n",
             pick: ("cube", 0), choice: "Offset X here", value: 2,
             edited: "x0 = 3;\ntranslate([(x0) + 2, 0, 0]) cube(1);\n", position: SIMD3(5, 0, 0)),

    // Primitive properties
    EditCase(name: "uniform cube", source: "cube(10);\n",
             pick: ("cube", 0), choice: "Uniform size", value: 12, edited: "cube(12);\n"),
    EditCase(name: "centered vector cube", source: "cube([10, 20, 30], center = true);\n",
             pick: ("cube", 0), choice: "Size Y (centered)", value: 24, edited: "cube([10, 24, 30], center = true);\n"),
    EditCase(name: "sphere diameter authored as a radius", source: "sphere(r = 2);\n",
             pick: ("sphere", 0), choice: "Diameter", value: 5, edited: "sphere(r = 2.5);\n"),
    EditCase(name: "cylinder diameter authored as a radius", source: "cylinder(h = 8, r = 2);\n",
             pick: ("cylinder", 0), choice: "Diameter", value: 5, edited: "cylinder(h = 8, r = 2.5);\n"),
    EditCase(name: "tapered cylinder bottom", source: "cylinder(8, 2, 3);\n",
             pick: ("cylinder", 0), choice: "Bottom radius", value: 2.5, edited: "cylinder(8, 2.5, 3);\n"),
    EditCase(name: "tapered cylinder top", source: "cylinder(h = 8, r1 = 3, r2 = 2);\n",
             pick: ("cylinder", 0), choice: "Top radius", value: 1, edited: "cylinder(h = 8, r1 = 3, r2 = 1);\n"),
    EditCase(name: "centered height", source: "cylinder(h = 8, d = 4, center = true);\n",
             pick: ("cylinder", 0), choice: "Height (centered)", value: 10,
             edited: "cylinder(h = 10, d = 4, center = true);\n"),

    // Transforms
    EditCase(name: "translation under a rotation",
             source: "rotate([0, 0, 90]) translate([10, 0, 0]) cube(2);\n",
             pick: ("cube", 0), choice: "Translate X", value: 12,
             edited: "rotate([0, 0, 90]) translate([12, 0, 0]) cube(2);\n", position: SIMD3(0, 12, 0)),
    EditCase(name: "translation under a nonuniform scale",
             source: "scale([2, 3, 4]) translate([1, 1, 1]) cube(1);\n",
             pick: ("cube", 0), choice: "Translate Y", value: 5,
             edited: "scale([2, 3, 4]) translate([1, 5, 1]) cube(1);\n", position: SIMD3(2, 15, 4)),
    EditCase(name: "translation under a mirror",
             source: "mirror([1, 0, 0]) translate([10, 0, 0]) cube(2);\n",
             pick: ("cube", 0), choice: "Translate X", value: 12,
             edited: "mirror([1, 0, 0]) translate([12, 0, 0]) cube(2);\n", position: SIMD3(-12, 0, 0)),
    EditCase(name: "negative translation",
             source: "translate([-3, 0, 0]) cube(1);\n",
             pick: ("cube", 0), choice: "Translate X", value: -4,
             edited: "translate([-4, 0, 0]) cube(1);\n", position: SIMD3(-4, 0, 0)),

    // Prefix insertion
    EditCase(name: "first move keeps BOM, CRLF and emoji",
             source: "\u{FEFF}// \u{1F527}\r\ncube(8);\r\n",
             pick: ("cube", 0), choice: "Move Y here", value: 2,
             edited: "\u{FEFF}// \u{1F527}\r\ntranslate([0, 2, 0]) cube(8);\r\n", position: SIMD3(0, 2, 0)),
    EditCase(name: "move follows the root modifier",
             source: "!cube(8);\n",
             pick: ("cube", 0), choice: "Move X here", value: 2,
             edited: "!translate([2, 0, 0]) cube(8);\n", position: SIMD3(2, 0, 0)),
    EditCase(name: "move follows the debug modifier",
             source: "#cube(8);\n",
             pick: ("cube", 0), choice: "Move Z here", value: 2,
             edited: "#translate([0, 0, 2]) cube(8);\n", position: SIMD3(0, 0, 2)),
    EditCase(name: "move follows stacked modifiers",
             source: "#!cube(8);\n",
             pick: ("cube", 0), choice: "Move X here", value: 2,
             edited: "#!translate([2, 0, 0]) cube(8);\n", position: SIMD3(2, 0, 0)),

    // Module scopes
    EditCase(name: "child chosen by children(i) in the wrapper's loop",
             source: "module spread() { for (i = [0 : $children - 1]) translate([i * 10, 0, 0]) children(i); }\n"
                 + "spread() { cube(1); translate([0, 3, 0]) cube(2); }\n",
             pick: ("cube", 1), choice: "Translate Y", value: 7,
             edited: "module spread() { for (i = [0 : $children - 1]) translate([i * 10, 0, 0]) children(i); }\n"
                 + "spread() { cube(1); translate([0, 7, 0]) cube(2); }\n",
             position: SIMD3(10, 7, 0)),
    EditCase(name: "child passed through children()",
             source: "module wrap() { translate([0, 0, 5]) children(); }\nwrap() translate([3, 0, 0]) cube(1);\n",
             pick: ("cube", 0), choice: "Translate X", value: 7,
             edited: "module wrap() { translate([0, 0, 5]) children(); }\nwrap() translate([7, 0, 0]) cube(1);\n",
             position: SIMD3(7, 0, 5)),
]

@MainActor
private struct Session {
    let engine: EngineClient
    let document: SourceDocument
    private let storage: URL
    private let fileURL: URL?

    /// Sibling files make the source a saved main file beside them.
    init(_ source: String, siblings: [String: String] = [:]) throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "Planner worker \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        fileURL = siblings.isEmpty ? nil : storage.appending(path: "Main.scad")
        if let fileURL {
            try Data(source.utf8).write(to: fileURL)
            for (name, text) in siblings {
                try Data(text.utf8).write(to: storage.appending(path: name))
            }
        }
        let resources = workerProduct.appending(path: "Resources")
        engine = EngineClient(runtime: WorkerRuntime(
            executable: workerProduct.appending(path: "bin/scadretto-engine"),
            resourceRoots: [resources], bundleLibraries: resources.appending(path: "libraries"), storageRoot: storage
        ))
        document = SourceDocument(buffer: try SourceBuffer(bytes: Data(source.utf8)))
    }

    func evaluate() async throws -> EvaluationResult {
        let snapshot = document.snapshot
        let request = try await engine.makeRequest(snapshot: snapshot, fileURL: fileURL, dependencyGeneration: 0,
                                                   requestID: UUID())
        return try await engine.evaluate(request, source: snapshot.buffer.bytes).outcome.result
    }

    func close() async {
        await engine.shutdown()
        try? FileManager.default.removeItem(at: storage)
    }

    func instance(_ pick: (name: String, ordinal: Int), in result: EvaluationResult) throws -> InstanceRecord {
        let named = try #require(result.scene).instances.filter { $0.name == pick.name }
        try #require(named.indices.contains(pick.ordinal))
        return named[pick.ordinal]
    }

    func choice(_ title: String, on picked: InstanceRecord, in result: EvaluationResult) throws -> PropertyChoice {
        let scene = try #require(result.scene)
        let byID = Dictionary(uniqueKeysWithValues: scene.instances.map { ($0.id, $0) })
        return try #require(PropertyChoice.choices(on: picked, among: byID).first { $0.title == title })
    }

    func plan(_ title: String, at pick: (name: String, ordinal: Int),
              in result: EvaluationResult) async throws -> PropertyEditPlan {
        let picked = try instance(pick, in: result)
        let choice = try choice(title, on: picked, in: result)
        let snapshot = document.snapshot
        return try choice.plan(in: result, source: snapshot, syntax: try await SyntaxParser().parse(snapshot))
    }

    /// The production picker over this result's meshes, as the app builds it.
    func candidates(from origin: SIMD3<Double>, toward target: SIMD3<Double>,
                    in result: EvaluationResult) throws -> [UInt32] {
        let scene = try #require(result.scene)
        let final = try #require(scene.mesh)
        let meshes = Dictionary(uniqueKeysWithValues: scene.operands.map {
            ($0.id, ViewportMesh(positions: $0.mesh.positions, indices: $0.mesh.indices))
        })
        let removed = scene.subtractedInstances
        let occurrences = scene.instances.compactMap { instance -> ViewportOperand? in
            guard let meshID = instance.operand else { return nil }
            func column(_ start: Int) -> SIMD4<Double> {
                SIMD4(instance.world[start], instance.world[start + 1], instance.world[start + 2], instance.world[start + 3])
            }
            return ViewportOperand(id: instance.id, meshID: meshID,
                                   world: simd_double4x4(columns: (column(0), column(4), column(8), column(12))),
                                   isSubtracted: removed.contains(instance.id))
        }
        let picker = try #require(ViewportPicker(mesh: ViewportMesh(positions: final.positions, indices: final.indices),
                                                 owners: final.triangleOwners, operandMeshes: meshes,
                                                 occurrences: occurrences))
        let picked = picker.pick(along: ViewportRay(origin: origin, direction: simd_normalize(target - origin)))
        return try #require(picked).candidates
    }

    func apply(_ plan: PropertyEditPlan, value: Double) throws -> [SourceEdit] {
        let planned = try plan.operation.edit(setting: value, in: document.snapshot)
        let edit = try #require(planned)
        return try document.apply(document.transaction(edits: [edit], label: "Change"))
    }
}

/// The real worker, the planner, the document transaction and a reevaluation.
@Suite(.serialized, .enabled(if: hasWorker, "Run Scripts/build-engine to test against the worker."))
struct LiveWorkerTests {
    @Test(arguments: matrix) @MainActor
    func editsOnlyItsTokenAndReevaluatesAsShown(_ test: EditCase) async throws {
        let session = try Session(test.source)
        let before = try await session.evaluate()
        let plan = try await session.plan(test.choice, at: test.pick, in: before)
        let inverse = try session.apply(plan, value: test.value)
        #expect(session.document.buffer.bytes == Data(test.edited.utf8))

        let after = try await session.evaluate()
        let picked = try session.instance(test.pick, in: after)
        if let position = test.position {
            let shown = SIMD3(picked.world[12], picked.world[13], picked.world[14])
            let error = shown - position
            #expect(abs(error.x) + abs(error.y) + abs(error.z) < 1e-9)
        } else {
            #expect(try session.choice(test.choice, on: picked, in: after).value == test.value)
        }

        try session.document.apply(session.document.transaction(edits: inverse, label: "Undo"))
        #expect(session.document.buffer.bytes == Data(test.source.utf8))
        await session.close()
    }

    @Test @MainActor func platePitchMovesTheFourBores() async throws {
        let plate = try String(contentsOf: repository.appending(path: "Tests/Fixtures/mounting-plate.scad"),
                               encoding: .utf8)
        let session = try Session(plate)
        let before = try await session.evaluate()
        let plan = try await session.plan("Pitch", at: ("cylinder", 2), in: before)
        #expect(plan.dragBlocker == nil)
        _ = try session.apply(plan, value: 22)
        #expect(session.document.buffer.bytes == Data(plate.replacingOccurrences(of: "pitch = 20;", with: "pitch = 22;").utf8))

        let scene = try #require(try await session.evaluate().scene)
        #expect(scene.instances.filter { $0.name == "cylinder" }.map { $0.world[12] } == [15, 37, 59, 81])
        await session.close()
    }

    @Test @MainActor func dependentBaseWithholdsPitchDragButKeepsNumericEntry() async throws {
        let session = try Session(
            "pitch = 20;\nx0 = pitch;\nfor (i = [0 : 3]) translate([x0 + i * pitch, 0, 0]) cylinder(h = 2, d = 4);\n"
        )
        let before = try await session.evaluate()
        let plan = try await session.plan("Pitch", at: ("cylinder", 2), in: before)
        #expect(plan.dragBlocker == .unverified)
        _ = try session.apply(plan, value: 22)
        let after = try await session.evaluate()
        #expect(try session.instance(("cylinder", 2), in: after).world[12] == 66)
        await session.close()
    }

    @Test @MainActor func aSharedGeneratorIsNeverRewrittenForOneOccurrence() async throws {
        let session = try Session("for (i = [0 : 2]) cube(1);\n")
        let before = try await session.evaluate()
        await #expect(throws: PropertyPlanningError.self) {
            try await session.plan("Move X here", at: ("cube", 1), in: before)
        }
        await session.close()
    }

    @Test @MainActor func aComputedListElementIsInspectOnly() async throws {
        let session = try Session("x = [1, 2, 3];\ncube([x[0], 20, 30]);\n")
        let before = try await session.evaluate()
        await #expect(throws: PropertyBindingError.expression) {
            try await session.plan("Size X", at: ("cube", 0), in: before)
        }
        await session.close()
    }

    @Test @MainActor func aBuiltInDefaultSaysSo() async throws {
        let session = try Session("sphere(r = 2);\n")
        let before = try await session.evaluate()
        do {
            _ = try await session.plan("Fragments ($fn)", at: ("sphere", 0), in: before)
            Issue.record("A built-in default became editable")
        } catch {
            #expect(error.localizedDescription == "The evaluator supplied a default for this property.")
        }
        await session.close()
    }

    @Test @MainActor func equalArgumentsAtTwoCallsKeepSeparateImpact() async throws {
        let session = try Session(
            "module hole(d) { cylinder(h = 2, d = d); }\nhole(4);\ntranslate([9, 0, 0]) hole(d = 4);\n"
        )
        let result = try await session.evaluate()
        let positional = try session.instance(("cylinder", 0), in: result).id
        let named = try session.instance(("cylinder", 1), in: result).id
        let first = try await session.plan("Diameter", at: ("cylinder", 0), in: result)
        let second = try await session.plan("Diameter", at: ("cylinder", 1), in: result)
        #expect(first.affected.contains(positional) && !first.affected.contains(named))
        #expect(second.affected.contains(named) && !second.affected.contains(positional))
        await session.close()
    }

    @Test @MainActor func aCloserFragmentCountLeavesTheSharedOnesImpact() async throws {
        let session = try Session("$fn = 64;\ncylinder(h = 2, d = 4);\ncylinder(h = 2, d = 4, $fn = 32);\n")
        let result = try await session.evaluate()
        let plan = try await session.plan("Fragments ($fn)", at: ("cylinder", 0), in: result)
        #expect(plan.affected.contains(try session.instance(("cylinder", 0), in: result).id))
        #expect(!plan.affected.contains(try session.instance(("cylinder", 1), in: result).id))
        await session.close()
    }

    @Test @MainActor func aLaterIncludeOwnsTheOverwrittenValue() async throws {
        let session = try Session("d = 4;\ninclude <sizes.scad>\ncylinder(h = 2, d = d);\n",
                                  siblings: ["sizes.scad": "d = 6;\n"])
        let result = try await session.evaluate()
        do {
            _ = try await session.plan("Diameter", at: ("cylinder", 0), in: result)
            Issue.record("A value owned by an include became editable")
        } catch PropertyBindingError.dependency(let path) {
            #expect(path.hasSuffix("/sizes.scad"))
        }
        await session.close()
    }

    @Test @MainActor func theMainFileOwnsAnOverwrittenIncludedDefault() async throws {
        let source = "include <sizes.scad>\nd = 4;\ncylinder(h = 2, d = d);\n"
        let session = try Session(source, siblings: ["sizes.scad": "d = 6;\n"])
        let result = try await session.evaluate()
        let plan = try await session.plan("Diameter", at: ("cylinder", 0), in: result)
        _ = try session.apply(plan, value: 5)
        #expect(session.document.buffer.bytes == Data(source.replacingOccurrences(of: "d = 4;", with: "d = 5;").utf8))
        await session.close()
    }

    @Test @MainActor func aUsedLibrarysDefaultNamesItsFile() async throws {
        let session = try Session("use <lib.scad>\nlib_size = 9;\nm();\n",
                                  siblings: ["lib.scad": "lib_size = 4;\nmodule m(d = lib_size) cylinder(h = 2, d = d);\n"])
        let result = try await session.evaluate()
        #expect(try session.choice("Diameter", on: session.instance(("cylinder", 0), in: result), in: result).value == 4)
        do {
            _ = try await session.plan("Diameter", at: ("cylinder", 0), in: result)
            Issue.record("A library default became editable")
        } catch PropertyBindingError.dependency(let path) {
            #expect(path.hasSuffix("/lib.scad"))
        }
        await session.close()
    }

    @Test @MainActor func anOffsetFollowsItsFormulaAndTakesAnotherAfterReopen() async throws {
        let source = "wall = 4;\ntranslate([wall/2, 0, 0]) cube(1);\n"
        let session = try Session(source)
        let first = try await session.plan("Offset X here", at: ("cube", 0), in: try await session.evaluate())
        _ = try session.apply(first, value: 3)
        let saved = String(decoding: session.document.buffer.bytes, as: UTF8.self)
        await session.close()

        let reopened = try Session(saved.replacingOccurrences(of: "wall = 4;", with: "wall = 8;"))
        let before = try await reopened.evaluate()
        #expect(try reopened.instance(("cube", 0), in: before).world[12] == 7)
        let second = try await reopened.plan("Offset X here", at: ("cube", 0), in: before)
        _ = try reopened.apply(second, value: 1)
        #expect(String(decoding: reopened.document.buffer.bytes, as: UTF8.self)
            == "wall = 8;\ntranslate([((wall/2) + 3) + 1, 0, 0]) cube(1);\n")
        #expect(try reopened.instance(("cube", 0), in: try await reopened.evaluate()).world[12] == 8)
        await reopened.close()
    }

    @Test(arguments: [
        ("cube([10, 20, 30], center = true);\n", "cube", "Size Y (centered)", 1),
        ("cube(10, center = true);\n", "cube", "Uniform size (centered)", 0),
        ("cylinder(h = 8, d = 4, center = true);\n", "cylinder", "Height (centered)", 2),
    ]) @MainActor
    func aCenteredResizeStaysSymmetric(source: String, name: String, title: String, axis: Int) async throws {
        let session = try Session(source)
        let plan = try await session.plan(title, at: (name, 0), in: try await session.evaluate())
        _ = try session.apply(plan, value: 14)
        let mesh = try #require(try await session.evaluate().scene?.mesh)
        let along = mesh.positions.map { Double($0[axis]) }
        #expect(along.min() == -7 && along.max() == 7)
        await session.close()
    }

    @Test @MainActor func aTopRadiusChangesOnlyTheTop() async throws {
        let session = try Session("cylinder(h = 8, r1 = 3, r2 = 2, $fn = 8);\n")
        let plan = try await session.plan("Top radius", at: ("cylinder", 0), in: try await session.evaluate())
        _ = try session.apply(plan, value: 1)
        let mesh = try #require(try await session.evaluate().scene?.mesh)
        for (z, radius) in [(0.0, 3.0), (8.0, 1.0)] {
            let end = mesh.positions.filter { Double($0.z) == z }.map { Double($0.x) }
            #expect(abs(try #require(end.max()) - radius) < 1e-9)
        }
        await session.close()
    }

    /// The app draws a move handle along the edited frame's world column.
    @Test(arguments: [
        "rotate([20, 30, 40]) translate([2, 3, 4]) cube(1);\n",
        "scale([2, -3, 4]) translate([2, 3, 4]) cube(1);\n",
        "mirror([1, 1, 0]) translate([2, 3, 4]) cube(1);\n",
        "translate([9, 0, 0]) rotate([0, 0, 35]) scale([2, 1, 1]) translate([2, 3, 4]) cube(1);\n",
    ]) @MainActor
    func aCommittedMoveFollowsItsHandlesAxis(_ source: String) async throws {
        let session = try Session(source)
        let before = try await session.evaluate()
        let cube = try session.instance(("cube", 0), in: before)
        guard case .value(let frame, _) = try session.choice("Translate Y", on: cube, in: before).action else {
            Issue.record("The translation offered no value")
            return
        }
        let plan = try await session.plan("Translate Y", at: ("cube", 0), in: before)
        #expect(plan.dragBlocker == nil)
        _ = try session.apply(plan, value: 8)
        let after = try session.instance(("cube", 0), in: try await session.evaluate())
        for row in 0..<3 {
            // Five authored units along the frame's local Y, which is column one.
            #expect(abs(after.world[12 + row] - cube.world[12 + row] - 5 * frame.world[4 + row]) < 1e-9)
        }
        await session.close()
    }

    @Test @MainActor func aSingularParentLeavesNoAxisToDrag() async throws {
        let session = try Session("scale([0, 1, 1]) translate([2, 3, 4]) cube(1);\n")
        let before = try await session.evaluate()
        let cube = try session.instance(("cube", 0), in: before)
        guard case .value(let frame, _) = try session.choice("Translate X", on: cube, in: before).action else {
            Issue.record("The translation offered no value")
            return
        }
        // A zero axis is refused by the viewport's handle, whatever the proof.
        #expect(Array(frame.world[0..<3]) == [0, 0, 0])
        await session.close()
    }

    @Test @MainActor func aBackgroundStatementOffersNothingToEdit() async throws {
        let session = try Session("cube(1);\n%translate([4, 0, 0]) cube(8);\n")
        let scene = try #require(try await session.evaluate().scene)
        #expect(scene.instances.filter { $0.name == "cube" }.count == 1)
        #expect(!scene.instances.contains { $0.name == "translate" })
        await session.close()
    }

    @Test @MainActor func aSharedCallsWallResolvesToItsOccurrence() async throws {
        let session = try Session("""
        module hole() translate([0, 0, -1]) cylinder(h = 6, d = 4, $fn = 32);
        difference() {
            cube([30, 10, 4]);
            translate([5, 5, 0]) hole();
            translate([25, 5, 0]) hole();
        }
        """)
        let result = try await session.evaluate()
        for (ordinal, x) in [(0, 5.0), (1, 25.0)] {
            let center = SIMD3(x, 5, 2.1)
            let wall = center + SIMD3(2 * cos(0.04), 2 * sin(0.04), 0)
            let expected = try session.instance(("cylinder", ordinal), in: result).id
            #expect(try session.candidates(from: center, toward: wall, in: result) == [expected])
        }
        await session.close()
    }

    /// A guide is a promise: its occurrence moves that far along that axis.
    @Test(arguments: [
        ("s = 4;\ntranslate([s, 0, 0]) cube(1);\ntranslate([-s, 0, 0]) cube(1);\n", "cube", "Translate X", 1),
        ("s = 4;\ntranslate([s, 0, 0]) cube(1);\ntranslate([2 * s, 0, 0]) cube(1);\n", "cube", "Translate X", 1),
        ("s = 4;\ntranslate([s, 0, 0]) cube(1);\ntranslate([0, s, 0]) cube(1);\n", "cube", "Translate X", 2),
        ("s = 2;\nsphere(r = s, $fn = 8);\ntranslate([s, 0, 0]) cube(1);\n", "sphere", "Diameter", 1),
        // Iteration zero stays put, so it has no guide.
        ("x0 = 1;\np = 5;\nfor (i = [0 : 3]) translate([x0 + i * p, 0, 0]) cube(1);\n", "cube", "Pitch", 3),
    ]) @MainActor
    func everyMotionGuideMatchesReevaluation(source: String, name: String, title: String, guided: Int) async throws {
        let session = try Session(source)
        let before = try await session.evaluate()
        let pick = (name: name, ordinal: title == "Pitch" ? 2 : 0)
        let choice = try session.choice(title, on: session.instance(pick, in: before), in: before)
        let plan = try await session.plan(title, at: pick, in: before)
        let old = try #require(before.scene).instances
        let motions = choice.previewMotions(affected: plan.affected,
                                            instances: Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) }))
        _ = try session.apply(plan, value: try #require(choice.value) + 2)
        let new = try #require(try await session.evaluate().scene).instances
        #expect(motions.count == guided)
        for motion in motions {
            let index = try #require(old.firstIndex { $0.id == motion.instance })
            for axis in ModelAxis.allCases {
                let shown = 2 * motion.localUnitsPerValue[axis.index]
                let moved = new[index].local[12 + axis.index] - old[index].local[12 + axis.index]
                #expect(abs(moved - shown) < 1e-9, "\(axis.rawValue) of instance \(motion.instance)")
            }
        }
        await session.close()
    }

    @Test(arguments: [
        ("s = 4;\ncylinder(h = 2, d = s);\ntranslate([9, 0, 0]) cylinder(h = s, d = 4);\n", [true, false]),
        ("s = 2;\ncylinder(h = 2, r = s);\ntranslate([9, 0, 0]) cylinder(h = 3, r = s);\n", [true, true]),
        ("s = 4;\ncylinder(h = 2, d = s);\ntranslate([9, 0, 0]) cylinder(h = 3, r = s);\n", [true, false]),
    ]) @MainActor
    func aRimIsShownOnlyWhereItsDiameterFollows(source: String, shown: [Bool]) async throws {
        let session = try Session(source)
        let result = try await session.evaluate()
        let choice = try session.choice("Diameter", on: session.instance(("cylinder", 0), in: result), in: result)
        let plan = try await session.plan("Diameter", at: ("cylinder", 0), in: result)
        let instances = try #require(result.scene).instances
        let rims = choice.previewRims(affected: plan.affected,
                                      instances: Dictionary(uniqueKeysWithValues: instances.map { ($0.id, $0) }))
        #expect(instances.filter { $0.name == "cylinder" }.map { rims.contains($0.id) } == shown)
        await session.close()
    }

    @Test @MainActor func nestedDifferenceWallsResolveToTheirOwnOperand() async throws {
        let session = try Session("""
        difference() {
            cube(10);
            difference() {
                translate([2, 2, -1]) cube([6, 6, 12]);
                translate([4, 4, -2]) cube([2, 2, 14]);
            }
        }
        """)
        let result = try await session.evaluate()
        let hole = try session.instance(("cube", 1), in: result).id
        let island = try session.instance(("cube", 2), in: result).id
        let inside = SIMD3<Double>(3, 5.1, 5.2)
        #expect(try session.candidates(from: inside, toward: SIMD3(2, 5.1, 5.2), in: result) == [hole])
        #expect(try session.candidates(from: inside, toward: SIMD3(4, 5.1, 5.2), in: result) == [island])
        await session.close()
    }

    @Test @MainActor func identicalCachedCuttersResolveToTheirOccurrence() async throws {
        let session = try Session("""
        difference() {
            cube([30, 10, 4]);
            for (x = [5, 25]) translate([x, 5, -1]) cylinder(h = 6, d = 4, $fn = 32);
        }
        """)
        let result = try await session.evaluate()
        let first = try session.instance(("cylinder", 0), in: result)
        let second = try session.instance(("cylinder", 1), in: result)
        #expect(first.operand == second.operand)
        for (cutter, x) in [(first, 5.0), (second, 25.0)] {
            let center = SIMD3(x, 5, 2.1)
            let wall = center + SIMD3(2 * cos(0.04), 2 * sin(0.04), 0)
            #expect(try session.candidates(from: center, toward: wall, in: result) == [cutter.id])
        }
        await session.close()
    }

    @Test @MainActor func coincidentCuttersPresentBothChoices() async throws {
        let session = try Session("""
        difference() {
            cube([10, 10, 4]);
            translate([5, 5, -1]) cylinder(h = 6, d = 4, $fn = 32);
            translate([5, 5, -1]) cylinder(h = 6, d = 4, $fn = 32);
        }
        """)
        let result = try await session.evaluate()
        let both = [try session.instance(("cylinder", 0), in: result).id, try session.instance(("cylinder", 1), in: result).id]
        let wall = SIMD3(5 + 2 * cos(0.04), 5 + 2 * sin(0.04), 2.1)
        #expect(Set(try session.candidates(from: SIMD3(5, 5, 2.1), toward: wall, in: result)) == Set(both))
        await session.close()
    }

    @Test @MainActor func aRimPickPresentsThePlateAndTheCutter() async throws {
        let session = try Session("""
        difference() {
            cube([10, 10, 4]);
            translate([5, 5, -1]) cylinder(h = 6, d = 4, $fn = 32);
        }
        """)
        let result = try await session.evaluate()
        let expected = [try session.instance(("cube", 0), in: result).id, try session.instance(("cylinder", 0), in: result).id]
        // The cutter has a vertex at angle zero, so this ray meets the rim exactly.
        let found = try session.candidates(from: SIMD3(4, 5, 8), toward: SIMD3(7, 5, 4), in: result)
        #expect(Set(found) == Set(expected))
        await session.close()
    }

    /// The app follows its own edit, reevaluates, then resolves and rechooses.
    @Test(arguments: ["cube(8);\n", "union() { cube(8); sphere(3); }\n", "!cube(8);\n"]) @MainActor
    func anInsertedMoveKeepsTheSelection(_ source: String) async throws {
        let session = try Session(source)
        let before = try await session.evaluate()
        let picked = try session.instance(("cube", 0), in: before)
        let beforeScene = try #require(before.scene)
        var path = SelectionPath(to: picked.id, in: beforeScene, files: before.files)
        let chosen = try session.choice("Move Y here", on: picked, in: before)
        let plan = try await session.plan("Move Y here", at: ("cube", 0), in: before)
        let planned = try plan.operation.edit(setting: 2, in: session.document.snapshot)
        let edit = try #require(planned)
        let inverse = try session.document.apply(session.document.transaction(edits: [edit], label: "Move"))
        let followed = path.follow([edit])
        #expect(followed)

        let after = try await session.evaluate()
        let cube = try session.instance(("cube", 0), in: after)
        let scene = try #require(after.scene)
        #expect(path.resolve(in: scene, files: after.files) == .exact(cube.id))
        let byID = Dictionary(uniqueKeysWithValues: scene.instances.map { ($0.id, $0) })
        let choices = PropertyChoice.choices(on: cube, among: byID)
        let index = try #require(PropertyChoice.selectedIndex(after: chosen.id, in: choices))
        #expect(choices[index].title == "Translate Y")

        var moved = SelectionPath(to: cube.id, in: scene, files: after.files)
        try session.document.apply(session.document.transaction(edits: inverse, label: "Undo"))
        let followedUndo = moved.follow(inverse)
        #expect(followedUndo)
        let restored = try await session.evaluate()
        let restoredScene = try #require(restored.scene)
        let original = try session.instance(("cube", 0), in: restored)
        #expect(moved.resolve(in: restoredScene, files: restored.files) == .exact(original.id))
        await session.close()
    }

    @Test @MainActor func aTypedWrapperKeepsTheSelectionOffItsEqualSibling() async throws {
        let session = try Session("cube(8);\ncube(8);\n")
        let before = try await session.evaluate()
        let picked = try session.instance(("cube", 1), in: before)
        let beforeScene = try #require(before.scene)
        var path = SelectionPath(to: picked.id, in: beforeScene, files: before.files)
        var point = "cube(8);\n".utf8.count
        // Typing arrives as several small insertions.
        for piece in ["rot", "ate(45", ") "] {
            let edit = SourceEdit(range: point..<point, expected: Data(), replacement: Data(piece.utf8))
            try session.document.apply(session.document.transaction(edits: [edit], label: "Typing"))
            let followed = path.follow([edit])
            #expect(followed)
            point += piece.utf8.count
        }
        let after = try await session.evaluate()
        let scene = try #require(after.scene)
        let second = try session.instance(("cube", 1), in: after)
        #expect(path.resolve(in: scene, files: after.files) == .exact(second.id))
        await session.close()
    }

    @Test @MainActor func nestedDifferencesAlternateTheCutters() async throws {
        let session = try Session("difference() { cube(9); difference() { cube(5); cube(2); } }\n")
        let scene = try #require(try await session.evaluate().scene)
        let removed = scene.subtractedInstances
        #expect(scene.instances.filter { $0.name == "cube" }.map { removed.contains($0.id) } == [false, true, false])
        await session.close()
    }
}
