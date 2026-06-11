import Foundation
import GRDB

/// Durable SQLite-backed queue and history. Every recording gets a row before
/// audio capture starts; rows only reach a terminal state once transcription
/// succeeded or definitively failed, so a crash at any point is recoverable.
final class TranscriptStore {
    enum StoreError: Error, Equatable {
        case invalidTransition(from: ItemState, to: ItemState)
        case notFound(Int64)
    }

    let dbQueue: DatabaseQueue

    /// On-disk store in Application Support.
    static func onDisk() throws -> TranscriptStore {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("VoiceKey", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try TranscriptStore(path: dir.appendingPathComponent("voicekey.sqlite").path)
    }

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        // WAL so a second process (the iOS keyboard extension) can read
        // while the app writes. Harmless for the single-process macOS app.
        // Must run outside a transaction: SQLite refuses to switch journal
        // modes mid-transaction, and `write` wraps its block in one — which
        // made every fresh-database launch fail (existing databases were
        // already WAL, so the pragma was a no-op and the bug stayed hidden).
        try dbQueue.writeWithoutTransaction { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
        }
        try migrate()
    }

    /// In-memory store for tests.
    init(inMemory: Void) throws {
        dbQueue = try DatabaseQueue()
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("created_at", .datetime).notNull()
                t.column("duration_s", .double).notNull().defaults(to: 0)
                t.column("state", .text).notNull()
                t.column("retry_count", .integer).notNull().defaults(to: 0)
                t.column("text", .text)
                t.column("audio_path", .text)
                t.column("app_bundle_id", .text)
                t.column("cost_usd", .double)
                t.column("error", .text)
            }
            try db.create(index: "idx_items_state", on: "items", columns: ["state"])
            try db.create(index: "idx_items_created_at", on: "items", columns: ["created_at"])
        }
        migrator.registerMigration("v2") { db in
            // CR-2 focus guard: app identity and timestamp at recording stop.
            try db.alter(table: "items") { t in
                t.add(column: "app_name", .text)
                t.add(column: "stopped_at", .datetime)
            }
        }
        migrator.registerMigration("v3") { db in
            // iOS handoff: consume-once auto-insert flag for the keyboard
            // extension (single row, replaced on each new transcript).
            try db.create(table: "pending_insert") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("transcript_id", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("consumed_at", .datetime)
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: Creation

    func createRecording(audioPath: String, appBundleId: String?) throws -> TranscriptItem {
        var item = TranscriptItem(
            id: nil,
            createdAt: Date(),
            durationS: 0,
            state: .recording,
            retryCount: 0,
            text: nil,
            audioPath: audioPath,
            appBundleId: appBundleId,
            costUsd: nil,
            error: nil,
            appName: nil,
            stoppedAt: nil
        )
        try dbQueue.write { db in
            try item.insert(db)
        }
        return item
    }

    // MARK: State machine

    /// Validated state transition with an optional mutation applied
    /// atomically in the same write.
    @discardableResult
    func transition(
        id: Int64,
        to newState: ItemState,
        mutate: ((inout TranscriptItem) -> Void)? = nil
    ) throws -> TranscriptItem {
        try dbQueue.write { db in
            guard var item = try TranscriptItem.fetchOne(db, key: id) else {
                throw StoreError.notFound(id)
            }
            guard item.state.canTransition(to: newState) else {
                throw StoreError.invalidTransition(from: item.state, to: newState)
            }
            item.state = newState
            mutate?(&item)
            try item.update(db)
            return item
        }
    }

    func update(id: Int64, mutate: @escaping (inout TranscriptItem) -> Void) throws -> TranscriptItem {
        try dbQueue.write { db in
            guard var item = try TranscriptItem.fetchOne(db, key: id) else {
                throw StoreError.notFound(id)
            }
            mutate(&item)
            try item.update(db)
            return item
        }
    }

    // MARK: Queue access

    /// Oldest queued item, if any.
    func nextQueued() throws -> TranscriptItem? {
        try dbQueue.read { db in
            try TranscriptItem
                .filter(Column("state") == ItemState.queued.rawValue)
                .order(Column("created_at").asc)
                .fetchOne(db)
        }
    }

    func item(id: Int64) throws -> TranscriptItem? {
        try dbQueue.read { db in try TranscriptItem.fetchOne(db, key: id) }
    }

    static func defaultFileNonEmpty(_ path: String) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return ((attributes?[.size] as? Int) ?? 0) > 0
    }

    /// Crash recovery: on launch, every non-terminal row is brought back to a
    /// resumable state.
    /// - `uploading` -> `queued` (the upload was cut off; retry it)
    /// - `recording` -> `queued` if its CAF capture file is non-empty
    ///   (CR-1: partial audio is still worth transcribing), otherwise
    ///   `failed`. Transcoding to the upload artifact happens in the queue.
    func recoverOnLaunch(fileNonEmpty: (String) -> Bool = TranscriptStore.defaultFileNonEmpty) throws {
        let nonTerminal = try dbQueue.read { db in
            try TranscriptItem
                .filter([ItemState.recording.rawValue, ItemState.uploading.rawValue].contains(Column("state")))
                .fetchAll(db)
        }
        for item in nonTerminal {
            guard let id = item.id else { continue }
            switch item.state {
            case .uploading:
                try transition(id: id, to: .queued)
                Log.store.info("recovery: item \(id) uploading -> queued")
            case .recording:
                if let path = item.audioPath, fileNonEmpty(path) {
                    try transition(id: id, to: .queued) { $0.error = nil }
                    Log.store.info("recovery: item \(id) recording -> queued (partial audio kept)")
                } else {
                    try transition(id: id, to: .failed) {
                        $0.error = "Recording interrupted; no audio file found."
                    }
                    Log.store.warning("recovery: item \(id) recording -> failed (no audio)")
                }
            default:
                break
            }
        }
    }

    /// Manual retry from History: failed -> queued with a fresh retry budget.
    @discardableResult
    func manualRetry(id: Int64) throws -> TranscriptItem {
        try transition(id: id, to: .queued) {
            $0.retryCount = 0
            $0.error = nil
        }
    }

    // MARK: History

    func recent(limit: Int, search: String? = nil) throws -> [TranscriptItem] {
        try dbQueue.read { db in
            var request = TranscriptItem.order(Column("created_at").desc)
            if let search, !search.isEmpty {
                request = request.filter(Column("text").like("%\(search)%"))
            }
            return try request.limit(limit).fetchAll(db)
        }
    }

    func lastDone() throws -> TranscriptItem? {
        try dbQueue.read { db in
            try TranscriptItem
                .filter(Column("state") == ItemState.done.rawValue)
                .order(Column("created_at").desc)
                .fetchOne(db)
        }
    }

    func delete(id: Int64) throws {
        let item = try self.item(id: id)
        if let path = item?.audioPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        _ = try dbQueue.write { db in
            try TranscriptItem.deleteOne(db, key: id)
        }
    }

    /// Keeps the newest `limit` terminal items; non-terminal (queued/
    /// uploading/recording) rows are never pruned. Audio files of pruned rows
    /// are deleted.
    func pruneHistory(limit: Int) throws {
        let doomed: [TranscriptItem] = try dbQueue.read { db in
            try TranscriptItem
                .filter([ItemState.done.rawValue, ItemState.failed.rawValue].contains(Column("state")))
                .order(Column("created_at").desc)
                .fetchAll(db)
                .dropFirst(limit)
                .map { $0 }
        }
        for item in doomed {
            if let id = item.id { try delete(id: id) }
        }
    }
}
