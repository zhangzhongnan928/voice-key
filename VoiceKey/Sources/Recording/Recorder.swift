import AVFoundation
import Foundation

/// Captures microphone audio with an AVAudioEngine tap and writes 16 kHz mono
/// 16-bit WAV to disk *incrementally* — never buffered only in memory, so a
/// crash mid-recording loses at most the last buffer (~0.25 s).
final class Recorder {
    enum RecorderError: Error, LocalizedError {
        case noInputDevice
        case formatSetup(String)
        case diskWrite(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No usable microphone was found."
            case .formatSetup(let detail): return "Audio setup failed: \(detail)"
            case .diskWrite(let detail): return "Could not write audio to disk: \(detail)"
            }
        }
    }

    enum StopReason {
        case user
        case cancelled
        case autoStop          // hit the configured maximum duration
        case deviceLost        // input device disappeared mid-recording
        case error(Error)      // e.g. disk full
    }

    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var startDate: Date?
    private var tickTimer: Timer?
    private var warned = false
    private(set) var isRecording = false
    private(set) var currentURL: URL?

    // Limits, injected from settings at start.
    private var warnAtSeconds: Double = 840
    private var maxSeconds: Double = 900

    // Callbacks fire on the main queue.
    var onLevel: ((Float) -> Void)?
    var onElapsed: ((TimeInterval) -> Void)?
    var onDurationWarning: (() -> Void)?
    var onAutoStop: (() -> Void)?
    var onDeviceLost: (() -> Void)?
    var onWriteError: ((Error) -> Void)?

    var elapsed: TimeInterval {
        startDate.map { Date().timeIntervalSince($0) } ?? 0
    }

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configurationChanged),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start(writingTo url: URL, warnAtSeconds: Double, maxSeconds: Double) throws {
        precondition(!isRecording, "Recorder.start while already recording")
        self.warnAtSeconds = warnAtSeconds
        self.maxSeconds = maxSeconds
        warned = false

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw RecorderError.formatSetup("cannot create 16 kHz mono format")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.formatSetup("cannot convert from \(inputFormat)")
        }
        self.converter = converter

        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw RecorderError.diskWrite(error.localizedDescription)
        }
        currentURL = url

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, inputFormat: inputFormat, targetFormat: targetFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw RecorderError.formatSetup(error.localizedDescription)
        }

        startDate = Date()
        isRecording = true
        Log.audio.info("recording started -> \(url.lastPathComponent, privacy: .public)")

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Stops capture. The WAV on disk is complete and valid after this
    /// returns. Returns the recorded duration in seconds.
    @discardableResult
    func stop() -> TimeInterval {
        guard isRecording else { return 0 }
        let duration = elapsed
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tickTimer?.invalidate()
        tickTimer = nil
        file = nil          // closes the file, finalizing the WAV header
        converter = nil
        isRecording = false
        startDate = nil
        Log.audio.info("recording stopped, duration \(duration, format: .fixed(precision: 1))s")
        return duration
    }

    // MARK: - Private

    private func handle(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        // Level meter from the raw input buffer.
        if let channel = buffer.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames { sum += channel[i] * channel[i] }
            let rms = frames > 0 ? sqrtf(sum / Float(frames)) : 0
            // Map RMS to a 0...1 display level (-50 dB floor).
            let db = 20 * log10f(max(rms, 1e-7))
            let level = max(0, min(1, (db + 50) / 50))
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }

        guard let converter, let file else { return }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, converted.frameLength > 0 else { return }

        do {
            try file.write(from: converted)
        } catch {
            // Disk full or I/O error: stop gracefully, keep what we have.
            Log.audio.error("audio write failed: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRecording else { return }
                self.stop()
                self.onWriteError?(error)
            }
        }
    }

    private func tick() {
        guard isRecording else { return }
        let elapsed = self.elapsed
        onElapsed?(elapsed)
        if !warned, elapsed >= warnAtSeconds {
            warned = true
            onDurationWarning?()
        }
        if elapsed >= maxSeconds {
            stop()
            onAutoStop?()
        }
    }

    /// Fired when the engine configuration changes — typically the input
    /// device disappearing (AirPods died, USB mic unplugged). Stop gracefully
    /// and let the controller queue whatever was captured.
    @objc private func configurationChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            Log.audio.warning("input configuration changed mid-recording; stopping gracefully")
            self.stop()
            self.onDeviceLost?()
        }
    }
}
