import Foundation
import WHOOPHealthSyncCore

protocol HealthKitAuthorizing {
    func requestAuthorization() async throws
}

@MainActor
protocol AccountBindingProviding {
    func bindCurrentAccountManually() async throws
}

extension LiveSyncRuntime: AccountBindingProviding {}

@MainActor protocol RecoveryConfiguring {
    var recoveryAvailable: Bool { get }
    func authorizeRecovery() async throws -> RecoveryAuthorization
    func configureRecovery(start: Date, fullReadConfirmed: Bool, whoopBundle: String?) async throws
    func importRecoveryHistory() async throws -> SyncSummary
}
extension LiveSyncRuntime: RecoveryConfiguring {}

protocol SyncRunning {
    func synchronize() async throws -> SyncSummary
}

extension HealthKitService: HealthKitAuthorizing {}
extension SyncEngine: SyncRunning {}
extension LiveSyncRuntime: HealthKitAuthorizing {
    func requestAuthorization() async throws {
        try await requestHealthKitAuthorization()
    }
}
extension LiveSyncRuntime: SyncRunning {}

struct NextSyncPreview: Equatable {
    var sleepWindowStart: Date
    var sleepWindowEnd: Date
    var heartRateWindowStart: Date
    var heartRateWindowEnd: Date
    var isFirstSleepSync: Bool
    var isFirstHeartRateSync: Bool
}

@MainActor
final class SyncViewModel: ObservableObject {
    @Published var authStatus: AuthStatus = .disconnected
    @Published var isSyncing = false
    @Published var isAuthenticating = false
    @Published var lastSummary: SyncSummary?
    @Published var diagnostics: SyncDiagnostics = .empty
    @Published var recoveryState = RecoverySyncState()
    @Published var recoveryProbeText: String = ""
    @Published var requiresAccountBinding = false
    @Published var isBindingAccount = false
    @Published var errors: [String] = []
    @Published var events: [String] = []

    private var authService: WhoopAuthService?
    private var healthKitService: (any HealthKitAuthorizing)?
    private var repository: SyncRepository?
    private var syncEngine: (any SyncRunning)?
    private var activeSyncTask: Task<SyncSummary, Error>?
    private var recoveryConfigurator: (any RecoveryConfiguring)?
    private var accountBinder: (any AccountBindingProviding)?
    private var isConfigured = false
    private var preferredHeartRateStepSeconds: Int

    init(
        authService: WhoopAuthService? = nil,
        healthKitService: (any HealthKitAuthorizing)? = nil,
        repository: SyncRepository? = nil,
        syncEngine: (any SyncRunning)? = nil,
        accountBinder: (any AccountBindingProviding)? = nil,
        recoveryConfigurator: (any RecoveryConfiguring)? = nil,
        initialAuthStatus: AuthStatus = .disconnected,
        preferredHeartRateStepSeconds: Int = 6
    ) {
        self.recoveryConfigurator = recoveryConfigurator
        self.accountBinder = accountBinder
        self.authService = authService
        self.healthKitService = healthKitService
        self.repository = repository
        self.syncEngine = syncEngine
        self.authStatus = initialAuthStatus
        self.preferredHeartRateStepSeconds = preferredHeartRateStepSeconds
        self.isConfigured = authService != nil || healthKitService != nil || repository != nil || syncEngine != nil || accountBinder != nil || recoveryConfigurator != nil
    }

    func configure() {
        guard !isConfigured else {
            refreshDiagnostics()
            return
        }
        #if targetEnvironment(simulator) && WHOOP_VALIDATION_BUILD && WHOOP_IOS27_SDK
        if #available(iOS 27, *), ProcessInfo.processInfo.arguments.contains("-whoopRecoveryUITest"),
           ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("WHOOP 0.2 QA") == true {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-ui-fixture")
            try? FileManager.default.removeItem(at: directory)
            let repository = SyncRepository(fileURL: directory.appendingPathComponent("sync-store.json"))
            try? repository.bindAccountManually("isolated-ui-account")
            self.repository = repository
            self.recoveryConfigurator = IsolatedRecoveryUIFixture(repository: repository)
            self.authStatus = .authenticated(email: "simulator@example.invalid")
            self.isConfigured = true; refreshDiagnostics(); return
        }
        #endif
        let runtime = LiveSyncRuntime.shared

        self.recoveryConfigurator = runtime
        runtime.recoveryProgressChanged = { [weak self] state, summary in
            self?.recoveryState = state; self?.recoveryProgress = summary
        }
        self.accountBinder = runtime
        self.authService = runtime.authService
        self.healthKitService = runtime
        self.repository = runtime.repository
        self.preferredHeartRateStepSeconds = runtime.preferredHeartRateStepSeconds
        self.syncEngine = runtime
        self.authStatus = runtime.authService.currentStatus()
        self.isConfigured = true
        refreshDiagnostics()
        appendEvent("Aplicacion inicializada.")
    }

