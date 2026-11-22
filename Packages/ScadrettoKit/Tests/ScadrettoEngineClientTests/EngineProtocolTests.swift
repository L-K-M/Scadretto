import CryptoKit
import Foundation
import ScadrettoCore
import Testing
@testable import ScadrettoEngineClient

private let workerSHA = String(repeating: "ab", count: 32)
private let fixedRequestID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!

private func contextDigest(_ fields: [String]) -> String {
    var bytes: [UInt8] = []
    for field in fields {
        let utf8 = Array(field.utf8)
        bytes.append(contentsOf: Array("\(utf8.count):".utf8))
        bytes.append(contentsOf: utf8)
    }
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@MainActor private func makeRequest(source: String = "cube(2);\n") throws -> EngineRequest {
    let document = SourceDocument(buffer: try SourceBuffer(bytes: Data(source.utf8)))
    return try EngineRequest.make(
        snapshot: document.snapshot,
        logicalPath: "/doc/main.scad",
        libraryRoots: ["/lib/a", "/lib/b"],
        resourceRoots: ["/res"],
        dependencyGeneration: 3,
        workerBuild: workerSHA,
        requestID: fixedRequestID
    )
}

private func makeJobDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "scadretto-engine-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private func appendDoubleLE(_ data: inout Data, _ value: Double) {
    appendLE(&data, value.bitPattern)
}

/// Builds a SCADMESH v1 payload and its manifest descriptor for `path`.
private func makePayload(
    path: String,
    vertices: [SIMD3<Double>],
    indices: [UInt32],
    owners: [UInt32]?,
    bounds: ([Double], [Double])? = nil
) -> (Data, [String: Any]) {
    let vertexOffset = 16
    let indexOffset = vertexOffset + vertices.count * 24
    let ownerOffset = owners == nil ? nil : indexOffset + indices.count * 4

    var data = Data("SCADMESH".utf8)
    appendLE(&data, UInt32(1))
    appendLE(&data, UInt32(0))
    for vertex in vertices {
        appendDoubleLE(&data, vertex.x)
        appendDoubleLE(&data, vertex.y)
        appendDoubleLE(&data, vertex.z)
    }
    for index in indices { appendLE(&data, index) }
    for owner in owners ?? [] { appendLE(&data, owner) }

    let minBound = bounds?.0 ?? [0, 0, 0]
    let maxBound = bounds?.1 ?? [1, 1, 0]
    var descriptor: [String: Any] = [
        "path": path,
        "vertexOffset": vertexOffset,
        "vertexCount": vertices.count,
        "vertexStride": 24,
        "positionType": "float64",
        "indexOffset": indexOffset,
        "indexCount": indices.count,
        "indexStride": 4,
        "indexType": "uint32",
        "winding": "ccw",
        "bounds": ["min": minBound, "max": maxBound],
    ]
    if let ownerOffset { descriptor["ownerOffset"] = ownerOffset }
    return (data, descriptor)
}

private let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

/// A manifest for the happy path: exit 0, one triangle, one operand shared by
/// one child cube under a difference root.
private func validManifest(request: EngineRequest) throws -> [String: Any] {
    let keyData = try JSONEncoder().encode(request.key)
    let key = try JSONSerialization.jsonObject(with: keyData)
    return [
        "protocolVersion": 1,
        "requestID": request.requestID.uuidString,
        "key": key,
        "buildSHA": workerSHA,
        "status": "ok",
        "detail": "rendered",
        "files": [[
            "id": 0,
            "logicalPath": "/doc/main.scad",
            "resolvedPath": "/doc/main.scad",
            "sha256": request.sourceSHA256,
            "byteLength": 9,
            "kind": "main",
            "writable": true,
        ]],
        "diagnostics": [[
            "severity": "warning",
            "message": "polyhedron deprecated",
            "fileID": 0,
            "span": ["fileID": 0, "start": 0, "end": 4],
            "repeatCount": 2,
        ]],
        "console": [["group": "echo", "text": "hello", "fileID": 0]],
        "droppedConsoleMessages": 0,
        "instances": [
            [
                "id": 0,
                "name": "difference",
                "span": ["fileID": 0, "start": 0, "end": 8],
                "iteration": [String: Double](),
                "local": identity,
                "world": identity,
            ],
            [
                "id": 1,
                "parent": 0,
                "name": "cube",
                "span": ["fileID": 0, "start": 0, "end": 4],
                "iteration": ["i": 0],
                "local": identity,
                "world": identity,
            ],
        ],
        "operations": [[
            "instanceID": 0,
            "children": [["instanceID": 1, "role": "positive"]],
        ]],
        "dependencyEdges": [[
            "span": ["fileID": 0, "start": 0, "end": 7],
            "instanceID": 1,
            "property": "size",
        ]],
        "lookups": [[
            "requestingFileID": 0,
            "name": "part.scad",
            "candidates": ["/lib/a/part.scad", "/lib/b/part.scad"],
            "winner": "/lib/b/part.scad",
        ]],
    ]
}

