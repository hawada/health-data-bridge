import XCTest
@testable import WHOOPHealthSyncCore

final class NightlyVitalsTests: XCTestCase {
    // Synthetic examples; no personal health records or account identifiers.
    private func record(id: Int = 42, recoveryFields: [String: Any] = ["spo2_percentage": 95.66],
                        sleepFields: [String: Any] = ["respiratory_rate": 13.6], state: String = "complete",
                        nap: Any = false) -> [String: Any] {
        var recovery: [String: Any] = ["user_id": 123, "activity_id": "sleep-\(id)", "state": state]
        recovery.merge(recoveryFields) { $1 }
        var sleep: [String: Any] = ["activity_id": "sleep-\(id)", "is_nap": nap,
                                    "during": "[\"2026-08-14T23:00:00Z\",\"2026-08-15T07:00:00Z\")"]
        sleep.merge(sleepFields) { $1 }
        return ["cycle": ["id": id, "user_id": 123], "recovery": recovery, "sleeps": [sleep]]
    }
    func testReadsBothVitalsAtSleepMidpoint() throws {
        let sleep = TimeRange(start: try XCTUnwrap(WhoopDateCodec.date(from: "2026-08-14T23:00:00Z")),
                              end: try XCTUnwrap(WhoopDateCodec.date(from: "2026-08-15T07:00:00Z")))
        let readings = WhoopNightlyVitalsAdapter.readings(fromCyclesJSON: ["records": [record()]])
        XCTAssertEqual(Set(readings.map(\.syncIdentifier)), ["whoop-spo2:42", "whoop-resp-rate:42"])
        XCTAssertEqual(readings.first { $0.vital == .oxygenSaturation },
                       NightlyVitalReading(vital: .oxygenSaturation, cycleID: "42", value: 95.66, sleep: sleep))
        XCTAssertEqual(readings.first { $0.vital == .respiratoryRate },
                       NightlyVitalReading(vital: .respiratoryRate, cycleID: "42", value: 13.6, sleep: sleep))
        XCTAssertEqual(readings.first?.date, WhoopDateCodec.date(from: "2026-08-15T03:00:00Z"))
    }
    func testAcceptsScoreObjectsAlternateNamesAndFractions() {
        let readings = WhoopNightlyVitalsAdapter.readings(fromCyclesJSON: ["records": [
            record(recoveryFields: ["score": ["spo2": 0.957]], sleepFields: ["score": ["resp_rate": 12.9]])
        ]])
        XCTAssertEqual(readings.first { $0.vital == .oxygenSaturation }?.value ?? 0, 95.7, accuracy: 0.0001)
        XCTAssertEqual(readings.first { $0.vital == .respiratoryRate }?.value, 12.9)
    }
    func testSkipsMissingImplausibleIncompleteAndNaps() {
        let records = [record(id: 1, recoveryFields: [:], sleepFields: [:]),
                       record(id: 2, recoveryFields: ["spo2_percentage": 140], sleepFields: ["respiratory_rate": true]),
                       record(id: 3, state: "pending"), record(id: 4, nap: true)]
        XCTAssertTrue(WhoopNightlyVitalsAdapter.readings(fromCyclesJSON: ["records": records]).isEmpty)
    }
    func testFieldNamesListsNamesOnly() {
        XCTAssertEqual(WhoopNightlyVitalsAdapter.fieldNames(fromCyclesJSON: ["records": [record(sleepFields: ["score": ["x": 1]])]]),
                       ["activity_id", "during", "is_nap", "score", "score.x", "spo2_percentage", "state", "user_id"])
    }
    func testToWriteSkipsOnlyNightsThisAppAlreadyWrote() throws {
        let reading = try XCTUnwrap(WhoopNightlyVitalsAdapter.readings(fromCyclesJSON: ["records": [record()]]).first)
        let end = reading.sleep.end
        XCTAssertEqual(NightlyVitalReading.toWrite([reading], existing: [(end.addingTimeInterval(-0.157), nil),
                                                                         (reading.date, "other-app:1")]), [reading])
        XCTAssertTrue(NightlyVitalReading.toWrite([reading], existing: [(end.addingTimeInterval(86400), reading.syncIdentifier)]).isEmpty)
    }
}
