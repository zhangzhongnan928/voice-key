import XCTest
@testable import VoiceKey

final class SettingsRoundTripTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: SettingsStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SettingsRoundTripTests")
        defaults.removePersistentDomain(forName: "SettingsRoundTripTests")
        settings = SettingsStore(defaults: defaults)
    }

    func testDefaults() {
        XCTAssertEqual(settings.model, .gpt4oMiniTranscribe)
        XCTAssertEqual(settings.language, "", "auto language detection must be the default")
        XCTAssertEqual(settings.vocabularyPrompt, "")
        XCTAssertEqual(settings.hotkeyMode, .toggle)
        XCTAssertEqual(settings.historyLimit, 50)
        XCTAssertFalse(settings.keepAudio)
        XCTAssertEqual(settings.insertionStrategy, .paste)
        XCTAssertEqual(settings.clipboardRestoreDelayMs, 500)
        XCTAssertTrue(settings.soundsEnabled)
        XCTAssertEqual(settings.warnAtSeconds, 840)
        XCTAssertEqual(settings.maxRecordingSeconds, 900)
    }

    func testRoundTrip() {
        settings.model = .whisper1
        settings.language = "zh"
        settings.vocabularyPrompt = "VoiceKey, GRDB, XcodeGen"
        settings.hotkeyMode = .pushToTalk
        settings.historyLimit = 0
        settings.keepAudio = true
        settings.insertionStrategy = .type
        settings.clipboardRestoreDelayMs = 1200
        settings.soundsEnabled = false
        settings.monthlyAlertUSD = 25

        // Fresh store over the same defaults = relaunch.
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.model, .whisper1)
        XCTAssertEqual(reloaded.language, "zh")
        XCTAssertEqual(reloaded.vocabularyPrompt, "VoiceKey, GRDB, XcodeGen")
        XCTAssertEqual(reloaded.hotkeyMode, .pushToTalk)
        XCTAssertEqual(reloaded.historyLimit, 0)
        XCTAssertTrue(reloaded.keepAudio)
        XCTAssertEqual(reloaded.insertionStrategy, .type)
        XCTAssertEqual(reloaded.clipboardRestoreDelayMs, 1200)
        XCTAssertFalse(reloaded.soundsEnabled)
        XCTAssertEqual(reloaded.monthlyAlertUSD, 25)
    }

    func testCorruptValuesFallBackToDefaults() {
        defaults.set("not-a-model", forKey: SettingsStore.Keys.model)
        defaults.set("sideways", forKey: SettingsStore.Keys.hotkeyMode)
        defaults.set("teleport", forKey: SettingsStore.Keys.insertionStrategy)

        XCTAssertEqual(settings.model, .gpt4oMiniTranscribe)
        XCTAssertEqual(settings.hotkeyMode, .toggle)
        XCTAssertEqual(settings.insertionStrategy, .paste)
    }

    func testHistoryLimitClampsNegative() {
        settings.historyLimit = -10
        XCTAssertEqual(settings.historyLimit, 0)
    }
}
