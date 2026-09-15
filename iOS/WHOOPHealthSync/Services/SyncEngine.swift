import Foundation
import WHOOPHealthSyncCore

protocol WhoopAPIProviding {
    func fetchCurrentUser() async throws -> WhoopUser
    func fetchSleepActivities(userID: String, start: Date, end: Date) async throws -> [WhoopSleepActivity]
    func fetchSleepSession(activity: WhoopSleepActivity) async throws -> SleepSession
    func fetchHeartRate(userID: String, start: Date, end: Date, stepSeconds: Int) async throws -> [HeartRatePoint]
}

protocol HealthDataProviding {
    func authorizedBoundary(for type: String) async throws -> Date?
    func querySleepSamples(from start: Date, to end: Date) async throws -> [HealthKitSleepSampleRecord]
    func saveSleepFragments(_ fragments: [SleepWriteFragment]) async throws
    func deleteSleepSamples(_ records: [HealthKitSleepSampleRecord]) async throws
    func queryHeartRateSamples(from start: Date, to end: Date) async throws -> [HealthKitHeartRateSampleRecord]
    func saveHeartRatePoints(_ points: [HeartRatePoint], stepSeconds: Int) async throws
    func deleteHeartRateSamples(_ records: [HealthKitHeartRateSampleRecord]) async throws
}

@MainActor
protocol SyncPersisting {
    func checkpoints() throws -> SyncCheckpointState
    func setHeartRateCheckpoint(_ date: Date, resolution: Int) throws
    func setSleepCheckpoint(_ date: Date) throws
    func sleepRecord(for whoopSleepID: String) -> SleepSyncRecord?
    func upsertSleepRecord(session: SleepSession, fingerprint: String, result: String) throws
    func createRun(startedAt: Date, plan: IncrementalSyncPlan) throws -> UUID
    func createRejectedRun(startedAt: Date) throws -> UUID
    func finishRun(_ runID: UUID, summary: SyncSummary, status: String) throws
    func validateAccount(_ key: String) throws
    func deferredWindow(for type: String) throws -> TimeRange?
    func setDeferredWindow(_ window: TimeRange?, for type: String) throws
    func appendEvent(runID: UUID?, level: String, category: String, message: String) throws
}

extension SyncPersisting {
    func validateAccount(_ key: String) throws {}
    func deferredWindow(for type: String) throws -> TimeRange? { nil }
    func setDeferredWindow(_ window: TimeRange?, for type: String) throws {}
}
extension HealthDataProviding {
    func authorizedBoundary(for type: String) async throws -> Date? { nil }
}

extension WhoopAPIClient: WhoopAPIProviding {}
extension HealthKitService: HealthDataProviding {}
extension SyncRepository: SyncPersisting {}

@MainActor
final class SyncEngine {
    private let api: any WhoopAPIProviding
    private let healthKit: any HealthDataProviding
    private let repository: any SyncPersisting
    private let heartRateStepSeconds: Int
    private let heartRateFallbackStepSeconds: Int?
    private let requiresInitialHealthKitReadVisibility: Bool
    private let initialReadVisibilityLookbackDays: Int
    private let heartRateChunkSeconds: TimeInterval = 6 * 60 * 60
    private var isSynchronizing = false
    private var interruptedSummary = SyncSummary()
    private let recoveryPipeline: RecoverySyncPipeline?
    private var sleepBoundary: Date?
    private var heartRateBoundary: Date?

    init(
        api: any WhoopAPIProviding,
        healthKit: any HealthDataProviding,
        repository: any SyncPersisting,
        heartRateStepSeconds: Int = 6,
        heartRateFallbackStepSeconds: Int? = 60,
        requiresInitialHealthKitReadVisibility: Bool = false,
        initialReadVisibilityLookbackDays: Int = 30,
        recoveryPipeline: RecoverySyncPipeline? = nil
    ) {
        self.recoveryPipeline = recoveryPipeline
        self.api = api
        self.healthKit = healthKit
        self.repository = repository
        self.heartRateStepSeconds = heartRateStepSeconds
        self.heartRateFallbackStepSeconds = heartRateFallbackStepSeconds
        self.requiresInitialHealthKitReadVisibility = requiresInitialHealthKitReadVisibility
        self.initialReadVisibilityLookbackDays = initialReadVisibilityLookbackDays
    }

