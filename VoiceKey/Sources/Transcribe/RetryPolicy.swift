import Foundation

/// F5: backoff 2/4/8/16/30 s, max 5 automatic retry attempts, then `failed`.
enum RetryPolicy {
    static let delays: [TimeInterval] = [2, 4, 8, 16, 30]
    static let maxRetries = 5

    /// Delay before the next automatic retry, given how many retries have
    /// already failed (0-based). Returns nil when retries are exhausted and
    /// the item must move to `failed`.
    static func delay(afterFailures retryCount: Int) -> TimeInterval? {
        guard retryCount >= 0, retryCount < maxRetries else { return nil }
        return delays[min(retryCount, delays.count - 1)]
    }
}

/// Injectable clock so retry timing is unit-testable without real sleeps.
protocol AsyncClock: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

struct RealClock: AsyncClock {
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
