import Foundation
import CoreFoundation

/// One nightly WHOOP skin temperature, stamped at the end of the sleep it was measured in.
public struct SkinTemperatureReading: Equatable, Sendable {
    public var cycleID: String
    public var celsius: Double
    public var date: Date
    public init(cycleID: String, celsius: Double, date: Date) {
        self.cycleID = cycleID; self.celsius = celsius; self.date = date
    }
    public var syncIdentifier: String { "whoop-skin-temp:\(cycleID)" }
}

/// Reads skin temperature from the private cycles/details payload already used for sleep and recovery.
/// The private field name is not documented, so a few likely names are accepted; values outside a
/// plausible skin range are dropped rather than written.
public enum WhoopSkinTemperatureAdapter {
    public static let candidateKeys = ["skin_temp_celsius", "skin_temp", "skin_temperature_celsius", "skin_temperature"]
    public static let plausibleCelsius: ClosedRange<Double> = 25...42

    public static func readings(fromCyclesJSON json: Any) -> [SkinTemperatureReading] {
        var byCycle: [String: SkinTemperatureReading] = [:]
        for record in records(json) {
            guard let cycle = record["cycle"] as? [String: Any], let cycleID = integerID(cycle["id"]),
                  let recovery = record["recovery"] as? [String: Any],
                  recovery["state"] as? String == "complete",
                  let celsius = candidateKeys.lazy.compactMap({ number(recovery[$0]) }).first,
                  plausibleCelsius.contains(celsius),
                  let date = sleepEnd(record: record, recovery: recovery) else { continue }
            byCycle[cycleID] = SkinTemperatureReading(cycleID: cycleID, celsius: celsius, date: date)
        }
        return byCycle.values.sorted { $0.date < $1.date }
    }

    /// Field names (never values) of the recovery objects, for the sync log when no reading is found.
    public static func recoveryKeys(fromCyclesJSON json: Any) -> [String] {
        Array(Set(records(json).compactMap { $0["recovery"] as? [String: Any] }.flatMap(\.keys))).sorted()
    }

    private static func records(_ json: Any) -> [[String: Any]] {
        (json as? [String: Any])?["records"] as? [[String: Any]] ?? []
    }
    private static func sleepEnd(record: [String: Any], recovery: [String: Any]) -> Date? {
        guard let sleepID = recovery["activity_id"] as? String, !sleepID.isEmpty,
              let sleeps = record["sleeps"] as? [[String: Any]] else { return nil }
        let linked = sleeps.filter { $0["activity_id"] as? String == sleepID }
        guard linked.count == 1, (linked[0]["is_nap"] as? NSNumber)?.boolValue != true else { return nil }
        return WhoopPayloadAdapters.timeRange(from: linked[0]["during"])?.end
    }
    private static func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func integerID(_ raw: Any?) -> String? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let id = Int64(n.stringValue), id > 0 else { return nil }
        return String(id)
    }
}
