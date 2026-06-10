import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let keychain: KeychainStore
    let client: TranscriberClient

    @State private var apiKeyDraft = ""
    @State private var keyIsStored = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        TabView {
            apiTab.tabItem { Label("API", systemImage: "key") }
            dictationTab.tabItem { Label("Dictation", systemImage: "mic") }
            insertionTab.tabItem { Label("Insertion", systemImage: "text.cursor") }
            costTab.tabItem { Label("Cost", systemImage: "dollarsign.circle") }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { keyIsStored = keychain.apiKey() != nil }
    }

    // MARK: API

    private var apiTab: some View {
        Form {
            SecureField(keyIsStored ? "•••••••• (stored in Keychain)" : "sk-...", text: $apiKeyDraft)
            HStack {
                Button("Save Key") {
                    if keychain.setAPIKey(apiKeyDraft) {
                        keyIsStored = true
                        apiKeyDraft = ""
                        testResult = "Key saved to Keychain."
                    } else {
                        testResult = "Could not save to Keychain."
                    }
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                Button(testing ? "Testing…" : "Test") {
                    testing = true
                    testResult = nil
                    let key = apiKeyDraft.isEmpty ? (keychain.apiKey() ?? "") : apiKeyDraft
                    Task {
                        do {
                            try await client.testKey(key)
                            testResult = "✓ Key works."
                        } catch {
                            testResult = "✗ \(error.localizedDescription)"
                        }
                        testing = false
                    }
                }
                .disabled(testing || (!keyIsStored && apiKeyDraft.isEmpty))

                if keyIsStored {
                    Button("Remove", role: .destructive) {
                        keychain.deleteAPIKey()
                        keyIsStored = false
                    }
                }
            }
            if let testResult {
                Text(testResult).font(.caption).foregroundStyle(.secondary)
            }
            Text("The key is stored only in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Dictation

    private var dictationTab: some View {
        Form {
            KeyboardShortcuts.Recorder("Hotkey:", name: .record)

            Picker("Hotkey mode:", selection: binding(\.hotkeyMode)) {
                Text("Toggle (press to start/stop)").tag(HotkeyMode.toggle)
                Text("Push-to-talk (hold)").tag(HotkeyMode.pushToTalk)
            }

            Picker("Model:", selection: binding(\.model)) {
                ForEach(TranscriptionModel.allCases) { model in
                    Text(model.rawValue).tag(model)
                }
            }

            TextField("Language (blank = auto):", text: binding(\.language), prompt: Text("auto"))
            Text("Leave blank for automatic detection — required for mixed Chinese/English.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading) {
                Text("Custom vocabulary (sent as the API prompt):")
                TextEditor(text: binding(\.vocabularyPrompt))
                    .font(.body)
                    .frame(height: 56)
                    .border(Color.gray.opacity(0.3))
            }

            Stepper(value: binding(\.historyLimit), in: 0...500, step: 10) {
                Text("History size: \(settings.historyLimit)\(settings.historyLimit == 0 ? " (text not stored)" : "")")
            }
            Toggle("Keep audio files after transcription", isOn: binding(\.keepAudio))
            Toggle("Sounds", isOn: binding(\.soundsEnabled))
        }
    }

    // MARK: Insertion

    private var insertionTab: some View {
        Form {
            Picker("Strategy:", selection: binding(\.insertionStrategy)) {
                Text("Paste (clipboard + ⌘V)").tag(InsertionStrategy.paste)
                Text("Type (for apps that block paste)").tag(InsertionStrategy.type)
            }
            Stepper(value: binding(\.clipboardRestoreDelayMs), in: 0...5000, step: 100) {
                Text("Clipboard restore delay: \(settings.clipboardRestoreDelayMs) ms")
            }
            Text("In password fields the transcript goes to the clipboard only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Cost

    private var costTab: some View {
        Form {
            ForEach(TranscriptionModel.allCases) { model in
                TextField(
                    "\(model.rawValue) ($/min):",
                    value: Binding(
                        get: { settings.ratePerMinute(for: model) },
                        set: { settings.setRatePerMinute($0, for: model) }
                    ),
                    format: .number.precision(.fractionLength(0...5))
                )
            }
            TextField(
                "Monthly alert threshold ($, 0 = off):",
                value: binding(\.monthlyAlertUSD),
                format: .number.precision(.fractionLength(0...2))
            )
            Text(String(format: "This month so far: $%.2f",
                        settings.costTotal(forMonth: AppController.monthKey(for: Date()))))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }
}

/// Plain window hosting the settings form (the app has no main window).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeView: () -> SettingsView

    init(makeView: @escaping () -> SettingsView) {
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "VoiceKey Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
