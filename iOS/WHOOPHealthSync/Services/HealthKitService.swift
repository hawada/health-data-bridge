import Foundation
import HealthKit
import WHOOPHealthSyncCore

struct HealthKitSleepSampleRecord {
    var sample: HKCategorySample
    var existing: ExistingSleepSample
}

struct HealthKitHeartRateSampleRecord {
    var sample: HKQuantitySample
    var existing: ExistingHeartRateSample
}

final class HealthKitService {
    private let store = HKHealthStore()
    private let sleepType = HealthKitSampleFactory.sleepType
    private let heartRateType = HealthKitSampleFactory.heartRateType
    private let heartRateUnit = HealthKitSampleFactory.heartRateUnit

    func authorizedBoundary(for type: String) async throws -> Date? {
        #if os(iOS)
        if #available(iOS 27, *) {
            #if WHOOP_IOS27_SDK
            let objectType: HKObjectType = type == "sleep" ? sleepType : heartRateType
            let dates: [HKObjectType: Date] = try await withCheckedThrowingContinuation { continuation in
                store.getEarliestAuthorizedSampleDate(for: [objectType]) { dates, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: dates ?? [:]) }
                }
            }
            return dates[objectType]
            #else
            throw RecoverySyncError.unavailable
            #endif
        }
        #endif
        return nil
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitSyncError.healthDataUnavailable
        }

        let shareTypes: Set<HKSampleType> = [sleepType, heartRateType]
        let readTypes: Set<HKObjectType> = [sleepType, heartRateType]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: shareTypes, read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: HealthKitSyncError.authorizationRejected)
                    return
                }
                continuation.resume()
            }
        }
        try Self.validateWriteAuthorization(
            sleepStatus: store.authorizationStatus(for: sleepType),
            heartRateStatus: store.authorizationStatus(for: heartRateType)
        )
        AppLog.healthKit.info("HealthKit authorization request completed with required write permissions.")
    }

    func validateExistingAuthorization() throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitSyncError.healthDataUnavailable
        }
        try Self.validateWriteAuthorization(
            sleepStatus: store.authorizationStatus(for: sleepType),
            heartRateStatus: store.authorizationStatus(for: heartRateType)
        )
    }

    func querySleepSamples(from start: Date, to end: Date) async throws -> [HealthKitSleepSampleRecord] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKCategorySample] = try await runSampleQuery(sampleType: sleepType, predicate: predicate)
        AppLog.healthKit.info("Read \(samples.count) sleep samples from HealthKit.")
        return samples.map { sample in
            HealthKitSleepSampleRecord(
                sample: sample,
                existing: ExistingSleepSample(
                    id: sample.uuid.uuidString,
                    range: TimeRange(start: sample.startDate, end: sample.endDate),
                    value: HealthKitSampleFactory.existingSleepValue(from: sample.value),
                    isOwnedByApp: isOwnedByThisApp(sample),
                    whoopSleepID: sample.metadata?[MetadataKeys.whoopSleepID] as? String,
                    whoopSleepFingerprint: sample.metadata?[MetadataKeys.whoopSleepFingerprint] as? String,
                    syncIdentifier: sample.metadata?[HKMetadataKeySyncIdentifier] as? String
                )
            )
        }
    }

    func saveSleepFragments(_ fragments: [SleepWriteFragment]) async throws {
        guard !fragments.isEmpty else { return }
        let samples = fragments.map { HealthKitSampleFactory.sleepSample(from: $0) }
        try await save(samples)
        AppLog.healthKit.info("Saved \(samples.count) detailed sleep samples to HealthKit.")
    }

    func deleteSleepSamples(_ records: [HealthKitSleepSampleRecord]) async throws {
        guard !records.isEmpty else { return }
        try await delete(records.map(\.sample))
        AppLog.healthKit.info("Deleted \(records.count) app-owned sleep samples from HealthKit.")
    }

    func queryHeartRateSamples(from start: Date, to end: Date) async throws -> [HealthKitHeartRateSampleRecord] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKQuantitySample] = try await runSampleQuery(sampleType: heartRateType, predicate: predicate)
        AppLog.healthKit.info("Read \(samples.count) heart-rate samples from HealthKit.")
        return samples.map { sample in
            HealthKitHeartRateSampleRecord(
                sample: sample,
                existing: ExistingHeartRateSample(
                    id: sample.uuid.uuidString,
                    range: TimeRange(start: sample.startDate, end: sample.endDate),
                    bpm: sample.quantity.doubleValue(for: heartRateUnit),
                    isOwnedByApp: isOwnedByThisApp(sample),
                    syncIdentifier: sample.metadata?[HKMetadataKeySyncIdentifier] as? String
                )
            )
        }
    }

    func saveHeartRatePoints(_ points: [HeartRatePoint], stepSeconds: Int) async throws {
        guard !points.isEmpty else { return }
        let samples = points.map { HealthKitSampleFactory.heartRateSample(from: $0, stepSeconds: stepSeconds) }
        try await save(samples)
        AppLog.healthKit.info("Saved \(samples.count) heart-rate samples to HealthKit.")
    }

    func deleteHeartRateSamples(_ records: [HealthKitHeartRateSampleRecord]) async throws {
        guard !records.isEmpty else { return }
        try await delete(records.map(\.sample))
        AppLog.healthKit.info("Deleted \(records.count) app-owned heart-rate samples from HealthKit.")
    }

    private func runSampleQuery<T: HKSample>(sampleType: HKSampleType, predicate: NSPredicate) async throws -> [T] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[T], Error>) in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [T]) ?? [])
            }
            store.execute(query)
        }
    }

    private func save(_ samples: [HKSample]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.save(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: HealthKitSyncError.saveRejected)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func delete(_ samples: [HKSample]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.delete(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: HealthKitSyncError.deleteRejected)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func isOwnedByThisApp(_ sample: HKSample) -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }
        return sample.sourceRevision.source.bundleIdentifier == bundleIdentifier
            && MetadataKeys.isRecognizedAppMetadata(sample.metadata)
    }

    static func validateWriteAuthorization(
        sleepStatus: HKAuthorizationStatus,
        heartRateStatus: HKAuthorizationStatus
    ) throws {
        var deniedTypes: [String] = []
        if sleepStatus != .sharingAuthorized {
            deniedTypes.append("Sleep Analysis")
        }
        if heartRateStatus != .sharingAuthorized {
            deniedTypes.append("Heart Rate")
        }
        guard deniedTypes.isEmpty else {
            throw HealthKitSyncError.writeAuthorizationDenied(deniedTypes)
        }
    }

}

enum HealthKitSyncError: Error, LocalizedError {
    case healthDataUnavailable
    case authorizationRejected
    case writeAuthorizationDenied([String])
    case saveRejected
    case deleteRejected

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "Health data is not available on this device."
        case .authorizationRejected:
            return "HealthKit authorization was not granted."
        case let .writeAuthorizationDenied(types):
            return "HealthKit write authorization missing for \(types.joined(separator: ", "))."
        case .saveRejected:
            return "HealthKit rejected the save operation."
        case .deleteRejected:
            return "HealthKit rejected the delete operation."
        }
    }
}