    func synchronize() async throws -> SyncSummary {
        try await synchronize(recoveryMode: .recent)
    }

    func synchronize(recoveryMode: RecoveryRunMode, resumeDeferred: Bool = true) async throws -> SyncSummary {
        guard !isSynchronizing else {
            AppLog.sync.warning("Rejected concurrent manual sync request.")
            throw SyncEngineError.syncAlreadyRunning
        }
        isSynchronizing = true
        defer {
            isSynchronizing = false
        }

        let startedAt = Date()
        var summary = SyncSummary()
        summary.effectiveHeartRateResolution = heartRateStepSeconds

        var activeRun: UUID?
        do {
            try Task.checkCancellation()
            let user = try await api.fetchCurrentUser()
            try Task.checkCancellation()
            try repository.validateAccount(WhoopRecovery.pseudonymousAccountKey(userID: user.id))
            let checkpoints = try repository.checkpoints()
            var plan = SyncWindowPlanner.makePlan(
                now: startedAt,
                checkpoints: checkpoints,
                heartRateStepSeconds: heartRateStepSeconds
            )
            if resumeDeferred {
                if let window = try repository.deferredWindow(for: "sleep") {
                    plan.sleepDiscoveryWindow.start = min(plan.sleepDiscoveryWindow.start, window.start)
                }
                if let window = try repository.deferredWindow(for: "heartRate") {
                    plan.heartRateWindow.start = min(plan.heartRateWindow.start, window.start)
                }
            }
            let sleepQueryWindow = SyncWindowPlanner.sleepQueryWindow(for: plan)
            summary.heartRateWindowStart = plan.heartRateWindow.start
            summary.heartRateWindowEnd = plan.heartRateWindow.end
            summary.sleepQueryWindowStart = sleepQueryWindow.start
            summary.sleepQueryWindowEnd = sleepQueryWindow.end

            let run = try repository.createRun(startedAt: startedAt, plan: plan)
            activeRun = run
            recordEvent(runID: run, level: "info", category: "sync", message: "Inicio manual. Ventana HR \(Self.iso(plan.heartRateWindow.start)) → \(Self.iso(plan.heartRateWindow.end)); ventana sueño \(Self.iso(sleepQueryWindow.start)) → \(Self.iso(sleepQueryWindow.end)).")
            AppLog.sync.info("Manual sync started. HR \(plan.heartRateWindow.start, privacy: .public)-\(plan.heartRateWindow.end, privacy: .public)")

            try Task.checkCancellation()
            sleepBoundary = try await healthKit.authorizedBoundary(for: "sleep")
            heartRateBoundary = try await healthKit.authorizedBoundary(for: "heartRate")
            try await validateHealthKitReadVisibility(plan: plan, runID: run)
            recordEvent(runID: run, level: "info", category: "api", message: "Usuario WHOOP autenticado; id recibido.")
            summary.merge(try await syncSleep(user: user, plan: plan, runID: run))
            interruptedSummary = SyncSummary()
            summary.merge(try await syncHeartRate(user: user, plan: plan, runID: run))
            interruptedSummary = SyncSummary()
            if let recoveryPipeline {
                do {
                    summary.recovery = try await recoveryPipeline.run(accountKey: WhoopRecovery.pseudonymousAccountKey(userID: user.id), mode: recoveryMode, maxPages: recoveryMode == .history ? Int.max : 20)
                    if [.readUnverified, .issues].contains(summary.recovery.status) {
                        summary.errors.append("Recovery HRV: " + summary.recovery.status.rawValue)
                    }
                } catch {
                    summary.recovery = recoveryPipeline.lastSummary
                    summary.recovery.status = .issues
                    if Self.isGlobalFailure(error) { throw error }
                    // Provider payloads and physiological values never enter operational logs.
                    summary.errors.append("Recovery HRV could not complete; validation or provider retry required.")
                }
            }
            summary.elapsedSeconds = Date().timeIntervalSince(startedAt)
            let status = summary.errors.isEmpty ? "success" : "partial"
            try repository.finishRun(run, summary: summary, status: status)
            recordEvent(runID: run, level: status == "success" ? "info" : "warning", category: "sync", message: "Fin de sync: \(status). Sueños descargados=\(summary.sleepsDownloaded), fases escritas=\(summary.stagesWritten), HR descargadas=\(summary.heartRateDownloaded), HR escritas=\(summary.heartRateWritten), errores=\(summary.errors.count).")
            AppLog.sync.info("Manual sync finished with status \(status, privacy: .public).")
            return summary
        } catch {
            summary.merge(interruptedSummary)
            interruptedSummary = SyncSummary()
            summary.elapsedSeconds = Date().timeIntervalSince(startedAt)
            summary.errors.append(Self.message(error))
            // Authentication/account failures are recorded without reading unvalidated checkpoints.
            let failedRun = activeRun ?? (try? repository.createRejectedRun(startedAt: startedAt))
            if let run = failedRun {
                try? repository.finishRun(run, summary: summary, status: error is CancellationError ? "cancelled" : "failed")
                recordEvent(runID: run, level: "error", category: "sync", message: "Sync fallida: \(Self.message(error))")
            }
            AppLog.sync.error("Manual sync failed: \(Self.message(error), privacy: .public)")
            throw error
        }
    }

