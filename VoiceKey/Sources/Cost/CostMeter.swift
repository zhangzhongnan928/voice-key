import Foundation

/// Cost accounting (F9). Per item: `ceil(duration_s) / 60 * rate_for_model`.
/// Monthly totals are accumulated in SettingsStore (keyed by "yyyy-MM") so
/// they survive history pruning; rates are user-editable so pricing changes
/// never require a code change.
enum CostMeter {
    static func cost(durationSeconds: Double, ratePerMinute: Double) -> Double {
        guard durationSeconds > 0, ratePerMinute > 0 else { return 0 }
        return durationSeconds.rounded(.up) / 60.0 * ratePerMinute
    }
}
