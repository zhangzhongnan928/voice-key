import XCTest
@testable import PureLogic

// Mirrors the pure-logic portions of the macOS test suite so they can be
// executed on Linux, where AppKit/GRDB-dependent tests cannot run.

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
        XCTAssertNil(RetryPolicy.delay(afterFailures: -1))
    }

    func testRetryAfterParsing() {
        XCTAssertEqual(RetryPolicy.parseRetryAfter("7"), 7)
        XCTAssertEqual(RetryPolicy.parseRetryAfter(" 30 "), 30)
        XCTAssertEqual(RetryPolicy.parseRetryAfter("-5"), 0)
        XCTAssertNil(RetryPolicy.parseRetryAfter(nil))
        XCTAssertNil(RetryPolicy.parseRetryAfter(""))
        XCTAssertNil(RetryPolicy.parseRetryAfter("soon"))

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let httpDate = formatter.string(from: now.addingTimeInterval(42))
        let parsed = RetryPolicy.parseRetryAfter(httpDate, now: now)
        XCTAssertEqual(parsed ?? -1, 42, accuracy: 1.0)

        // Past HTTP-date clamps to zero.
        let pastDate = formatter.string(from: now.addingTimeInterval(-100))
        XCTAssertEqual(RetryPolicy.parseRetryAfter(pastDate, now: now) ?? -1, 0, accuracy: 1.0)
    }
}

final class FocusGuardTests: XCTestCase {
    private let stop = Date(timeIntervalSince1970: 1_750_000_000)

    private func decide(
        enabled: Bool = true,
        stored: String? = "com.apple.TextEdit",
        current: String? = "com.apple.TextEdit",
        elapsed: TimeInterval = 5,
        window: TimeInterval = 120
    ) -> Bool {
        FocusGuard.shouldAutoInsert(
            enabled: enabled,
            storedBundleId: stored,
            currentBundleId: current,
            stoppedAt: stop,
            now: stop.addingTimeInterval(elapsed),
            windowSeconds: window
        )
    }

    func testSameAppWithinWindowInserts() {
        XCTAssertTrue(decide())
        XCTAssertTrue(decide(elapsed: 120))
    }

    func testFocusChangeBlocksInsert() {
        XCTAssertFalse(decide(current: "com.apple.Safari"))
    }

    func testWindowExpiryBlocksInsert() {
        XCTAssertFalse(decide(elapsed: 121))
        XCTAssertFalse(decide(elapsed: 3600))
    }

    func testUnknownStateFailsSafe() {
        XCTAssertFalse(decide(stored: nil))
        XCTAssertFalse(decide(current: nil))
        XCTAssertFalse(FocusGuard.shouldAutoInsert(
            enabled: true, storedBundleId: "a", currentBundleId: "a",
            stoppedAt: nil, now: Date(), windowSeconds: 120
        ))
    }

    func testDisabledGuardAlwaysInserts() {
        XCTAssertTrue(decide(enabled: false, current: "com.apple.Safari", elapsed: 999))
        XCTAssertTrue(decide(enabled: false, stored: nil))
    }
}

final class ClipboardRestorePolicyTests: XCTestCase {
    func testRestoreWhenNothingChanged() {
        XCTAssertTrue(ClipboardRestorePolicy.shouldRestore(changeCountAtWrite: 41, currentChangeCount: 41))
    }

    func testSkipRestoreWhenUserCopiedInBetween() {
        XCTAssertFalse(ClipboardRestorePolicy.shouldRestore(changeCountAtWrite: 41, currentChangeCount: 42))
        XCTAssertFalse(ClipboardRestorePolicy.shouldRestore(changeCountAtWrite: 41, currentChangeCount: 57))
    }
}

