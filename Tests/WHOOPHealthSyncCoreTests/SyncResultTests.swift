import XCTest
@testable import WHOOPHealthSyncCore

final class SyncResultTests: XCTestCase {
    func testEmptyWindowDoesNotReplaceConfirmedWritesOrAccessPending() {
        var accumulated = SyncSummary()
        accumulated.sleepResult = .updated; accumulated.stagesWritten = 3
        accumulated.heartRateResult = .pendingAccess
        var empty = SyncSummary(); empty.sleepResult = .noData; empty.heartRateResult = .noData
        accumulated.merge(empty)
        XCTAssertEqual(accumulated.sleepResult, .updated)
        XCTAssertEqual(accumulated.heartRateResult, .pendingAccess)
        XCTAssertEqual(accumulated.stagesWritten, 3)
    }

    func testLaterFailureMakesHistoryPartialWithoutErasingConfirmedSamples() {
        var summary = SyncSummary(); summary.sleepResult = .updated; summary.stagesWritten = 2
        var failure = SyncSummary(); failure.sleepResult = .failed; failure.errors = ["synthetic error"]
        summary.merge(failure)
        XCTAssertEqual(summary.sleepResult, .failed); XCTAssertEqual(summary.stagesWritten, 2)
        XCTAssertEqual(summary.errors.count, 1)
    }

    func testNoDataExistingAndUnverifiedAreDifferentResults() {
        XCTAssertNotEqual(SyncDataResult.noData, .existing)
        XCTAssertNotEqual(SyncDataResult.noData, .pendingAccess)
        XCTAssertNotEqual(SyncDataResult.notAttempted, .updated)
    }
}
