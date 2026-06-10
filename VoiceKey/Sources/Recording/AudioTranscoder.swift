import AVFoundation
import Foundation

/// Transcodes long WAV recordings to AAC (~32 kbps m4a) before upload to keep
/// payloads small. Used when duration > 2 minutes (see F2).
enum AudioTranscoder {
    /// Recordings longer than this are transcoded before upload.
    static let transcodeThresholdSeconds: Double = 120

    /// Maximum encoded upload size accepted by the API path (F3).
    static let maxUploadBytes: Int = 24 * 1024 * 1024

    enum TranscodeError: Error, LocalizedError {
        case read(String)
        case write(String)

        var errorDescription: String? {
            switch self {
            case .read(let detail): return "Could not read recording: \(detail)"
            case .write(let detail): return "Could not encode m4a: \(detail)"
            }
        }
    }

    /// Synchronously transcodes `input` (WAV) to `output` (.m4a, AAC 32 kbps
    /// mono). Call off the main thread.
    static func transcodeToM4A(input: URL, output: URL) throws {
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: input)
        } catch {
            throw TranscodeError.read(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        try? FileManager.default.removeItem(at: output)
        let outFile: AVAudioFile
        do {
            outFile = try AVAudioFile(forWriting: output, settings: settings)
        } catch {
            throw TranscodeError.write(error.localizedDescription)
        }

        let format = sourceFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw TranscodeError.write("cannot allocate transcode buffer")
        }
        while true {
            do {
                try sourceFile.read(into: buffer)
            } catch {
                throw TranscodeError.read(error.localizedDescription)
            }
            if buffer.frameLength == 0 { break }
            do {
                try outFile.write(from: buffer)
            } catch {
                throw TranscodeError.write(error.localizedDescription)
            }
            if sourceFile.framePosition >= sourceFile.length { break }
        }
    }

    static func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int) ?? 0
    }
}
