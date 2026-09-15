import XCTest
import HealthKit
import WHOOPHealthSyncCore
@testable import WHOOPHealthSync

final class RecoveryHealthKitTests: XCTestCase {
    @MainActor func testUnifiedSetupAtomicNativeSaveAndRollback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("setup-native-\(UUID())")
        let url = directory.appendingPathComponent("sync-store.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SyncRepository(fileURL: url)
        var state = RecoverySyncState(); state.accountKey = "synthetic-account"
        state.enabled = true; state.configured = true
        state.historyStartDate = Date(timeIntervalSince1970: 1_000_000)
        try repo.saveSyncSetup(recovery: state, accountKey: state.accountKey)
        let bytes = try Data(contentsOf: url)
        let relaunched = SyncRepository(fileURL: url)
        XCTAssertTrue(relaunched.hasCompletedSyncSetup); XCTAssertEqual(try relaunched.recoveryState(), state)
        let failing = SyncRepository(fileURL: url, writeData: { _, _ in throw SyncRepositoryError.storeWriteFailed })
        var optOut = state; optOut.enabled = false
        XCTAssertThrowsError(try failing.saveSyncSetup(recovery: optOut))
        XCTAssertEqual(try failing.recoveryState(), state); XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    @MainActor func testUnreadableRepositoryCannotBeClassifiedAsNewOrOverwriteOriginal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unreadable-setup-\(UUID()).json")
        let bytes = Data("synthetic corrupt fixture".utf8); try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = SyncRepository(fileURL: url)
        XCTAssertThrowsError(try repo.ensureUsable()); XCTAssertFalse(repo.hasCompletedSyncSetup)
        XCTAssertThrowsError(try repo.saveSyncSetup(recovery: RecoverySyncState()))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    @MainActor func testT02NativeRMSSDTypeUnitDateAndMetadata() throws {
        guard #available(iOS 27, *) else { throw XCTSkip("RMSSD requires iOS 27") }
        guard HKObjectType.quantityType(forIdentifier: .heartRateVariabilityRMSSD) != nil else {
            throw XCTSkip("This runtime does not expose RMSSD; final iOS 27 runtime is required")
        }
        let end = Date(timeIntervalSince1970: 1_600_000_000)
        let recovery = WhoopRecovery(accountKey: "test-account", cycleID: "1", sleepID: "sleep",
            sleepRange: TimeRange(start: end.addingTimeInterval(-28800), end: end), sourceTimeZoneID: "Europe/Madrid",
            milliseconds: 31.813562, scoreState: .scored, updatedAt: end)
        let fingerprint = try recovery.fingerprint()
        let sample = try HealthKitRecoveryAdapter.makeSample(recovery, fingerprint: fingerprint, version: 3)
        XCTAssertEqual(sample.quantityType, HKQuantityType(.heartRateVariabilityRMSSD))
        XCTAssertEqual(sample.quantity.doubleValue(for: .secondUnit(with: .milli)), 31.813562)
        XCTAssertEqual(sample.startDate, end); XCTAssertEqual(sample.endDate, end)
        XCTAssertEqual(sample.metadata?[HKMetadataKeySyncIdentifier] as? String, recovery.identifier)
        XCTAssertEqual((sample.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(sample.metadata?[MetadataKeys.recoveryTimestampBasis] as? String, "sleepEndSummary")
        XCTAssertEqual(sample.metadata?[MetadataKeys.recoveryMethod] as? String, "RMSSD")
        // Factory only: deliberately does not write synthetic values into any HealthKit store.
    }
    @MainActor func testT06NativeFactoryRejectsInvalidRecord() throws {
        guard #available(iOS 27, *) else { throw XCTSkip("RMSSD requires iOS 27") }
        guard HKObjectType.quantityType(forIdentifier: .heartRateVariabilityRMSSD) != nil else {
            throw XCTSkip("This runtime does not expose RMSSD; final iOS 27 runtime is required")
        }
        let end = Date()
        let recovery = WhoopRecovery(accountKey: "test", cycleID: "1", sleepID: "sleep",
            sleepRange: TimeRange(start: end.addingTimeInterval(-28800), end: end), sourceTimeZoneID: "Europe/Madrid",
            milliseconds: 0, scoreState: .scored, updatedAt: end)
        XCTAssertThrowsError(try HealthKitRecoveryAdapter.makeSample(recovery, fingerprint: "invalid", version: 1))
    }
    func testT10LegacyMetadataStillRecognized() {
        XCTAssertTrue(MetadataKeys.isRecognizedAppMetadata([MetadataKeys.adapterVersion: "0.1.0"]))
        XCTAssertTrue(MetadataKeys.isRecognizedAppMetadata([HKMetadataKeySyncIdentifier: "sleep:old"]))
        XCTAssertFalse(MetadataKeys.isRecognizedAppMetadata([HKMetadataKeySyncIdentifier: "unrelated"]))
    }
    @MainActor func testT01CapabilityFollowsRuntimeAvailability() {
        let adapter = HealthKitRecoveryAdapter()
        if #available(iOS 27, *) { XCTAssertEqual(adapter.supported, HKObjectType.quantityType(forIdentifier: .heartRateVariabilityRMSSD) != nil) }
        else { XCTAssertFalse(adapter.supported) }
    }
    @MainActor func testG3IsolatedSimulatorSaveReadReviseAndDeleteHistoricalSample() async throws {
        #if targetEnvironment(simulator)
        guard #available(iOS 27, *), let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilityRMSSD) else {
            throw XCTSkip("RMSSD requires a supporting iOS 27 runtime")
        }
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("WHOOP 0.2 QA") == true else {
            throw XCTSkip("Synthetic writes are restricted to the isolated WHOOP 0.2 QA simulator")
        }
        guard HKHealthStore.isHealthDataAvailable() else { throw XCTSkip("HealthKit store unavailable in this simulator") }
        let store = HKHealthStore()
        guard await authorizeForIsolatedWrite(store, type: type) else { return }
        XCTAssertEqual(store.authorizationStatus(for: type), .sharingAuthorized)
        let id = "whoop-rmssd:test-only:" + UUID().uuidString
        let historicalDate = Date(timeIntervalSince1970: 1_600_000_000)
        func sample(value: Double, version: Int) -> HKQuantitySample {
            HKQuantitySample(type: type, quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: value),
                start: historicalDate, end: historicalDate,
                metadata: [HKMetadataKeySyncIdentifier: id, HKMetadataKeySyncVersion: version,
                           "com.whoophealthsync.validationOnly": true])
        }
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [id])
        func readOwnTestSample() async throws -> [HKQuantitySample] {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: samples as? [HKQuantitySample] ?? []) }
                }
                store.execute(query)
            }
        }
        do {
            try await store.save(sample(value: 17.25, version: 1))
            let first = try await readOwnTestSample()
            XCTAssertEqual(first.count, 1); XCTAssertEqual(first.first?.startDate, historicalDate)
            XCTAssertEqual(first.first?.quantity.doubleValue(for: .secondUnit(with: .milli)), 17.25)
            try await store.save(sample(value: 19.5, version: 2))
            let revised = try await readOwnTestSample()
            XCTAssertEqual(revised.count, 1)
            XCTAssertEqual(revised.first?.quantity.doubleValue(for: .secondUnit(with: .milli)), 19.5)
            // Cleanup only the exact UUIDs returned by the unique test identifier, never by day/source.
            if !revised.isEmpty { try await store.delete(revised) }
            let empty = try await readOwnTestSample(); XCTAssertTrue(empty.isEmpty)
        } catch {
            if let own = try? await readOwnTestSample(), !own.isEmpty { try? await store.delete(own) }
            throw error
        }
        // Re-reading our own sample is a store roundtrip test, never evidence of external read authorization.
        #else
        throw XCTSkip("Synthetic validation samples must never be written on a physical device")
        #endif
    }

    @MainActor func testG5NativeMigrationPreservesCheckpointsAndExactBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("legacy.json")
        let checkpoint = Date(timeIntervalSince1970: 1_600_000_000)
        let original = SyncRepository(fileURL: file)
        try original.setSleepCheckpoint(checkpoint)
        try original.setHeartRateCheckpoint(checkpoint, resolution: 60)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json.removeValue(forKey: "schemaVersion")
        json.removeValue(forKey: "recovery")
        json.removeValue(forKey: "linkedAccountKey")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        try legacy.write(to: file)
        let migrated = SyncRepository(fileURL: file)
        XCTAssertTrue(migrated.requiresManualAccountBinding)
        XCTAssertThrowsError(try migrated.validateAccount("simulator-account-A"))
        XCTAssertEqual(try Data(contentsOf: file), legacy)
        try migrated.bindAccountManually("simulator-account-A")
        let backup = file.appendingPathExtension("v1-backup")
        XCTAssertEqual(try Data(contentsOf: backup), legacy)
        let restarted = SyncRepository(fileURL: file)
        XCTAssertFalse(restarted.requiresManualAccountBinding)
        try restarted.validateAccount("simulator-account-A")
        let bytes = try Data(contentsOf: file)
        XCTAssertThrowsError(try restarted.validateAccount("simulator-account-B"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try restarted.checkpoints().lastSleepQueryEnd, checkpoint)
        XCTAssertEqual(try restarted.checkpoints().lastHeartRateEnd, checkpoint)
        XCTAssertEqual(try restarted.checkpoints().lastHeartRateResolution, 60)
        XCTAssertFalse(try restarted.recoveryState().enabled)
    }

    @MainActor func testT13NativePersistenceFailureAndCorruptionPreserveOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("store.json")
        let checkpoint = Date(timeIntervalSince1970: 1_600_000_000)
        try SyncRepository(fileURL: file).setSleepCheckpoint(checkpoint)
        let bytes = try Data(contentsOf: file)
        let failing = SyncRepository(fileURL: file, writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try failing.setSleepCheckpoint(checkpoint.addingTimeInterval(600)))
        XCTAssertEqual(try failing.checkpoints().lastSleepQueryEnd, checkpoint)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: file)
        let blocked = SyncRepository(fileURL: file)
        XCTAssertThrowsError(try blocked.ensureUsable())
        XCTAssertThrowsError(try blocked.setSleepCheckpoint(checkpoint))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    @MainActor func testT18NativeFilesHaveCompleteProtection() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The tested simulator returns no file protection attribute; effective Data Protection requires physical-device verification")
        #else
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("legacy.json")
        try SyncRepository(fileURL: file).setSleepCheckpoint(Date(timeIntervalSince1970: 1_600_000_000))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json.removeValue(forKey: "schemaVersion")
        json.removeValue(forKey: "recovery")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        try SyncRepository(fileURL: file).bindAccountManually("physical-persistence-test-only")
        for url in [file, file.appendingPathExtension("v1-backup")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
        }
        #endif
    }

    @MainActor func testG4OwnUnrecognizedSampleDoesNotProveExternalReadAccess() async throws {
        #if targetEnvironment(simulator)
        guard #available(iOS 27, *), let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilityRMSSD) else {
            throw XCTSkip("RMSSD requires iOS 27")
        }
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("WHOOP 0.2 QA") == true else {
            throw XCTSkip("Synthetic writes require the isolated WHOOP 0.2 QA simulator")
        }
        let store = HKHealthStore()
        guard await authorizeForIsolatedWrite(store, type: type) else { return }
        let dates: [HKObjectType: Date] = try await withCheckedThrowingContinuation { continuation in
            store.getEarliestAuthorizedSampleDate(for: [type]) { dates, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: dates ?? [:]) }
            }
        }
        guard dates[type] == nil else { throw XCTSkip("This case requires unbounded read access selected in the isolated simulator") }
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        // Deliberately incomplete metadata: ownership recognition must not be used to infer source permission.
        let own = HKQuantitySample(type: type,
            quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: 20), start: date, end: date,
            metadata: ["com.whoophealthsync.validationOnly": UUID().uuidString])
        try await store.save(own)
        do {
            let access = try await HealthKitRecoveryAdapter(store: store).readAccess()
            XCTAssertEqual(access, .unknown, "Our own source cannot distinguish denied from full read permission")
            try await store.delete(own)
        } catch {
            try? await store.delete(own)
            throw error
        }
        #else
        throw XCTSkip("Synthetic samples are never written on a physical device")
        #endif
    }

    @MainActor func testG4NativeAccessMatchesAuthorizedTemporalBoundary() async throws {
        guard #available(iOS 27, *), let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilityRMSSD) else {
            throw XCTSkip("RMSSD requires iOS 27")
        }
        let store = HKHealthStore()
        let dates: [HKObjectType: Date] = try await withCheckedThrowingContinuation { continuation in
            store.getEarliestAuthorizedSampleDate(for: [type]) { dates, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: dates ?? [:]) }
            }
        }
        let access = try await HealthKitRecoveryAdapter(store: store).readAccess()
        let confirmedAccess = try await HealthKitRecoveryAdapter(store: store, manualConfirmation: { true }).readAccess()
        if let boundary = dates[type] {
            XCTAssertEqual(access, .limited(since: boundary))
            XCTAssertEqual(confirmedAccess, .limited(since: boundary), "Personal confirmation cannot override a real temporal boundary")
            print("G4 native RMSSD scope: limited; boundary returned by HealthKit")
        } else {
            XCTAssertEqual(access, .unknown, "An empty boundary and empty/own-only store cannot prove full or denied read access")
            XCTAssertEqual(confirmedAccess, .userConfirmedFullAccess, "Manual confirmation is explicit, never inferred from own data")
            print("G4 native RMSSD scope: no boundary; empty or own-only remains unknown; personal confirmation is distinct")
        }
    }

    @MainActor private func authorizeForIsolatedWrite(_ store: HKHealthStore, type: HKQuantityType) async -> Bool {
        let completed = expectation(description: "HealthKit authorization completes in the initialized QA simulator")
        store.requestAuthorization(toShare: [type], read: [type]) { success, error in
            XCTAssertNil(error)
            XCTAssertTrue(success)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 120)
        let authorized = store.authorizationStatus(for: type) == .sharingAuthorized
        XCTAssertTrue(authorized, "Grant synthetic-write permission only in the isolated QA simulator")
        return authorized
    }

}
