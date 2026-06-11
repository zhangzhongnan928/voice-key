import AppIntents

/// "Start Dictation" for the Action Button / Shortcuts / Siri: opens the app
/// and immediately starts a handoff recording — same flow as the keyboard's
/// voicekey://record URL, so the finished transcript arms the keyboard's
/// consume-once insert.
struct StartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription(
        "Opens VoiceKey and starts recording right away. Stop the recording and the transcript is ready for the VoiceKey keyboard to insert."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DictationTrigger.shared.fire()
        return .result()
    }
}

struct VoiceKeyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start \(.applicationName) dictation",
                "Dictate with \(.applicationName)",
            ],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
    }
}

/// Bridges the intent to the live AppModel. The intent can run before the
/// SwiftUI scene has built the model on a cold launch, so a missed trigger is
/// kept pending and consumed when the model registers.
@MainActor
final class DictationTrigger {
    static let shared = DictationTrigger()

    private weak var model: AppModel?
    private var pending = false

    func register(_ model: AppModel) {
        self.model = model
        if pending {
            pending = false
            model.startHandoffRecording()
        }
    }

    func fire() {
        if let model {
            model.startHandoffRecording()
        } else {
            pending = true
        }
    }
}
