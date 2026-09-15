import AppIntents
import SwiftUI

struct SyncDashboardView: View {
    @ObservedObject var viewModel: SyncViewModel
    @Binding var showsAuthentication: Bool
    @Environment(\.locale) private var locale
    @AppStorage("shortcutsIntroductionDismissed") private var shortcutsIntroductionDismissed = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        Text(syncHeadline)
                    } icon: {
                        Image(systemName: syncStatusSystemImage)
                    }
                    .font(.headline)
                    .foregroundStyle(isAuthenticated ? .primary : .secondary)

                    Text(syncDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        if isAuthenticated {
                            Task {
                                await viewModel.synchronize()
                            }
                        } else {
                            showsAuthentication = true
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if viewModel.isSyncing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(primaryButtonTitle)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.isSyncing || viewModel.isAuthenticating)
                    .accessibilityHint(
                        isAuthenticated
                            ? Text("Fills gaps detected in Apple Health since the last sync")
                            : Text("Opens the WHOOP sign-in flow")
                    )
                }
                .padding(.vertical, 8)
            }

            if !shortcutsIntroductionDismissed {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "wand.and.stars")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 5) {
                                Text("Available in Shortcuts")
                                    .font(.headline)
                                Text("Run the same sync from Siri or a personal automation. Your account and HealthKit must first be authorized in this app.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 4)

                            Button {
                                withAnimation {
                                    shortcutsIntroductionDismissed = true
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dismiss Shortcuts information")
                        }

                        #if os(iOS)
                        ShortcutsLink()
                        #else
                        Text("Open Shortcuts on your iPhone to add the Sync WHOOP action.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        #endif
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Recovery HRV") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(viewModel.recoveryStatusKey))
                        .accessibilityIdentifier("recovery.dashboard.status")
                    if let date = viewModel.recoveryState.lastDiscoveryEnd {
                        Text(dateValue(date)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Last synced data") {
                lastRunRow
                syncedDataRow(
                    title: "Sleep",
                    systemImage: "moon.zzz.fill",
                    value: dateValue(viewModel.diagnostics.lastSleepCheckpoint)
                )
                syncedDataRow(
                    title: "Heart rate",
                    systemImage: "heart.fill",
                    value: dateValue(viewModel.diagnostics.lastHeartRateCheckpoint)
                )
            }

        }
        .whoopDashboardListStyle()
        .navigationTitle("HealthDataBridge")
    }

    private var isAuthenticated: Bool {
        if case .authenticated = viewModel.authStatus {
            return true
        }
        return false
    }

    private var syncHeadline: LocalizedStringKey {
        if viewModel.isSyncing {
            return "Sync in progress"
        }
        return isAuthenticated ? "Ready to sync" : "Connect WHOOP to get started"
    }

    private var syncDescription: LocalizedStringKey {
        if isAuthenticated {
            return "Adds only missing sleep stages and heart rate samples, without replacing data from other sources."
        }
        return "Authorize WHOOP and Apple Health once; then sync here or from Shortcuts."
    }

    private var syncStatusSystemImage: String {
        if viewModel.isSyncing {
            return "arrow.triangle.2.circlepath"
        }
        return isAuthenticated ? "heart.text.square.fill" : "lock.circle"
    }

    private var primaryButtonTitle: LocalizedStringKey {
        if viewModel.isSyncing {
            return "Syncing…"
        }
        if isAuthenticated {
            return "Sync now"
        }
        switch viewModel.authStatus {
        case .mfaRequired:
            return "Complete MFA"
        case .reconnectRequired:
            return "Reconnect"
        case .authenticated, .disconnected:
            return "Connect WHOOP"
        }
    }

    private var lastRunRow: some View {
        HStack(spacing: 12) {
            Label("Last run", systemImage: "clock.fill")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let date = viewModel.diagnostics.lastRunFinishedAt ?? viewModel.diagnostics.lastRunStartedAt {
                    Text(dateValue(date))
                        .monospacedDigit()
                    Text(lastRunStatus)
                        .font(.caption)
                        .foregroundStyle(lastRunStatusColor)
                } else {
                    Text("Never")
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.trailing)
        }
    }

    private var lastRunStatus: LocalizedStringKey {
        switch viewModel.diagnostics.lastRunStatus {
        case "success":
            return "Completed"
        case "partial":
            return "Completed with issues"
        case "failed":
            return "Failed"
        case "running":
            return "In progress"
        default:
            return "Unknown"
        }
    }

    private var lastRunStatusColor: Color {
        switch viewModel.diagnostics.lastRunStatus {
        case "success":
            return .green
        case "partial":
            return .orange
        case "failed":
            return .red
        default:
            return .secondary
        }
    }

    private func syncedDataRow(title: LocalizedStringKey, systemImage: String, value: String) -> some View {
        HStack(spacing: 12) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
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
}

extension View {
    @ViewBuilder
    func whoopDashboardListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }
}
