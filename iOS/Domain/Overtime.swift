import Foundation

/// A day's worked hours split into regular vs. overtime.
struct OvertimeSplit: Equatable {
    var regular: Double
    var overtime: Double
}

/// 8-hour-mode split. Leave is not OT-eligible and is passed separately by the
/// caller. `isWeekend` → ALL the day's worked hours are overtime (federal
/// maxiflex: Sat/Sun work is entirely OT).
///
/// NOTE: the PWA's v21 refinement redefined 8h-mode OT at the period level to
/// `max(0, worked − scheduledHours(day))` (ungated). This helper is the literal
/// `time.js` port (fixed-8 floor); the scheduled-hours rule will live in the
/// period-totals aggregator (Phase 2/3), which is the single OT authority.
func overtimeSplit(workedHours: Double, otModeEnabled: Bool, isWeekend: Bool = false) -> OvertimeSplit {
    if !otModeEnabled { return OvertimeSplit(regular: workedHours, overtime: 0) }
    if isWeekend { return OvertimeSplit(regular: 0, overtime: workedHours) }
    if workedHours <= TimeConstants.dailyOTThreshold {
        return OvertimeSplit(regular: workedHours, overtime: 0)
    }
    return OvertimeSplit(regular: TimeConstants.dailyOTThreshold,
                         overtime: workedHours - TimeConstants.dailyOTThreshold)
}

/// Maxiflex per-day overtime: hours worked beyond that day's *scheduled* hours,
/// counted as OT only when the period as a whole exceeds 80 worked hours.
/// Explicit per-entry OT and holiday-worked OT are added on top by the caller.
/// `dayRegularWorked` must EXCLUDE hours already counted as explicit OT.
func maxiflexDayOvertime(dayRegularWorked: Double, dayScheduledHours: Double, periodOver80: Bool) -> Double {
    guard periodOver80 else { return 0 }
    return max(0, dayRegularWorked - dayScheduledHours)
}
