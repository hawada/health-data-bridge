import Foundation
import WHOOPHealthSyncCore

@main
struct SyncViewModelSmokeCheck {
    @MainActor
    static func main() async throws {
        try await testAuthenticationFailureRequiresReconnect()
        try await testFailedSyncClearsPreviousSummary()
        try await testNextSyncPreviewUsesStoredCheckpoints()
        try await testDiagnosticsReportIsOperationalAndSanitized()
        try await testLegacyAccountConfirmationBlocksSyncAndRetainsProgress()
        try await testRecoveryConfigurationAndDedicatedImport()
        print("SyncViewModel smoke check passed (account confirmation, recovery setup, failed authorization and dedicated import)")
    }

    @MainActor
    private static func testAuthenticationFailureRequiresReconnect() async throws {
        let healthKit = FakeHealthKitAuthorizer()
        let runner = FailingSyncRunner(error: WhoopAPIError.http(status: 401, path: "/auth-service/v2/user", message: "expired"))
        let viewModel = SyncViewModel(
            healthKitService: healthKit,
            syncEngine: runner,
            initialAuthStatus: .authenticated(email: "jose@example.com")
        )

        await viewModel.synchronize()

        expect(healthKit.requestCount == 1, "ViewModel should request HealthKit authorization before sync.")
        expect(runner.requestCount == 1, "ViewModel should call the sync runner once.")
        expect(!viewModel.isSyncing, "ViewModel should leave syncing state after an auth failure.")
        expect(viewModel.errors.count == 1, "ViewModel should expose the auth failure.")
        guard case let .reconnectRequired(reason) = viewModel.authStatus else {
            fatalError("ViewModel should mark WHOOP as reconnect-required after an auth failure.")
        }
        expect(reason.contains("401"), "Reconnect reason should include the API status.")
    }

    @MainActor
    private static func testFailedSyncClearsPreviousSummary() async throws {
        let healthKit = FakeHealthKitAuthorizer()
        var successfulSummary = SyncSummary()
        successfulSummary.sleepsDownloaded = 1
        successfulSummary.stagesWritten = 2
        successfulSummary.elapsedSeconds = 1.2
        let runner = SequenceSyncRunner(results: [
            .success(successfulSummary),
            .failure(SyncEngineError.healthKitReadVisibilityUnverified(["Sleep Analysis"]))
        ])
        let viewModel = SyncViewModel(
            healthKitService: healthKit,
            syncEngine: runner,
            initialAuthStatus: .authenticated(email: "jose@example.com")
        )

        await viewModel.synchronize()
        expect(viewModel.lastSummary == successfulSummary, "Successful sync should expose its summary.")

        await viewModel.synchronize()
        expect(viewModel.lastSummary == nil, "A later failed sync should clear the previous summary to avoid stale UI.")
        expect(viewModel.errors.count == 1, "Failed sync should expose the new error.")
        expect(healthKit.requestCount == 2, "Each sync attempt should request HealthKit authorization.")
        expect(runner.requestCount == 2, "Runner should be called once per sync attempt.")
    }

    @MainActor
    private static func testNextSyncPreviewUsesStoredCheckpoints() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncViewModelPreview-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = SyncRepository(fileURL: fileURL)
        try repository.setSleepCheckpoint(date(699_000))
        try repository.setHeartRateCheckpoint(date(699_000), resolution: 60)

        let viewModel = SyncViewModel(
            repository: repository,
            initialAuthStatus: .authenticated(email: "jose@example.com"),
            preferredHeartRateStepSeconds: 6
        )
        viewModel.configure()

