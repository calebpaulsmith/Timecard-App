import Foundation

enum PaceStatus: String, Equatable {
    case ahead
    case onPace = "on-pace"
    case behind
}

/// Average hours per remaining day to finish the period on target.
func pace(hoursWorked: Double, daysRemaining: Int, target: Double = TimeConstants.payPeriodTarget) -> Double {
    let remaining = max(0, target - hoursWorked)
    if daysRemaining <= 0 { return 0 }
    return remaining / Double(daysRemaining)
}

/// Expected cumulative hours by end of `dayIndex` (0-based; day 0 = end of day 1).
func expectedByDay(_ dayIndex: Int) -> Double {
    TimeConstants.payPeriodTarget * Double(dayIndex + 1) / Double(TimeConstants.payPeriodDays)
}

/// Status with a 2-hour deadband to prevent flicker.
func paceStatus(hoursWorked: Double, dayIndex: Int) -> PaceStatus {
    let expected = expectedByDay(dayIndex)
    if hoursWorked > expected + 2 { return .ahead }
    if hoursWorked < expected - 2 { return .behind }
    return .onPace
}
