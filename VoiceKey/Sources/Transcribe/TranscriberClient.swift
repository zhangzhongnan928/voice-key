import Foundation

enum TranscriberError: Error, Equatable, LocalizedError {
    case noAPIKey
    case fileTooLarge(bytes: Int)
    case http(status: Int, body: String, retryAfter: TimeInterval?)
    case network(String)
    case timeout
    case malformedResponse(String)

    /// CR-4 retry taxonomy. Retryable: URL errors (offline, timeout),
    /// HTTP 408, 429, 5xx. Everything else (400/401/403/413/422, parse
    /// errors, oversize) fails immediately.
    var isRetryable: Bool {
        switch self {
        case .http(let status, _, _):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .network, .timeout:
            return true
        case .noAPIKey, .fileTooLarge, .malformedResponse:
            return false
        }
    }

    /// CR-4: 401/403 (and a missing key) should tell the owner to check the
    /// API key in Settings.
    var needsKeyCheck: Bool {
        switch self {
        case .noAPIKey:
            return true
        case .http(let status, _, _):
            return status == 401 || status == 403
        default:
            return false
        }
    }

    /// Server-requested minimum wait (Retry-After on 429), if any.
    var retryAfterSeconds: TimeInterval? {
        if case .http(_, _, let retryAfter) = self { return retryAfter }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Add it in Settings."
        case .fileTooLarge(let bytes):
            return "Encoded audio is \(bytes / 1_048_576) MB, over the 24 MB upload limit."
        case .http(let status, let body, _):
            return "API error HTTP \(status): \(String(body.prefix(200)))"
        case .network(let detail):
            return "Network error: \(detail)"
        case .timeout:
            return "Request timed out."
        case .malformedResponse(let body):
            return "Unexpected API response: \(String(body.prefix(200)))"
        }
    }
}

/// OpenAI transcription API client. Stateless; the session configuration is
/// injectable so tests can register a URLProtocol mock.
final class TranscriberClient {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!

    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        // CR-5: 30 s inactivity timeout, 10 min total — a 15-minute
        // recording's upload must not die on a fixed short total timeout.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration)
    }

    /// Uploads `fileURL` and returns the transcript text.
    func transcribe(
        fileURL: URL,
        model: String,
        language: String?,
        prompt: String?,
        apiKey: String
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw TranscriberError.noAPIKey }
        let size = AudioTranscoder.fileSize(at: fileURL)
        guard size <= AudioTranscoder.maxUploadBytes else {
            throw TranscriberError.fileTooLarge(bytes: size)
        }

        let boundary = "voicekey-\(UUID().uuidString)"
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.multipartBody(
            boundary: boundary,
            fileURL: fileURL,
            model: model,
            language: language,
            prompt: prompt
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw TranscriberError.timeout
        } catch {
            throw TranscriberError.network(error.localizedDescription)
        }

        let httpResponse = response as? HTTPURLResponse
        let status = httpResponse?.statusCode ?? 0
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else {
            throw TranscriberError.http(
                status: status,
                body: bodyText,
                retryAfter: RetryPolicy.parseRetryAfter(httpResponse?.value(forHTTPHeaderField: "Retry-After"))
            )
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw TranscriberError.malformedResponse(bodyText)
        }
        return text
    }

    /// Cheap key validation for the Settings "Test" button: lists models.
    func testKey(_ apiKey: String) async throws {
        guard !apiKey.isEmpty else { throw TranscriberError.noAPIKey }
        var request = URLRequest(url: Self.modelsEndpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranscriberError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TranscriberError.http(status: status, body: String(data: data, encoding: .utf8) ?? "", retryAfter: nil)
        }
    }

    static func multipartBody(
        boundary: String,
        fileURL: URL,
        model: String,
        language: String?,
        prompt: String?
    ) throws -> Data {
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }

        appendField("model", model)
        if let language, !language.isEmpty {
            appendField("language", language)
        }
        if let prompt, !prompt.isEmpty {
            appendField("prompt", prompt)
        }

        let filename = fileURL.lastPathComponent
        let contentType = filename.hasSuffix(".m4a") ? "audio/m4a" : "audio/wav"
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(try Data(contentsOf: fileURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
