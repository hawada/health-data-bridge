import Foundation
import WHOOPHealthSyncCore
#if os(iOS)
import UIKit
#endif

@MainActor
final class LiveSyncRuntime {
    static let shared = LiveSyncRuntime()

    let authService: WhoopAuthService
    let repository: SyncRepository
    let preferredHeartRateStepSeconds: Int

    private let api: WhoopAPIClient
    private let healthKitService: HealthKitService
    private var syncInProgress = false
    private let recoveryAdapter: HealthKitRecoveryAdapter
    private let recoveryPipeline: RecoverySyncPipeline
    private let syncEngine: SyncEngine

    private init() {
        let tokenStore = KeychainTokenStore()
        let authService = WhoopAuthService(tokenStore: tokenStore)
        let apiConfiguration = WhoopPrivateAPIConfiguration()
        let api = WhoopAPIClient(auth: authService, configuration: apiConfiguration)
        let healthKitService = HealthKitService()
        let repository = SyncRepository()

        self.api = api
        self.authService = authService
        self.healthKitService = healthKitService
        self.repository = repository
        self.preferredHeartRateStepSeconds = apiConfiguration.preferredHeartRateStepSeconds
        let recoveryAdapter = HealthKitRecoveryAdapter(manualConfirmation: { (try? repository.recoveryState().userConfirmedFullReadAccess) == true }, officialBundle: { try? repository.recoveryState().officialWhoopBundle })
        self.recoveryAdapter = recoveryAdapter
        let provider = WhoopPrivateRecoveryProvider(currentUserID: { try await api.fetchCurrentUser().id }, fetch: { id, window in
            try await api.fetchRecoveryCycleRecords(userID: id, window: window)
        }, state: { try repository.recoveryState() }, commitState: { try repository.commitRecoveryState($0) })
        let recoveryPipeline = RecoverySyncPipeline(provider: provider, health: recoveryAdapter, persistence: repository, appBundle: "com.joselourido.WHOOPHealthSync", canContinueHistory: {
            #if os(iOS)
            return UIApplication.shared.applicationState == .active
            #else
            return true
            #endif
        }, canContinueSync: {
            if case .authenticated = authService.currentStatus() { return true }; return false
        })
        self.recoveryPipeline = recoveryPipeline
        self.syncEngine = SyncEngine(
            api: api,
            healthKit: healthKitService,
            repository: repository,
            heartRateStepSeconds: apiConfiguration.preferredHeartRateStepSeconds,
            requiresInitialHealthKitReadVisibility: true,
            recoveryPipeline: recoveryPipeline
        )
    }

    var recoveryProgressChanged: ((RecoverySyncState, RecoverySyncSummary) -> Void)? {
        get { recoveryPipeline.progressChanged }
        set { recoveryPipeline.progressChanged = newValue }
    }
    var recoveryAvailable: Bool { recoveryAdapter.supported }
    func authorizeRecovery() async throws -> RecoveryAuthorization {
        guard !syncInProgress else { throw RecoverySyncError.unavailable }
        syncInProgress = true; defer { syncInProgress = false }
        var saved = try repository.recoveryState()
        saved.enabled = false; saved.userConfirmedFullReadAccess = false
        try repository.commitRecoveryState(saved)
        try await recoveryAdapter.requestAuthorization()
        let access = try await recoveryAdapter.readAccess()
        let sources = (try? await recoveryAdapter.observedWhoopSources()) ?? []
        return RecoveryAuthorization(sources: sources, access: access)
    }
    func configureRecovery(start: Date, fullReadConfirmed: Bool, whoopBundle: String?) async throws {
        guard !syncInProgress else { throw RecoverySyncError.unavailable }
        syncInProgress = true; defer { syncInProgress = false }
        guard case let .authenticated(email) = authService.currentStatus() else { throw AutomatedSyncError.whoopNotConnected }
        let user = try await api.fetchCurrentUser()
        let key = WhoopRecovery.pseudonymousAccountKey(userID: user.id)
        try repository.validateAccount(key)
        guard case let .authenticated(current) = authService.currentStatus(), current == email else { throw RecoverySyncError.accountMismatch }
        guard start < Date(), HKRecoverySetup.validBundle(whoopBundle) else { throw RecoverySyncError.invalidRecord }
        let setupAdapter = HealthKitRecoveryAdapter(manualConfirmation: { fullReadConfirmed }, officialBundle: { whoopBundle })
        let access = try await setupAdapter.readAccess()
        guard access != .unknown else { throw RecoverySyncError.readUnverified }
        guard case let .authenticated(afterAuthorization) = authService.currentStatus(), afterAuthorization == email else { throw RecoverySyncError.accountMismatch }
        var state = try repository.recoveryState()
        if state.historyStartDate != start {
            state.historicalCursor = nil; state.initialEnumerationComplete = false; state.historicalPagesConfirmed = 0
            state.confirmedCursorFingerprints = []; state.initialImportCutoff = nil
        }
        state.accountKey = key; state.historyStartDate = start
        state.userConfirmedFullReadAccess = fullReadConfirmed; state.officialWhoopBundle = whoopBundle
        state.historyScopeLimited = true; state.pausedForNativeExport = false
        state.enabled = true; state.configured = true
        try repository.commitRecoveryState(state)
        if case let .nativeExporter(bundle) = access {
            state.officialWhoopBundle = bundle; state.pausedForNativeExport = true
            try repository.commitRecoveryState(state)
        }
    }

