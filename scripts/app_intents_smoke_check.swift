import AppIntents
import Foundation
import WHOOPHealthSyncCore

@main
struct AppIntentsSmokeCheck {
    static func main() {
        var summary = SyncSummary()
        summary.stagesWritten = 4
        summary.heartRateWritten = 120

        let text = SynchronizeWhoopIntent.resultText(summary)
        precondition(text.contains("completed") || text.contains("completada"))
        precondition(text.contains("stages=4") || text.contains("fases=4"))
        precondition(text.contains("HR=120") || text.contains("FC=120"))
        precondition(WHOOPHealthSyncShortcuts.appShortcuts.count == 1)

        summary.errors = ["fixture"]
        let partialText = SynchronizeWhoopIntent.resultText(summary)
        precondition(partialText.contains("issues") || partialText.contains("incidencias"))

        print("App Intents smoke check passed")
    }
}
