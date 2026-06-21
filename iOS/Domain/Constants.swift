import Foundation

/// Constants ported verbatim from the PWA's `time.js`. Source of truth for the
/// maxiflex rules. Do not change without changing the spec.
enum TimeConstants {
    static let quarterMinutes = 15
    static let lunchThresholdHours = 4.0
    static let lunchDeductHours = 0.5
    static let forgottenCutoffHours = 16.0
    static let payPeriodDays = 14
    static let payPeriodTarget = 80.0
    static let dailyOTThreshold = 8.0
    /// FLSA standard: overtime pays 1.5× the straight-time rate.
    static let otMultiplier = 1.5
    /// Worked federal holidays flagged "holiday worked" pay at 2× (double time).
    static let holidayMultiplier = 2.0
    /// Lag between period-end and check-date, used for YTD year bucketing.
    static let paydateOffsetDays = 12
}
