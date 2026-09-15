import AppIntents
import SwiftUI
import WHOOPHealthSyncCore
#if os(iOS)
import UIKit
#endif

struct OptionsView: View {
    @ObservedObject var viewModel: SyncViewModel
    @State private var showsAccountBindingConfirmation = false
    @State private var showsRecoverySetup = false
    @Binding var appLanguage: AppLanguage

    var body: some View {
        Form {
            if viewModel.requiresAccountBinding {
                Section("Account for saved sync progress") {
                    Text("Confirm that the saved sync progress belongs to your current WHOOP account before reusing it. Your existing progress will be retained.")
                    if case let .authenticated(email) = viewModel.authStatus {
                        Text(email)
                        Button("Confirm this account") { showsAccountBindingConfirmation = true }
                            .disabled(viewModel.isSyncing || viewModel.isAuthenticating || viewModel.isBindingAccount)
                            .accessibilityIdentifier("account.confirmSavedProgress")
                    } else {
                        Text("Connect WHOOP to confirm the account for saved sync progress.")
                    }
                }
                .confirmationDialog("Does the saved sync progress belong to this WHOOP account?", isPresented: $showsAccountBindingConfirmation, titleVisibility: .visible) {
                    Button("Confirm this account") { Task { await viewModel.confirmExistingAccount() } }
                    Button("Cancel", role: .cancel) {}
                }
            }
            Section("Recovery HRV") {
                Text(LocalizedStringKey(viewModel.recoveryStatusKey))
                    .accessibilityIdentifier("recovery.status")
                Text("Imports the HRV measured during the main sleep, not the WHOOP recovery percentage. Subsequent syncs review the last seven days. No daytime readings are generated.")
                    .font(.footnote)
                Button("Configure recovery HRV") { showsRecoverySetup = true }
                    .disabled(!viewModel.canConfigureRecovery)
                    .accessibilityIdentifier("recovery.configure")
                Button("Import indicated history") { Task { await viewModel.importRecoveryHistory() } }
                    .disabled(!viewModel.canImportRecovery)
                    .accessibilityIdentifier("recovery.importHistory")
                if viewModel.isSyncing && viewModel.recoveryState.enabled {
                    ProgressView()
                    LabeledContent("Recovery history pages", value: "\(viewModel.recoveryProgress.pagesConfirmed)")
                    LabeledContent("Recovery HRV written", value: "\(viewModel.recoveryProgress.written)")
                    Button("Stop import") { viewModel.cancelRecoveryImport() }
                }
                if viewModel.recoveryState.enabled {
                    Button("Disable recovery HRV") { viewModel.disableRecovery() }
                }
            }

            #if WHOOP_VALIDATION_BUILD
            Section("Read-only recovery validation") {
                Text("Uses the existing WHOOP cycles route and shows field names and types only. Does not request HealthKit access or write health data.")
                Button("Inspect WHOOP recovery schema") { Task { await viewModel.probeRecoverySchema() } }
                    .disabled(viewModel.isSyncing || viewModel.isAuthenticating || viewModel.isProbingRecovery)
                Text("This additional diagnostic displays your HRV values and sleep dates locally to compare with WHOOP. It does not write to Health or include account identifiers or credentials.")
                    .font(.footnote)
                Button("Compare recovery values with WHOOP") { Task { await viewModel.probeRecoveryValues() } }
                    .disabled(viewModel.isSyncing || viewModel.isAuthenticating || viewModel.isProbingRecovery)
                    .accessibilityIdentifier("recovery.compareValues")
                if viewModel.isProbingRecovery { ProgressView() }
                if !viewModel.recoveryProbeText.isEmpty {
                    Text(viewModel.recoveryProbeText).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            #endif

            Section {
                Picker("App language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Automatic uses Spanish when the iPhone is set to Spanish and English for every other language.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sync with Shortcuts", systemImage: "wand.and.stars")
                        .font(.headline)
                    Text("Open Shortcuts to add the Sync WHOOP action or include it in a personal automation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                #if os(iOS)
                ShortcutsLink()
                #else
                Text("Open Shortcuts on your iPhone to add the Sync WHOOP action.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #endif
            } header: {
                Text("Automation")
            }

            Section {
                NavigationLink {
                    SyncActivityView(viewModel: viewModel)
                } label: {
                    HStack(spacing: 12) {
                        Label("Activity and diagnostics", systemImage: "list.bullet.rectangle.portrait")
                        Spacer()
                        if !viewModel.errors.isEmpty {
                            Text("\(viewModel.errors.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.red, in: Capsule())
                        }
                    }
                }
            } footer: {
                Text("Detailed sync windows, summaries, errors, events and the local log.")
            }

            Section {
                Text("Independent project. Not affiliated with, sponsored by, or endorsed by WHOOP.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }

        }
        .navigationTitle("Options")
        .sheet(isPresented: $showsRecoverySetup) { RecoverySetupView(viewModel: viewModel) }
    }
}

private struct RecoverySetupView: View {
    @ObservedObject var viewModel: SyncViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var start = Calendar.current.date(from: DateComponents(year: 2025, month: 12, day: 1)) ?? Date()
    @State private var fullReading = false
    @State private var nativeExportChecked = false
    @State private var sourceBundle = ""

    private var needsReadConfirmation: Bool {
        guard let authorization = viewModel.recoveryAuthorization else { return false }
        if case .unknown = authorization.access { return true }
        return false
    }
    private var nativeExporter: Bool {
        guard let authorization = viewModel.recoveryAuthorization else { return false }
        if case .nativeExporter = authorization.access { return true }
        return false
    }
    private var ready: Bool {
        viewModel.canConfigureRecovery && !viewModel.requiresAccountBinding && viewModel.recoveryAuthorization != nil &&
        !nativeExporter && nativeExportChecked && (!needsReadConfirmation || fullReading)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Recovery HRV") {
                    Text("Imports the HRV measured during the main sleep, not the WHOOP recovery percentage. Subsequent syncs review the last seven days. No daytime readings are generated.")
                    DatePicker("WHOOP history starts", selection: $start, in: ...Date(), displayedComponents: .date)
                    Text("Select when you started using WHOOP. Completion applies to the indicated period; it does not certify the end of the provider's history.")
                        .font(.footnote)
                }
                Section("Health access") {
                    Button("Authorize recovery HRV") {
                        fullReading = false; nativeExportChecked = false
                        Task { await viewModel.authorizeRecovery() }
                    }
                    .disabled(!viewModel.canConfigureRecovery)
                    .accessibilityIdentifier("recovery.authorize")
                    if viewModel.isConfiguringRecovery { ProgressView() }
                    if let authorization = viewModel.recoveryAuthorization {
                        if case let .limited(date) = authorization.access {
                            Text("Health reading is limited from")
                            Text(date, style: .date)
                            Text("Older recoveries remain pending until reading covers their sleep dates.")
                        }
                        if nativeExporter {
                            Text("WHOOP already writes recovery HRV to Health. Import remains paused to avoid duplicates.")
                        } else {
                            if !authorization.sources.isEmpty {
                                Picker("WHOOP source in Health", selection: $sourceBundle) {
                                    Text("Not identified").tag("")
                                    ForEach(authorization.sources) { source in Text(source.name).tag(source.bundle) }
                                }
                            }
                            Toggle("I checked that WHOOP does not already write recovery HRV to Health", isOn: $nativeExportChecked)
                                .accessibilityIdentifier("recovery.confirmNoNativeExport")
                            if needsReadConfirmation {
                                Text("Health does not reveal denied reading when only this app's data or no data is visible. Check that recovery HRV reading is allowed for all dates in Health before enabling import.")
                                    .font(.footnote)
                                Toggle("I allowed recovery HRV reading for all dates", isOn: $fullReading)
                                    .accessibilityIdentifier("recovery.confirmFullReading")
                            }
                        }
                    }
                }
                if viewModel.requiresAccountBinding {
                    Section { Text("Confirm the account for saved sync progress in Options before enabling recovery HRV.") }
                }
                if let error = viewModel.errors.last {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button("Enable recovery HRV") {
                        Task {
                            if await viewModel.enableRecovery(start: Calendar.current.startOfDay(for: start),
                                fullReadConfirmed: needsReadConfirmation && fullReading,
                                whoopBundle: sourceBundle.isEmpty ? nil : sourceBundle) { dismiss() }
                        }
                    }
                    .disabled(!ready)
                    .accessibilityIdentifier("recovery.enable")
                }
            }
            .navigationTitle("Configure recovery HRV")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .interactiveDismissDisabled(viewModel.isConfiguringRecovery)
            .onAppear { if let saved = viewModel.recoveryState.historyStartDate { start = saved } }
            .onChange(of: viewModel.recoveryAuthorization?.sources) { _, sources in
                let whoop = sources?.filter { $0.name.caseInsensitiveCompare("WHOOP") == .orderedSame } ?? []
                if whoop.count == 1 { sourceBundle = whoop[0].bundle }
            }
        }
    }
}

struct SyncActivityView: View {
    @ObservedObject var viewModel: SyncViewModel
    @Environment(\.locale) private var locale
    @State private var diagnosticCopyMessage: LocalizedStringKey?

    var body: some View {
        List {
            if !viewModel.errors.isEmpty {
                Section("Current issues") {
                    ForEach(viewModel.errors, id: \.self) { error in
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }

            if let summary = viewModel.lastSummary {
                Section("Latest sync summary") {
                    localizedMetric("Result", summary.errors.isEmpty ? "Completed" : "Completed with issues")
                    metric("Recovery HRV written", summary.recovery.written)
                    metric("Recovery HRV skipped", summary.recovery.skippedExternal)
                    metric("Recovery history pages", summary.recovery.pagesConfirmed)
                    metric("Sleeps downloaded", summary.sleepsDownloaded)
                    metric("Sleeps written", summary.sleepsWritten)
                    metric("Sleeps unchanged", summary.sleepsUnchanged)
                    metric("Sleeps revised", summary.sleepsRevised)
                    metric("Sleeps outside the window", summary.sleepsDiscardedOutOfWindow)
                    metric("Stages written", summary.stagesWritten)
                    metric("Stages skipped", summary.stagesSkipped)
                    metric("Stages removed", summary.stagesRemoved)
                    metric("Heart-rate samples downloaded", summary.heartRateDownloaded)
                    metric("Heart-rate samples written", summary.heartRateWritten)
                    metric("Heart-rate samples skipped", summary.heartRateSkipped)
                    metric("Heart-rate samples removed", summary.heartRateRemoved)
                    metric("Heart-rate samples outside the window", summary.heartRateDiscardedOutOfWindow)
                    if let resolution = summary.effectiveHeartRateResolution {
                        metric("Heart-rate resolution", "\(resolution) s")
                    }
                    metric("Sleep window", dateRange(start: summary.sleepQueryWindowStart, end: summary.sleepQueryWindowEnd))
                    metric("Heart-rate window", dateRange(start: summary.heartRateWindowStart, end: summary.heartRateWindowEnd))
                    metric("Elapsed time", "\(String(format: "%.1f", summary.elapsedSeconds)) s")
                }
            }

            Section("Recovery HRV progress") {
                Text(LocalizedStringKey(viewModel.recoveryStatusKey))
                if let date = viewModel.recoveryState.historyStartDate { metric("WHOOP history starts", dateValue(date)) }
                if let date = viewModel.recoveryState.initialImportCutoff { metric("Initial history cutoff", dateValue(date)) }
                if let date = viewModel.recoveryState.oldestEnumeratedDate { metric("Oldest enumerated recovery", dateValue(date)) }
                metric("Recovery history pages", viewModel.recoveryState.historicalPagesConfirmed)
                metric("Pending recoveries", viewModel.recoveryState.pendingItems.count)
                Text("Completion covers the indicated period. Provider-certified full history has not been established.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(viewModel.recoveryState.pendingItems.values.sorted { $0.firstDetectedAt < $1.firstDetectedAt }, id: \.cycleID) { item in
                    VStack(alignment: .leading) {
                        Text(item.reason == "access" ? "Pending Health reading" : "Pending recovery validation")
                        if let range = item.range { Text(dateRange(start: range.start, end: range.end)).font(.footnote) }
                        if item.requiresManualReview(at: Date()) { Text("Manual review required").font(.footnote) }
                    }
                }
            }

            Section("Local progress") {
                let preview = viewModel.nextSyncPreview()
                metric("Sleep checkpoint", dateValue(viewModel.diagnostics.lastSleepCheckpoint))
                metric("Heart-rate checkpoint", dateValue(viewModel.diagnostics.lastHeartRateCheckpoint))
                metric("Next sleep review window", dateRange(start: preview.sleepWindowStart, end: preview.sleepWindowEnd))
                metric("Next heart-rate window", dateRange(start: preview.heartRateWindowStart, end: preview.heartRateWindowEnd))
                localizedMetric("Sleep mode", preview.isFirstSleepSync ? "First sync" : "Incremental")
                localizedMetric("Heart-rate mode", preview.isFirstHeartRateSync ? "First sync" : "Incremental")
                if let resolution = viewModel.diagnostics.heartRateResolution {
                    metric("Saved heart-rate resolution", "\(resolution) s")
                }
                metric("Last run", lastRunText)
                metric("Recorded sleeps", viewModel.diagnostics.recordedSleepCount)
                if !lastRunErrorsText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last run errors")
                        Text(lastRunErrorsText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }

            if !viewModel.events.isEmpty {
                Section("This session") {
                    ForEach(viewModel.events, id: \.self) { event in
                        Text(event)
                            .font(.footnote)
                    }
                }
            }

            if !viewModel.diagnostics.recentEvents.isEmpty {
                Section("Local log") {
                    ForEach(viewModel.diagnostics.recentEvents) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(event.level.uppercased()) · \(event.category)")
                                .font(.caption)
                                .foregroundStyle(levelColor(event.level))
                            Text(event.message)
                                .font(.footnote)
                            Text(dateValue(event.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Diagnostics") {
                Button("Copy diagnostics") {
                    copyDiagnostics()
                }
                if let diagnosticCopyMessage {
                    Text(diagnosticCopyMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .whoopDashboardListStyle()
        .navigationTitle("Activity")
    }

    private var lastRunText: String {
        guard let startedAt = viewModel.diagnostics.lastRunStartedAt else {
            return "-"
        }
        let status = localizedStatus(viewModel.diagnostics.lastRunStatus)
        if let finishedAt = viewModel.diagnostics.lastRunFinishedAt {
            return "\(status), \(dateValue(startedAt)) → \(dateValue(finishedAt))"
        }
        return "\(status), \(dateValue(startedAt))"
    }

    private var lastRunErrorsText: String {
        SensitiveTextSanitizer.redact(viewModel.diagnostics.lastRunErrorsText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func metric(_ title: LocalizedStringKey, _ value: Int) -> some View {
        metric(title, "\(value)")
    }

    private func metric(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func localizedMetric(_ title: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func dateRange(start: Date?, end: Date?) -> String {
        guard let start, let end else {
            return "-"
        }
        return "\(dateValue(start)) → \(dateValue(end))"
    }

    private func dateValue(_ date: Date?) -> String {
        guard let date else {
            return "-"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func localizedStatus(_ status: String?) -> String {
        let usesSpanish = locale.language.languageCode?.identifier == "es"
        switch status {
        case "success":
            return usesSpanish ? "completada" : "completed"
        case "partial":
            return usesSpanish ? "con incidencias" : "with issues"
        case "failed":
            return usesSpanish ? "fallida" : "failed"
        case "running":
            return usesSpanish ? "en curso" : "in progress"
        default:
            return usesSpanish ? "desconocida" : "unknown"
        }
    }

    private func copyDiagnostics() {
        let report = viewModel.diagnosticsReport()
        #if os(iOS)
        UIPasteboard.general.string = report
        diagnosticCopyMessage = "Diagnostics copied."
        #else
        diagnosticCopyMessage = "Copying diagnostics is only available on iOS."
        #endif
    }

    private func levelColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "error":
            return .red
        case "warning":
            return .orange
        default:
            return .secondary
        }
    }
}
