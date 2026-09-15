import Foundation
import HealthKit
import WHOOPHealthSyncCore

@main
struct HealthKitFactorySmokeCheck {
    static func main() throws {
        let sleepFragment = SleepWriteFragment(
            whoopSleepID: "sleep-hk",
            fingerprint: "fingerprint-hk",
            interval: SleepStageInterval(
                start: date(100),
                end: date(200),
                stage: .rem
            )
        )
        let sleepSample = HealthKitSampleFactory.sleepSample(from: sleepFragment)
        expect(sleepSample.sampleType == HealthKitSampleFactory.sleepType, "Sleep sample should use sleepAnalysis type.")
        expect(sleepSample.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue, "REM should map to HealthKit asleepREM.")
        expect(sleepSample.startDate == date(100), "Sleep sample should preserve start date.")
        expect(sleepSample.endDate == date(200), "Sleep sample should preserve end date.")
        expect(sleepSample.metadata?[HKMetadataKeySyncIdentifier] as? String == "sleep:sleep-hk:rem:100000:200000", "Sleep sample should carry deterministic sync identifier.")
        expect(sleepSample.metadata?[HKMetadataKeySyncVersion] as? Int == MetadataKeys.syncVersion, "Sleep sample should carry numeric sync version.")
        expect(sleepSample.metadata?[MetadataKeys.whoopSleepFingerprint] as? String == "fingerprint-hk", "Sleep sample should carry WHOOP sleep fingerprint.")
        expect(sleepSample.metadata?[MetadataKeys.whoopSleepID] as? String == "sleep-hk", "Sleep sample should carry WHOOP sleep ID.")
        expect(MetadataKeys.isRecognizedAppMetadata(sleepSample.metadata), "Sleep metadata should be recognized as app-owned metadata.")
        expect(HealthKitSampleFactory.existingSleepValue(from: HKCategoryValueSleepAnalysis.inBed.rawValue) == .inBed, "inBed should stay generic.")
        expect(HealthKitSampleFactory.existingSleepValue(from: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue) == .asleepUnspecified, "asleepUnspecified should stay generic.")

        let heartRatePoint = HeartRatePoint(timestamp: date(300), bpm: 62, sourceStepSeconds: 6)
        let heartRateSample = HealthKitSampleFactory.heartRateSample(from: heartRatePoint, stepSeconds: 6)
        expect(heartRateSample.sampleType == HealthKitSampleFactory.heartRateType, "HR sample should use heartRate type.")
        expect(heartRateSample.quantity.doubleValue(for: HealthKitSampleFactory.heartRateUnit) == 62, "HR sample should use count/min quantity.")
        expect(heartRateSample.startDate == date(300), "HR sample should preserve timestamp as start.")
        expect(heartRateSample.endDate == date(306), "HR sample should end after one bucket.")
        expect(heartRateSample.metadata?[HKMetadataKeySyncIdentifier] as? String == "heart-rate:300000:6", "HR sample should carry deterministic sync identifier.")
        expect(heartRateSample.metadata?[HKMetadataKeySyncVersion] as? Int == MetadataKeys.syncVersion, "HR sample should carry numeric sync version.")
        expect(heartRateSample.metadata?[MetadataKeys.sourceStepSeconds] as? Int == 6, "HR sample should carry source step.")
        expect(heartRateSample.metadata?[MetadataKeys.whoopHeartRateTimestamp] as? String == WhoopDateCodec.isoString(date(300)), "HR sample should carry WHOOP timestamp.")
        expect(MetadataKeys.isRecognizedAppMetadata(heartRateSample.metadata), "HR metadata should be recognized as app-owned metadata.")
        expect(!MetadataKeys.isRecognizedAppMetadata([HKMetadataKeySyncIdentifier: "external:sample"]), "Unknown sync identifiers should not be recognized as app-owned metadata.")
        expect(!MetadataKeys.isRecognizedAppMetadata(nil), "Missing metadata should not be recognized as app-owned metadata.")

        try HealthKitService.validateWriteAuthorization(
            sleepStatus: .sharingAuthorized,
            heartRateStatus: .sharingAuthorized
        )
        do {
            try HealthKitService.validateWriteAuthorization(
                sleepStatus: .sharingDenied,
                heartRateStatus: .sharingAuthorized
            )
            fatalError("Denied sleep write permission should fail validation.")
        } catch let error as HealthKitSyncError {
            expect(error.localizedDescription.contains("Sleep Analysis"), "Denied sleep write permission should name Sleep Analysis.")
        }
        do {
            try HealthKitService.validateWriteAuthorization(
                sleepStatus: .sharingAuthorized,
                heartRateStatus: .notDetermined
            )
            fatalError("Undetermined heart-rate write permission should fail validation.")
        } catch let error as HealthKitSyncError {
            expect(error.localizedDescription.contains("Heart Rate"), "Undetermined HR write permission should name Heart Rate.")
        }

        print("HealthKitSampleFactory smoke check passed")
    }

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }
}
