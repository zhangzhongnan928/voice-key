import XCTest
@testable import VoiceKey

final class StateMachineTests: XCTestCase {
    func testHappyPathTransitions() {
        XCTAssertTrue(ItemState.recording.canTransition(to: .queued))
        XCTAssertTrue(ItemState.queued.canTransition(to: .uploading))
        XCTAssertTrue(ItemState.uploading.canTransition(to: .done))
    }

    func testRetryTransitions() {
        XCTAssertTrue(ItemState.uploading.canTransition(to: .queued), "retryable failure requeues")
        XCTAssertTrue(ItemState.uploading.canTransition(to: .failed), "exhausted retries fail")
        XCTAssertTrue(ItemState.failed.canTransition(to: .queued), "manual retry from History")
    }

    func testFailureFromRecordingAndQueued() {
        XCTAssertTrue(ItemState.recording.canTransition(to: .failed), "disk full mid-recording")
        XCTAssertTrue(ItemState.queued.canTransition(to: .failed), "missing audio / no API key")
    }

    func testInvalidTransitions() {
        XCTAssertFalse(ItemState.done.canTransition(to: .queued), "done is terminal")
        XCTAssertFalse(ItemState.done.canTransition(to: .uploading))
        XCTAssertFalse(ItemState.recording.canTransition(to: .uploading), "must queue first")
        XCTAssertFalse(ItemState.recording.canTransition(to: .done))
        XCTAssertFalse(ItemState.queued.canTransition(to: .done), "must pass through uploading")
        XCTAssertFalse(ItemState.failed.canTransition(to: .done))
        XCTAssertFalse(ItemState.uploading.canTransition(to: .recording))
    }

    func testTerminalStates() {
        XCTAssertTrue(ItemState.done.isTerminal)
        XCTAssertTrue(ItemState.failed.isTerminal)
        XCTAssertFalse(ItemState.recording.isTerminal)
        XCTAssertFalse(ItemState.queued.isTerminal)
        XCTAssertFalse(ItemState.uploading.isTerminal)
    }

    func testStoreRejectsInvalidTransition() throws {
        let store = try TranscriptStore(inMemory: ())
        let item = try store.createRecording(audioPath: "/tmp/a.wav", appBundleId: nil)
        let id = try XCTUnwrap(item.id)

        XCTAssertThrowsError(try store.transition(id: id, to: .done)) { error in
            XCTAssertEqual(
                error as? TranscriptStore.StoreError,
                .invalidTransition(from: .recording, to: .done)
            )
        }
        // State unchanged after the rejected transition.
        XCTAssertEqual(try store.item(id: id)?.state, .recording)
    }

    func testStoreAppliesMutationAtomicallyWithTransition() throws {
        let store = try TranscriptStore(inMemory: ())
        let item = try store.createRecording(audioPath: "/tmp/a.wav", appBundleId: "com.apple.TextEdit")
        let id = try XCTUnwrap(item.id)

        let queued = try store.transition(id: id, to: .queued) { $0.durationS = 12.5 }
        XCTAssertEqual(queued.state, .queued)
        XCTAssertEqual(queued.durationS, 12.5)

        let reloaded = try XCTUnwrap(try store.item(id: id))
        XCTAssertEqual(reloaded.state, .queued)
        XCTAssertEqual(reloaded.durationS, 12.5)
        XCTAssertEqual(reloaded.appBundleId, "com.apple.TextEdit")
    }
}
