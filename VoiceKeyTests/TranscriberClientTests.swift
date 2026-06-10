import XCTest
@testable import VoiceKey

final class TranscriberClientTests: XCTestCase {
    private var client: TranscriberClient!
    private var audioURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = TranscriberClient(configuration: config)

        audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-test-\(UUID().uuidString).wav")
        try Data(repeating: 0xAB, count: 128).write(to: audioURL)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: audioURL)
        super.tearDown()
    }

    private func transcribe() async throws -> String {
        try await client.transcribe(
            fileURL: audioURL,
            model: "gpt-4o-mini-transcribe",
            language: nil,
            prompt: "VoiceKey, GRDB",
            apiKey: "sk-test"
        )
    }

    func testSuccessParsesText() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url, TranscriberClient.endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") ?? false)
            return (200, Data(#"{"text": "你好 hello world"}"#.utf8))
        }
        let text = try await transcribe()
        XCTAssertEqual(text, "你好 hello world")
    }

    func test429IsRetryable() async throws {
        MockURLProtocol.handler = { _ in (429, Data(#"{"error": {"message": "rate limited"}}"#.utf8)) }
        do {
            _ = try await transcribe()
            XCTFail("expected error")
        } catch let error as TranscriberError {
            XCTAssertEqual(error, .http(status: 429, body: #"{"error": {"message": "rate limited"}}"#))
            XCTAssertTrue(error.isRetryable)
        }
    }

    func test500IsRetryable() async throws {
        MockURLProtocol.handler = { _ in (500, Data()) }
        do {
            _ = try await transcribe()
            XCTFail("expected error")
        } catch let error as TranscriberError {
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testTimeoutMapsToTimeoutError() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await transcribe()
            XCTFail("expected error")
        } catch let error as TranscriberError {
            XCTAssertEqual(error, .timeout)
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testMalformedJSONIsPermanentFailure() async throws {
        MockURLProtocol.handler = { _ in (200, Data("not json at all".utf8)) }
        do {
            _ = try await transcribe()
            XCTFail("expected error")
        } catch let error as TranscriberError {
            XCTAssertEqual(error, .malformedResponse("not json at all"))
            XCTAssertFalse(error.isRetryable)
        }
    }

    func testMissingTextFieldIsMalformed() async throws {
        MockURLProtocol.handler = { _ in (200, Data(#"{"transcript": "wrong key"}"#.utf8)) }
        do {
            _ = try await transcribe()
            XCTFail("expected error")
        } catch let error as TranscriberError {
            if case .malformedResponse = error {} else {
                XCTFail("expected malformedResponse, got \(error)")
            }
        }
    }

    func testOversizedFileRejectedBeforeUpload() async throws {
        // No handler: the request must never be sent.
        MockURLProtocol.handler = { _ in
            XCTFail("oversized file must not be uploaded")
            return (200, Data())
        }
        let bigURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("big-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: bigURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: bigURL)
        try handle.truncate(atOffset: UInt64(AudioTranscoder.maxUploadBytes) + 1)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: bigURL) }

        do {
            _ = try await client.transcribe(fileURL: bigURL, model: "whisper-1", language: nil, prompt: nil, apiKey: "sk-test")
            XCTFail("expected fileTooLarge")
        } catch let error as TranscriberError {
            if case .fileTooLarge = error {
                XCTAssertFalse(error.isRetryable)
            } else {
                XCTFail("expected fileTooLarge, got \(error)")
            }
        }
    }

    func testMultipartBodyContainsFields() throws {
        let body = try TranscriberClient.multipartBody(
            boundary: "B",
            fileURL: audioURL,
            model: "whisper-1",
            language: "zh",
            prompt: "GRDB"
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nwhisper-1"))
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nzh"))
        XCTAssertTrue(text.contains("name=\"prompt\"\r\n\r\nGRDB"))
        XCTAssertTrue(text.contains("name=\"file\""))
        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
    }

    func testLanguageOmittedWhenAuto() throws {
        let body = try TranscriberClient.multipartBody(
            boundary: "B",
            fileURL: audioURL,
            model: "gpt-4o-mini-transcribe",
            language: nil,
            prompt: nil
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("name=\"language\""), "auto language must omit the field")
        XCTAssertFalse(text.contains("name=\"prompt\""))
    }
}
