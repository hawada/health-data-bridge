import AppIntents
import Foundation
import WHOOPHealthSyncCore

struct SynchronizeWhoopIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync WHOOP"
    static let description = IntentDescription(
        "Fills heart-rate and sleep-stage gaps in Apple Health using WHOOP."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        do {
            let summary = try await LiveSyncRuntime.shared.synchronizeFromAutomation()
            let result = Self.resultText(summary)

            if summary.errors.isEmpty {
                let dialog: IntentDialog = Self.usesSpanish ? "Sincronización completada." : "Sync completed."
                return .result(
                    value: result,
                    dialog: dialog
                )
            }

            let dialog: IntentDialog = Self.usesSpanish ? "Sincronización completada con incidencias." : "Sync completed with issues."
            return .result(
                value: result,
                dialog: dialog
            )
        } catch {
            throw ShortcutSyncError.failed(Self.message(error))
        }
    }

    static func resultText(_ summary: SyncSummary) -> String {
        if usesSpanish {
            let status = summary.errors.isEmpty ? "completada" : "con incidencias"
            return "Sincronización \(status): fases=\(summary.stagesWritten), FC=\(summary.heartRateWritten), HRV=\(summary.recovery.written), omitidas HRV=\(summary.recovery.skippedExternal), HRV: \(recoveryStatus(summary.recovery.status, spanish: true)), incidencias=\(summary.errors.count)"
        }
        let status = summary.errors.isEmpty ? "completed" : "completed with issues"
        return "Sync \(status): stages=\(summary.stagesWritten), HR=\(summary.heartRateWritten), HRV=\(summary.recovery.written), skipped HRV=\(summary.recovery.skippedExternal), HRV: \(recoveryStatus(summary.recovery.status, spanish: false)), issues=\(summary.errors.count)"
    }

    static func recoveryStatus(_ status: RecoveryFlowStatus, spanish: Bool) -> String {
        switch status {
        case .disabled: return spanish ? "desactivada" : "disabled"
        case .configurationPending: return spanish ? "configuración pendiente" : "configuration pending"
        case .requiresIOS27: return spanish ? "requiere iOS 27" : "requires iOS 27"
        case .completed: return spanish ? "completada" : "completed"
        default: return spanish ? "pendiente/con incidencias" : "pending/with issues"
        }
    }
    private static var usesSpanish: Bool {
        let preference = UserDefaults.standard.string(forKey: "appLanguage")
        if preference == "spanish" { return true }
        if preference == "english" { return false }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("es") == true
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
}

private enum ShortcutSyncError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

struct WHOOPHealthSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SynchronizeWhoopIntent(),
            phrases: [
                "Sync \(.applicationName)",
                "Update Apple Health with \(.applicationName)",
                "Sincronizar \(.applicationName)",
                "Actualizar Apple Health con \(.applicationName)"
            ],
            shortTitle: "Sync WHOOP",
            systemImageName: "arrow.triangle.2.circlepath.heart"
        )
    }
}
