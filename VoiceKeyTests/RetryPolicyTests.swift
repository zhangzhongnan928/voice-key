import XCTest
@testable import VoiceKey

final class RetryPolicyTests: XCTestCase {
    func testBackoffSequence() {
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 0), 2)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 1), 4)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 2), 8)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 3), 16)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 4), 30)
    }

    func testRetriesExhaustedAfterMax() {
        XCTAssertNil(RetryPolicy.delay(afterFailures: RetryPolicy.maxRetries))
        XCTAssertNil(RetryPolicy.delay(afterFailures: 99))
    }

    func testRetryableErrorClassification() {
        XCTAssertTrue(TranscriberError.http(status: 429, body: "").isRetryable)
        XCTAssertTrue(TranscriberError.http(status: 500, body: "").isRetryable)
        XCTAssertTrue(TranscriberError.http(status: 503, body: "").isRetryable)
        XCTAssertTrue(TranscriberError.timeout.isRetryable)
        XCTAssertTrue(TranscriberError.network("offline").isRetryable)

        XCTAssertFalse(TranscriberError.http(status: 400, body: "").isRetryable)
        XCTAssertFalse(TranscriberError.http(status: 401, body: "").isRetryable)
        XCTAssertFalse(TranscriberError.noAPIKey.isRetryable)
        XCTAssertFalse(TranscriberError.fileTooLarge(bytes: 30_000_000).isRetryable)
        XCTAssertFalse(TranscriberError.malformedResponse("").isRetryable)
    }
}

/// Clock that records requested delays instead of sleeping — injected into
/// UploadQueue so retry timing is testable without real waits.
final class TestClock: AsyncClock, @unchecked Sendable {
    private(set) var sleeps: [TimeInterval] = []
    func sleep(seconds: TimeInterval) async throws {
        sleeps.append(seconds)
    }
}

@MainActor
final class UploadQueueRetryTests: XCTestCase {
    /// End-to-end through the queue with a mocked HTTP layer returning 500s:
    /// the item must be retried with 2/4/8/16/30 s backoff and then fail.
    func testQueueExhaustsRetriesWithBackoffThenFails() async throws {
        let store = try TranscriptStore(inMemory: ())

        // A real (tiny) audio file so the existence check passes.
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-test-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let item = try store.createRecording(audioPath: audioURL.path, appBundleId: nil)
        let id = try XCTUnwrap(item.id)
        try store.transition(id: id, to: .queued) { $0.durationS = 1 }

        MockURLProtocol.handler = { _ in
            (500, Data(#"{"error": {"message": "server exploded"}}"#.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = TranscriberClient(configuration: config)

        let clock = TestClock()
        let queue = UploadQueue(
            store: store,
            client: client,
            clock: clock,
            apiKeyProvider: { "sk-test" },
            paramsProvider: { .init(model: "gpt-4o-mini-transcribe", language: nil, prompt: nil) }
        )

        let idle = expectation(description: "queue idle")
        var sawPermanentFailure = false
        queue.onEvent = { event in
            switch event {
            case .failedPermanently: sawPermanentFailure = true
            case .idle: idle.fulfill()
            default: break
            }
        }
        queue.kick()
        await fulfillment(of: [idle], timeout: 10)

        XCTAssertTrue(sawPermanentFailure)
        XCTAssertEqual(clock.sleeps, [2, 4, 8, 16, 30], "backoff schedule per F5")
        let final = try XCTUnwrap(try store.item(id: id))
        XCTAssertEqual(final.state, .failed)
        XCTAssertEqual(final.retryCount, RetryPolicy.maxRetries)
        XCTAssertNotNil(final.error)
    }
}
