import Foundation

/// An in-progress (open) clock-in, folded live into "today" by `periodTotals`.
struct OpenEntry: Equatable, Sendable {
    var date: String          // "YYYY-MM-DD"
    var startTime: Date
    var payKind: PayKind = .auto
}

/// A recorded federal holiday's pay treatment for a given date.
struct HolidayInfo: Equatable, Sendable {
    var doubleTime: Bool      // worked hours pay 2× instead of 1.5×
}

/// Aggregated totals for one pay period — the single source of truth for
/// overtime + credit hours. Mirrors the PWA's `periodTotals` return shape.
struct PeriodTotals: Equatable, Sendable {
    var worked: Double
    var ot: Double
    var leave: Double
    var total: Double
    var byDate: [String: Double]      // total worked hours per day
    var otByDate: [String: Double]    // overtime hours per day
    var leaveByDate: [String: Double]
    var otDollars: Double
    /// Banked credit hours (beyond-schedule, over-80 work the user marked credit
    /// instead of OT — 1:1, no premium). Maxiflex only.
    var credit: Double = 0
    var creditByDate: [String: Double] = [:]
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

/// A worked unit on a day: paid hours, its pay classification, and a sort key
/// (minutes-since-midnight) so the day's beyond-schedule slice goes latest-first.
private struct WorkedUnit { var hours: Double; var kind: PayKind; var sortKey: Int }

/// Split a day's worked units into forced + candidate-auto premium hours under
/// the refined **Maxiflex** rule (the period-level over-80 cap is applied
/// separately by `periodTotals`):
///  - forced `overtime`/`credit` units pay their whole hours (uncapped) and sit
///    ON TOP of the schedule (they don't consume the cushion);
///  - `auto`/`autoCredit`/`regular` units share the day's beyond-cushion hours
///    (leave already filled the schedule), allocated latest-first: `auto`→OT
///    candidate, `autoCredit`→credit candidate, `regular`→stays regular.
private func splitMaxiflexDay(units: [WorkedUnit], cushion: Double)
    -> (forcedOT: Double, forcedCredit: Double, autoOT: Double, autoCredit: Double) {
    var forcedOT = 0.0, forcedCredit = 0.0
    for u in units {
        if u.kind == .overtime { forcedOT += u.hours }
        else if u.kind == .credit { forcedCredit += u.hours }
    }
    let flex = units.filter { $0.kind == .auto || $0.kind == .autoCredit || $0.kind == .regular }
    let flexWorked = flex.reduce(0) { $0 + $1.hours }
    var pool = max(0, flexWorked - cushion)
    var autoOT = 0.0, autoCredit = 0.0
    for u in flex.sorted(by: { $0.sortKey > $1.sortKey }) {     // latest-first
        if pool <= 0 { break }
        let slice = min(pool, u.hours)
        switch u.kind {
        case .auto:       autoOT += slice
        case .autoCredit: autoCredit += slice
        default:          break        // regular absorbs extra but stays regular
        }
        pool -= slice
    }
    return (forcedOT, forcedCredit, autoOT, autoCredit)
}

/// Totals for a whole pay period. Pure — the caller supplies the period's
/// entries, leave, schedule, mode, rate, holidays, and any open entry.
///
/// OT rules (canonical in `../LOGIC-FREEZE.md` §4):
///  - **8-hour mode** (`otMode == true`): per-day work beyond that day's
///    SCHEDULED hours is OT, ungated. No credit-hour concept.
///  - **Maxiflex** (`otMode == false`): per-entry `PayKind` classification, with
///    leave counting toward the 80h requirement and filling the daily schedule
///    first. The period's **auto** (non-forced) premium is **capped at the hours
///    over 80** (`max(0, worked + leave − 80)`), kept latest-first — so a period
///    only 1.75h over 80 yields at most 1.75h of auto OT/credit, not the full
///    sum of every beyond-schedule hour. Forced overtime/credit are uncapped.
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
    var units: [String: [WorkedUnit]] = [:]     // per-day worked units (Maxiflex)
    for d in period.days { byDate[d] = 0; units[d] = [] }