private func writeManifest(_ manifest: [String: Any], to job: URL) throws {
    try JSONSerialization.data(withJSONObject: manifest)
        .write(to: job.appending(path: "result.json"))
}

@Test @MainActor func requestDigestsFollowTheContextFormat() throws {
    let request = try makeRequest()
    #expect(request.protocolVersion == 1)
    #expect(request.snapshot == "main.scad")
    #expect(request.preview == false)
    #expect(request.backend == "manifold")
    #expect(request.expectedWorkerBuild == workerSHA)
    #expect(request.sourceSHA256 == sha256Hex(Data("cube(2);\n".utf8)))
    #expect(request.key.sourceRevision == 0)
    #expect(request.key.dependencyGeneration == 3)
    #expect(request.key.workerBuild == workerSHA)
    #expect(request.key.resolutionDigest == contextDigest([
        "resolution-v1", "/doc/main.scad", "", "2", "/lib/a", "/lib/b", "1", "/res",
    ]))
    #expect(request.key.optionsDigest == contextDigest(["options-v1", "manifold", "false"]))

    let untitled = try EngineRequest.make(
        snapshot: SourceDocument(buffer: try SourceBuffer(bytes: Data("x".utf8))).snapshot,
        logicalPath: "/doc/main.scad",
        untitledBaseDirectory: "/tmp/untitled",
        dependencyGeneration: 0,
        workerBuild: workerSHA
    )
    #expect(untitled.key.resolutionDigest == contextDigest([
        "resolution-v1", "/doc/main.scad", "/tmp/untitled", "0", "0",
    ]))
}

@Test @MainActor func requestRejectsNonAbsoluteInputs() throws {
    let document = SourceDocument(buffer: try SourceBuffer(bytes: Data("x".utf8)))
    let snapshot = document.snapshot
    #expect(throws: EngineError.self) {
        try EngineRequest.make(
            snapshot: snapshot, logicalPath: "relative/main.scad",
            dependencyGeneration: 0, workerBuild: workerSHA
        )
    }
    #expect(throws: EngineError.self) {
        try EngineRequest.make(
            snapshot: snapshot, logicalPath: "/doc/main.scad",
            libraryRoots: ["relative"], dependencyGeneration: 0, workerBuild: workerSHA
        )
    }
    #expect(throws: EngineError.self) {
        try EngineRequest.make(
            snapshot: snapshot, logicalPath: "/doc/main.scad",
            dependencyGeneration: 0, workerBuild: "not-hex"
        )
    }
}

@Test @MainActor func decodesRenderedScene() throws {
    let request = try makeRequest()
    let job = try makeJobDirectory()
    defer { try? FileManager.default.removeItem(at: job) }

    let (meshData, meshDescriptor) = makePayload(
        path: "mesh.bin",
        vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
        indices: [0, 1, 2],
        owners: [1]
    )
    let (operandData, operandDescriptor) = makePayload(
        path: "operands.bin",
        vertices: [SIMD3(5, 5, 5), SIMD3(6, 5, 5), SIMD3(5, 6, 5)],
        indices: [0, 1, 2],
        owners: nil,
        bounds: ([5, 5, 5], [6, 6, 5])
    )
    try meshData.write(to: job.appending(path: "mesh.bin"))
    try operandData.write(to: job.appending(path: "operands.bin"))

    var manifest = try validManifest(request: request)
    manifest["mesh"] = meshDescriptor
    manifest["operands"] = [["id": 0, "mesh": operandDescriptor]]
    var instances = try #require(manifest["instances"] as? [[String: Any]])
    instances[1]["operand"] = 0
    manifest["instances"] = instances
    try writeManifest(manifest, to: job)

    let outcome = try ResultDecoder().decode(
        jobDirectory: job, request: request, termination: .exited(0)
    )
    guard case .rendered(let result) = outcome else {
        Issue.record("expected rendered, got \(outcome)")
        return
    }
    #expect(result.requestID == fixedRequestID)
    #expect(result.key == request.key)
    #expect(result.workerBuild == workerSHA)
    #expect(result.files.count == 1)
    #expect(result.files[0].kind == .main)
    #expect(result.diagnostics == [
        EngineDiagnostic(
            severity: .warning, message: "polyhedron deprecated", fileID: 0,
            span: WireSpan(fileID: 0, start: 0, end: 4), callPath: [], repeatCount: 2
        )
    ])
    #expect(result.lookups[0].winner == "/lib/b/part.scad")

    let scene = try #require(result.scene)
    let mesh = try #require(scene.mesh)
    #expect(mesh.positions == [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
    #expect(mesh.indices == [0, 1, 2])
    #expect(mesh.triangleOwners == [1])
    #expect(mesh.bounds.min == SIMD3(0, 0, 0))
    #expect(mesh.bounds.max == SIMD3(1, 1, 0))
    #expect(scene.instances.map(\.id) == [0, 1])
    #expect(scene.instances[1].operand == 0)
    #expect(scene.operandMesh(for: 0)?.positions[0] == SIMD3(5, 5, 5))
    #expect(scene.operations[0].children == [OperationRecord.Child(instanceID: 1, role: .positive)])
}