    private func validateHealthKitReadVisibility(plan: IncrementalSyncPlan, runID: UUID) async throws {
        guard requiresInitialHealthKitReadVisibility else { return }

        var missingTypes: [String] = []
        let visibilityWindow = initialReadVisibilityWindow(for: plan)

        if plan.isFirstSleepSync {
            let samples = try await healthKit.querySleepSamples(from: min(max(visibilityWindow.start, sleepBoundary ?? .distantPast), visibilityWindow.end), to: visibilityWindow.end)
            let externalCount = samples.filter { !$0.existing.isOwnedByApp }.count
            recordEvent(
                runID: runID,
                level: externalCount > 0 ? "info" : "warning",
                category: "healthkit.read_preflight",
                message: "Preflight lectura sueño \(Self.iso(visibilityWindow.start)) → \(Self.iso(visibilityWindow.end)): \(samples.count) muestras visibles, externas=\(externalCount)."
            )
            if externalCount == 0 {
                missingTypes.append("Sleep Analysis")
            }
        } else {
            let samples = try await healthKit.querySleepSamples(from: min(max(visibilityWindow.start, sleepBoundary ?? .distantPast), visibilityWindow.end), to: visibilityWindow.end)
            recordEvent(
                runID: runID,
                level: samples.isEmpty ? "warning" : "info",
                category: "healthkit.read_guard",
                message: "Guardia lectura sueño \(Self.iso(visibilityWindow.start)) → \(Self.iso(visibilityWindow.end)): \(samples.count) muestras visibles."
            )
            if samples.isEmpty {
                missingTypes.append("Sleep Analysis")
            }
        }

        if plan.isFirstHeartRateSync {
            let samples = try await healthKit.queryHeartRateSamples(from: min(max(visibilityWindow.start, heartRateBoundary ?? .distantPast), visibilityWindow.end), to: visibilityWindow.end)
            let externalCount = samples.filter { !$0.existing.isOwnedByApp }.count
            recordEvent(
                runID: runID,
                level: externalCount > 0 ? "info" : "warning",
                category: "healthkit.read_preflight",
                message: "Preflight lectura HR \(Self.iso(visibilityWindow.start)) → \(Self.iso(visibilityWindow.end)): \(samples.count) muestras visibles, externas=\(externalCount)."
            )
            if externalCount == 0 {
                missingTypes.append("Heart Rate")
            }
        } else {
            let samples = try await healthKit.queryHeartRateSamples(from: min(max(visibilityWindow.start, heartRateBoundary ?? .distantPast), visibilityWindow.end), to: visibilityWindow.end)
            recordEvent(
                runID: runID,
                level: samples.isEmpty ? "warning" : "info",
                category: "healthkit.read_guard",
                message: "Guardia lectura HR \(Self.iso(visibilityWindow.start)) → \(Self.iso(visibilityWindow.end)): \(samples.count) muestras visibles."
            )
            if samples.isEmpty {
                missingTypes.append("Heart Rate")
            }
        }

        guard missingTypes.isEmpty else {
            throw SyncEngineError.healthKitReadVisibilityUnverified(missingTypes)
        }
    }

