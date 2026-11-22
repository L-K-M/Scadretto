import Foundation
import ScadrettoCore
import Testing
import ScadrettoEngineClient

@Test(arguments: ["cube", "invalid", "plate"])
func checkedInEngineJobsDecode(name: String) throws {
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let directory = repository.appending(path: "Engine/protocol/golden/\(name)")
    let request = try JSONDecoder().decode(EngineRequest.self,
                                           from: Data(contentsOf: directory.appending(path: "request.json")))
    let source = name == "plate" ? repository.appending(path: "Tests/Fixtures/mounting-plate.scad")
        : directory.appending(path: "main.scad")
    let raw = try SourceBuffer(bytes: Data(contentsOf: source))
    let outcome = try ResultDecoder().decode(jobDirectory: directory, request: request,
                                             termination: .exited(name == "invalid" ? 1 : 0),
                                             sourceByteLength: UInt64(raw.bytes.count))
    #expect(outcome.result.requestID == request.requestID)
    #expect(outcome.result.files.first?.sha256 == raw.sha256)

    switch name {
    case "cube":
        let scene = try #require(outcome.scene)
        #expect(scene.mesh?.bounds.max == SIMD3(2, 2, 2))
        #expect(scene.mesh?.indices.count == 36)
        #expect(scene.instances.contains { $0.name == "cube" })
    case "invalid":
        #expect(outcome.scene == nil)
        #expect(outcome.result.diagnostics.contains { $0.severity == .error })
    case "plate":
        let scene = try #require(outcome.scene)
        let cutters = scene.instances.filter { $0.name == "cylinder" }
        #expect(cutters.compactMap { $0.iteration["i"] } == [0, 1, 2, 3])
        #expect(Set(cutters.compactMap(\.operand)).count == 1)
        let third = try #require(cutters.first { $0.iteration["i"] == 2 })
        #expect(third.diameter?.chain.last?.span == WireSpan(fileID: 0, start: 74, end: 75))
        #expect(scene.operations.flatMap(\.children).contains { $0.role == .subtracted })
    default:
        Issue.record("Unexpected golden: \(name)")
    }
}
