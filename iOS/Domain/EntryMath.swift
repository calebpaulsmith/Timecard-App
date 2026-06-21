import Foundation

/// Result of computing paid hours for a single entry.
struct EntryHours: Equatable {
    var hours: Double
    var lunchMinutes: Double
    var lunchDeducted: Bool
    var rawHours: Double

    static let zero = EntryHours(hours: 0, lunchMinutes: 0, lunchDeducted: false, rawHours: 0)
}

/// Decimal paid hours between start and end, with lunch deduction.
/// `lunchMinutes` nil → default rule: 30 min if span ≥ 4h, else 0.
/// `lunchMinutes` non-nil → used as-is (clamped ≥ 0), overriding the default.
/// Uses absolute elapsed time (matches the PWA's `(end-start)/MS_PER_HOUR`).
func hoursForEntry(start: Date?, end: Date?, lunchMinutes: Double? = nil) -> EntryHours {
    guard let start, let end else { return .zero }
    let rawHours = end.timeIntervalSince(start) / 3600.0
    if rawHours <= 0 { return .zero }
    let lm: Double
    if let lunchMinutes {
        lm = max(0, lunchMinutes)
    } else {
        lm = rawHours >= TimeConstants.lunchThresholdHours ? TimeConstants.lunchDeductHours * 60 : 0
    }
    let hours = max(0, rawHours - lm / 60)
    return EntryHours(hours: hours, lunchMinutes: lm, lunchDeducted: lm > 0, rawHours: rawHours)
}

/// True if an in-progress entry has been open more than 16 hours.
func isForgotten(start: Date, now: Date = Date()) -> Bool {
    now.timeIntervalSince(start) / 3600.0 > TimeConstants.forgottenCutoffHours
}

/// If clocked in at `clockIn`, when do we clock out to book `targetHours` paid?
/// Accounts for the 30-min lunch deduction when the resulting span would be ≥ 4h.
func projectedClockOut(clockIn: Date, targetHours: Double) -> Date {
    let withLunchEnd = clockIn.addingTimeInterval((targetHours + TimeConstants.lunchDeductHours) * 3600)
    let withLunchSpan = withLunchEnd.timeIntervalSince(clockIn) / 3600
    if withLunchSpan >= TimeConstants.lunchThresholdHours { return withLunchEnd }
    return clockIn.addingTimeInterval(targetHours * 3600)
}