    func signIn(email: String, password: String) async {
        guard !isSyncing, !isConfiguringRecovery, let authService else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let step = try await authService.signIn(email: email, password: password)
            switch step {
            case let .authenticated(bundle):
                authStatus = .authenticated(email: bundle.email)
                appendEvent("WHOOP autenticado.")
            case let .challenge(challenge):
                authStatus = .mfaRequired(challengeName: challenge.challengeName, destination: challenge.destination)
                appendEvent("WHOOP solicita MFA: \(challenge.challengeName).")
            }
        } catch {
            let message = Self.message(error)
            authStatus = .reconnectRequired(reason: message)
            errors.append(message)
        }
    }

    func submitMFA(code: String) async {
        guard !isSyncing, !isConfiguringRecovery, let authService else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let bundle = try await authService.respondToChallenge(code: code)
            authStatus = .authenticated(email: bundle.email)
            appendEvent("MFA completado.")
        } catch {
            let message = Self.message(error)
            errors.append(message)
            authStatus = .reconnectRequired(reason: message)
        }
    }

    func disconnect() {
        activeSyncTask?.cancel()
        do {
            try authService?.disconnect()
            authStatus = .disconnected
            appendEvent("Sesion WHOOP eliminada del Keychain.")
        } catch {
            errors.append(Self.message(error))
        }
    }

    func synchronize() async {
        guard let healthKitService, let syncEngine else { return }
        guard !isSyncing, !isBindingAccount, !isConfiguringRecovery, !isProbingRecovery else {
            appendEvent("Sincronizacion ignorada: ya hay una sincronizacion en curso.")
            return
        }
        guard case .authenticated = authStatus else {
            errors.append("Conecta WHOOP antes de sincronizar.")
            return
        }

        do { try repository?.ensureUsable() }
        catch { errors = [Self.message(error)]; return }
        guard repository?.requiresManualAccountBinding != true else {
            errors = [Self.message(SyncRepositoryError.accountBindingRequired)]
            refreshDiagnostics()
            return
        }
        isSyncing = true
        errors.removeAll()
        lastSummary = nil
        appendEvent("Sincronizacion manual iniciada.")
        defer {
            isSyncing = false
            refreshDiagnostics()
        }

        do {
            let task = Task { @MainActor in
                try await healthKitService.requestAuthorization()
                try Task.checkCancellation()
                return try await syncEngine.synchronize()
            }
            activeSyncTask = task
            defer { activeSyncTask = nil }
            let summary = try await task.value
            lastSummary = summary
            errors = summary.errors.map(SensitiveTextSanitizer.redact)
            appendEvent("Sincronizacion terminada en \(String(format: "%.1f", summary.elapsedSeconds)) s.")
        } catch {
            let message = Self.message(error)
            if Self.requiresReconnect(error) {
                authStatus = .reconnectRequired(reason: message)
            }
            errors.append(message)
            appendEvent("Sincronizacion fallida: \(message)")
        }
    }

    func nextSyncPreview(now: Date = Date()) -> NextSyncPreview {
        let checkpoints = SyncCheckpointState(
            lastHeartRateEnd: diagnostics.lastHeartRateCheckpoint,
            lastSleepQueryEnd: diagnostics.lastSleepCheckpoint,
            lastHeartRateResolution: diagnostics.heartRateResolution
        )
        let plan = SyncWindowPlanner.makePlan(
            now: now,
            checkpoints: checkpoints,
            heartRateStepSeconds: preferredHeartRateStepSeconds
        )
        let sleepWindow = SyncWindowPlanner.sleepQueryWindow(for: plan)
        return NextSyncPreview(
            sleepWindowStart: sleepWindow.start,
            sleepWindowEnd: sleepWindow.end,
            heartRateWindowStart: plan.heartRateWindow.start,
            heartRateWindowEnd: plan.heartRateWindow.end,
            isFirstSleepSync: plan.isFirstSleepSync,
            isFirstHeartRateSync: plan.isFirstHeartRateSync
        )
    }

    func diagnosticsReport() -> String {
        let preview = nextSyncPreview()
        var lines: [String] = [
            "HealthDataBridge Diagnostics",
            "Generated: \(Self.iso(Date()))",
            "Auth status: \(Self.authStatusDescription(authStatus))",
            "",
            "Local progress:",
            "- Sleep checkpoint: \(Self.isoOrDash(diagnostics.lastSleepCheckpoint))",
            "- Heart-rate checkpoint: \(Self.isoOrDash(diagnostics.lastHeartRateCheckpoint))",
            "- Heart-rate resolution: \(diagnostics.heartRateResolution.map { "\($0) s" } ?? "-")",
            "- Last run started: \(Self.isoOrDash(diagnostics.lastRunStartedAt))",
            "- Last run finished: \(Self.isoOrDash(diagnostics.lastRunFinishedAt))",
            "- Last run status: \(diagnostics.lastRunStatus ?? "-")",
            "- Last run errors: \(diagnostics.lastRunErrorsText.isEmpty ? "-" : SensitiveTextSanitizer.redact(diagnostics.lastRunErrorsText))",
            "- Recorded sleep count: \(diagnostics.recordedSleepCount)",
            "",
            "Next sync preview:",
            "- Sleep window: \(Self.iso(preview.sleepWindowStart)) -> \(Self.iso(preview.sleepWindowEnd))",
            "- Heart-rate window: \(Self.iso(preview.heartRateWindowStart)) -> \(Self.iso(preview.heartRateWindowEnd))",
            "- First sleep sync: \(preview.isFirstSleepSync)",
            "- First heart-rate sync: \(preview.isFirstHeartRateSync)"
        ]

        if let summary = lastSummary {
            lines.append(contentsOf: [
                "",
                "Visible summary:",
                "- Sleeps downloaded: \(summary.sleepsDownloaded)",
                "- Sleeps written: \(summary.sleepsWritten)",
                "- Sleeps unchanged: \(summary.sleepsUnchanged)",
                "- Sleeps revised: \(summary.sleepsRevised)",
                "- Sleeps discarded out of window: \(summary.sleepsDiscardedOutOfWindow)",
                "- Stages written: \(summary.stagesWritten)",
                "- Stages skipped: \(summary.stagesSkipped)",
                "- Stages removed: \(summary.stagesRemoved)",
                "- HR downloaded: \(summary.heartRateDownloaded)",
                "- HR written: \(summary.heartRateWritten)",
                "- HR skipped: \(summary.heartRateSkipped)",
                "- HR removed: \(summary.heartRateRemoved)",
                "- HR discarded out of window: \(summary.heartRateDiscardedOutOfWindow)",
                "- Effective HR resolution: \(summary.effectiveHeartRateResolution.map { "\($0) s" } ?? "-")",
                "- Sleep window: \(Self.isoOrDash(summary.sleepQueryWindowStart)) -> \(Self.isoOrDash(summary.sleepQueryWindowEnd))",
                "- HR window: \(Self.isoOrDash(summary.heartRateWindowStart)) -> \(Self.isoOrDash(summary.heartRateWindowEnd))",
                "- Elapsed seconds: \(String(format: "%.1f", summary.elapsedSeconds))",
                "- Summary errors: \(summary.errors.count)"
            ])
        } else {
            lines.append(contentsOf: ["", "Visible summary: -"])
        }

        if !errors.isEmpty {
            lines.append("")
            lines.append("Current errors:")
            lines.append(contentsOf: errors.map { "- \(SensitiveTextSanitizer.redact($0))" })
        }

        if !events.isEmpty {
            lines.append("")
            lines.append("Session events:")
            lines.append(contentsOf: events.prefix(20).map { "- \(SensitiveTextSanitizer.redact($0))" })
        }

        if !diagnostics.recentEvents.isEmpty {
            lines.append("")
            lines.append("Persistent events:")
            lines.append(contentsOf: diagnostics.recentEvents.prefix(50).map {
                "- \(Self.iso($0.timestamp)) [\($0.level.uppercased())/\($0.category)] \(SensitiveTextSanitizer.redact($0.message))"
            })
        }

        return lines.joined(separator: "\n")
    }

    var recoveryStatusKey: String {
        #if os(iOS)
        if #unavailable(iOS 27) { return "Requires iOS 27" }
        #endif
        if !recoveryState.enabled { return "Disabled" }
        if recoveryState.pausedForNativeExport { return "Paused: WHOOP already exports HRV" }
        if !recoveryState.configured { return "Configuration pending" }
        if recoveryState.historicalResolved { return recoveryState.historyScopeLimited ? "Indicated history imported" : "Completed" }
        if recoveryState.pendingItems.values.contains(where: { $0.reason == "access" }) { return "Partial history: Health access pending" }
        if recoveryState.pendingItems.values.contains(where: { $0.requiresManualReview(at: Date()) }) { return "History pending manual review" }
        if recoveryState.initialImportCutoff != nil { return "History pending continuation" }
        return "Ready to sync"
    }

    func probeRecoverySchema() async {
        guard !isProbingRecovery, !isSyncing, !isAuthenticating, !isConfiguringRecovery else { return }
        isProbingRecovery = true
        defer { isProbingRecovery = false }
        do { recoveryProbeText = try await LiveSyncRuntime.shared.probeExistingCyclesSchema() }
        catch { recoveryProbeText = "Recovery contract probe could not complete; reconnect WHOOP or retry." }
    }

    @Published private(set) var isProbingRecovery = false

    func probeRecoveryValues() async {
        guard !isProbingRecovery, !isSyncing, !isAuthenticating, !isConfiguringRecovery else { return }
        isProbingRecovery = true
        recoveryProbeText = String(localized: "Reading recovery values…")
        defer { isProbingRecovery = false }
        do { recoveryProbeText = try await LiveSyncRuntime.shared.probeRecoveryValues() }
        catch { recoveryProbeText = String(localized: "Recovery value probe could not complete; retry. No health data was written.") }
    }

    @Published private(set) var isConfiguringRecovery = false
    @Published private(set) var recoveryAuthorization: RecoveryAuthorization?
    @Published private(set) var recoveryProgress = RecoverySyncSummary()
    var supportsRecovery: Bool { recoveryConfigurator?.recoveryAvailable == true }
    var canConfigureRecovery: Bool {
        if case .authenticated = authStatus { return supportsRecovery && !isSyncing && !isAuthenticating && !isBindingAccount && !isProbingRecovery && !isConfiguringRecovery }
        return false
    }
    var canImportRecovery: Bool {
        canConfigureRecovery && recoveryState.enabled && recoveryState.configured && !requiresAccountBinding && !recoveryState.pausedForNativeExport
    }
    func authorizeRecovery() async {
        guard canConfigureRecovery, let recoveryConfigurator else { return }
        isConfiguringRecovery = true; recoveryAuthorization = nil
        defer { isConfiguringRecovery = false; refreshDiagnostics() }
        do { recoveryAuthorization = try await recoveryConfigurator.authorizeRecovery() }
        catch { errors.append(Self.message(error)) }
    }
    func enableRecovery(start: Date, fullReadConfirmed: Bool, whoopBundle: String?) async -> Bool {
        guard canConfigureRecovery, !requiresAccountBinding, recoveryAuthorization != nil, let recoveryConfigurator else { return false }
        isConfiguringRecovery = true
        defer { isConfiguringRecovery = false; refreshDiagnostics() }
        do {
            try await recoveryConfigurator.configureRecovery(start: start, fullReadConfirmed: fullReadConfirmed, whoopBundle: whoopBundle)
            return true
        } catch { errors.append(Self.message(error)); return false }
    }
    func importRecoveryHistory() async {
        guard canImportRecovery, let recoveryConfigurator else { return }
        isSyncing = true; errors.removeAll(); lastSummary = nil; recoveryProgress = RecoverySyncSummary()
        defer { isSyncing = false; activeSyncTask = nil; refreshDiagnostics() }
        let task = Task { @MainActor in try await recoveryConfigurator.importRecoveryHistory() }
        activeSyncTask = task
        do { lastSummary = try await task.value }
        catch {
            if Self.requiresReconnect(error) { authStatus = .reconnectRequired(reason: Self.message(error)) }
            if !(error is CancellationError) { errors.append(Self.message(error)) }
        }
    }
    func cancelRecoveryImport() { activeSyncTask?.cancel() }

    func disableRecovery() {
        activeSyncTask?.cancel()
        guard let repository else { return }
        do {
            var state = try repository.recoveryState(); state.enabled = false
            try repository.commitRecoveryState(state)
            refreshDiagnostics()
        } catch { errors.append(Self.message(error)) }
    }

    func confirmExistingAccount() async {
        guard let accountBinder, !isSyncing, !isAuthenticating, !isBindingAccount else { return }
        guard case .authenticated = authStatus else { return }
        isBindingAccount = true
        defer { isBindingAccount = false; refreshDiagnostics() }
        do {
            try await accountBinder.bindCurrentAccountManually()
            errors.removeAll()
            appendEvent("Saved sync progress account confirmed.")
        } catch {
            let message = Self.message(error)
            if Self.requiresReconnect(error) { authStatus = .reconnectRequired(reason: message) }
            errors.append(message)
        }
    }

    private func refreshDiagnostics() {
        requiresAccountBinding = repository?.requiresManualAccountBinding ?? false
        diagnostics = repository?.diagnostics() ?? .empty
        recoveryState = (try? repository?.recoveryState()) ?? RecoverySyncState()
        if repository?.loadError != nil, errors.isEmpty { errors.append("Local sync data unavailable; synchronization is blocked.") }
    }

    private func appendEvent(_ event: String) {
        events.insert(SensitiveTextSanitizer.redact(event), at: 0)
        if events.count > 100 {
            events.removeLast(events.count - 100)
        }
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

    private static func requiresReconnect(_ error: Error) -> Bool {
        SyncEngine.isAuthenticationFailure(error)
    }

    private static func authStatusDescription(_ status: AuthStatus) -> String {
        switch status {
        case .authenticated:
            return "authenticated"
        case .disconnected:
            return "disconnected"
        case .mfaRequired:
            return "mfaRequired"
        case .reconnectRequired:
            return "reconnectRequired"
        }
    }

    private static func isoOrDash(_ date: Date?) -> String {
        guard let date else { return "-" }
        return iso(date)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

}

#if targetEnvironment(simulator) && WHOOP_VALIDATION_BUILD && WHOOP_IOS27_SDK
/// UI state fixture: no network transport or HealthKit store, never compiled for a physical device.
@MainActor private final class IsolatedRecoveryUIFixture: RecoveryConfiguring {
    let repository: SyncRepository
    var recoveryAvailable: Bool { true }
    init(repository: SyncRepository) { self.repository = repository }
    func authorizeRecovery() async throws -> RecoveryAuthorization { RecoveryAuthorization(sources: [], access: .unknown) }
    func configureRecovery(start: Date, fullReadConfirmed: Bool, whoopBundle: String?) async throws {
        guard fullReadConfirmed else { throw RecoverySyncError.readUnverified }
        var state = try repository.recoveryState()
        state.enabled = true; state.configured = true; state.historyStartDate = start; state.historyScopeLimited = true
        try repository.commitRecoveryState(state)
    }
    func importRecoveryHistory() async throws -> SyncSummary {
        var state = try repository.recoveryState()
        state.initialEnumerationComplete = true; state.historicalPagesConfirmed = 3
        try repository.commitRecoveryState(state)
        var summary = SyncSummary(); summary.recovery.written = 2; summary.recovery.pagesConfirmed = 3
        summary.recovery.status = .historyLimited; return summary
    }
}
#endif