@Test @MainActor func decodesEmptyAndModelErrorOutcomes() throws {
    let request = try makeRequest()
    let job = try makeJobDirectory()
    defer { try? FileManager.default.removeItem(at: job) }

    var empty = try validManifest(request: request)
    empty["detail"] = "empty"
    try writeManifest(empty, to: job)
    let emptyOutcome = try ResultDecoder().decode(
        jobDirectory: job, request: request, termination: .exited(0)
    )
    guard case .empty(let emptyResult) = emptyOutcome else {
        Issue.record("expected empty, got \(emptyOutcome)")
        return
    }
    #expect(emptyResult.scene?.mesh == nil)
    #expect(emptyResult.scene?.instances.count == 2)

    var failure = try validManifest(request: request)
    failure["status"] = "error"
    failure["detail"] = "modelError"
    failure["diagnostics"] = [[
        "severity": "error",
        "message": "undefined variable 'nope'",
        "fileID": 0,
        "span": ["fileID": 0, "start": 5, "end": 9],
        "repeatCount": 0,
    ]]
    failure["instances"] = [Any]()
    failure["operations"] = [Any]()
    failure["dependencyEdges"] = [Any]()
    try writeManifest(failure, to: job)
    let failureOutcome = try ResultDecoder().decode(
        jobDirectory: job, request: request, termination: .exited(1)
    )
    guard case .modelError(let failureResult) = failureOutcome else {
        Issue.record("expected modelError, got \(failureOutcome)")
        return
    }
    #expect(failureResult.scene == nil)
    #expect(failureResult.diagnostics[0].severity == .error)
}

@Test @MainActor func binaryCubeRetainsUnitWidthFarFromOrigin() throws {
    let request = try makeRequest()
    let job = try makeJobDirectory()
    defer { try? FileManager.default.removeItem(at: job) }
    let x = 100_000_000.0
    let positions: [SIMD3<Double>] = [
        SIMD3(x, 0, 0), SIMD3(x + 1, 0, 0), SIMD3(x + 1, 1, 0), SIMD3(x, 1, 0),
        SIMD3(x, 0, 1), SIMD3(x + 1, 0, 1), SIMD3(x + 1, 1, 1), SIMD3(x, 1, 1),
    ]
    let indices: [UInt32] = [
        0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4,
        1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7,
    ]
    let (payload, mesh) = makePayload(path: "mesh.bin", vertices: positions, indices: indices,
                                      owners: nil, bounds: ([x, 0, 0], [x + 1, 1, 1]))
    try payload.write(to: job.appending(path: "mesh.bin"))
    var manifest = try validManifest(request: request)
    manifest["mesh"] = mesh
    try writeManifest(manifest, to: job)
    let result = try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    let decoded = try #require(result.scene?.mesh)
    #expect(decoded.bounds.min.x == x)
    #expect(decoded.bounds.max.x == x + 1)
    #expect(decoded.positions == positions)
}

