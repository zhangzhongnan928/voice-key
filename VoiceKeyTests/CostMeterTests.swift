import XCTest
@testable import VoiceKey

final class CostMeterTests: XCTestCase {
    func testCostRoundsDurationUpToWholeSeconds() {
        // ceil(duration_s) / 60 * rate (F9)
        XCTAssertEqual(CostMeter.cost(durationSeconds: 60, ratePerMinute: 0.006), 0.006, accuracy: 1e-9)
        XCTAssertEqual(CostMeter.cost(durationSeconds: 30, ratePerMinute: 0.006), 0.003, accuracy: 1e-9)
        XCTAssertEqual(CostMeter.cost(durationSeconds: 2.1, ratePerMinute: 0.006), 3.0 / 60 * 0.006, accuracy: 1e-9)
        XCTAssertEqual(CostMeter.cost(durationSeconds: 2.9, ratePerMinute: 0.006), 3.0 / 60 * 0.006, accuracy: 1e-9)
    }

    func testZeroAndNegativeInputs() {
        XCTAssertEqual(CostMeter.cost(durationSeconds: 0, ratePerMinute: 0.006), 0)
        XCTAssertEqual(CostMeter.cost(durationSeconds: -5, ratePerMinute: 0.006), 0)
        XCTAssertEqual(CostMeter.cost(durationSeconds: 60, ratePerMinute: 0), 0)
    }

    func testMonthlyAccumulationInSettings() {
        let defaults = UserDefaults(suiteName: "CostMeterTests")!
        defaults.removePersistentDomain(forName: "CostMeterTests")
        let settings = SettingsStore(defaults: defaults)

        settings.addCost(0.10, forMonth: "2026-06")
        settings.addCost(0.25, forMonth: "2026-06")
        settings.addCost(9.99, forMonth: "2026-07")

        XCTAssertEqual(settings.costTotal(forMonth: "2026-06"), 0.35, accuracy: 1e-9)
        XCTAssertEqual(settings.costTotal(forMonth: "2026-07"), 9.99, accuracy: 1e-9)
        XCTAssertEqual(settings.costTotal(forMonth: "2026-08"), 0)
    }

    func testRatesAreUserEditable() {
        let defaults = UserDefaults(suiteName: "CostMeterRates")!
        defaults.removePersistentDomain(forName: "CostMeterRates")
        let settings = SettingsStore(defaults: defaults)

        XCTAssertEqual(settings.ratePerMinute(for: .gpt4oMiniTranscribe), 0.003)
        settings.setRatePerMinute(0.0123, for: .gpt4oMiniTranscribe)
        XCTAssertEqual(settings.ratePerMinute(for: .gpt4oMiniTranscribe), 0.0123)
        // Other models unaffected.
        XCTAssertEqual(settings.ratePerMinute(for: .whisper1), 0.006)
    }
}
