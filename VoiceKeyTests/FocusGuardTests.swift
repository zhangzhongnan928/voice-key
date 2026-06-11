import XCTest
@testable import VoiceKey

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
        XCTAssertTrue(decide(elapsed: 120), "boundary: exactly the window is allowed")
    }

    func testFocusChangeBlocksInsert() {
        // CR-2 acceptance: dictate in TextEdit, switch to Safari -> no paste.
        XCTAssertFalse(decide(current: "com.apple.Safari"))
    }

    func testWindowExpiryBlocksInsert() {
        XCTAssertFalse(decide(elapsed: 121))
        XCTAssertFalse(decide(elapsed: 3600))
    }

    func testUnknownStateFailsSafe() {
        XCTAssertFalse(decide(stored: nil))
        XCTAssertFalse(decide(current: nil))
        XCTAssertFalse(
            FocusGuard.shouldAutoInsert(
                enabled: true,
                storedBundleId: "a",
                currentBundleId: "a",
                stoppedAt: nil,
                now: Date(),
                windowSeconds: 120
            ),
            "missing stop timestamp must not insert"
        )
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
        // CR-3 acceptance: copying during the restore delay must win.
        XCTAssertFalse(ClipboardRestorePolicy.shouldRestore(changeCountAtWrite: 41, currentChangeCount: 42))
        XCTAssertFalse(ClipboardRestorePolicy.shouldRestore(changeCountAtWrite: 41, currentChangeCount: 57))
    }
}
