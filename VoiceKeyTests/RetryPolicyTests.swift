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
        // CR-4: retryable = URL errors, 408, 429, 5xx.
        XCTAssertTrue(TranscriberError.http(status: 408, body: "", retryAfter: nil).isRetryable)
        XCTAssertTrue(TranscriberError.http(status: 429, body: "", retryAfter: nil).isRetryable)
        XCTAssertTrue(TranscriberError.http(status: 500, body: "", retryAfter: nil).isRetryable)
        XCTAssertTrue(TranscriberError.http(status: 503, body: "", retryAfter: nil).isRetryable)
        XCTAssertTrue(TranscriberError.timeout.isRetryable)
        XCTAssertTrue(TranscriberError.network("offline").isRetryable)

        // CR-4: non-retryable = 400, 401, 403, 413, 422 and local errors.
        for status in [400, 401, 403, 413, 422] {
            XCTAssertFalse(
                TranscriberError.http(status: status, body: "", retryAfter: nil).isRetryable,
                "HTTP \(status) must fail immediately"
            )
        }
        XCTAssertFalse(TranscriberError.noAPIKey.isRetryable)
        XCTAssertFalse(TranscriberError.fileTooLarge(bytes: 30_000_000).isRetryable)
        XCTAssertFalse(TranscriberError.malformedResponse("").isRetryable)
    }

    func testKeyCheckClassification() {
        // CR-4: 401/403 (and missing key) prompt "Check API key in Settings."
        XCTAssertTrue(TranscriberError.http(status: 401, body: "", retryAfter: nil).needsKeyCheck)
        XCTAssertTrue(TranscriberError.http(status: 403, body: "", retryAfter: nil).needsKeyCheck)
        XCTAssertTrue(TranscriberError.noAPIKey.needsKeyCheck)
        XCTAssertFalse(TranscriberError.http(status: 400, body: "", retryAfter: nil).needsKeyCheck)
        XCTAssertFalse(TranscriberError.http(status: 500, body: "", retryAfter: nil).needsKeyCheck)
        XCTAssertFalse(TranscriberError.timeout.needsKeyCheck)
    }

    func testRetryAfterParsing() {
        XCTAssertEqual(TranscriberClient.parseRetryAfter("7"), 7)
        XCTAssertEqual(TranscriberClient.parseRetryAfter(" 30 "), 30)
        XCTAssertEqual(TranscriberClient.parseRetryAfter("-5"), 0, "negative clamps to zero")
        XCTAssertNil(TranscriberClient.parseRetryAfter(nil))
        XCTAssertNil(TranscriberClient.parseRetryAfter(""))
        XCTAssertNil(TranscriberClient.parseRetryAfter("soon"))

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let httpDate = formatter.string(from: now.addingTimeInterval(42))
        let parsed = TranscriberClient.parseRetryAfter(httpDate, now: now)
        XCTAssertEqual(parsed ?? -1, 42, accuracy: 1.0)
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

/// Thread-safe counter for closures invoked off the test thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor
final class UploadQueueRetryTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.responseHeaders = [:]
        super.tearDown()
    }

    private struct Fixture {
        let store: TranscriptStore
        let itemID: Int64
        let queue: UploadQueue
        let clock: TestClock
        let audioURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let store = try TranscriptStore(inMemory: ())

        // A real (tiny) audio file so the existence check passes.
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-test-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: audioURL)

        let item = try store.createRecording(audioPath: audioURL.path, appBundleId: nil)
        let id = try XCTUnwrap(item.id)
        try store.transition(id: id, to: .queued) { $0.durationS = 1 }

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
        return Fixture(store: store, itemID: id, queue: queue, clock: clock, audioURL: audioURL)
    }

    /// End-to-end through the queue with a mocked HTTP layer returning 500s:
    /// the item must be retried with 2/4/8/16/30 s backoff and then fail.
    func testQueueExhaustsRetriesWithBackoffThenFails() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.audioURL) }
        MockURLProtocol.handler = { _ in
            (500, Data(#"{"error": {"message": "server exploded"}}"#.utf8))
        }

        let idle = expectation(description: "queue idle")
        var sawPermanentFailure = false
        fixture.queue.onEvent = { event in
            switch event {
            case .failedPermanently: sawPermanentFailure = true
            case .idle: idle.fulfill()
            default: break
            }
        }
        fixture.queue.kick()
        await fulfillment(of: [idle], timeout: 10)

        XCTAssertTrue(sawPermanentFailure)
        XCTAssertEqual(fixture.clock.sleeps, [2, 4, 8, 16, 30], "backoff schedule per F5")
        let final = try XCTUnwrap(try fixture.store.item(id: fixture.itemID))
        XCTAssertEqual(final.state, .failed)
        XCTAssertEqual(final.retryCount, RetryPolicy.maxRetries)
        XCTAssertNotNil(final.error)
    }

    /// CR-4: an invalid key (401) makes exactly one request, no retry loop,
    /// and surfaces the key-check flag.
    func testInvalidKeyFailsAfterSingleAttempt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.audioURL) }
        let requestCounter = Counter()
        MockURLProtocol.handler = { _ in
            requestCounter.increment()
            return (401, Data(#"{"error": {"message": "invalid api key"}}"#.utf8))
        }

        let idle = expectation(description: "queue idle")
        var keyCheckFlag: Bool?
        fixture.queue.onEvent = { event in
            switch event {
            case .failedPermanently(_, let needsKeyCheck): keyCheckFlag = needsKeyCheck
            case .idle: idle.fulfill()
            default: break
            }
        }
        fixture.queue.kick()
        await fulfillment(of: [idle], timeout: 10)

        XCTAssertEqual(requestCounter.value, 1, "401 must not be retried")
        XCTAssertEqual(keyCheckFlag, true, "401 must prompt a key check")
        XCTAssertTrue(fixture.clock.sleeps.isEmpty, "no backoff sleeps for permanent failures")
        XCTAssertEqual(try fixture.store.item(id: fixture.itemID)?.state, .failed)
    }

    /// CR-4: a 429 with Retry-After waits max(backoff, Retry-After).
    func testRateLimitHonorsRetryAfterHeader() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.audioURL) }
        MockURLProtocol.responseHeaders = ["Retry-After": "7"]
        MockURLProtocol.handler = { _ in
            (429, Data(#"{"error": {"message": "rate limited"}}"#.utf8))
        }

        let idle = expectation(description: "queue idle")
        fixture.queue.onEvent = { event in
            if case .idle = event { idle.fulfill() }
        }
        fixture.queue.kick()
        await fulfillment(of: [idle], timeout: 10)

        // Backoff schedule is 2/4/8/16/30; Retry-After of 7 lifts the first
        // two waits to 7, later backoffs already exceed it.
        XCTAssertEqual(fixture.clock.sleeps, [7, 7, 8, 16, 30])
    }
}
