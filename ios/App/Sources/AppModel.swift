import AVFoundation
import Foundation
import SwiftUI

/// Container-app glue: same store/state machine/queue/client as desktop
/// (F4/F5), recording via AVAudioSession + the shared Recorder, queue and
/// history in the App Group SQLite (WAL), API key in this app's Keychain
/// only — the keyboard never sees it.
@MainActor
final class AppModel: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0
    @Published var statusText = ""
    @Published var lastTranscript: String?
    /// Shown after a keyboard-initiated dictation completes; iOS has no API
    /// to name or switch to the previous app, so the banner says "swipe back".
    @Published var showReturnBanner = false
    @Published var historyItems: [TranscriptItem] = []
    /// Non-nil when the App Group container is unavailable (entitlement
    /// misconfigured); the app runs on a non-shared fallback store so it is
    /// still usable, but the keyboard cannot see transcripts.
    @Published var setupWarning: String?

    let settings: SettingsStore
    let keychain = KeychainStore()
    let store: TranscriptStore
    let recorder = Recorder()
    let client = TranscriberClient()
    private(set) var queue: UploadQueue!

    private var currentItemID: Int64?
    /// Item whose completion should arm the keyboard's consume-once insert
    /// (only for dictations started from the keyboard handoff).
    private var handoffItemID: Int64?
    private var launchedFromKeyboard = false
    private let audioDirectory: URL

    init() {
        var warning: String?
        if let dbURL = AppGroup.databaseURL, let audioDir = AppGroup.audioDirectory {
            audioDirectory = audioDir
            if let shared = try? TranscriptStore(path: dbURL.path) {
                store = shared
            } else {
                store = try! TranscriptStore(inMemory: ())
                warning = "Shared database could not be opened; transcripts won't reach the keyboard."
            }
        } else {
            audioDirectory = FileManager.default.temporaryDirectory
            store = try! TranscriptStore(inMemory: ())
            warning = "App Group container unavailable. Check the group.com.victor.voicekey entitlement; the keyboard cannot see transcripts."
        }
        settings = SettingsStore(defaults: AppGroup.defaults)
        setupWarning = warning

        queue = UploadQueue(
            store: store,
            client: client,
            apiKeyProvider: { [keychain] in keychain.apiKey() },
            paramsProvider: { [settings] in
                UploadQueue.RequestParams(
                    model: settings.model.rawValue,
                    language: settings.language.isEmpty ? nil : settings.language,
                    prompt: settings.vocabularyPrompt.isEmpty ? nil : settings.vocabularyPrompt
                )
            }
        )
        queue.onEvent = { [weak self] event in self?.handleQueueEvent(event) }

        wireRecorder()
        try? store.recoverOnLaunch()
        queue.start()
        reloadHistory()
    }

    // MARK: URL scheme (keyboard handoff)

    func handleURL(_ url: URL) {
        guard url.scheme == "voicekey" else { return }
        if url.host == "record" {
            launchedFromKeyboard = true
            showReturnBanner = false
            startRecording()
        }
    }

    // MARK: Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !recorder.isRecording else { return }
        statusText = ""

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.statusText = "Microphone access denied. Enable it in Settings > Privacy > Microphone."
                    return
                }
                self.beginCapture()
            }
        }
    }

    private func beginCapture() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let url = audioDirectory.appendingPathComponent("rec-\(UUID().uuidString).caf")
            let item = try store.createRecording(audioPath: url.path, appBundleId: nil)
            currentItemID = item.id
            try recorder.start(
                writingTo: url,
                warnAtSeconds: settings.warnAtSeconds,
                maxSeconds: settings.maxRecordingSeconds
            )
            isRecording = true
        } catch {
            statusText = "Could not start recording: \(error.localizedDescription)"
            if let id = currentItemID {
                try? store.transition(id: id, to: .failed) { $0.error = error.localizedDescription }
                currentItemID = nil
            }
        }
    }

    func stopRecording() {
        guard recorder.isRecording else { return }
        recorder.stop()
        finishRecording()
    }

    func cancelRecording() {
        recorder.stop()
        isRecording = false
        if let id = currentItemID {
            try? store.delete(id: id)
            currentItemID = nil
        }
        deactivateSession()
        reloadHistory()
    }

    private func finishRecording() {
        isRecording = false
        deactivateSession()
        guard let id = currentItemID else { return }
        currentItemID = nil

        do {
            _ = try store.transition(id: id, to: .queued) {
                $0.durationS = self.elapsed
                $0.stoppedAt = Date()
            }
            if launchedFromKeyboard {
                handoffItemID = id
                launchedFromKeyboard = false
            }
            statusText = "Transcribing…"
            queue.kick()
        } catch {
            statusText = "Could not queue recording: \(error.localizedDescription)"
        }
        reloadHistory()
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func wireRecorder() {
        recorder.onLevel = { [weak self] level in self?.level = level }
        recorder.onElapsed = { [weak self] elapsed in self?.elapsed = elapsed }
        recorder.onAutoStop = { [weak self] in self?.finishRecording() }
        recorder.onDeviceLost = { [weak self] in self?.finishRecording() }
        recorder.onWriteError = { [weak self] error in
            guard let self else { return }
            self.isRecording = false
            if let id = self.currentItemID {
                try? self.store.transition(id: id, to: .failed) {
                    $0.error = "Disk write failed: \(error.localizedDescription)"
                }
                self.currentItemID = nil
            }
            self.statusText = "Recording failed: could not write audio."
        }
    }

    // MARK: Queue events

    private func handleQueueEvent(_ event: UploadQueue.Event) {
        switch event {
        case .uploading:
            statusText = "Transcribing…"
        case .transcribed(let item, let text):
            if let id = item.id { complete(id: id, item: item, text: text) }
        case .failedPermanently(let item, let needsKeyCheck):
            statusText = needsKeyCheck
                ? "Check API key in Settings."
                : (item.error ?? "Transcription failed. Retry from History.")
            reloadHistory()
        case .idle:
            break
        }
    }

    private func complete(id: Int64, item: TranscriptItem, text: String) {
        let storeText = settings.historyLimit > 0
        let rate = settings.ratePerMinute(for: settings.model)
        let cost = CostMeter.cost(durationSeconds: item.durationS, ratePerMinute: rate)
        settings.addCost(cost, forMonth: Self.monthKey(for: Date()))

        try? store.transition(id: id, to: .done) {
            $0.text = storeText ? text : nil
            $0.costUsd = cost
            $0.error = nil
        }
        if !settings.keepAudio, let audioURL = item.audioURL {
            let base = audioURL.deletingPathExtension()
            for ext in ["caf", "wav", "m4a"] {
                try? FileManager.default.removeItem(at: base.appendingPathExtension(ext))
            }
            try? store.update(id: id) { $0.audioPath = nil }
        }
        try? store.pruneHistory(limit: max(settings.historyLimit, 1))

        lastTranscript = text
        statusText = "Done."

        if handoffItemID == id {
            handoffItemID = nil
            try? store.setPendingInsert(transcriptId: id, text: text)
            showReturnBanner = true
        }
        reloadHistory()
    }

    // MARK: History

    func reloadHistory() {
        historyItems = (try? store.recent(limit: max(settings.historyLimit, 1))) ?? []
    }

    func retry(item: TranscriptItem) {
        guard let id = item.id else { return }
        try? store.manualRetry(id: id)
        queue.kick()
        reloadHistory()
    }

    func delete(item: TranscriptItem) {
        guard let id = item.id else { return }
        try? store.delete(id: id)
        reloadHistory()
    }

    var monthlyCost: Double {
        settings.costTotal(forMonth: Self.monthKey(for: Date()))
    }

    static func monthKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
