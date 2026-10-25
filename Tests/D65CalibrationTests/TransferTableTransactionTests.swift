import D65Core
import D65Display
import XCTest

@MainActor final class TransferTableTransactionTests: XCTestCase {
    func testCumulativeApplicationIsIdempotentAndRestoresExactNonlinearBaseline() async throws {
        let backend = MemoryTables()
        let baseline = backend.snapshot
        let transaction = TransferTableTransaction(backend: backend)
        try transaction.begin()
        let gains = CorrectionRequest(gains: .init(r: 0.8, g: 0.9, b: 1), alpha: 0.5).resolved()
        try transaction.setCumulativeGains(gains, gamma: 2.2)
        let first = backend.snapshot
        try transaction.setCumulativeGains(gains, gamma: 2.2)
        XCTAssertEqual(backend.snapshot.red, first.red)
        XCTAssertEqual(backend.snapshot.red.last!, baseline.red.last! * pow(0.9, 1 / 2.2), accuracy: 1e-12)
        try transaction.restore()
        XCTAssertEqual(backend.snapshot.red, baseline.red)
        XCTAssertEqual(backend.snapshot.green, baseline.green)
        XCTAssertEqual(backend.snapshot.blue, baseline.blue)
    }
    func testReadOnlyTransactionDoesNotWriteTables() async throws {
        let backend = MemoryTables()
        let transaction = TransferTableTransaction(backend: backend)
        try transaction.begin(); try transaction.restore()
        XCTAssertEqual(backend.writes, 0)
    }
    func testFailedApplyStillRestoresAndFailedRestoreCanBeRetried() async throws {
        let backend = MemoryTables()
        let baseline = backend.snapshot
        let transaction = TransferTableTransaction(backend: backend)
        try transaction.begin()
        backend.failWrite = true
        XCTAssertThrowsError(try transaction.setCumulativeGains(.init(r: 0.7, g: 1, b: 1), gamma: 2.2))
        XCTAssertThrowsError(try transaction.restore())
        backend.failWrite = false
        try transaction.restore()
        XCTAssertEqual(backend.snapshot.red, baseline.red)
    }
}
private final class MemoryTables: TransferTableBackend, @unchecked Sendable {
    var snapshot = DisplayTransferSnapshot(displayID: 7, red: [0, 0.1, 0.75], green: [0, 0.2, 0.85], blue: [0, 0.3, 0.95])
    var writes = 0
    var failWrite = false
    func probe() throws -> DisplayTransferSnapshot { snapshot }
    func restore(_ snapshot: DisplayTransferSnapshot) throws {
        writes += 1
        self.snapshot = snapshot
        if failWrite { throw TransferTransactionError.notStarted }
    }
}