    for e in entries {
        if e.incomplete || e.endTime == nil { continue }
        guard dayset.contains(e.date) else { continue }
        let h = e.paidHours
        byDate[e.date, default: 0] += h
        let key = e.startTime.map { minutesOfDay($0, calendar: calendar) } ?? 0
        units[e.date, default: []].append(WorkedUnit(hours: h, kind: e.payKind, sortKey: key))
    }

    // Fold the running open entry into its day (typically today).
    if let open = openEntry, dayset.contains(open.date) {
        let end = roundToQuarter(now, calendar: calendar)
        let h = hoursForEntry(start: open.startTime, end: end).hours
        byDate[open.date, default: 0] += h
        units[open.date, default: []].append(
            WorkedUnit(hours: h, kind: open.payKind, sortKey: minutesOfDay(open.startTime, calendar: calendar)))
    }

    var worked = 0.0, leaveTotal = 0.0
    for d in period.days { worked += byDate[d] ?? 0; leaveTotal += Double(leaveByDate[d] ?? 0) }
    // Leave counts toward the 80h requirement (paid pay-status time); the cap
    // below is the *amount* over 80, not a boolean.
    let overAmount = max(0, (worked + leaveTotal) - TimeConstants.payPeriodTarget)

    var otByDate: [String: Double] = [:]
    var creditOut: [String: Double] = [:]
    var leaveOut: [String: Double] = [:]
    // Candidate auto-premium per day (subject to the period over-80 cap below).
    var autoOTByDate: [String: Double] = [:]
    var autoCreditByDate: [String: Double] = [:]
    var ot = 0.0, leave = 0.0, otDollars = 0.0, credit = 0.0

    // Pass 1: holidays, 8h-mode OT, and the per-day Maxiflex forced + auto split.
    for (i, d) in period.days.enumerated() {
        let dayWorked = byDate[d] ?? 0
        let dayLeaveInt = leaveByDate[d] ?? 0
        let scheduled = scheduledHoursForIndex(schedule, i, calendar: calendar)
        otByDate[d] = 0; creditOut[d] = 0; autoOTByDate[d] = 0; autoCreditByDate[d] = 0

        if let holiday = holidays[d] {
            otByDate[d] = dayWorked
            ot += dayWorked
            otDollars += dayWorked * hourlyRate * (holiday.doubleTime ? TimeConstants.holidayMultiplier : TimeConstants.otMultiplier)
        } else if otMode {
            let o = max(0, dayWorked - scheduled)
            otByDate[d] = o; ot += o
            otDollars += o * hourlyRate * TimeConstants.otMultiplier
        } else {
            let cushion = max(0, scheduled - Double(dayLeaveInt))
            let s = splitMaxiflexDay(units: units[d] ?? [], cushion: cushion)
            otByDate[d] = s.forcedOT          // forced premium is uncapped
            creditOut[d] = s.forcedCredit
            ot += s.forcedOT; credit += s.forcedCredit
            otDollars += s.forcedOT * hourlyRate * TimeConstants.otMultiplier
            autoOTByDate[d] = s.autoOT        // candidates, capped in pass 2
            autoCreditByDate[d] = s.autoCredit
        }

        let dayLeave = Double(dayLeaveInt)
        leaveOut[d] = dayLeave
        leave += dayLeave
    }

    // Pass 2 (Maxiflex): pay auto-premium only up to the hours over 80, kept
    // latest-first (the hours that put the period over 80 are the most recent).
    if !otMode {
        var budget = overAmount
        for d in period.days.reversed() {
            if budget <= 0 { break }
            let kOT = min(autoOTByDate[d] ?? 0, budget); budget -= kOT
            let kCredit = min(autoCreditByDate[d] ?? 0, budget); budget -= kCredit
            otByDate[d, default: 0] += kOT
            creditOut[d, default: 0] += kCredit
            ot += kOT; credit += kCredit
            otDollars += kOT * hourlyRate * TimeConstants.otMultiplier
        }
    }

    return PeriodTotals(worked: worked, ot: ot, leave: leave, total: worked + leave,
                        byDate: byDate, otByDate: otByDate, leaveByDate: leaveOut,
                        otDollars: otDollars, credit: credit, creditByDate: creditOut)
}
