import AppKit
import XCTest
@testable import VoiceKey

final class InsertionPlannerTests: XCTestCase {
    func testPasteStrategySelected() {
        XCTAssertEqual(
            InsertionPlanner.method(strategy: .paste, secureInputEnabled: false),
            .paste
        )
    }

    func testTypeStrategySelected() {
        XCTAssertEqual(
            InsertionPlanner.method(strategy: .type, secureInputEnabled: false),
            .type
        )
    }

    func testSecureInputOverridesEitherStrategy() {
        // F6: password fields -> clipboard only, never synthetic input.
        XCTAssertEqual(
            InsertionPlanner.method(strategy: .paste, secureInputEnabled: true),
            .clipboardOnly
        )
        XCTAssertEqual(
            InsertionPlanner.method(strategy: .type, secureInputEnabled: true),
            .clipboardOnly
        )
    }
}

final class InserterSecureInputTests: XCTestCase {
    /// With secure input active the inserter must not post any events; the
    /// transcript lands in the clipboard and the outcome says why.
    func testSecureInputFallsBackToClipboard() {
        let inserter = Inserter()
        inserter.secureInputDetector = { true }
        inserter.accessibilityTrusted = { true }

        let outcome = inserter.insert("s3cret dictation", strategy: .paste, clipboardRestoreDelayMs: 0)

        guard case .clipboardFallback(let reason) = outcome else {
            return XCTFail("expected clipboard fallback, got \(outcome)")
        }
        XCTAssertTrue(reason.lowercased().contains("password"))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "s3cret dictation")
    }

    func testMissingAccessibilityFallsBackToClipboard() {
        let inserter = Inserter()
        inserter.secureInputDetector = { false }
        inserter.accessibilityTrusted = { false }

        let outcome = inserter.insert("hello", strategy: .paste, clipboardRestoreDelayMs: 0)

        guard case .clipboardFallback(let reason) = outcome else {
            return XCTFail("expected clipboard fallback, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("Accessibility"))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")
    }
}
