import Foundation
import Network

/// Durable upload worker (F5). Items live in SQLite; this class drains the
/// `queued` state. Uploads pause while offline (NWPathMonitor) and resume on
/// reconnect. Retryable failures back off per RetryPolicy; permanent failures
/// and exhausted retries move the item to `failed` (audio kept).
@MainActor
final class UploadQueue {
    struct RequestParams {
        var model: String
        var language: String?
        var prompt: String?
    }

    enum Event {
        case uploading(TranscriptItem)
        /// Transcription succeeded; the item is still in `uploading` state —
        /// the handler owns the `done` transition (text, cost, insertion).
        case transcribed(item: TranscriptItem, text: String)
        /// CR-4: `needsKeyCheck` is true for 401/403/missing key so the UI
        /// can tell the owner to check the API key in Settings.
        case failedPermanently(TranscriptItem, needsKeyCheck: Bool)
        case idle
    }

    var onEvent: ((Event) -> Void)?

    private let store: TranscriptStore
    private let client: TranscriberClient
    private let clock: AsyncClock
    private let apiKeyProvider: () -> String?
    private let paramsProvider: () -> RequestParams

    private let pathMonitor = NWPathMonitor()
    private(set) var isOnline = true
    private var worker: Task<Void, Never>?

    init(
        store: TranscriptStore,
        client: TranscriberClient,
        clock: AsyncClock = RealClock(),
        apiKeyProvider: @escaping () -> String?,
        paramsProvider: @escaping () -> RequestParams
    ) {
        self.store = store
        self.client = client
        self.clock = clock
        self.apiKeyProvider = apiKeyProvider
        self.paramsProvider = paramsProvider
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasOnline = self.isOnline
                self.isOnline = online
                if online && !wasOnline {
                    Log.net.info("network restored; resuming uploads")
                    self.kick()
                } else if !online {
                    Log.net.info("offline; uploads paused")
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "voicekey.pathmonitor"))
        kick()
    }

    /// Ensures a worker task is draining the queue.
    func kick() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            await self?.drain()
            self?.worker = nil
        }
    }

    private func drain() async {
        while isOnline {
            guard let item = try? store.nextQueued(), let id = item.id else { break }
            await process(item: item, id: id)
        }
        onEvent?(.idle)
    }

    private func process(item: TranscriptItem, id: Int64) async {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            fail(id: id, message: TranscriberError.noAPIKey.localizedDescription, needsKeyCheck: true)
            return
        }
        guard let audioURL = item.audioURL, FileManager.default.fileExists(atPath: audioURL.path) else {
            fail(id: id, message: "Audio file missing.")
            return
        }

        let current: TranscriptItem
        do {
            current = try store.transition(id: id, to: .uploading)
        } catch {
            Log.store.error("uploading transition failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        onEvent?(.uploading(current))

        do {
            let uploadURL = try await prepareUpload(item: current, audioURL: audioURL)
            let params = paramsProvider()
            let text = try await client.transcribe(
                fileURL: uploadURL,
                model: params.model,
                language: params.language,
                prompt: params.prompt,
                apiKey: apiKey
            )
            onEvent?(.transcribed(item: current, text: text))
        } catch {
            await handleFailure(id: id, item: current, error: error)
        }
    }

    /// CR-1: the CAF capture is never uploaded — produce the wav/m4a upload
    /// artifact off the main thread. The 24 MB cap is enforced by the client.
    private func prepareUpload(item: TranscriptItem, audioURL: URL) async throws -> URL {
        guard audioURL.pathExtension == "caf" else {
            return audioURL   // legacy pre-CR-1 items uploaded directly
        }
        let duration = item.durationS
        return try await Task.detached(priority: .utility) {
            try AudioTranscoder.makeUploadArtifact(captureURL: audioURL, durationS: duration)
        }.value
    }

    private func handleFailure(id: Int64, item: TranscriptItem, error: Error) async {
        let transcriberError = error as? TranscriberError
        let retryable = transcriberError?.isRetryable ?? true
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        guard retryable, let backoff = RetryPolicy.delay(afterFailures: item.retryCount) else {
            fail(id: id, message: message, needsKeyCheck: transcriberError?.needsKeyCheck ?? false)
            return
        }
        // CR-4: on 429, honor Retry-After when present.
        let delay = max(backoff, transcriberError?.retryAfterSeconds ?? 0)

        do {
            try store.transition(id: id, to: .queued) {
                $0.retryCount += 1
                $0.error = message
            }
        } catch {
            Log.store.error("requeue failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        Log.net.info("item \(id) retry \(item.retryCount + 1)/\(RetryPolicy.maxRetries) in \(delay, format: .fixed(precision: 0))s")
        try? await clock.sleep(seconds: delay)
    }

    /// Terminal failure. Audio is kept regardless of the keep-audio setting
    /// so a manual retry from History is always possible.
    private func fail(id: Int64, message: String, needsKeyCheck: Bool = false) {
        let failedItem = try? store.transition(id: id, to: .failed) { $0.error = message }
        Log.net.error("item \(id) failed permanently: \(message, privacy: .public)")
        if let failedItem {
            onEvent?(.failedPermanently(failedItem, needsKeyCheck: needsKeyCheck))
        }
    }
}
