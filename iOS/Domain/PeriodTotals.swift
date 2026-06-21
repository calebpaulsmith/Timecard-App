import Foundation

/// An in-progress (open) clock-in, folded live into "today" by `periodTotals`.
struct OpenEntry: Equatable, Sendable {
    var date: String          // "YYYY-MM-DD"
    var startTime: Date
    var isOvertime: Bool
}

/// A recorded federal holiday's pay treatment for a given date.
struct HolidayInfo: Equatable, Sendable {
    var doubleTime: Bool      // worked hours pay 2× instead of 1.5×
}

/// Aggregated totals for one pay period — the single source of truth for
/// overtime. Mirrors the PWA's `periodTotals` return shape.
struct PeriodTotals: Equatable, Sendable {
    var worked: Double
    var ot: Double
    var leave: Double
    var total: Double
    var byDate: [String: Double]      // total worked hours per day
    var otByDate: [String: Double]    // overtime hours per day
    var leaveByDate: [String: Double]
    var otDollars: Double
}

/// Scheduled paid hours for a default-schedule slot. `nil`/disabled/invalid → 0.
/// Lunch-deducts exactly like a real entry (an 8.5h slot → 8.0 scheduled hours).
func scheduledHours(_ slot: ScheduleSlot?, calendar: Calendar = DomainCalendar.shared) -> Double {
    guard let slot, slot.enabled, let s = slot.startMin, let e = slot.endMin, e > s else { return 0 }
    let start = buildDateTime("2000-01-01", hour24: s / 60, minute: s % 60, calendar: calendar)
    let end = buildDateTime("2000-01-01", hour24: e / 60, minute: e % 60, calendar: calendar)
    return hoursForEntry(start: start, end: end).hours
}

/// Scheduled paid hours for a day-of-period index (0..13).
func scheduledHoursForIndex(_ schedule: [ScheduleSlot?], _ i: Int,
                            calendar: Calendar = DomainCalendar.shared) -> Double {
    guard i >= 0, i < schedule.count else { return 0 }
    return scheduledHours(schedule[i], calendar: calendar)
}

/// Totals for a whole pay period. Pure — the caller supplies the period's
/// entries, leave, schedule, mode, rate, holidays, and any open entry.
///
/// OT rules (ported verbatim from `app.js periodTotals`):
///  - **8-hour mode** (`otMode == true`): per-day work beyond that day's
///    SCHEDULED hours is OT, ungated. Unscheduled weekends/off days = all-OT.
///  - **Maxiflex** (`otMode == false`): explicit per-entry OT (`isOvertime`) +
///    auto OT (work beyond scheduled hours, only once the period exceeds 80h).
///  - Worked-holiday hours are entirely OT in either mode, paying 2× when the
///    holiday is flagged double-time, else 1.5×.
func periodTotals(period: PayPeriod,
                  entries: [EntryRecord],
                  leaveByDate: [String: Int],
                  schedule: [ScheduleSlot?],
                  otMode: Bool,
                  hourlyRate: Double = 0,
                  holidays: [String: HolidayInfo] = [:],
                  openEntry: OpenEntry? = nil,
                  now: Date = Date(),
                  calendar: Calendar = DomainCalendar.shared) -> PeriodTotals {
    let dayset = Set(period.days)
    var byDate: [String: Double] = [:]
    var explicitByDate: [String: Double] = [:]
    for d in period.days { byDate[d] = 0; explicitByDate[d] = 0 }

    for e in entries {
        if e.incomplete || e.endTime == nil { continue }
        guard dayset.contains(e.date) else { continue }
        let h = e.paidHours
        byDate[e.date, default: 0] += h
        if e.isOvertime { explicitByDate[e.date, default: 0] += h }
    }

    // Fold the running open entry into its day (typically today).
    if let open = openEntry, dayset.contains(open.date) {
        let end = roundToQuarter(now, calendar: calendar)
        let h = hoursForEntry(start: open.startTime, end: end).hours
        byDate[open.date, default: 0] += h
        if open.isOvertime { explicitByDate[open.date, default: 0] += h }
    }

    var worked = 0.0
    for d in period.days { worked += byDate[d] ?? 0 }
    let periodOver80 = worked > TimeConstants.payPeriodTarget

    var otByDate: [String: Double] = [:]
    var leaveOut: [String: Double] = [:]
    var ot = 0.0, leave = 0.0, otDollars = 0.0

    for (i, d) in period.days.enumerated() {
        let dayWorked = byDate[d] ?? 0
        let dayOT: Double
        if let holiday = holidays[d] {
            dayOT = dayWorked
            otDollars += dayOT * hourlyRate * (holiday.doubleTime ? TimeConstants.holidayMultiplier : TimeConstants.otMultiplier)
        } else {
            if otMode {
                dayOT = max(0, dayWorked - scheduledHoursForIndex(schedule, i, calendar: calendar))
            } else {
                let explicit = explicitByDate[d] ?? 0
                let regularWorked = max(0, dayWorked - explicit)
                let auto = maxiflexDayOvertime(dayRegularWorked: regularWorked,
                                               dayScheduledHours: scheduledHoursForIndex(schedule, i, calendar: calendar),
                                               periodOver80: periodOver80)
                dayOT = explicit + auto
            }
            otDollars += dayOT * hourlyRate * TimeConstants.otMultiplier
        }
        otByDate[d] = dayOT
        ot += dayOT
        let dayLeave = Double(leaveByDate[d] ?? 0)
        leaveOut[d] = dayLeave
        leave += dayLeave
    }

    return PeriodTotals(worked: worked, ot: ot, leave: leave, total: worked + leave,
                        byDate: byDate, otByDate: otByDate, leaveByDate: leaveOut,
                        otDollars: otDollars)
}
