import Foundation
import HealthKit
import WHOOPHealthSyncCore

enum MetadataKeys {
    static let whoopSleepID = "com.whoophealthsync.whoopSleepID"
    static let whoopSleepFingerprint = "com.whoophealthsync.whoopSleepFingerprint"
    static let whoopHeartRateTimestamp = "com.whoophealthsync.whoopHeartRateTimestamp"
    static let adapterVersion = "com.whoophealthsync.adapterVersion"
    static let sourceStepSeconds = "com.whoophealthsync.sourceStepSeconds"
    static let appVersion = "0.2.0"
    static let recoveryFingerprint = "com.whoophealthsync.recoveryFingerprint"
    static let recoveryCycleID = "com.whoophealthsync.recoveryCycleID"
    static let recoveryMethod = "com.whoophealthsync.recoveryMethod"
    static let recoveryUnit = "com.whoophealthsync.recoveryUnit"
    static let recoveryTimestampBasis = "com.whoophealthsync.recoveryTimestampBasis"
    static let syncVersion = 1

    static func unixMilliseconds(_ date: Date) -> Int64 {
        SyncIdentifiers.unixMilliseconds(date)
    }

    static func sleepSyncIdentifier(whoopSleepID: String, stage: SleepStage, start: Date, end: Date) -> String {
        SyncIdentifiers.sleep(whoopSleepID: whoopSleepID, stage: stage, start: start, end: end)
    }

    static func heartRateSyncIdentifier(timestamp: Date, stepSeconds: Int) -> String {
        SyncIdentifiers.heartRate(timestamp: timestamp, stepSeconds: stepSeconds)
    }

    static func isRecognizedAppMetadata(_ metadata: [String: Any]?) -> Bool {
        guard let metadata else {
            return false
        }
        if ["0.1.0", appVersion].contains(metadata[adapterVersion] as? String ?? "") {
            return true
        }
        if metadata[whoopSleepID] as? String != nil || metadata[whoopHeartRateTimestamp] as? String != nil {
            return true
        }
        if let syncIdentifier = metadata[HKMetadataKeySyncIdentifier] as? String {
            return syncIdentifier.hasPrefix("sleep:") || syncIdentifier.hasPrefix("heart-rate:")
        }
        return false
    }
}