@Test @MainActor func rejectsIdentityAndStatusContradictions() throws {
    let request = try makeRequest()
    let job = try makeJobDirectory()
    defer { try? FileManager.default.removeItem(at: job) }

    let manifest = try validManifest(request: request)
    try writeManifest(manifest, to: job)

    #expect(throws: EngineError.workerSignaled(9)) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .uncaughtSignal(9))
    }
    #expect(throws: EngineError.workerExit(2)) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(2))
    }

    var contradictory = manifest
    contradictory["status"] = "error"
    contradictory["detail"] = "rendered"
    try writeManifest(contradictory, to: job)
    #expect(throws: EngineError.statusContradiction("exit 0 with status error detail rendered")) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    }
    try writeManifest(manifest, to: job)

    var wrongID = manifest
    wrongID["requestID"] = UUID().uuidString
    try writeManifest(wrongID, to: job)
    #expect(throws: EngineError.identityMismatch(field: "requestID")) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    }

    var wrongBuild = manifest
    wrongBuild["buildSHA"] = String(repeating: "cd", count: 32)
    try writeManifest(wrongBuild, to: job)
    #expect(throws: EngineError.buildMismatch) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    }

    var wrongVersion = manifest
    wrongVersion["protocolVersion"] = 2
    try writeManifest(wrongVersion, to: job)
    #expect(throws: EngineError.protocolMismatch) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    }
}

@Test @MainActor func rejectsUnsafePayloadPathsAndFiles() throws {
    let request = try makeRequest()
    let job = try makeJobDirectory()
    defer { try? FileManager.default.removeItem(at: job) }

    var manifest = try validManifest(request: request)
    manifest["mesh"] = [
        "path": "../mesh.bin",
        "vertexOffset": 16, "vertexCount": 0, "vertexStride": 24,
        "positionType": "float64",
        "indexOffset": 16, "indexCount": 0, "indexStride": 4,
        "indexType": "uint32", "winding": "ccw",
        "bounds": ["min": [0, 0, 0], "max": [0, 0, 0]],
    ]
    try writeManifest(manifest, to: job)
    #expect(throws: EngineError.pathRejected("../mesh.bin")) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    }

    var absolute = manifest
    if var mesh = absolute["mesh"] as? [String: Any] {
        mesh["path"] = "/etc/passwd"
        absolute["mesh"] = mesh
    }
    try writeManifest(absolute, to: job)
    #expect(throws: EngineError.pathRejected("/etc/passwd")) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    }

    // A symlinked payload is refused by O_NOFOLLOW.
    let (meshData, meshDescriptor) = makePayload(
        path: "mesh.bin", vertices: [], indices: [], owners: nil,
        bounds: ([0, 0, 0], [0, 0, 0])
    )
    var linked = try validManifest(request: request)
    linked["mesh"] = meshDescriptor
    try writeManifest(linked, to: job)
    try FileManager.default.createSymbolicLink(
        at: job.appending(path: "mesh.bin"),
        withDestinationURL: URL(fileURLWithPath: "/dev/null")
    )
    #expect {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    } throws: { error in
        guard case EngineError.fileUnreadable(let name, _) = error else { return false }
        return name == "mesh.bin"
    }
    try FileManager.default.removeItem(at: job.appending(path: "mesh.bin"))
    try meshData.write(to: job.appending(path: "mesh.bin"))

    // A rendered result whose payload is a directory is not a regular file.
    try FileManager.default.removeItem(at: job.appending(path: "mesh.bin"))
    try FileManager.default.createDirectory(
        at: job.appending(path: "mesh.bin"), withIntermediateDirectories: false
    )
    #expect(throws: EngineError.fileNotRegular(name: "mesh.bin")) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    }
}