        let preview = viewModel.nextSyncPreview(now: date(700_000))
        expect(preview.sleepWindowStart == date(700_000 - 7 * 24 * 60 * 60), "Sleep preview should include the revision lookback window.")
        expect(preview.sleepWindowEnd == date(700_000), "Sleep preview should end at the planned sync time.")
        expect(preview.heartRateWindowStart == date(698_940), "HR preview should back up by the stored 60-second effective resolution.")
        expect(preview.heartRateWindowEnd == date(700_000), "HR preview should end at the planned sync time.")
        expect(!preview.isFirstSleepSync, "Preview should show sleep as incremental after a stored checkpoint.")
        expect(!preview.isFirstHeartRateSync, "Preview should show HR as incremental after a stored checkpoint.")

        let report = viewModel.diagnosticsReport()
        expect(report.contains("Next sync preview:"), "Diagnostics report should include the next sync preview.")
        expect(report.contains("- First sleep sync: false"), "Diagnostics report should expose incremental sleep mode.")
        expect(report.contains("- First heart-rate sync: false"), "Diagnostics report should expose incremental HR mode.")
    }

    @MainActor
    private static func testDiagnosticsReportIsOperationalAndSanitized() async throws {
        let healthKit = FakeHealthKitAuthorizer()
        var summary = SyncSummary()
        summary.sleepsDownloaded = 1
        summary.sleepsRevised = 1
        summary.stagesWritten = 4
        summary.heartRateWritten = 10
        summary.effectiveHeartRateResolution = 6
        let viewModel = SyncViewModel(
            healthKitService: healthKit,
            syncEngine: SequenceSyncRunner(results: [.success(summary)]),
            initialAuthStatus: .authenticated(email: "jose@example.com")
        )

        await viewModel.synchronize()
        let report = viewModel.diagnosticsReport()

        expect(report.contains("HealthDataBridge Diagnostics"), "Diagnostics report should have a recognizable title.")
        expect(report.contains("Auth status: authenticated"), "Diagnostics report should expose auth state.")
        expect(report.contains("- Sleeps downloaded: 1"), "Diagnostics report should include sleep counters.")
        expect(report.contains("- Sleeps revised: 1"), "Diagnostics report should include revision counters.")
        expect(report.contains("- HR written: 10"), "Diagnostics report should include HR counters.")
        expect(report.contains("- Effective HR resolution: 6 s"), "Diagnostics report should include HR resolution.")
        expect(!report.contains("jose@example.com"), "Diagnostics report should not expose the authenticated email.")

        let sensitiveRunner = SequenceSyncRunner(results: [
            .failure(SensitiveSmokeError())
        ])
        let sensitiveViewModel = SyncViewModel(
            healthKitService: healthKit,
            syncEngine: sensitiveRunner,
            initialAuthStatus: .authenticated(email: "jose@example.com")
        )
        await sensitiveViewModel.synchronize()
        let sensitiveReport = sensitiveViewModel.diagnosticsReport()
        let visibleSensitiveText = (sensitiveViewModel.errors + sensitiveViewModel.events).joined(separator: "\n")
        expect(!visibleSensitiveText.contains("jose@example.com"), "Visible ViewModel errors/events should redact emails.")
        expect(!visibleSensitiveText.contains("secret-token"), "Visible ViewModel errors/events should redact bearer token material.")
        expect(!visibleSensitiveText.contains("secret-password"), "Visible ViewModel errors/events should redact password material.")
        expect(!visibleSensitiveText.contains("refresh-secret"), "Visible ViewModel errors/events should redact refresh tokens.")
        expect(!visibleSensitiveText.contains("header.payload.signature"), "Visible ViewModel errors/events should redact JWT-like values.")
        expect(visibleSensitiveText.contains("[redacted-email]"), "Visible ViewModel errors/events should show email redaction marker.")
        expect(visibleSensitiveText.contains("Bearer [redacted-token]"), "Visible ViewModel errors/events should show bearer redaction marker.")
        expect(!sensitiveReport.contains("jose@example.com"), "Diagnostics report should redact emails from errors.")
        expect(!sensitiveReport.contains("secret-token"), "Diagnostics report should redact bearer token material.")
        expect(!sensitiveReport.contains("secret-password"), "Diagnostics report should redact password material.")
        expect(!sensitiveReport.contains("refresh-secret"), "Diagnostics report should redact refresh tokens.")
        expect(!sensitiveReport.contains("header.payload.signature"), "Diagnostics report should redact JWT-like values.")
        expect(sensitiveReport.contains("[redacted-email]"), "Diagnostics report should show email redaction marker.")
        expect(sensitiveReport.contains("Bearer [redacted-token]"), "Diagnostics report should show bearer redaction marker.")
    }


    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }

    @MainActor
    private static func testLegacyAccountConfirmationBlocksSyncAndRetainsProgress() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vm-account-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = SyncRepository(fileURL: url)
        let checkpoint = Date(timeIntervalSince1970: 123)
        try repo.setSleepCheckpoint(checkpoint)
        let health = FakeHealthKitAuthorizer()
        let runner = SequenceSyncRunner(results: [.success(SyncSummary())])
        let binder = FakeAccountBinder(repository: repo)
        let vm = SyncViewModel(healthKitService: health, repository: repo, syncEngine: runner,
            accountBinder: binder, initialAuthStatus: .authenticated(email: "owner@example.com"))
        vm.configure()
        expect(vm.requiresAccountBinding, "Legacy confirmation must be shown.")
        await vm.synchronize()
        expect(health.requestCount == 0 && runner.requestCount == 0, "Unbound migration must not request HealthKit permissions or start sync.")
        binder.error = CocoaError(.fileWriteNoPermission)
        await vm.confirmExistingAccount()
        expect(vm.requiresAccountBinding && !vm.isBindingAccount, "Failed confirmation retains the prompt and clears busy state.")
        binder.error = WhoopAPIError.http(status: 401, path: "/auth-service/v2/user", message: "expired")
        await vm.confirmExistingAccount()
        guard case .reconnectRequired = vm.authStatus else { fatalError("Binding authentication failure must request reconnection") }
        expect(vm.requiresAccountBinding && !vm.isBindingAccount, "Authentication failure preserves unbound progress.")
        vm.authStatus = .authenticated(email: "owner@example.com")
        binder.error = nil
        await vm.confirmExistingAccount()
        expect(!vm.requiresAccountBinding && vm.errors.isEmpty, "Successful manual confirmation clears the prompt and errors.")
        let preservedCheckpoint = try repo.checkpoints().lastSleepQueryEnd
        expect(preservedCheckpoint == checkpoint, "Confirmation preserves existing checkpoints.")
        await vm.synchronize()
        expect(health.requestCount == 1 && runner.requestCount == 1, "Confirmed account can continue the existing manual sync flow.")
    }

    @MainActor
    private static func testRecoveryConfigurationAndDedicatedImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WHOOPRecoverySetup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SyncRepository(fileURL: directory.appendingPathComponent("sync-store.json"))
        try repository.bindAccountManually("setup-account")
        let configuration = FakeRecoveryConfigurator(repository: repository)
        let legacy = SequenceSyncRunner(results: [.success(SyncSummary())])
        let vm = SyncViewModel(repository: repository, syncEngine: legacy, recoveryConfigurator: configuration, initialAuthStatus: .authenticated(email: "jose@example.com"))
        vm.configure()
        expect(vm.canConfigureRecovery && !vm.canImportRecovery, "Connected existing users can configure before recovery is enabled.")
        let unauthorized = await vm.enableRecovery(start: date(1), fullReadConfirmed: true, whoopBundle: nil)
        expect(!unauthorized, "No activation before authorization.")
        configuration.authorizationError = RecoverySyncError.readUnverified
        await vm.authorizeRecovery()
        let afterFailure = try repository.recoveryState()
        expect(vm.recoveryAuthorization == nil && !afterFailure.enabled, "Failed authorization must not activate recovery.")
        configuration.authorizationError = nil
        await vm.authorizeRecovery()
        configuration.configurationError = RecoverySyncError.accountMismatch
        let wrongAccount = await vm.enableRecovery(start: date(1), fullReadConfirmed: true, whoopBundle: nil)
        expect(!wrongAccount, "Wrong account cannot activate.")
        configuration.configurationError = nil
        let enabled = await vm.enableRecovery(start: date(1), fullReadConfirmed: true, whoopBundle: nil)
        expect(enabled && vm.canImportRecovery, "Successful setup enables dedicated history import.")
        await vm.importRecoveryHistory()
        expect(configuration.imports == 1 && legacy.requestCount == 0, "Dedicated HRV import must not execute legacy sleep or heart-rate sync.")
        expect(vm.lastSummary?.recovery.written == 2 && !vm.isSyncing, "Dedicated summary is published and busy state clears.")
        configuration.importError = RecoverySyncError.rateLimited(until: Date().addingTimeInterval(60))
        await vm.importRecoveryHistory()
        expect(vm.lastSummary == nil && !vm.isSyncing && vm.errors.count == 1, "Failed recovery import clears prior successful summary and exposes the current failure.")
        vm.disableRecovery()
        let disabled = try repository.recoveryState()
        expect(!vm.canImportRecovery && disabled.historyStartDate == date(1), "Disable preserves configured historical progress.")
    }

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}