    private func initialReadVisibilityWindow(for plan: IncrementalSyncPlan) -> TimeRange {
        let lookback = max(initialReadVisibilityLookbackDays, 1)
        let start = plan.syncStartedAt.addingTimeInterval(-TimeInterval(lookback * 24 * 60 * 60))
        return TimeRange(start: start, end: plan.syncStartedAt)
    }

    private func syncSleep(user: WhoopUser, plan: IncrementalSyncPlan, runID: UUID) async throws -> SyncSummary {
        var summary = SyncSummary()
        defer { interruptedSummary = summary }
        var sleepHadErrors = false
        let sleepWindow = SyncWindowPlanner.sleepQueryWindow(for: plan)

        do {
            if let boundary = sleepBoundary, sleepWindow.start < boundary {
                try repository.setDeferredWindow(TimeRange(start: sleepWindow.start, end: min(boundary, sleepWindow.end)), for: "sleep")
            }
            let activities = try await api.fetchSleepActivities(userID: user.id, start: sleepWindow.start, end: sleepWindow.end)
            summary.sleepsDownloaded = activities.count
            recordEvent(runID: runID, level: "info", category: "sleep.api", message: "Descargados \(activities.count) IDs de sueño para \(Self.iso(sleepWindow.start)) → \(Self.iso(sleepWindow.end)).")
            AppLog.sleep.info("Downloaded \(activities.count) sleep activity IDs.")

            for activity in activities {
                do {
                    try Task.checkCancellation()
                    let session = try await api.fetchSleepSession(activity: activity)
                    guard TimeRange(start: session.start, end: session.end).overlaps(sleepWindow) else {
                        summary.sleepsDiscardedOutOfWindow += 1
                        recordEvent(runID: runID, level: "warning", category: "sleep.filter", message: "Sueño descartado fuera de ventana: \(session.whoopSleepID).")
                        AppLog.sleep.warning("Sleep \(session.whoopSleepID, privacy: .public) discarded because it is outside query window.")
                        continue
                    }

                    let fingerprint = SleepFingerprint.make(for: session)
                    let existingRecord = repository.sleepRecord(for: session.whoopSleepID)
                    let fingerprintChanged = existingRecord.map { $0.fingerprint != fingerprint } ?? false

                    let healthKitWindowStart = session.start.addingTimeInterval(-5 * 60)
                    let healthKitWindowEnd = session.end.addingTimeInterval(5 * 60)
                    if let boundary = sleepBoundary, healthKitWindowStart < boundary {
                        try repository.setDeferredWindow(TimeRange(start: healthKitWindowStart, end: healthKitWindowEnd), for: "sleep")
                        sleepHadErrors = true
                        summary.errors.append("Sleep interval deferred by historical access limit.")
                        continue
                    }
                    let existingSamples = try await healthKit.querySleepSamples(from: healthKitWindowStart, to: healthKitWindowEnd)
                    recordEvent(runID: runID, level: "info", category: "sleep.healthkit", message: "Leídas \(existingSamples.count) muestras HealthKit para sueño \(session.whoopSleepID).")
                    let reconciliation = SleepCoverageReconciler.plan(
                        session: session,
                        existingSamples: existingSamples.map(\.existing),
                        fingerprintChanged: fingerprintChanged
                    )

                    let deleteIDs = Set(reconciliation.ownSamplesToDelete.map(\.id))
                    let recordsToDelete = existingSamples.filter { deleteIDs.contains($0.existing.id) }
                    try Task.checkCancellation()
                    if let refreshed = try await healthKit.authorizedBoundary(for: "sleep"), healthKitWindowStart < refreshed {
                        try repository.setDeferredWindow(TimeRange(start: healthKitWindowStart, end: healthKitWindowEnd), for: "sleep")
                        sleepHadErrors = true
                        summary.errors.append("Sleep access changed before writing; interval deferred.")
                        continue
                    }
                    try await healthKit.deleteSleepSamples(recordsToDelete)
                    try await healthKit.saveSleepFragments(reconciliation.fragmentsToWrite)

                    summary.stagesRemoved += recordsToDelete.count
                    summary.stagesWritten += reconciliation.fragmentsToWrite.count
                    summary.stagesSkipped += reconciliation.skippedDetailedFragments
                    if fingerprintChanged {
                        summary.sleepsRevised += 1
                    }
                    if reconciliation.fragmentsToWrite.isEmpty && recordsToDelete.isEmpty && !fingerprintChanged {
                        summary.sleepsUnchanged += 1
                    } else {
                        summary.sleepsWritten += 1
                    }

                    let result = "written=\(reconciliation.fragmentsToWrite.count), skipped=\(reconciliation.skippedDetailedFragments), removed=\(recordsToDelete.count)"
                    try repository.upsertSleepRecord(session: session, fingerprint: fingerprint, result: result)
                    recordEvent(runID: runID, level: "info", category: "sleep.write", message: "Sueño \(session.whoopSleepID): \(result).")
                    AppLog.sleep.info("Sleep \(session.whoopSleepID, privacy: .public): \(result, privacy: .public)")
                } catch {
                    if Self.isGlobalFailure(error) {
                        throw error
                    }
                    sleepHadErrors = true
                    let message = "Sueño \(activity.activityID): \(Self.message(error))"
                    summary.errors.append(message)
                    recordEvent(runID: runID, level: "error", category: "sleep", message: message)
                    AppLog.sleep.error("\(message, privacy: .public)")
                }
            }

            if !sleepHadErrors {
                try Task.checkCancellation()
                if sleepBoundary.map({ sleepWindow.start >= $0 }) ?? true { try repository.setDeferredWindow(nil, for: "sleep") }
                try repository.setSleepCheckpoint(plan.sleepDiscoveryWindow.end)
                recordEvent(runID: runID, level: "info", category: "sleep.checkpoint", message: "Checkpoint de sueño actualizado a \(Self.iso(plan.sleepDiscoveryWindow.end)).")
            }
        } catch {
            if Self.isGlobalFailure(error) {
                throw error
            }
            summary.errors.append("Sueño: \(Self.message(error))")
            recordEvent(runID: runID, level: "error", category: "sleep", message: "Pipeline sueño falló: \(Self.message(error))")
            AppLog.sleep.error("Sleep pipeline failed: \(Self.message(error), privacy: .public)")
        }

        return summary
    }

