import Foundation
import HealthKit
import WHOOPHealthSyncCore

struct RecoveryHealthSource: Identifiable, Equatable {
    var name: String
    var bundle: String
    var id: String { bundle }
}

struct RecoveryAuthorization {
    var sources: [RecoveryHealthSource]
    var access: HealthReadAccess
    var writeAuthorized = true
}

struct SyncDataAuthorization {
    var sleepWriteAuthorized: Bool
    var heartRateWriteAuthorized: Bool
    // nil means unknown, never full-read authorization.
    var sleepReadBoundary: Date?
    var heartRateReadBoundary: Date?
    var recovery: RecoveryAuthorization?
    var baseWriteAuthorized: Bool { sleepWriteAuthorized && heartRateWriteAuthorized }
}

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
    private let bodyTemperatureType = HKQuantityType.quantityType(forIdentifier: .bodyTemperature)!
    private let oxygenSaturationType = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!
    private let respiratoryRateType = HKQuantityType.quantityType(forIdentifier: .respiratoryRate)!
    private let hrvSDNNType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!

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
        try await requestAuthorization(includeRecovery: false)
    }

    func requestAuthorization(includeRecovery: Bool) async throws {
        let result = try await requestSelectedAuthorization(includeRecovery: includeRecovery)
        var denied: [String] = []
        if !result.sleepWriteAuthorized { denied.append("Sleep Analysis") }
        if !result.heartRateWriteAuthorized { denied.append("Heart Rate") }
        if !denied.isEmpty { throw HealthKitSyncError.writeAuthorizationDenied(denied) }
    }

    func requestSelectedAuthorization(includeRecovery: Bool) async throws -> SyncDataAuthorization {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitSyncError.healthDataUnavailable
        }

        var shareTypes: Set<HKSampleType> = [sleepType, heartRateType, bodyTemperatureType, oxygenSaturationType, respiratoryRateType,
                                             hrvSDNNType]
        var readTypes: Set<HKObjectType> = [sleepType, heartRateType, bodyTemperatureType, oxygenSaturationType, respiratoryRateType,
                                            hrvSDNNType]
        #if WHOOP_IOS27_SDK && os(iOS)
        if #available(iOS 27, *), includeRecovery,
           let recovery = HKObjectType.quantityType(forIdentifier: .heartRateVariabilityRMSSD) {
            shareTypes.insert(recovery)
            readTypes.insert(recovery)
        }
        #endif

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
        return SyncDataAuthorization(
            sleepWriteAuthorized: store.authorizationStatus(for: sleepType) == .sharingAuthorized,
            heartRateWriteAuthorized: store.authorizationStatus(for: heartRateType) == .sharingAuthorized,
            sleepReadBoundary: try await authorizedBoundary(for: "sleep"),
            heartRateReadBoundary: try await authorizedBoundary(for: "heartRate"), recovery: nil)
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

    /// Writes WHOOP skin temperature as Body Temperature (Bevel can use it in place of wrist temperature).
    /// A night that already has a body temperature within an hour (from this app or an earlier manual import)
    /// is skipped, so repeated syncs never duplicate.
    func saveSkinTemperatures(_ readings: [SkinTemperatureReading]) async throws -> Int {
        guard !readings.isEmpty else { return 0 }
        if store.authorizationStatus(for: bodyTemperatureType) == .notDetermined {
            try await store.requestAuthorization(toShare: [bodyTemperatureType], read: [bodyTemperatureType])
        }
        guard store.authorizationStatus(for: bodyTemperatureType) == .sharingAuthorized else {
            throw HealthKitSyncError.writeAuthorizationDenied(["Body Temperature"])
        }
        let dates = readings.map(\.date)
        let predicate = HKQuery.predicateForSamples(withStart: dates.min()!.addingTimeInterval(-3600),
                                                    end: dates.max()!.addingTimeInterval(3600), options: [])
        let existing: [HKQuantitySample] = try await runSampleQuery(sampleType: bodyTemperatureType, predicate: predicate)
        let written = Set(existing.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String })
        let samples = readings.filter { reading in
            !written.contains(reading.syncIdentifier)
                && !existing.contains { abs($0.startDate.timeIntervalSince(reading.date)) < 3600 }
        }.map { reading in
            HKQuantitySample(type: bodyTemperatureType,
                             quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: reading.celsius),
                             start: reading.date, end: reading.date,
                             metadata: [HKMetadataKeySyncIdentifier: reading.syncIdentifier,
                                        HKMetadataKeySyncVersion: MetadataKeys.syncVersion,
                                        MetadataKeys.adapterVersion: MetadataKeys.appVersion,
                                        "com.whoophealthsync.measurement": "WHOOP skin temperature"])
        }
        guard !samples.isEmpty else { return 0 }
        try await save(samples)
        AppLog.healthKit.info("Saved \(samples.count) skin temperature samples to HealthKit.")
        return samples.count
    }

    /// Writes WHOOP blood oxygen, respiratory rate and HRV at the middle of each sleep, where Bevel counts them.
    /// Nights this app already wrote are skipped (see `NightlyVitalReading.toWrite`).
    func saveNightlyVitals(_ readings: [NightlyVitalReading]) async throws -> [NightlyVital: Int] {
        var savedCounts: [NightlyVital: Int] = [:]
        for vital in NightlyVital.allCases {
            let nights = readings.filter { $0.vital == vital }
            guard !nights.isEmpty else { continue }
            let type = quantityType(for: vital)
            if store.authorizationStatus(for: type) == .notDetermined {
                try await store.requestAuthorization(toShare: [type], read: [type])
            }
            guard store.authorizationStatus(for: type) == .sharingAuthorized else {
                throw HealthKitSyncError.writeAuthorizationDenied([displayName(for: vital)])
            }
            let predicate = HKQuery.predicateForSamples(withStart: nights.map(\.sleep.start).min()!,
                                                        end: nights.map(\.sleep.end).max()!.addingTimeInterval(86400), options: [])
            let existing: [HKQuantitySample] = try await runSampleQuery(sampleType: type, predicate: predicate)
            let samples = NightlyVitalReading.toWrite(nights, existing: existing.map {
                ($0.startDate, $0.metadata?[HKMetadataKeySyncIdentifier] as? String)
            }).map { reading in
                HKQuantitySample(type: type,
                                 quantity: quantity(for: reading),
                                 start: reading.date, end: reading.date,
                                 metadata: [HKMetadataKeySyncIdentifier: reading.syncIdentifier,
                                            HKMetadataKeySyncVersion: MetadataKeys.syncVersion,
                                            MetadataKeys.adapterVersion: MetadataKeys.appVersion,
                                            "com.whoophealthsync.measurement": "WHOOP \(vital.rawValue)"])
            }
            guard !samples.isEmpty else { continue }
            try await save(samples)
            AppLog.healthKit.info("Saved \(samples.count) \(vital.rawValue, privacy: .public) samples to HealthKit.")
            savedCounts[vital] = samples.count
        }
        return savedCounts
    }

    private func quantityType(for vital: NightlyVital) -> HKQuantityType {
        switch vital {
        case .oxygenSaturation: oxygenSaturationType
        case .respiratoryRate: respiratoryRateType
        case .heartRateVariability: hrvSDNNType
        }
    }

    private func displayName(for vital: NightlyVital) -> String {
        switch vital {
        case .oxygenSaturation: "Blood Oxygen"
        case .respiratoryRate: "Respiratory Rate"
        case .heartRateVariability: "Heart Rate Variability"
        }
    }

    private func quantity(for reading: NightlyVitalReading) -> HKQuantity {
        switch reading.vital {
        case .oxygenSaturation: HKQuantity(unit: .percent(), doubleValue: reading.value / 100)
        case .respiratoryRate: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: reading.value)
        case .heartRateVariability: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: reading.value)
        }
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
