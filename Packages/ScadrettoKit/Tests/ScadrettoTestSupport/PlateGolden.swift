import Foundation
import ScadrettoCore
import ScadrettoEngineClient

/// The checked-in plate result, keyed to a document with the fixture's bytes.
public struct PlateGolden {
    public let document: SourceDocument
    public let snapshot: SourceSnapshot
    public let result: EvaluationResult

    @MainActor
    public static func load() async throws -> PlateGolden {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let job = repository.appending(path: "Engine/protocol/golden/plate")
        let source = repository.appending(path: "Tests/Fixtures/mounting-plate.scad")

        let request = try JSONDecoder().decode(EngineRequest.self,
                                               from: Data(contentsOf: job.appending(path: "request.json")))
        let document = SourceDocument(buffer: try SourceBuffer(bytes: Data(contentsOf: source)))
        let snapshot = document.snapshot
        let decoded = try ResultDecoder().decode(jobDirectory: job, request: request, termination: .exited(0),
                                                 sourceByteLength: UInt64(snapshot.buffer.bytes.count)).result

        // Only the snapshot identity is rebound. The payload stays the golden's.
        let result = EvaluationResult(
            requestID: decoded.requestID,
            key: EvaluationKey(
                documentID: snapshot.documentID,
                sourceRevision: snapshot.revision,
                dependencyGeneration: decoded.key.dependencyGeneration,
                resolutionDigest: decoded.key.resolutionDigest,
                optionsDigest: decoded.key.optionsDigest,
                workerBuild: decoded.key.workerBuild
            ),
            workerBuild: decoded.workerBuild,
            files: decoded.files,
            diagnostics: decoded.diagnostics,
            console: decoded.console,
            droppedConsoleMessages: decoded.droppedConsoleMessages,
            dependencyEdges: decoded.dependencyEdges,
            lookups: decoded.lookups,
            scene: decoded.scene
        )
        return PlateGolden(document: document, snapshot: snapshot, result: result)
    }
}
