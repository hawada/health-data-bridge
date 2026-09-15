import SwiftUI

struct AuthenticationSheet: View {
    @ObservedObject var viewModel: SyncViewModel
    var onConnected: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                switch viewModel.authStatus {
                case let .mfaRequired(challengeName, destination):
                    Section("MFA") {
                        Text(challengeDescription(challengeName: challengeName, destination: destination))
                            .foregroundStyle(.secondary)
                        TextField("Code", text: $code)
                            .whoopOneTimeCodeInput()
                            .privacySensitive()
                    }
                default:
                    Section("WHOOP") {
                        TextField("Email", text: $email)
                            .whoopEmailInput()
                        SecureField("Password", text: $password)
                            .whoopPasswordInput()
                            .privacySensitive()
                    }
                }

                if !viewModel.errors.isEmpty {
                    Section("Errors") {
                        ForEach(viewModel.errors, id: \.self) { error in
                            Text(error)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Connect WHOOP")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        clearCredentials()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await submit()
                        }
                    } label: {
                        Text(actionTitle)
                    }
                    .disabled(viewModel.isAuthenticating || !canSubmit)
                }
            }
            .onDisappear {
                clearCredentials()
            }
        }
    }

    private var actionTitle: LocalizedStringKey {
        if viewModel.isAuthenticating {
            return "Connecting"
        }
        if case .mfaRequired = viewModel.authStatus {
            return "Verify"
        }
        return "Connect"
    }

    private var canSubmit: Bool {
        if case .mfaRequired = viewModel.authStatus {
            return !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func submit() async {
        if case .mfaRequired = viewModel.authStatus {
            let submittedCode = code
            code = ""
            await viewModel.submitMFA(code: submittedCode)
        } else {
            let submittedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let submittedPassword = password
            password = ""
            await viewModel.signIn(email: submittedEmail, password: submittedPassword)
        }

        if case .authenticated = viewModel.authStatus {
            clearCredentials()
            onConnected()
            dismiss()
        }
    }

    private func clearCredentials() {
        email = ""
        password = ""
        code = ""
    }

    private func challengeDescription(challengeName: String, destination: String?) -> String {
        if let destination, !destination.isEmpty {
            return "\(challengeName): \(destination)"
        }
        return challengeName
    }
}

private extension View {
    @ViewBuilder
    func whoopEmailInput() -> some View {
        #if os(iOS)
        self
            .textContentType(.username)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
        #else
        self
        #endif
    }

    @ViewBuilder
    func whoopPasswordInput() -> some View {
        #if os(iOS)
        self
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
        #else
        self
        #endif
    }

    @ViewBuilder
    func whoopOneTimeCodeInput() -> some View {
        #if os(iOS)
        self
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
        #else
        self
        #endif
    }
}
