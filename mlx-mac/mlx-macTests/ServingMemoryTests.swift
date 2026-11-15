import XCTest
@testable import mlx_workbench

final class ServingMemoryTests: XCTestCase {
    func testSharedProcessesAreCountedOnceAndProviderAllocationIsSeparate() {
        let readings: [Int: UInt64] = [10: 100, 20: 200, 30: 300]
        let a = ServingMemory.row(.init(modelPID: 10, gatewayPID: 20, hostPID: 30, reportedBytes: 999), readings: readings)
        let b = ServingMemory.row(.init(modelPID: 10, hostPID: 30, reportedBytes: 777), readings: readings)
        let summary = ServingMemory.summary([a, b])
        XCTAssertEqual(summary.measuredBytes, 600)
        XCTAssertEqual(summary.measuredProcesses, 3)
        XCTAssertEqual(summary.identifiedProcesses, 3)
        XCTAssertEqual(a.reportedBytes, 999)
        XCTAssertEqual(b.reportedBytes, 777)
    }

    func testMissingZeroStaleAndInvalidOwnership() {
        let measuredZero = ServingMemory.row(.init(gatewayPID: 4), readings: [4: 0])
        let missing = ServingMemory.row(.init(modelPID: 5), readings: [:])
        let invalid = ServingMemory.row(.init(modelPID: -1, hostPID: 0, reportedBytes: -1), readings: [0: 20])
        let stale = ServingMemory.row(.init(modelPID: 7, reportedBytes: 10, stale: true), readings: [7: 20])
        let summary = ServingMemory.summary([measuredZero, missing, invalid, stale])
        XCTAssertEqual(summary.measuredBytes, 0)
        XCTAssertEqual(summary.measuredProcesses, 1)
        XCTAssertEqual(summary.identifiedProcesses, 2)
        XCTAssertEqual(summary.unknownOwners, 2)
        XCTAssertNil(invalid.reportedBytes)
        XCTAssertNil(stale.reportedBytes)
        XCTAssertNil(ServingMemory.summary([missing]).measuredBytes)
    }

    func testKnownGatewayDoesNotHideUnknownModelOwnership() {
        let row = ServingMemory.row(.init(gatewayPID: 4, unknownOwnership: true), readings: [4: 10])
        XCTAssertEqual(ServingMemory.summary([row]).unknownOwners, 1)
        XCTAssertEqual(ServingMemory.summary([row]).measuredBytes, 10)
        let invalidModel = ServingMemory.row(.init(modelPID: -7, gatewayPID: 4), readings: [4: 10])
        XCTAssertEqual(ServingMemory.summary([invalidModel]).unknownOwners, 1)
        XCTAssertNil(invalidModel.modelPID)
    }

    func testOverflowDoesNotProduceAFalseTotal() {
        let row = ServingMemory.row(.init(modelPID: 1, gatewayPID: 2), readings: [1: .max, 2: 1])
        let summary = ServingMemory.summary([row])
        XCTAssertTrue(summary.overflow)
        XCTAssertNil(summary.measuredBytes)
    }
}
