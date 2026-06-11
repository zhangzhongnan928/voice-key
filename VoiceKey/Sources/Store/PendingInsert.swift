import Foundation
import GRDB

/// Consume-once handoff record for the iOS keyboard extension. The container
/// app writes it after a keyboard-initiated dictation completes; the keyboard
/// auto-inserts it exactly once on reappearance. Expired (TTL 10 min) or
/// already-consumed entries are never auto-inserted — "Insert latest" remains
/// the manual fallback.
struct PendingInsert: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "pending_insert"
    static let ttl: TimeInterval = 600

    var id: Int64?
    var transcriptId: Int64
    var text: String
    var createdAt: Date
    var consumedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case transcriptId = "transcript_id"
        case text
        case createdAt = "created_at"
        case consumedAt = "consumed_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    func isInsertable(now: Date) -> Bool {
        consumedAt == nil && now.timeIntervalSince(createdAt) <= Self.ttl
    }
}

extension TranscriptStore {
    /// Replaces any previous pending insert with a fresh one.
    func setPendingInsert(transcriptId: Int64, text: String, now: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_insert")
            var record = PendingInsert(
                id: nil,
                transcriptId: transcriptId,
                text: text,
                createdAt: now,
                consumedAt: nil
            )
            try record.insert(db)
        }
    }

    /// Atomically claims the pending insert: returns its text if it is fresh
    /// and unconsumed, marking it consumed in the same transaction. Returns
    /// nil (and never auto-inserts) for expired or consumed entries.
    func consumePendingInsert(now: Date = Date()) throws -> String? {
        try dbQueue.write { db in
            guard var record = try PendingInsert
                .order(Column("created_at").desc)
                .fetchOne(db),
                record.isInsertable(now: now)
            else { return nil }
            record.consumedAt = now
            try record.update(db)
            return record.text
        }
    }
}
