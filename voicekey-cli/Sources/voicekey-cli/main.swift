// voicekey-cli — M1 spike for VoiceKey.
// Records N seconds (default 3) from the default microphone to a 16 kHz mono
// 16-bit WAV on disk, uploads it to the OpenAI transcription API, and prints
// the transcript to stdout.
//
// Usage:
//   OPENAI_API_KEY=sk-... swift run voicekey-cli [--seconds 3] [--model gpt-4o-mini-transcribe] [--keep]
//   OPENAI_API_KEY=sk-... swift run voicekey-cli --selftest

import AVFoundation
import Foundation

// MARK: - Argument parsing

struct CLIOptions {
    var seconds: Double = 3
    var model = "gpt-4o-mini-transcribe"
    var keepAudio = false
    var selftest = false

    static func parse(_ args: [String]) -> CLIOptions {
        var options = CLIOptions()
        var iterator = args.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--seconds":
                if let value = iterator.next(), let seconds = Double(value), seconds > 0 {
                    options.seconds = min(seconds, 60)
                }
            case "--model":
                if let value = iterator.next() { options.model = value }
            case "--keep":
                options.keepAudio = true
            case "--selftest":
                options.selftest = true
            case "--help", "-h":
                print("""
                voicekey-cli — record from the default mic and print the transcript.

                  --seconds N   recording length in seconds (default 3, max 60)
                  --model M     gpt-4o-mini-transcribe | gpt-4o-transcribe | whisper-1
                  --keep        keep the recorded WAV file on disk
                  --selftest    3 s end-to-end round trip, exits 0 on success

                Requires OPENAI_API_KEY in the environment.
                """)
                exit(0)
            default:
                fputs("warning: ignoring unknown argument \(arg)\n", stderr)
            }
        }
        return options
    }
}

// MARK: - Recording

enum CLIError: Error, CustomStringConvertible {
    case noAPIKey
    case micPermissionDenied
    case audioFormat(String)
    case http(Int, String)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .noAPIKey:
            return "OPENAI_API_KEY is not set. Run: export OPENAI_API_KEY=sk-..."
        case .micPermissionDenied:
            return "Microphone permission denied. Grant it in System Settings > Privacy & Security > Microphone (for your terminal app), then retry."
        case .audioFormat(let detail):
            return "Audio setup failed: \(detail)"
        case .http(let status, let body):
            return "API request failed with HTTP \(status): \(body)"
        case .malformedResponse(let body):
            return "Could not parse API response: \(body)"
        }
    }
}

func requestMicPermission() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            semaphore.signal()
        }
        semaphore.wait()
        return granted
    default:
        return false
    }
}

/// Records `seconds` of audio from the default input device, writing
/// 16 kHz mono 16-bit PCM to `url` incrementally (the file is valid on disk
/// the moment recording stops — nothing is buffered only in memory).
func record(seconds: Double, to url: URL) throws {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0 else {
        throw CLIError.audioFormat("no usable input device (sample rate 0)")
    }

    guard let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    ) else {
        throw CLIError.audioFormat("could not create 16 kHz mono target format")
    }

    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
        throw CLIError.audioFormat("could not convert \(inputFormat) to 16 kHz mono")
    }

    let file = try AVAudioFile(
        forWriting: url,
        settings: targetFormat.settings,
        commonFormat: .pcmFormatInt16,
        interleaved: true
    )

    var writeError: Error?
    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
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
        if conversionError == nil, converted.frameLength > 0 {
            do { try file.write(from: converted) } catch { writeError = error }
        }
    }

    engine.prepare()
    try engine.start()
    print("Recording \(Int(seconds)) seconds... speak now.")
    Thread.sleep(forTimeInterval: seconds)
    input.removeTap(onBus: 0)
    engine.stop()

    if let writeError {
        throw CLIError.audioFormat("disk write failed: \(writeError.localizedDescription)")
    }
}

// MARK: - Upload

func multipartBody(boundary: String, fileURL: URL, model: String) throws -> Data {
    var body = Data()
    func append(_ string: String) { body.append(Data(string.utf8)) }

    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")

    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
    append("Content-Type: audio/wav\r\n\r\n")
    body.append(try Data(contentsOf: fileURL))
    append("\r\n--\(boundary)--\r\n")
    return body
}

func transcribe(fileURL: URL, model: String, apiKey: String) throws -> String {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    let boundary = "voicekey-\(UUID().uuidString)"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = try multipartBody(boundary: boundary, fileURL: fileURL, model: model)

    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<String, Error> = .failure(CLIError.malformedResponse("no response"))

    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error {
            result = .failure(error)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard (200..<300).contains(status) else {
            result = .failure(CLIError.http(status, bodyText))
            return
        }
        guard
            let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            result = .failure(CLIError.malformedResponse(bodyText))
            return
        }
        result = .success(text)
    }.resume()

    semaphore.wait()
    return try result.get()
}

// MARK: - Main

let options = CLIOptions.parse(CommandLine.arguments)
let seconds = options.selftest ? 3 : options.seconds

guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
    fputs("error: \(CLIError.noAPIKey)\n", stderr)
    exit(1)
}

guard requestMicPermission() else {
    fputs("error: \(CLIError.micPermissionDenied)\n", stderr)
    exit(1)
}

let audioURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("voicekey-cli-\(UUID().uuidString).wav")

do {
    try record(seconds: seconds, to: audioURL)
    let attributes = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
    let size = (attributes?[.size] as? Int) ?? 0
    print("Captured \(audioURL.lastPathComponent) (\(size) bytes). Uploading to \(options.model)...")
    let text = try transcribe(fileURL: audioURL, model: options.model, apiKey: apiKey)
    print("---")
    print(text)
    print("---")
    if options.keepAudio {
        print("Audio kept at \(audioURL.path)")
    } else {
        try? FileManager.default.removeItem(at: audioURL)
    }
    if options.selftest {
        print("selftest: OK")
    }
    exit(0)
} catch {
    try? FileManager.default.removeItem(at: audioURL)
    fputs("error: \(error)\n", stderr)
    exit(1)
}