final class CostMeterTests: XCTestCase {
    func testCostRoundsDurationUpToWholeSeconds() {
        XCTAssertEqual(CostMeter.cost(durationSeconds: 60, ratePerMinute: 0.006), 0.006, accuracy: 1e-9)
        XCTAssertEqual(CostMeter.cost(durationSeconds: 30, ratePerMinute: 0.006), 0.003, accuracy: 1e-9)
        XCTAssertEqual(CostMeter.cost(durationSeconds: 2.1, ratePerMinute: 0.006), 3.0 / 60 * 0.006, accuracy: 1e-9)
        XCTAssertEqual(CostMeter.cost(durationSeconds: 2.9, ratePerMinute: 0.006), 3.0 / 60 * 0.006, accuracy: 1e-9)
        XCTAssertEqual(CostMeter.cost(durationSeconds: 900, ratePerMinute: 0.003), 0.045, accuracy: 1e-9)
    }

    func testZeroAndNegativeInputs() {
        XCTAssertEqual(CostMeter.cost(durationSeconds: 0, ratePerMinute: 0.006), 0)
        XCTAssertEqual(CostMeter.cost(durationSeconds: -5, ratePerMinute: 0.006), 0)
        XCTAssertEqual(CostMeter.cost(durationSeconds: 60, ratePerMinute: 0), 0)
    }
}

final class StateMachineTests: XCTestCase {
    func testHappyPathTransitions() {
        XCTAssertTrue(ItemState.recording.canTransition(to: .queued))
        XCTAssertTrue(ItemState.queued.canTransition(to: .uploading))
        XCTAssertTrue(ItemState.uploading.canTransition(to: .done))
    }

    func testRetryTransitions() {
        XCTAssertTrue(ItemState.uploading.canTransition(to: .queued))
        XCTAssertTrue(ItemState.uploading.canTransition(to: .failed))
        XCTAssertTrue(ItemState.failed.canTransition(to: .queued))
    }

    func testFailureFromRecordingAndQueued() {
        XCTAssertTrue(ItemState.recording.canTransition(to: .failed))
        XCTAssertTrue(ItemState.queued.canTransition(to: .failed))
    }

    func testInvalidTransitions() {
        XCTAssertFalse(ItemState.done.canTransition(to: .queued))
        XCTAssertFalse(ItemState.done.canTransition(to: .uploading))
        XCTAssertFalse(ItemState.recording.canTransition(to: .uploading))
        XCTAssertFalse(ItemState.recording.canTransition(to: .done))
        XCTAssertFalse(ItemState.queued.canTransition(to: .done))
        XCTAssertFalse(ItemState.failed.canTransition(to: .done))
        XCTAssertFalse(ItemState.uploading.canTransition(to: .recording))
        for state in ItemState.allCases {
            XCTAssertFalse(state.canTransition(to: state), "\(state) must not self-transition")
        }
    }

    func testTerminalStates() {
        XCTAssertTrue(ItemState.done.isTerminal)
        XCTAssertTrue(ItemState.failed.isTerminal)
        XCTAssertFalse(ItemState.recording.isTerminal)
        XCTAssertFalse(ItemState.queued.isTerminal)
        XCTAssertFalse(ItemState.uploading.isTerminal)
    }
}

/// Simulates the UploadQueue retry loop arithmetic (the real loop needs
/// URLSession + GRDB): verifies the Retry-After interaction with backoff.
final class RetryAfterBackoffTests: XCTestCase {
    private func simulateSleeps(retryAfter: TimeInterval?) -> [TimeInterval] {
        var sleeps: [TimeInterval] = []
        var retryCount = 0
        while let backoff = RetryPolicy.delay(afterFailures: retryCount) {
            sleeps.append(max(backoff, retryAfter ?? 0))
            retryCount += 1
        }
        return sleeps
    }

    func testPlainBackoff() {
        XCTAssertEqual(simulateSleeps(retryAfter: nil), [2, 4, 8, 16, 30])
    }

    func testRetryAfterLiftsEarlyWaits() {
        XCTAssertEqual(simulateSleeps(retryAfter: 7), [7, 7, 8, 16, 30])
    }

    func testRetryAfterLargerThanAllBackoffs() {
        XCTAssertEqual(simulateSleeps(retryAfter: 60), [60, 60, 60, 60, 60])
    }
}
