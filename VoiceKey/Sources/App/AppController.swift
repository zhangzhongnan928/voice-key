import AppKit
import AVFoundation
import Foundation

/// Wires all modules together and owns the recording lifecycle.
@MainActor
final class AppController {
    let settings = SettingsStore()
    let keychain = KeychainStore()
    let store: TranscriptStore
    let recorder = Recorder()
    let hotkeys = HotkeyManager()
    let inserter = Inserter()
    let client = TranscriberClient()
    let statusItem = StatusItemController()
    let hud = RecordingHUDController()

    /// Row id of the in-flight recording.
    private var currentItemID: Int64?
    /// The item whose transcript should be auto-inserted when it completes
    /// (the recording the user just finished — retried history items are not
    /// auto-inserted).
    private var pendingInsertID: Int64?
    private var lastTranscript: String?
    private var isProcessing = false

    private let audioDirectory: URL

    init() throws {
        store = try TranscriptStore.onDisk()
        audioDirectory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("VoiceKey/audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    func start() {
        wireStatusItem()
        wireHotkeys()
        wireRecorder()
        Notifier.shared.requestAuthorization()
        requestMicPermissionIfNeeded()
        promptForAccessibilityIfNeeded()
        if keychain.apiKey() == nil {
            Notifier.shared.post(
                title: "VoiceKey needs an API key",
                body: "Open Settings from the menu bar icon and paste your OpenAI API key."
            )
        }
        Log.app.info("VoiceKey started")
    }

    // MARK: Wiring

    private func wireStatusItem() {
        statusItem.isRecordingProvider = { [weak self] in self?.recorder.isRecording ?? false }
        statusItem.lastTranscriptProvider = { [weak self] in self?.lastTranscript }
        statusItem.monthlyCostProvider = { [weak self] in
            guard let self else { return 0 }
            return self.settings.costTotal(forMonth: Self.monthKey(for: Date()))
        }
        statusItem.onToggleRecording = { [weak self] in self?.toggleRecording() }
        statusItem.onCopyLastTranscript = { [weak self] in
            guard let self, let last = self.lastTranscript else { return }
            self.inserter.setClipboard(last)
        }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onOpenHistory = { [weak self] in self?.openHistory() }
    }

    private func wireHotkeys() {
        hotkeys.mode = { [weak self] in self?.settings.hotkeyMode ?? .toggle }
        hotkeys.isRecording = { [weak self] in self?.recorder.isRecording ?? false }
        hotkeys.onStart = { [weak self] in self?.startRecording() }
        hotkeys.onStop = { [weak self] in self?.stopRecording() }
        hotkeys.onCancel = { [weak self] in self?.cancelRecording() }
        hotkeys.activate()
    }

    private func wireRecorder() {
        recorder.onLevel = { [weak self] level in self?.hud.model.level = level }
        recorder.onElapsed = { [weak self] elapsed in self?.hud.model.elapsed = elapsed }
        recorder.onDurationWarning = { [weak self] in
            guard let self else { return }
            self.hud.model.warning = true
            Notifier.shared.post(
                title: "Recording limit approaching",
                body: "Auto-stop in \(Int(self.settings.maxRecordingSeconds - self.settings.warnAtSeconds)) seconds."
            )
        }
        recorder.onAutoStop = { [weak self] in
            self?.finishRecording()
            Notifier.shared.post(title: "Recording auto-stopped", body: "Maximum duration reached. Transcribing what was captured.")
        }
        recorder.onDeviceLost = { [weak self] in
            self?.finishRecording()
            Notifier.shared.post(title: "Microphone disconnected", body: "Recording stopped. Transcribing what was captured.")
        }
        recorder.onWriteError = { [weak self] error in
            guard let self else { return }
            self.failCurrentRecording(error: "Disk write failed: \(error.localizedDescription)")
            Notifier.shared.post(title: "Recording failed", body: "Could not write audio to disk (disk full?).")
        }
    }

    // MARK: Recording lifecycle

    func toggleRecording() {
        recorder.isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !recorder.isRecording else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let url = audioDirectory.appendingPathComponent("rec-\(UUID().uuidString).wav")

        do {
            // Row exists before capture starts: never lose audio.
            let item = try store.createRecording(audioPath: url.path, appBundleId: frontmost)
            currentItemID = item.id
            try recorder.start(
                writingTo: url,
                warnAtSeconds: settings.warnAtSeconds,
                maxSeconds: settings.maxRecordingSeconds
            )
        } catch {
            Log.app.error("could not start recording: \(error.localizedDescription, privacy: .public)")
            if let id = currentItemID {
                try? store.transition(id: id, to: .failed) { $0.error = error.localizedDescription }
                currentItemID = nil
            }
            Notifier.shared.post(title: "Could not start recording", body: error.localizedDescription)
            return
        }

        hotkeys.installEscMonitor()
        hud.show()
        statusItem.setIcon(.recording)
        playSound("Pop")
    }

    func stopRecording() {
        guard recorder.isRecording else { return }
        recorder.stop()
        finishRecording()
    }

    /// Common path after capture ended (user stop, auto-stop, device lost):
    /// finalize duration, mark queued, kick the upload queue.
    private func finishRecording() {
        hotkeys.removeEscMonitor()
        hud.hide()
        playSound("Bottle")

        guard let id = currentItemID else {
            statusItem.setIcon(.idle)
            return
        }
        currentItemID = nil

        let duration = hud.model.elapsed
        do {
            let item = try store.transition(id: id, to: .queued) { $0.durationS = duration }
            pendingInsertID = item.id
            statusItem.setIcon(.uploading)
            processQueue()
        } catch {
            Log.store.error("queueing failed: \(error.localizedDescription, privacy: .public)")
            statusItem.setIcon(.error)
        }
    }

    func cancelRecording() {
        guard recorder.isRecording || currentItemID != nil else { return }
        recorder.stop()
        hotkeys.removeEscMonitor()
        hud.hide()
        statusItem.setIcon(.idle)
        if let id = currentItemID {
            try? store.delete(id: id)   // also removes the audio file
            currentItemID = nil
        }
        Log.app.info("recording cancelled")
    }

    private func failCurrentRecording(error message: String) {
        hotkeys.removeEscMonitor()
        hud.hide()
        statusItem.setIcon(.error)
        if let id = currentItemID {
            try? store.transition(id: id, to: .failed) { $0.error = message }
            currentItemID = nil
        }
    }

    // MARK: Upload processing (M2 happy path; durable queue lands in M3)

    func processQueue() {
        guard !isProcessing else { return }
        isProcessing = true
        Task { @MainActor in
            defer { self.isProcessing = false }
            while let item = try? self.store.nextQueued(), let id = item.id {
                await self.process(item: item, id: id)
            }
            self.statusItem.setIcon(.idle)
        }
    }

    private func process(item: TranscriptItem, id: Int64) async {
        guard let apiKey = keychain.apiKey() else {
            try? store.transition(id: id, to: .failed) { $0.error = TranscriberError.noAPIKey.localizedDescription }
            return
        }
        guard let audioURL = item.audioURL else {
            try? store.transition(id: id, to: .failed) { $0.error = "Audio file missing." }
            return
        }
        do {
            try store.transition(id: id, to: .uploading)
            let uploadURL = try prepareUpload(item: item, audioURL: audioURL)
            let text = try await client.transcribe(
                fileURL: uploadURL,
                model: settings.model.rawValue,
                language: settings.language.isEmpty ? nil : settings.language,
                prompt: settings.vocabularyPrompt.isEmpty ? nil : settings.vocabularyPrompt,
                apiKey: apiKey
            )
            complete(id: id, item: item, text: text)
        } catch {
            try? store.transition(id: id, to: .failed) { $0.error = error.localizedDescription }
            statusItem.setIcon(.error)
            Notifier.shared.post(title: "Transcription failed", body: error.localizedDescription)
        }
    }

    /// Transcodes recordings over 2 minutes to m4a before upload (F2/F3).
    private func prepareUpload(item: TranscriptItem, audioURL: URL) throws -> URL {
        guard item.durationS > AudioTranscoder.transcodeThresholdSeconds,
              audioURL.pathExtension == "wav" else { return audioURL }
        let m4aURL = audioURL.deletingPathExtension().appendingPathExtension("m4a")
        if !FileManager.default.fileExists(atPath: m4aURL.path) {
            try AudioTranscoder.transcodeToM4A(input: audioURL, output: m4aURL)
        }
        return m4aURL
    }

    /// Marks an item done, records cost, prunes history, inserts if it is the
    /// recording the user just finished.
    private func complete(id: Int64, item: TranscriptItem, text: String) {
        let storeText = settings.historyLimit > 0
        let rate = settings.ratePerMinute(for: settings.model)
        let cost = CostMeter.cost(durationSeconds: item.durationS, ratePerMinute: rate)
        settings.addCost(cost, forMonth: Self.monthKey(for: Date()))
        checkCostThreshold()

        do {
            try store.transition(id: id, to: .done) {
                $0.text = storeText ? text : nil
                $0.costUsd = cost
                $0.error = nil
            }
        } catch {
            Log.store.error("complete transition failed: \(error.localizedDescription, privacy: .public)")
        }

        if !settings.keepAudio, let audioURL = item.audioURL {
            try? FileManager.default.removeItem(at: audioURL)
            let m4a = audioURL.deletingPathExtension().appendingPathExtension("m4a")
            try? FileManager.default.removeItem(at: m4a)
            try? store.update(id: id) { $0.audioPath = nil }
        }
        try? store.pruneHistory(limit: max(settings.historyLimit, 1))

        lastTranscript = text

        if pendingInsertID == id {
            pendingInsertID = nil
            let outcome = inserter.insert(
                text,
                strategy: settings.insertionStrategy,
                clipboardRestoreDelayMs: settings.clipboardRestoreDelayMs
            )
            if case .clipboardFallback(let reason) = outcome {
                Notifier.shared.post(title: "Transcript in clipboard", body: reason)
            }
        }
    }

    func checkCostThreshold() {
        let month = Self.monthKey(for: Date())
        let threshold = settings.monthlyAlertUSD
        guard threshold > 0,
              settings.costAlertedMonth != month,
              settings.costTotal(forMonth: month) >= threshold else { return }
        settings.costAlertedMonth = month
        Notifier.shared.post(
            title: "Monthly cost alert",
            body: String(format: "Transcription spend this month passed $%.2f.", threshold)
        )
    }

    static func monthKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    // MARK: Permissions

    private func requestMicPermissionIfNeeded() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.app.info("microphone permission granted=\(granted)")
            }
        }
    }

    private func promptForAccessibilityIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: UI hooks (placeholder until M4 Settings/History windows)

    func openSettings() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Stored in the macOS Keychain. Full settings UI arrives in M4."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "sk-..."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            keychain.setAPIKey(field.stringValue)
        }
    }

    func openHistory() {
        // History popover lands in M4.
    }

    func playSound(_ name: String) {
        guard settings.soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
