import Foundation

/// The kind of local reminder the timecard schedules. The `rawValue` doubles as
/// the stable notification identifier prefix, so rescheduling replaces rather
/// than duplicates.
enum ReminderKind: String, CaseIterable, Sendable {
    case validationDeadline   // "validate your timecard today"
    case periodEnding         // "pay period ends tomorrow — you're N h short"
    case forgottenClockOut    // "you've been clocked in N h — forgot to clock out?"
}

/// A scheduled local reminder, computed purely from period state. The platform
/// layer maps each spec to a `UNNotificationRequest`. Value type — no UI/UN deps.
struct ReminderSpec: Equatable, Identifiable, Sendable {
    var id: String        // stable per kind (validation/period) or per open entry
    var kind: ReminderKind
    var title: String
    var body: String
    var fireDate: Date
}

enum ReminderRules {
    /// How long after clock-in to nudge about a possibly-forgotten clock-out.
    /// Well before the 16h auto-incomplete cutoff so it's actionable.
    static let forgottenClockOutHours = 9.0
    /// Hour of day (local) the dated reminders fire.
    static let fireHour = 9
}

/// Build the local reminders for a period from already-resolved inputs (kept pure
/// so it's unit-testable; the platform layer supplies the live values and does the
/// UNUserNotificationCenter scheduling). Only future fire dates are returned.
///
/// - `validationDayIndex`: the timecard-validation day-of-period (0..13) or nil.
/// - `workedPlusLeave`: the period's hours toward the 80 (worked + leave).
/// - `openEntryStart`: start time of the currently-running entry, or nil.
func buildReminders(now: Date,
                    period: PayPeriod,
                    validationDayIndex: Int?,
                    workedPlusLeave: Double,
                    openEntryStart: Date?,
                    calendar: Calendar = DomainCalendar.shared) -> [ReminderSpec] {
    var out: [ReminderSpec] = []

    func at(_ dayStr: String, hour: Int) -> Date? {
        let midnight = parseLocalDate(dayStr, calendar: calendar)
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: midnight)
    }

    // 1) Validation deadline — the domain-unique nudge. Fires the morning of the
    //    chosen validation day.
    if let idx = validationDayIndex, idx >= 0, idx < period.days.count,
       let fire = at(period.days[idx], hour: ReminderRules.fireHour), fire > now {
        out.append(ReminderSpec(
            id: ReminderKind.validationDeadline.rawValue,
            kind: .validationDeadline,
            title: "Validate your timecard",
            body: "Today is your timecard validation deadline. Review and validate before it closes.",
            fireDate: fire))
    }

    // 2) Pay period ending — only when still short of 80. Fires the morning of the
    //    second-to-last day ("ends tomorrow").
    if workedPlusLeave < TimeConstants.payPeriodTarget, period.days.count >= 2,
       let fire = at(period.days[period.days.count - 2], hour: ReminderRules.fireHour), fire > now {
        let short = TimeConstants.payPeriodTarget - workedPlusLeave
        out.append(ReminderSpec(
            id: ReminderKind.periodEnding.rawValue,
            kind: .periodEnding,
            title: "Pay period ends tomorrow",
            body: "You're \(formatHours(short)) h short of 80 — log the rest before the period closes.",
            fireDate: fire))
    }

    // 3) Forgotten clock-out — a one-off relative to the running entry's start.
    if let start = openEntryStart {
        let fire = start.addingTimeInterval(ReminderRules.forgottenClockOutHours * 3600)
        if fire > now {
            out.append(ReminderSpec(
                id: ReminderKind.forgottenClockOut.rawValue,
                kind: .forgottenClockOut,
                title: "Still clocked in",
                body: "You've been clocked in for \(formatHours(ReminderRules.forgottenClockOutHours)) h. Did you forget to clock out?",
                fireDate: fire))
        }
    }

    return out
}
