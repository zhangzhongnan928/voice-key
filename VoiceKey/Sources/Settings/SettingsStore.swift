import Foundation
import Combine

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case whisper1 = "whisper-1"

    var id: String { rawValue }

    /// Default USD per audio minute; user-editable in Settings so pricing
    /// changes never require a code change.
    var defaultRatePerMinute: Double {
        switch self {
        case .gpt4oMiniTranscribe: return 0.003
        case .gpt4oTranscribe: return 0.006
        case .whisper1: return 0.006
        }
    }
}

enum HotkeyMode: String, CaseIterable, Identifiable {
    case toggle
    case pushToTalk
    var id: String { rawValue }
}

enum InsertionStrategy: String, CaseIterable, Identifiable {
    case paste   // Strategy A: clipboard + synthetic Cmd+V (default)
    case type    // Strategy B: typing simulation for apps that block paste
    var id: String { rawValue }
}

/// All user preferences. UserDefaults-backed; the API key lives in the
/// Keychain (see `KeychainStore`), never here.
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    enum Keys {
        static let model = "model"
        static let language = "language"
        static let vocabularyPrompt = "vocabularyPrompt"
        static let hotkeyMode = "hotkeyMode"
        static let historyLimit = "historyLimit"
        static let keepAudio = "keepAudio"
        static let insertionStrategy = "insertionStrategy"
        static let clipboardRestoreDelayMs = "clipboardRestoreDelayMs"
        static let restoreClipboard = "restoreClipboard"
        static let focusGuardEnabled = "focusGuardEnabled"
        static let focusGuardWindowSeconds = "focusGuardWindowSeconds"
        static let soundsEnabled = "soundsEnabled"
        static let warnAtSeconds = "warnAtSeconds"
        static let maxRecordingSeconds = "maxRecordingSeconds"
        static let monthlyAlertUSD = "monthlyAlertUSD"
        static let ratePrefix = "ratePerMinute."        // + model raw value
        static let costMonthPrefix = "costTotal."       // + "yyyy-MM"
        static let costAlertedMonth = "costAlertedMonth"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func set<T>(_ value: T, for key: String) {
        defaults.set(value, forKey: key)
        objectWillChange.send()
    }

    var model: TranscriptionModel {
        get { TranscriptionModel(rawValue: defaults.string(forKey: Keys.model) ?? "") ?? .gpt4oMiniTranscribe }
        set { set(newValue.rawValue, for: Keys.model) }
    }

    /// Empty string means automatic language detection (the default — the
    /// owner speaks mixed Chinese and English).
    var language: String {
        get { defaults.string(forKey: Keys.language) ?? "" }
        set { set(newValue, for: Keys.language) }
    }

    /// Custom vocabulary fed to the API `prompt` field (product names,
    /// technical terms).
    var vocabularyPrompt: String {
        get { defaults.string(forKey: Keys.vocabularyPrompt) ?? "" }
        set { set(newValue, for: Keys.vocabularyPrompt) }
    }

    var hotkeyMode: HotkeyMode {
        get { HotkeyMode(rawValue: defaults.string(forKey: Keys.hotkeyMode) ?? "") ?? .toggle }
        set { set(newValue.rawValue, for: Keys.hotkeyMode) }
    }

    /// Number of transcripts kept in history. 0 disables storing text.
    var historyLimit: Int {
        get { defaults.object(forKey: Keys.historyLimit) as? Int ?? 50 }
        set { set(max(0, newValue), for: Keys.historyLimit) }
    }

    var keepAudio: Bool {
        get { defaults.bool(forKey: Keys.keepAudio) }
        set { set(newValue, for: Keys.keepAudio) }
    }

    var insertionStrategy: InsertionStrategy {
        get { InsertionStrategy(rawValue: defaults.string(forKey: Keys.insertionStrategy) ?? "") ?? .paste }
        set { set(newValue.rawValue, for: Keys.insertionStrategy) }
    }

    var clipboardRestoreDelayMs: Int {
        get { defaults.object(forKey: Keys.clipboardRestoreDelayMs) as? Int ?? 500 }
        set { set(max(0, newValue), for: Keys.clipboardRestoreDelayMs) }
    }

    /// CR-3: restore the previous clipboard after paste (guarded by
    /// changeCount so a user copy in between is never overwritten).
    var restoreClipboard: Bool {
        get { defaults.object(forKey: Keys.restoreClipboard) as? Bool ?? true }
        set { set(newValue, for: Keys.restoreClipboard) }
    }

    /// CR-2: only auto-insert while focus is unchanged and recent.
    var focusGuardEnabled: Bool {
        get { defaults.object(forKey: Keys.focusGuardEnabled) as? Bool ?? true }
        set { set(newValue, for: Keys.focusGuardEnabled) }
    }

    var focusGuardWindowSeconds: Double {
        get { defaults.object(forKey: Keys.focusGuardWindowSeconds) as? Double ?? FocusGuard.defaultWindowSeconds }
        set { set(max(0, newValue), for: Keys.focusGuardWindowSeconds) }
    }

    var soundsEnabled: Bool {
        get { defaults.object(forKey: Keys.soundsEnabled) as? Bool ?? true }
        set { set(newValue, for: Keys.soundsEnabled) }
    }

    /// Warn at 14:00 by default.
    var warnAtSeconds: Double {
        get { defaults.object(forKey: Keys.warnAtSeconds) as? Double ?? 840 }
        set { set(newValue, for: Keys.warnAtSeconds) }
    }

    /// Auto-stop at 15:00 by default.
    var maxRecordingSeconds: Double {
        get { defaults.object(forKey: Keys.maxRecordingSeconds) as? Double ?? 900 }
        set { set(newValue, for: Keys.maxRecordingSeconds) }
    }

    /// Monthly cost alert threshold in USD. 0 disables the alert.
    var monthlyAlertUSD: Double {
        get { defaults.object(forKey: Keys.monthlyAlertUSD) as? Double ?? 10.0 }
        set { set(newValue, for: Keys.monthlyAlertUSD) }
    }

    func ratePerMinute(for model: TranscriptionModel) -> Double {
        defaults.object(forKey: Keys.ratePrefix + model.rawValue) as? Double
            ?? model.defaultRatePerMinute
    }

    func setRatePerMinute(_ rate: Double, for model: TranscriptionModel) {
        set(max(0, rate), for: Keys.ratePrefix + model.rawValue)
    }

    // MARK: Cost meter persistence (survives history pruning)

    func costTotal(forMonth month: String) -> Double {
        defaults.double(forKey: Keys.costMonthPrefix + month)
    }

    func addCost(_ usd: Double, forMonth month: String) {
        set(costTotal(forMonth: month) + usd, for: Keys.costMonthPrefix + month)
    }

    var costAlertedMonth: String {
        get { defaults.string(forKey: Keys.costAlertedMonth) ?? "" }
        set { set(newValue, for: Keys.costAlertedMonth) }
    }
}
