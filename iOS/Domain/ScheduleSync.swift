import Foundation

/// One materialized item for the optional, **limited-window** work-schedule sync
/// (mirrors the PWA's `T.buildScheduleSyncEvents`). Unlike `buildScheduleIcs`,
/// which emits infinite biweekly RRULE series, this produces one plain,
/// non-recurring item per scheduled day so the calendar never carries the
/// schedule beyond the window. The caller re-runs it each sync and reconciles
/// (insert/update/delete) against the previous result, so the window rolls
/// forward and prunes days that fall out of it.
struct ScheduleSyncItem: Equatable {
    /// Stable per-item key for reconciliation:
    ///   `w:<date>` / `w:<date>#<n>` (extra work blocks) / `l:<date>` / `h:<date>`.
    let key: String
    let date: String          // YYYY-MM-DD
    let allDay: Bool
    let startMin: Int?
    let endMin: Int?
    let title: String
    /// True for leave items (so the caller can route them to a separate calendar).
    let isLeave: Bool

    init(key: String, date: String, allDay: Bool, startMin: Int?, endMin: Int?,
         title: String, isLeave: Bool = false) {
        self.key = key; self.date = date; self.allDay = allDay
        self.startMin = startMin; self.endMin = endMin; self.title = title
        self.isLeave = isLeave
    }
}

/// One actual worked interval on a day (clock in/out minutes-of-day), used when
/// the day has real recorded entries. Lunch is *not* subtracted — this is the
/// clocked span, mirroring how the schedule reads on a calendar.
struct ScheduleWorkBlock: Equatable {
    let startMin: Int
    let endMin: Int
}

/// A day's actual leave (minutes + optional explicit placement).
struct ScheduleLeaveInput: Equatable {
    let minutes: Int
    let startMin: Int?        // nil = auto-place (after the last work block / at scheduled start)
}

/// Leave at or above this many minutes with **no work** on the day reads as a
/// whole day off → an all-day "Leave" block. Below it (or alongside work) leave
/// is a timed block at its actual placement.
private let fullDayLeaveMinutes = 8 * 60

/// Materialize the schedule into concrete, dated items for a limited forward
/// window — `periodsAhead` whole pay periods starting at `periodStart` (the
/// current period's start).
///
/// **Source of truth is the user's ACTUAL data**, not the default schedule:
///   - A day is "touched" (in `touchedDates`) when it has real recorded entries
///     or leave. Touched days sync their actual worked blocks (`actualWork`) and
///     actual leave (`actualLeave`) — so a day the user cleared to leave-only
///     shows leave, not the default shift.
///   - An **untouched** day falls back to the **default-schedule** slot (so a
///     schedule the user hasn't applied/edited yet still goes onto the calendar).
///
/// `holidays` maps "YYYY-MM-DD" → a display name (possibly empty); a recorded
/// holiday overrides the day to an all-day "Holiday" item with **no work**,
/// matching `applyDefaultSchedule`.
///
/// Leave rules (both apps' intent):
///   - `includeLeave == false` → no leave items at all (user preference).
///   - leave ≥ 8h AND no work that day → an all-day "Leave (Nh)" item.
///   - otherwise → a **timed** "Leave (Nh)" block at its actual placement
///     (explicit `startMin`, else after the last work block, else the day's
///     scheduled start), so a 1h leave isn't shown as an all-day event.
func buildScheduleSyncItems(schedule: [ScheduleSlot?], periodStart: Date,
                            periodsAhead: Int, holidays: [String: String],
                            actualWork: [String: [ScheduleWorkBlock]] = [:],
                            actualLeave: [String: ScheduleLeaveInput] = [:],
                            touchedDates: Set<String> = [],
                            includeLeave: Bool = true,
                            workSummary: String = "Work",
                            calendar: Calendar = DomainCalendar.shared) -> [ScheduleSyncItem] {
    var out: [ScheduleSyncItem] = []
    let periods = max(1, periodsAhead)
    let total = TimeConstants.payPeriodDays * periods
    let start = startOfDay(periodStart, calendar: calendar)
    for n in 0..<total {
        let i = n % TimeConstants.payPeriodDays         // day-of-period index (0..13)
        let date = formatLocalDate(addDays(start, n, calendar: calendar), calendar: calendar)

        // Holiday overrides everything → all-day Holiday, no work.
        if let name = holidays[date] {
            let title = name.isEmpty ? "Holiday" : "Holiday — \(name)"
            out.append(ScheduleSyncItem(key: "h:\(date)", date: date, allDay: true,
                                        startMin: nil, endMin: nil, title: title))
            continue
        }

        let slot = schedule[i]
        let scheduledStart = slot?.startMin

        // Resolve work blocks + leave from ACTUAL data when touched, else the
        // default-schedule slot (so an unapplied schedule still syncs).
        var blocks: [ScheduleWorkBlock]
        var leaveMin: Int
        var leaveStart: Int?
        if touchedDates.contains(date) {
            blocks = actualWork[date] ?? []
            leaveMin = actualLeave[date]?.minutes ?? 0
            leaveStart = actualLeave[date]?.startMin
        } else if let slot {
            if slot.enabled, let s = slot.startMin, let e = slot.endMin, e > s {
                blocks = [ScheduleWorkBlock(startMin: s, endMin: e)]
            } else {
                blocks = []
            }
            leaveMin = max(0, slot.leaveHours) * 60
            leaveStart = nil
        } else {
            blocks = []
            leaveMin = 0
            leaveStart = nil
        }

        // Work items (one per actual block; keyed w:<date> then w:<date>#1, #2…).
        for (idx, b) in blocks.enumerated() where b.endMin > b.startMin {
            let key = idx == 0 ? "w:\(date)" : "w:\(date)#\(idx)"
            out.append(ScheduleSyncItem(key: key, date: date, allDay: false,
                                        startMin: b.startMin, endMin: b.endMin, title: workSummary))
        }

        // Leave item.
        guard includeLeave, leaveMin > 0 else { continue }
        let title = "Leave (\(leaveHoursLabel(leaveMin)))"
        if leaveMin >= fullDayLeaveMinutes && blocks.isEmpty {
            out.append(ScheduleSyncItem(key: "l:\(date)", date: date, allDay: true,
                                        startMin: nil, endMin: nil, title: title, isLeave: true))
        } else {
            let anchor = leaveStart ?? blocks.map(\.endMin).max() ?? scheduledStart ?? 9 * 60
            let s = max(0, min(anchor, 24 * 60 - 15))
            let e = min(24 * 60, s + leaveMin)
            out.append(ScheduleSyncItem(key: "l:\(date)", date: date, allDay: false,
                                        startMin: s, endMin: max(s + 15, e), title: title, isLeave: true))
        }
    }
    return out
}

/// "1h" / "1.5h" / "8h" — whole when on the hour, else a trimmed decimal.
private func leaveHoursLabel(_ minutes: Int) -> String {
    if minutes % 60 == 0 { return "\(minutes / 60)h" }
    var s = String(format: "%.2f", Double(minutes) / 60)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s + "h"
}
