import Foundation
import ScadrettoCore
import ScadrettoEngineClient
import ScadrettoTestSupport
import Testing

private func property(_ semantic: PropertyRecord.Semantic, on instance: UInt32,
                      in result: EvaluationResult) throws -> PropertyRecord {
    let record = try #require(result.scene?.instances.first { $0.id == instance })
    return try #require(record.properties?.first { $0.semantic == semantic })
}

@Test @MainActor func platePitchTargetsItsLiteralAndEveryLoopPlacement() async throws {
    let plate = try await PlateGolden.load()
    let pitch = try property(.pitch, on: 11, in: plate.result)
    let target = try plate.result.target(for: pitch, on: 11, in: plate.snapshot)

    #expect(target.span.bytes == 96..<98)
    #expect(target.authoredValue == 20)
    #expect(target.scope == .parameter("pitch"))
    #expect(target.affectedInstances == [5, 8, 11, 14])
    #expect(target.impactComplete)
}

@Test @MainActor func plateDiameterTargetsTheRootParameterThroughTheModule() async throws {
    let plate = try await PlateGolden.load()
    let diameter = try property(.cylinderDiameter, on: 13, in: plate.result)
    let target = try plate.result.target(for: diameter, on: 13, in: plate.snapshot)

    #expect(target.span.bytes == 74..<75)
    #expect(target.scope == .parameter("hole_d"))
    #expect(target.affectedInstances == [6, 7, 9, 10, 12, 13, 15, 16])
    #expect(target.impactComplete)
}

@Test @MainActor func plateThicknessAlsoReportsCuttersThatUseItInArithmetic() async throws {
    let plate = try await PlateGolden.load()
    let height = try property(.cubeSizeZ, on: 3, in: plate.result)
    let target = try plate.result.target(for: height, on: 3, in: plate.snapshot)

    #expect(target.span.bytes == 119..<120)
    #expect(target.scope == .parameter("plate_h"))
    #expect(target.affectedInstances == [3, 7, 10, 13, 16])
}

@Test @MainActor func plateExpressionsAndForeignRecordsHaveNoTarget() async throws {
    let plate = try await PlateGolden.load()
    let offset = try property(.translateX, on: 11, in: plate.result)
    let height = try property(.cylinderHeight, on: 13, in: plate.result)
    let otherPitch = try property(.pitch, on: 8, in: plate.result)

    #expect(throws: PropertyBindingError.expression) {
        try plate.result.target(for: offset, on: 11, in: plate.snapshot)
    }
    #expect(throws: PropertyBindingError.expression) {
        try plate.result.target(for: height, on: 13, in: plate.snapshot)
    }
    #expect(throws: PropertyBindingError.unobserved) {
        try plate.result.target(for: otherPitch, on: 11, in: plate.snapshot)
    }
}
