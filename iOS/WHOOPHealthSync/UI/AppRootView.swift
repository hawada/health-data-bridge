import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case spanish

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system:
            return "Automatic"
        case .english:
            return "English"
        case .spanish:
            return "Spanish"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            let preferredLanguage = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return Locale(identifier: preferredLanguage.hasPrefix("es") ? "es" : "en")
        case .english:
            return Locale(identifier: "en")
        case .spanish:
            return Locale(identifier: "es")
        }
    }
}

private enum AppTab: Hashable {
    case sync
    case options
}

struct AppRootView: View {
    @StateObject private var viewModel = SyncViewModel()
    @State private var selectedTab: AppTab = .sync
    @State private var showsAuthentication = false
    @State private var showsDisconnectConfirmation = false
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                SyncDashboardView(
                    viewModel: viewModel,
                    showsAuthentication: $showsAuthentication
                )
                .toolbar {
                    accountToolbar
                }
            }
            .tabItem {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .tag(AppTab.sync)

            NavigationStack {
                OptionsView(viewModel: viewModel, appLanguage: $appLanguage)
                    .toolbar {
                        accountToolbar
                    }
            }
            .tabItem {
                Label("Options", systemImage: "gearshape.fill")
            }
            .tag(AppTab.options)
        }
        .sheet(isPresented: $showsAuthentication) {
            AuthenticationSheet(viewModel: viewModel)
        }
        .confirmationDialog(
            "Disconnect WHOOP?",
            isPresented: $showsDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                viewModel.disconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved session will be removed from this iPhone. Data already written to Apple Health will not be deleted.")
        }
        .environment(\.locale, appLanguage.locale)
        .onAppear {
            viewModel.configure()
        }
    }

    @ToolbarContentBuilder
    private var accountToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if case let .authenticated(email) = viewModel.authStatus {
                    Button {} label: {
                        Label(email, systemImage: "person.crop.circle.fill")
                    }
                    .disabled(true)

                    Button {
                        showsAuthentication = true
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isAuthenticating || viewModel.isSyncing || viewModel.isBindingAccount)

                    Divider()

                    Button(role: .destructive) {
                        showsDisconnectConfirmation = true
                    } label: {
                        Label("Disconnect WHOOP", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(viewModel.isSyncing || viewModel.isBindingAccount)
                } else {
                    Button {
                        showsAuthentication = true
                    } label: {
                        Label(accountActionTitle, systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(viewModel.isAuthenticating || viewModel.isSyncing || viewModel.isBindingAccount)
                }
            } label: {
                Label("WHOOP account", systemImage: "ellipsis.circle")
            }
        }
    }

    private var accountActionTitle: LocalizedStringKey {
        switch viewModel.authStatus {
        case .mfaRequired:
            return "Complete MFA"
        case .reconnectRequired:
            return "Reconnect"
        case .authenticated, .disconnected:
            return "Connect"
        }
    }
}
