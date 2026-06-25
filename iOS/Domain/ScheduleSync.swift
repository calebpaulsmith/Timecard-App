import Foundation

/// One materialized item for the optional, **limited-window** work-schedule sync
/// (mirrors the PWA's `T.buildScheduleSyncEvents`). Unlike `buildScheduleIcs`,
/// which emits infinite biweekly RRULE series, this produces one plain,
/// non-recurring item per scheduled day so the calendar never carries the
/// schedule beyond the window. The caller re-runs it each sync and reconciles
/// (insert/update/delete) against the previous result, so the window rolls
/// forward and prunes days that fall out of it.
struct ScheduleSyncItem: Equatable {
    /// Stable per-day key for reconciliation: `w:<date>` / `l:<date>` / `h:<date>`.
    let key: String
    let date: String          // YYYY-MM-DD
    let allDay: Bool
    let startMin: Int?
    let endMin: Int?
    let title: String
}

/// Materialize the default schedule into concrete, dated items for a limited
/// forward window — `periodsAhead` whole pay periods starting at `periodStart`
/// (the current period's start). `holidays` maps "YYYY-MM-DD" → a display name
/// (possibly empty); a recorded holiday overrides that day to an all-day
/// "Holiday" item with **no work**, matching `applyDefaultSchedule`.
///
/// Emits, per day-of-period slot:
///   - enabled work slot → a timed work item (`w:<date>`)
///   - `leaveHours > 0` → an all-day "Leave (Nh)" item (`l:<date>`)
func buildScheduleSyncItems(schedule: [ScheduleSlot?], periodStart: Date,
                            periodsAhead: Int, holidays: [String: String],
                            workSummary: String = "Work",
                            calendar: Calendar = DomainCalendar.shared) -> [ScheduleSyncItem] {
    var out: [ScheduleSyncItem] = []
    let periods = max(1, periodsAhead)
    let total = TimeConstants.payPeriodDays * periods
    let start = startOfDay(periodStart, calendar: calendar)
    for n in 0..<total {
        let i = n % TimeConstants.payPeriodDays         // day-of-period index (0..13)
        let date = formatLocalDate(addDays(start, n, calendar: calendar), calendar: calendar)
        if let name = holidays[date] {
            let title = name.isEmpty ? "Holiday" : "Holiday — \(name)"
            out.append(ScheduleSyncItem(key: "h:\(date)", date: date, allDay: true,
                                        startMin: nil, endMin: nil, title: title))
            continue                                     // no work on a recorded holiday
        }
        guard let slot = schedule[i] else { continue }
        if slot.enabled, let s = slot.startMin, let e = slot.endMin, e > s {
            out.append(ScheduleSyncItem(key: "w:\(date)", date: date, allDay: false,
                                        startMin: s, endMin: e, title: workSummary))
        }
        let lv = max(0, slot.leaveHours)
        if lv > 0 {
            out.append(ScheduleSyncItem(key: "l:\(date)", date: date, allDay: true,
                                        startMin: nil, endMin: nil, title: "Leave (\(lv)h)"))
        }
    }
    return out
}