    private func syncHeartRate(user: WhoopUser, plan: IncrementalSyncPlan, runID: UUID) async throws -> SyncSummary {
        var summary = SyncSummary()
        defer { interruptedSummary = summary }
        summary.effectiveHeartRateResolution = heartRateStepSeconds
        let chunks = SyncWindowPlanner.heartRateChunks(
            window: plan.heartRateWindow,
            maxChunkSeconds: heartRateChunkSeconds
        )
        guard !chunks.isEmpty else { return summary }

        var activeStepSeconds = heartRateStepSeconds
        for chunk in chunks {
            do {
                try Task.checkCancellation()
                let fetch = try await fetchHeartRateWithFallback(
                    userID: user.id,
                    chunk: chunk,
                    preferredStepSeconds: activeStepSeconds,
                    runID: runID
                )
                activeStepSeconds = fetch.stepSeconds
                summary.effectiveHeartRateResolution = activeStepSeconds
                let rawPoints = fetch.points
                summary.heartRateDownloaded += rawPoints.count
                let pointsInChunk = rawPoints.filter { point in
                    point.timestamp >= chunk.start && point.timestamp < chunk.end
                }
                let discarded = rawPoints.count - pointsInChunk.count
                summary.heartRateDiscardedOutOfWindow += discarded
                if discarded > 0 {
                    recordEvent(runID: runID, level: "warning", category: "hr.filter", message: "Descartadas \(discarded) muestras HR fuera del chunk \(Self.iso(chunk.start)) → \(Self.iso(chunk.end)).")
                    AppLog.heartRate.warning("Discarded \(discarded) HR points outside chunk \(chunk.start, privacy: .public)-\(chunk.end, privacy: .public).")
                }
                let points = pointsInChunk.filter { point in
                    heartRateBoundary.map { HeartRateCoverageReconciler.bucket(for: point, stepSeconds: activeStepSeconds, semantics: .bucketStart).start >= $0 } ?? true
                }
                if let boundary = heartRateBoundary, chunk.start < boundary {
                    try repository.setDeferredWindow(TimeRange(start: chunk.start, end: min(chunk.end, boundary)), for: "heartRate")
                }
                if chunk.end <= (heartRateBoundary ?? .distantPast) {
                    if !summary.errors.contains("Heart-rate history is limited; earlier intervals remain pending.") {
                        summary.errors.append("Heart-rate history is limited; earlier intervals remain pending.")
                    }
                    continue
                }
                recordEvent(runID: runID, level: "info", category: "hr.api", message: "Chunk HR \(Self.iso(chunk.start)) → \(Self.iso(chunk.end)): \(rawPoints.count) descargadas, \(points.count) dentro, resolución \(activeStepSeconds)s.")
                AppLog.heartRate.info("Downloaded \(rawPoints.count) HR points for chunk \(chunk.start, privacy: .public)-\(chunk.end, privacy: .public); \(points.count) inside chunk.")

                let healthKitStart = max(chunk.start.addingTimeInterval(-TimeInterval(activeStepSeconds)), heartRateBoundary ?? .distantPast)
                let healthKitEnd = chunk.end.addingTimeInterval(TimeInterval(activeStepSeconds))
                let existingSamples = try await healthKit.queryHeartRateSamples(from: healthKitStart, to: healthKitEnd)
                recordEvent(runID: runID, level: "info", category: "hr.healthkit", message: "Leídas \(existingSamples.count) muestras HR de HealthKit para chunk.")
                let reconciliation = HeartRateCoverageReconciler.plan(
                    points: points,
                    existingSamples: existingSamples.map(\.existing),
                    stepSeconds: activeStepSeconds,
                    semantics: .bucketStart
                )

                let deleteIDs = Set(reconciliation.ownSamplesToDelete.map(\.id))
                let recordsToDelete = existingSamples.filter { record in
                    deleteIDs.contains(record.existing.id) && (heartRateBoundary.map { record.existing.range.start >= $0 } ?? true)
                }
                try Task.checkCancellation()
                let refreshed = try await healthKit.authorizedBoundary(for: "heartRate")
                if let refreshed, refreshed > (heartRateBoundary ?? .distantPast) {
                    try repository.setDeferredWindow(chunk, for: "heartRate")
                    summary.errors.append("Heart-rate access changed before writing; chunk deferred.")
                    return summary
                }
                try await healthKit.deleteHeartRateSamples(recordsToDelete)
                try await healthKit.saveHeartRatePoints(reconciliation.pointsToWrite, stepSeconds: activeStepSeconds)

                summary.heartRateRemoved += recordsToDelete.count
                summary.heartRateWritten += reconciliation.pointsToWrite.count
                summary.heartRateSkipped += reconciliation.skippedPointCount
                try repository.setHeartRateCheckpoint(chunk.end, resolution: activeStepSeconds)
                recordEvent(runID: runID, level: "info", category: "hr.write", message: "Chunk HR: escritas=\(reconciliation.pointsToWrite.count), omitidas=\(reconciliation.skippedPointCount), eliminadas=\(recordsToDelete.count), checkpoint=\(Self.iso(chunk.end)).")
            } catch {
                if Self.isGlobalFailure(error) {
                    throw error
                }
                let message = "Frecuencia cardiaca \(WhoopAPIClient.isoString(chunk.start))-\(WhoopAPIClient.isoString(chunk.end)): \(Self.message(error))"
                summary.errors.append(message)
                recordEvent(runID: runID, level: "error", category: "hr", message: message)
                AppLog.heartRate.error("\(message, privacy: .public)")
                return summary
            }
        }

        if heartRateBoundary.map({ plan.heartRateWindow.start >= $0 }) ?? true {
            try repository.setDeferredWindow(nil, for: "heartRate")
        }
        return summary
    }