    func requestHealthKitAuthorization() async throws {
        try await healthKitService.requestAuthorization()
    }

    func synchronize() async throws -> SyncSummary {
        guard !syncInProgress else { throw RecoverySyncError.unavailable }
        syncInProgress = true; defer { syncInProgress = false }
        return try await syncEngine.synchronize()
    }

    func probeExistingCyclesSchema() async throws -> String {
        try await api.probeExistingCyclesSchema()
    }

    func probeRecoveryValues() async throws -> String {
        try await api.probeRecoveryValues()
    }

    func importRecoveryHistory() async throws -> SyncSummary {
        guard !syncInProgress else { throw RecoverySyncError.unavailable }
        syncInProgress = true; defer { syncInProgress = false }
        let started = Date()
        let user = try await api.fetchCurrentUser()
        let key = WhoopRecovery.pseudonymousAccountKey(userID: user.id)
        try repository.validateAccount(key)
        let run = try repository.createRejectedRun(startedAt: started)
        var summary = SyncSummary()
        do {
            summary.recovery = try await recoveryPipeline.run(accountKey: key, mode: .history, maxPages: Int.max)
            summary.elapsedSeconds = Date().timeIntervalSince(started)
            try repository.finishRun(run, summary: summary, status: "success")
            return summary
        } catch {
            summary.recovery = recoveryPipeline.lastSummary; summary.recovery.status = .issues
            summary.elapsedSeconds = Date().timeIntervalSince(started)
            summary.errors = [SensitiveTextSanitizer.redact(error.localizedDescription)]
            try? repository.finishRun(run, summary: summary, status: error is CancellationError ? "cancelled" : "failed")
            throw error
        }
    }

    func bindCurrentAccountManually() async throws {
        guard case let .authenticated(email) = authService.currentStatus() else { throw AutomatedSyncError.whoopNotConnected }
        let user = try await api.fetchCurrentUser()
        try Task.checkCancellation()
        guard case let .authenticated(currentEmail) = authService.currentStatus(), currentEmail == email else { throw RecoverySyncError.accountMismatch }
        try repository.bindAccountManually(WhoopRecovery.pseudonymousAccountKey(userID: user.id))
    }

    func synchronizeFromAutomation() async throws -> SyncSummary {
        guard !syncInProgress else { throw RecoverySyncError.unavailable }
        syncInProgress = true; defer { syncInProgress = false }
        guard case .authenticated = authService.currentStatus() else {
            throw AutomatedSyncError.whoopNotConnected
        }

        guard !repository.requiresManualAccountBinding else { throw SyncRepositoryError.accountBindingRequired }
        let checkpoints = try repository.checkpoints()
        guard checkpoints.lastSleepQueryEnd != nil, checkpoints.lastHeartRateEnd != nil else {
            throw AutomatedSyncError.initialManualSyncRequired
        }

        try healthKitService.validateExistingAuthorization()
        return try await syncEngine.synchronize(recoveryMode: .recent, resumeDeferred: false)
    }
}

enum AutomatedSyncError: Error, LocalizedError {
    case whoopNotConnected
    case initialManualSyncRequired

    var errorDescription: String? {
        switch self {
        case .whoopNotConnected:
            return "Abre HealthDataBridge y conecta tu cuenta antes de ejecutar la automatización."
        case .initialManualSyncRequired:
            return "Completa una primera sincronización manual en HealthDataBridge antes de activar la automatización."
        }
    }
}

private enum HKRecoverySetup {
    static func validBundle(_ bundle: String?) -> Bool {
        guard let bundle else { return true }
        return bundle.range(of: "^[A-Za-z0-9.-]{1,200}$", options: .regularExpression) != nil
    }
}
