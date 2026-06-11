import Foundation
import GRDB

struct TranscriptItem: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "items"

    var id: Int64?
    var createdAt: Date
    var durationS: Double
    var state: ItemState
    var retryCount: Int
    var text: String?
    var audioPath: String?
    var appBundleId: String?
    var costUsd: Double?
    var error: String?
    /// CR-2: frontmost app's localized name and the moment recording stopped,
    /// captured at stop time for the focus guard.
    var appName: String?
    var stoppedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case durationS = "duration_s"
        case state
        case retryCount = "retry_count"
        case text
        case audioPath = "audio_path"
        case appBundleId = "app_bundle_id"
        case costUsd = "cost_usd"
        case error
        case appName = "app_name"
        case stoppedAt = "stopped_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var audioURL: URL? {
        audioPath.map { URL(fileURLWithPath: $0) }
    }

    var firstLine: String {
        (text ?? "").split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }
}