    private func fetchHeartRateWithFallback(
        userID: String,
        chunk: TimeRange,
        preferredStepSeconds: Int,
        runID: UUID
    ) async throws -> (points: [HeartRatePoint], stepSeconds: Int) {
        do {
            let points = try await api.fetchHeartRate(
                userID: userID,
                start: chunk.start,
                end: chunk.end,
                stepSeconds: preferredStepSeconds
            )
            return (points, preferredStepSeconds)
        } catch {
            guard
                let fallback = heartRateFallbackStepSeconds,
                fallback != preferredStepSeconds,
                Self.shouldFallbackHeartRateResolution(for: error)
            else {
                throw error
            }

            AppLog.heartRate.warning("HR step \(preferredStepSeconds, privacy: .public)s rejected; retrying with \(fallback, privacy: .public)s.")
            recordEvent(runID: runID, level: "warning", category: "hr.api", message: "Resolución HR \(preferredStepSeconds)s rechazada; reintentando con \(fallback)s.")
            let points = try await api.fetchHeartRate(
                userID: userID,
                start: chunk.start,
                end: chunk.end,
                stepSeconds: fallback
            )
            return (points, fallback)
        }
    }

    private static func shouldFallbackHeartRateResolution(for error: Error) -> Bool {
        guard let apiError = error as? WhoopAPIError else {
            return false
        }
        switch apiError {
        case let .http(status, _, _):
            return [400, 404, 422].contains(status)
        case .invalidURL, .invalidHTTPResponse:
            return false
        }
    }

