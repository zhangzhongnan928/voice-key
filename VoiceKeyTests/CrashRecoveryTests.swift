import XCTest
@testable import VoiceKey

/// F5 acceptance: kill -9 at any phase, then relaunch, must resume the item.
/// These tests exercise the launch-recovery scan directly.
final class CrashRecoveryTests: XCTestCase {
    func testUploadingItemIsRequeuedOnLaunch() throws {
        let store = try TranscriptStore(inMemory: ())
        let item = try store.createRecording(audioPath: "/tmp/u.wav", appBundleId: nil)
        let id = try XCTUnwrap(item.id)
        try store.transition(id: id, to: .queued)
        try store.transition(id: id, to: .uploading)

        // "Relaunch": the upload was cut off by kill -9.
        try store.recoverOnLaunch(fileExists: { _ in true })

        XCTAssertEqual(try store.item(id: id)?.state, .queued, "interrupted upload must be retried")
    }

    func testCrashedRecordingWithAudioOnDiskIsQueued() throws {
        let store = try TranscriptStore(inMemory: ())
        let item = try store.createRecording(audioPath: "/tmp/partial.wav", appBundleId: nil)
        let id = try XCTUnwrap(item.id)

        // App died mid-recording; the WAV written so far is on disk.
        try store.recoverOnLaunch(fileExists: { path in path == "/tmp/partial.wav" })

        XCTAssertEqual(try store.item(id: id)?.state, .queued, "partial audio is still transcribed — never lose audio")
    }

    func testCrashedRecordingWithoutAudioFails() throws {
        let store = try TranscriptStore(inMemory: ())
        let item = try store.createRecording(audioPath: "/tmp/ghost.wav", appBundleId: nil)
        let id = try XCTUnwrap(item.id)

        try store.recoverOnLaunch(fileExists: { _ in false })

        let recovered = try XCTUnwrap(try store.item(id: id))
        XCTAssertEqual(recovered.state, .failed)
        XCTAssertNotNil(recovered.error)
    }

    func testTerminalItemsAreUntouchedByRecovery() throws {
        let store = try TranscriptStore(inMemory: ())
        let doneItem = try store.createRecording(audioPath: "/tmp/d.wav", appBundleId: nil)
        let doneID = try XCTUnwrap(doneItem.id)
        try store.transition(id: doneID, to: .queued)
        try store.transition(id: doneID, to: .uploading)
        try store.transition(id: doneID, to: .done) { $0.text = "hello" }

        let failedItem = try store.createRecording(audioPath: "/tmp/f.wav", appBundleId: nil)
        let failedID = try XCTUnwrap(failedItem.id)
        try store.transition(id: failedID, to: .failed) { $0.error = "x" }

        try store.recoverOnLaunch(fileExists: { _ in true })

        XCTAssertEqual(try store.item(id: doneID)?.state, .done)
        XCTAssertEqual(try store.item(id: doneID)?.text, "hello")
        XCTAssertEqual(try store.item(id: failedID)?.state, .failed)
    }

    func testManualRetryResetsRetryBudget() throws {
        let store = try TranscriptStore(inMemory: ())
        let item = try store.createRecording(audioPath: "/tmp/r.wav", appBundleId: nil)
        let id = try XCTUnwrap(item.id)
        try store.transition(id: id, to: .queued) { $0.retryCount = 5 }
        try store.transition(id: id, to: .uploading)
        try store.transition(id: id, to: .failed) { $0.error = "boom" }

        let retried = try store.manualRetry(id: id)

        XCTAssertEqual(retried.state, .queued)
        XCTAssertEqual(retried.retryCount, 0)
        XCTAssertNil(retried.error)
    }
}
