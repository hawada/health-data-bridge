import Foundation
import CoreFoundation

/// Overnight WHOOP vitals written to Health as Blood Oxygen and Respiratory Rate.
public enum NightlyVital: String, CaseIterable, Sendable {
    case oxygenSaturation = "spo2"
    case respiratoryRate = "resp-rate"

    /// The private field names are not documented, so a few likely names are accepted.
    public var candidateKeys: [String] {
        switch self {
        case .oxygenSaturation: ["spo2_percentage", "spo2", "spo2_percent", "blood_oxygen", "oxygen_saturation"]
        case .respiratoryRate: ["respiratory_rate", "resp_rate", "respiratory_rate_bpm", "respiration_rate"]
        }
    }

    /// Percent for oxygen saturation, breaths per minute for respiratory rate.
    public var plausibleRange: ClosedRange<Double> {
        switch self {
        case .oxygenSaturation: 80...100
        case .respiratoryRate: 5...40
        }
    }
}

/// One nightly WHOOP vital, stamped at the middle of the sleep it was measured in. Bevel only counts
/// these readings when they fall inside the sleep; WHOOP's own Health feed stamps them at wake time.
public struct NightlyVitalReading: Equatable, Sendable {
    public var vital: NightlyVital
    public var cycleID: String
    public var value: Double
    /// The sleep the value was measured in; `date` is its midpoint.
    public var sleep: TimeRange
    public var date: Date { sleep.start.addingTimeInterval(sleep.end.timeIntervalSince(sleep.start) / 2) }
    public init(vital: NightlyVital, cycleID: String, value: Double, sleep: TimeRange) {
        self.vital = vital; self.cycleID = cycleID; self.value = value; self.sleep = sleep
    }
    public var syncIdentifier: String { "whoop-\(vital.rawValue):\(cycleID)" }
}

extension NightlyVitalReading {
    /// A night is already covered only when this app wrote it. Other sources' samples never count:
    /// WHOOP's own feed and earlier manual imports sit at wake time (to the second, while the sleep end
    /// carries milliseconds), where Bevel ignores them, so the mid-sleep reading is still written.
    public static func toWrite(_ readings: [NightlyVitalReading], existing: [(start: Date, syncIdentifier: String?)]) -> [NightlyVitalReading] {
        let written = Set(existing.compactMap(\.syncIdentifier))
        return readings.filter { !written.contains($0.syncIdentifier) }
    }
}

/// Reads blood oxygen and respiratory rate from the private cycles/details payload already used for
/// sleep and recovery. Each value is looked up on the recovery and on the linked sleep (and their `score`
/// objects); values outside a plausible range are dropped rather than written.
public enum WhoopNightlyVitalsAdapter {
    public static func readings(fromCyclesJSON json: Any) -> [NightlyVitalReading] {
        var byID: [String: NightlyVitalReading] = [:]
        for record in records(json) {
            guard let cycle = record["cycle"] as? [String: Any], let cycleID = integerID(cycle["id"]),
                  let recovery = record["recovery"] as? [String: Any],
                  recovery["state"] as? String == "complete",
                  let sleep = linkedSleep(record: record, recovery: recovery),
                  let range = WhoopPayloadAdapters.timeRange(from: sleep["during"]), range.end > range.start else { continue }
            let sources = [recovery, recovery["score"] as? [String: Any], sleep, sleep["score"] as? [String: Any]].compactMap { $0 }
            for vital in NightlyVital.allCases {
                guard var value = sources.lazy.flatMap({ source in vital.candidateKeys.lazy.compactMap { number(source[$0]) } }).first
                else { continue }
                if vital == .oxygenSaturation, value > 0, value <= 1 { value *= 100 }
                guard vital.plausibleRange.contains(value) else { continue }
                let reading = NightlyVitalReading(vital: vital, cycleID: cycleID, value: value, sleep: range)
                byID[reading.syncIdentifier] = reading
            }
        }
        return byID.values.sorted { ($0.date, $0.vital.rawValue) < ($1.date, $1.vital.rawValue) }
    }

    /// Field names (never values) of the recovery and sleep objects, for the sync log when no reading is found.
    public static func fieldNames(fromCyclesJSON json: Any) -> [String] {
        let objects = records(json).flatMap { record -> [[String: Any]] in
            [record["recovery"] as? [String: Any]].compactMap { $0 } + (record["sleeps"] as? [[String: Any]] ?? [])
        }
        let nested = objects.compactMap { $0["score"] as? [String: Any] }.flatMap { $0.keys.map { "score.\($0)" } }
        return Array(Set(objects.flatMap(\.keys) + nested)).sorted()
    }

    private static func records(_ json: Any) -> [[String: Any]] {
        (json as? [String: Any])?["records"] as? [[String: Any]] ?? []
    }
    private static func linkedSleep(record: [String: Any], recovery: [String: Any]) -> [String: Any]? {
        guard let sleepID = recovery["activity_id"] as? String, !sleepID.isEmpty,
              let sleeps = record["sleeps"] as? [[String: Any]] else { return nil }
        let linked = sleeps.filter { $0["activity_id"] as? String == sleepID }
        guard linked.count == 1, (linked[0]["is_nap"] as? NSNumber)?.boolValue != true else { return nil }
        return linked[0]
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
