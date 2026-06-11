import Foundation

/// Shared container locations for the app + keyboard extension.
/// The keyboard only ever READS here (transcripts, pending insert); it never
/// holds the API key and never makes network calls.
enum AppGroup {
    static let identifier = "group.com.victor.voicekey"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var databaseURL: URL? {
        guard let container = containerURL else { return nil }
        let dir = container.appendingPathComponent("VoiceKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voicekey.sqlite")
    }

    static var audioDirectory: URL? {
        guard let container = containerURL else { return nil }
        let dir = container.appendingPathComponent("VoiceKey/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Settings shared for display purposes (cost meter etc.). The API key is
    /// NOT here — it lives in the container app's Keychain only.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
