import Security
import SwiftUI

/// Prompt 2 settings: API key, model, vocabulary prompt, history size.
struct IOSSettingsView: View {
    @EnvironmentObject var model: AppModel

    @State private var apiKeyDraft = ""
    @State private var keyIsStored = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("API key") {
                    SecureField(keyIsStored ? "•••••••• (stored in Keychain)" : "sk-...", text: $apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Save") {
                            let status = model.keychain.setAPIKey(apiKeyDraft)
                            if status == errSecSuccess {
                                keyIsStored = true
                                apiKeyDraft = ""
                                testResult = "Key saved to Keychain."
                            } else {
                                testResult = "Could not save to Keychain (\(KeychainStore.describe(status)))"
                            }
                        }
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                        Spacer()

                        Button(testing ? "Testing…" : "Test") {
                            testing = true
                            testResult = nil
                            let key = apiKeyDraft.isEmpty ? (model.keychain.apiKey() ?? "") : apiKeyDraft
                            Task {
                                do {
                                    try await model.client.testKey(key)
                                    testResult = "✓ Key works."
                                } catch {
                                    testResult = "✗ \(error.localizedDescription)"
                                }
                                testing = false
                            }
                        }
                        .disabled(testing || (!keyIsStored && apiKeyDraft.isEmpty))
                    }
                    if let testResult {
                        Text(testResult).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("The key never leaves this app — the keyboard extension makes no network calls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Transcription") {
                    Picker("Model", selection: modelBinding) {
                        ForEach(TranscriptionModel.allCases) { model in
                            Text(model.rawValue).tag(model)
                        }
                    }
                    TextField("Custom vocabulary (API prompt)", text: vocabularyBinding, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("History") {
                    Stepper(value: historyLimitBinding, in: 0...500, step: 10) {
                        Text("Keep \(model.settings.historyLimit) transcripts\(model.settings.historyLimit == 0 ? " (text not stored)" : "")")
                    }
                }

                Section("Cost") {
                    ForEach(TranscriptionModel.allCases) { transcriptionModel in
                        LabeledContent(transcriptionModel.rawValue) {
                            TextField(
                                "$/min",
                                value: rateBinding(for: transcriptionModel),
                                format: .number.precision(.fractionLength(0...5))
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        }
                    }
                    Text(String(format: "This month: $%.2f — this device only (estimate). Authoritative usage: OpenAI dashboard.", model.monthlyCost))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onAppear { keyIsStored = model.keychain.apiKey() != nil }
        }
    }

    private var modelBinding: Binding<TranscriptionModel> {
        Binding(
            get: { model.settings.model },
            set: { model.settings.model = $0 }
        )
    }

    private var vocabularyBinding: Binding<String> {
        Binding(
            get: { model.settings.vocabularyPrompt },
            set: { model.settings.vocabularyPrompt = $0 }
        )
    }

    private var historyLimitBinding: Binding<Int> {
        Binding(
            get: { model.settings.historyLimit },
            set: { model.settings.historyLimit = $0 }
        )
    }

    private func rateBinding(for transcriptionModel: TranscriptionModel) -> Binding<Double> {
        Binding(
            get: { model.settings.ratePerMinute(for: transcriptionModel) },
            set: { model.settings.setRatePerMinute($0, for: transcriptionModel) }
        )
    }
}
