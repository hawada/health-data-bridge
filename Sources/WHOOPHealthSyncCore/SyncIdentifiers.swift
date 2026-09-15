import Foundation

public enum SyncIdentifiers {
    public static func unixMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    public static func sleep(whoopSleepID: String, stage: SleepStage, start: Date, end: Date) -> String {
        "sleep:\(whoopSleepID):\(stage.rawValue):\(unixMilliseconds(start)):\(unixMilliseconds(end))"
    }

    public static func heartRate(timestamp: Date, stepSeconds: Int) -> String {
        "heart-rate:\(unixMilliseconds(timestamp)):\(stepSeconds)"
    }
}
