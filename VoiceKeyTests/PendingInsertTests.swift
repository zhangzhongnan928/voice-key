import XCTest
@testable import VoiceKey

/// iOS handoff semantics (Prompt 2 patch): consume-once, 10-minute TTL.
final class PendingInsertTests: XCTestCase {
    private func store() throws -> TranscriptStore {
        try TranscriptStore(inMemory: ())
    }

    func testConsumeOnce() throws {
        let store = try store()
        try store.setPendingInsert(transcriptId: 1, text: "hello")

        XCTAssertEqual(try store.consumePendingInsert(), "hello")
        XCTAssertNil(try store.consumePendingInsert(), "second consume must return nothing")
    }

    func testExpiredEntryIsNeverInserted() throws {
        let store = try store()
        let created = Date(timeIntervalSince1970: 1_750_000_000)
        try store.setPendingInsert(transcriptId: 1, text: "stale", now: created)

        let afterTTL = created.addingTimeInterval(PendingInsert.ttl + 1)
        XCTAssertNil(try store.consumePendingInsert(now: afterTTL))
    }

    func testFreshEntryWithinTTLInserted() throws {
        let store = try store()
        let created = Date(timeIntervalSince1970: 1_750_000_000)
        try store.setPendingInsert(transcriptId: 1, text: "fresh", now: created)

        let justBeforeTTL = created.addingTimeInterval(PendingInsert.ttl)
        XCTAssertEqual(try store.consumePendingInsert(now: justBeforeTTL), "fresh")
    }

    func testNewTranscriptReplacesPrevious() throws {
        let store = try store()
        try store.setPendingInsert(transcriptId: 1, text: "first")
        try store.setPendingInsert(transcriptId: 2, text: "second")

        XCTAssertEqual(try store.consumePendingInsert(), "second")
        XCTAssertNil(try store.consumePendingInsert())
    }

    func testEmptyStoreYieldsNothing() throws {
        XCTAssertNil(try store().consumePendingInsert())
    }
}
