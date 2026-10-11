import XCTest
@testable import WHOOPHealthSyncCore

final class SkinTemperatureTests: XCTestCase {
    // Synthetic examples; no personal health records or account identifiers.
    private func record(id: Int = 42, temp: Any? = 33.57, key: String = "skin_temp_celsius", state: String = "complete",
                        nap: Any = false) -> [String: Any] {
        var recovery: [String: Any] = ["user_id": 123, "activity_id": "sleep-\(id)", "state": state]
        if let temp { recovery[key] = temp }
        return ["cycle": ["id": id, "user_id": 123], "recovery": recovery,
                "sleeps": [["activity_id": "sleep-\(id)", "is_nap": nap,
                            "during": "[\"2026-08-14T23:00:00Z\",\"2026-08-15T07:00:00Z\")"]]]
    }
    func testReadsCelsiusAtSleepEnd() throws {
        let readings = WhoopSkinTemperatureAdapter.readings(fromCyclesJSON: ["records": [record()]])
        XCTAssertEqual(readings, [SkinTemperatureReading(cycleID: "42", celsius: 33.57,
                                                         date: try XCTUnwrap(WhoopDateCodec.date(from: "2026-08-15T07:00:00Z")))])
        XCTAssertEqual(readings.first?.syncIdentifier, "whoop-skin-temp:42")
    }
    func testAcceptsAlternateFieldName() {
        XCTAssertEqual(WhoopSkinTemperatureAdapter.readings(fromCyclesJSON: ["records": [record(key: "skin_temp")]]).count, 1)
    }
    func testSkipsMissingImplausibleIncompleteAndNaps() {
        let records = [record(id: 1, temp: nil), record(id: 2, temp: 92.4), record(id: 3, temp: true),
                       record(id: 4, state: "pending"), record(id: 5, nap: true)]
        XCTAssertTrue(WhoopSkinTemperatureAdapter.readings(fromCyclesJSON: ["records": records]).isEmpty)
    }
    func testRecoveryKeysListsNamesOnly() {
        XCTAssertEqual(WhoopSkinTemperatureAdapter.recoveryKeys(fromCyclesJSON: ["records": [record()]]),
                       ["activity_id", "skin_temp_celsius", "state", "user_id"])
    }
}