@Test @MainActor func rejectsMalformedPayloadsAndRelationships() throws {
    let request = try makeRequest()
    let job = try makeJobDirectory()
    defer { try? FileManager.default.removeItem(at: job) }

    // Bad magic.
    var manifest = try validManifest(request: request)
    let (completeHeader, meshDescriptor) = makePayload(
        path: "mesh.bin", vertices: [], indices: [], owners: nil,
        bounds: ([0, 0, 0], [0, 0, 0])
    )
    manifest["mesh"] = meshDescriptor
    let badMagic = Data("NOTMESH!".utf8) + completeHeader.dropFirst(8)
    try badMagic.write(to: job.appending(path: "mesh.bin"))
    try writeManifest(manifest, to: job)
    #expect(throws: EngineError.payloadMalformed(name: "mesh.bin", detail: "bad magic or version")) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    }

    // Index outside the vertex range.
    let (badIndex, badIndexDescriptor) = makePayload(
        path: "mesh.bin",
        vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
        indices: [0, 1, 3], owners: nil
    )
    var outOfRange = try validManifest(request: request)
    outOfRange["mesh"] = badIndexDescriptor
    try badIndex.write(to: job.appending(path: "mesh.bin"))
    try writeManifest(outOfRange, to: job)
    #expect(throws: EngineError.validationFailed("mesh.bin index 2 is out of range")) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    }

    // A parent that appears after its child breaks the executed order.
    var cycle = try validManifest(request: request)
    cycle["detail"] = "empty"
    cycle["instances"] = [
        [
            "id": 0, "parent": 1, "name": "cube", "iteration": [String: Double](),
            "local": identity, "world": identity,
        ],
        [
            "id": 1, "name": "difference", "iteration": [String: Double](),
            "local": identity, "world": identity,
        ],
    ]
    cycle["operations"] = [["instanceID": 1, "children": [["instanceID": 0, "role": "positive"]]]]
    cycle["dependencyEdges"] = [Any]()
    try writeManifest(cycle, to: job)
    #expect(throws: EngineError.validationFailed("instance 0 parent 1 is missing or follows it")) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    }

    // A span outside the file's byte length.
    var badSpan = try validManifest(request: request)
    badSpan["diagnostics"] = [[
        "severity": "error", "message": "x", "fileID": 0,
        "span": ["fileID": 0, "start": 0, "end": 100], "repeatCount": 0,
    ]]
    badSpan.removeValue(forKey: "mesh")
    try writeManifest(badSpan, to: job)
    #expect(throws: EngineError.self) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    }

    // Non-finite vertex position.
    let nanVertex = SIMD3(Double.nan, 0, 0)
    let (nanData, nanDescriptor) = makePayload(
        path: "mesh.bin", vertices: [nanVertex, SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
        indices: [0, 1, 2], owners: nil,
        bounds: ([0, 0, 0], [1, 1, 0])
    )
    var nonFinite = try validManifest(request: request)
    nonFinite["mesh"] = nanDescriptor
    try nanData.write(to: job.appending(path: "mesh.bin"))
    try writeManifest(nonFinite, to: job)
    #expect(throws: EngineError.self) {
        try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0))
    }
}

@Test @MainActor func enforcesByteCaps() throws {
    let request = try makeRequest()
    let job = try makeJobDirectory()
    defer { try? FileManager.default.removeItem(at: job) }

    var limits = ResultDecoder.Limits()
    limits.manifestByteLimit = 64
    try writeManifest(try validManifest(request: request), to: job)
    #expect(throws: EngineError.fileOversized(name: "result.json")) {
        try ResultDecoder(limits: limits).decode(
            jobDirectory: job, request: request, termination: .exited(0)
        )
    }

    let missing = job.appending(path: "missing")
    #expect(throws: EngineError.self) {
        try ResultDecoder().decode(jobDirectory: missing, request: request, termination: .exited(0))
    }
}

@Test func followsLookupIntoNewDirectory() throws {
    let key = EvaluationKey(documentID: UUID(), sourceRevision: 1, dependencyGeneration: 0,
                            resolutionDigest: workerSHA, optionsDigest: workerSHA, workerBuild: workerSHA)
    let root = try makeJobDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let newLibrary = root.appending(path: "new-library", directoryHint: .isDirectory)
    let preferred = newLibrary.appending(path: "part.scad")
    let fallback = root.appending(path: "fallback.scad")
    try Data("cube(2);".utf8).write(to: fallback)
    let result = EvaluationResult(
        requestID: fixedRequestID, key: key, workerBuild: workerSHA,
        files: [], diagnostics: [], console: [], droppedConsoleMessages: 0,
        dependencyEdges: [], lookups: [LookupRecord(
            requestingFileID: nil, name: "part.scad", candidates: [preferred.path, fallback.path],
            winner: fallback.path
        )], scene: nil
    )
    let changes = DispatchSemaphore(value: 0)
    let watch = DependencyWatch(result: result) { changes.signal() }
    try #require(watch.isCurrent())

    try FileManager.default.createDirectory(at: newLibrary, withIntermediateDirectories: false)
    try #require(changes.wait(timeout: .now() + .seconds(2)) == .success)
    try #require(watch.isCurrent())
    while changes.wait(timeout: .now()) == .success {}

    try Data("sphere(2);".utf8).write(to: preferred)
    try #require(changes.wait(timeout: .now() + .seconds(2)) == .success)
    #expect(!watch.isCurrent())
}
