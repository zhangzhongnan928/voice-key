import AVFoundation
import Foundation

/// CR-1: capture is CAF (truncation-tolerant); the API does not accept CAF,
/// so an upload artifact is always produced after stop or during recovery:
/// <= 2 min -> WAV (PCM), > 2 min -> M4A (AAC ~32 kbps).
enum AudioTranscoder {
    /// Recordings longer than this upload as m4a instead of wav.
    static let transcodeThresholdSeconds: Double = 120

    /// Maximum encoded upload size accepted by the API path (F3).
    static let maxUploadBytes: Int = 24 * 1024 * 1024

    enum TranscodeError: Error, LocalizedError {
        case read(String)
        case write(String)

        var errorDescription: String? {
            switch self {
            case .read(let detail): return "Could not read recording: \(detail)"
            case .write(let detail): return "Could not encode upload audio: \(detail)"
            }
        }
    }

    /// Produces (or reuses) the upload artifact next to the CAF capture
    /// file. Synchronous; call off the main thread.
    static func makeUploadArtifact(captureURL: URL, durationS: Double) throws -> URL {
        let useM4A = durationS > transcodeThresholdSeconds
        let output = captureURL.deletingPathExtension()
            .appendingPathExtension(useM4A ? "m4a" : "wav")
        if fileSize(at: output) > 0 {
            return output   // already transcoded (e.g. retry after crash)
        }

        let settings: [String: Any]
        if useM4A {
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
        } else {
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
        try convert(input: captureURL, output: output, settings: settings)
        return output
    }

    private static func convert(input: URL, output: URL, settings: [String: Any]) throws {
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: input)
        } catch {
            throw TranscodeError.read(error.localizedDescription)
        }

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