private final class FakeHealthKitAuthorizer: HealthKitAuthorizing {
    var requestCount = 0

    func requestAuthorization() async throws {
        requestCount += 1
    }
}

private final class FailingSyncRunner: SyncRunning {
    let error: Error
    var requestCount = 0

    init(error: Error) {
        self.error = error
    }

    func synchronize() async throws -> SyncSummary {
        requestCount += 1
        throw error
    }
}

private final class SequenceSyncRunner: SyncRunning {
    private var results: [Result<SyncSummary, Error>]
    var requestCount = 0

    init(results: [Result<SyncSummary, Error>]) {
        self.results = results
    }

    func synchronize() async throws -> SyncSummary {
        requestCount += 1
        guard !results.isEmpty else {
            return SyncSummary()
        }
        let result = results.removeFirst()
        switch result {
        case let .success(summary):
            return summary
        case let .failure(error):
            throw error
        }
    }
}

private struct SensitiveSmokeError: LocalizedError {
    var errorDescription: String? {
        "Failure for jose@example.com Authorization: Bearer secret-token password=secret-password refreshToken: refresh-secret jwt=header.payload.signature"
    }
}

@MainActor
private final class FakeAccountBinder: AccountBindingProviding {
    let repository: SyncRepository
    var error: Error?
    init(repository: SyncRepository) { self.repository = repository }
    func bindCurrentAccountManually() async throws {
        if let error { throw error }
        try repository.bindAccountManually("confirmed-test-account")
    }
}

@MainActor private final class FakeRecoveryConfigurator: RecoveryConfiguring {
    let repository: SyncRepository
    var recoveryAvailable = true
    var authorizationError: Error?
    var configurationError: Error?
    var imports = 0
    var importError: Error?
    init(repository: SyncRepository) { self.repository = repository }
    func authorizeRecovery() async throws -> RecoveryAuthorization {
        if let authorizationError { throw authorizationError }
        return RecoveryAuthorization(sources: [], access: .unknown)
    }
    func configureRecovery(start: Date, fullReadConfirmed: Bool, whoopBundle: String?) async throws {
        if let configurationError { throw configurationError }
        var state = try repository.recoveryState()
        state.enabled = true; state.configured = true; state.historyStartDate = start
        try repository.commitRecoveryState(state)
    }
    func importRecoveryHistory() async throws -> SyncSummary {
        imports += 1; if let importError { throw importError }; var summary = SyncSummary(); summary.recovery.written = 2; return summary
    }
}