    private static func isGlobalFailure(_ error: Error) -> Bool {
        error is CancellationError || error is SyncRepositoryError || error as? RecoverySyncError == .accountMismatch || isAuthenticationFailure(error)
    }

    static func isAuthenticationFailure(_ error: Error) -> Bool {
        if error is WhoopAuthError {
            return true
        }
        if let apiError = error as? WhoopAPIError {
            switch apiError {
            case let .http(status, _, _):
                return status == 401 || status == 403
            case .invalidURL, .invalidHTTPResponse:
                return false
            }
        }
        return false
    }

    private static func message(_ error: Error) -> String {
        let rawMessage: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            rawMessage = description
        } else {
            rawMessage = error.localizedDescription
        }
        return SensitiveTextSanitizer.redact(rawMessage)
    }

    private func recordEvent(runID: UUID?, level: String, category: String, message: String) {
        try? repository.appendEvent(runID: runID, level: level, category: category, message: message)
    }

    private static func iso(_ date: Date) -> String {
        WhoopDateCodec.isoString(date)
    }
}

enum SyncEngineError: Error, Equatable, LocalizedError {
    case syncAlreadyRunning
    case healthKitReadVisibilityUnverified([String])

    var errorDescription: String? {
        switch self {
        case .syncAlreadyRunning:
            return "A manual sync is already running."
        case let .healthKitReadVisibilityUnverified(types):
            return "HealthKit read visibility could not be verified for \(types.joined(separator: ", ")). Sync stopped before writing to avoid duplicates; confirm Apple Health read access and existing samples are visible."
        }
    }
}
