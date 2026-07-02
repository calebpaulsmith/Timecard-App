import Foundation
import Observation

/// Drives the Day editor for one "YYYY-MM-DD": its entries, leave, clock-in/out,
/// and the day's worked/OT/leave summary. OT is period-level, so the day's OT is
/// read from the single `periodTotals` authority for the period containing this
/// day (an open clock-in is folded in live for today). UI is dumb.
@MainActor
@Observable
final class DayViewModel {
    private let store: TimecardStore
    private let calendar: Calendar
    let date: String

    private(set) var entries: [EntryRecord] = []
    private(set) var openEntry: EntryRecord?
    private(set) var worked: Double = 0
    private(set) var ot: Double = 0
    private(set) var leave: Double = 0
    /// Precise leave minutes for this day (15-min granularity) + whether the
    /// 15-minute-step setting is on (drives the leave stepper).
    private(set) var leaveMinutes: Int = 0
    private(set) var leaveGranular: Bool = false
    /// Placement of the leave block (minute-of-day), or nil = auto-place.
    private(set) var leaveStartMin: Int? = nil
    /// This day's scheduled work start (minute-of-day), or nil if unscheduled —
    /// anchors a leave-only day's bar so a whole day off fills from there.
    private(set) var scheduledStartMin: Int? = nil
    /// Leave anchor for a leave-only day: scheduled start, else the strip's left edge.
    var leaveFallbackStartMin: Int { scheduledStartMin ?? TimelineConstants.absoluteStart }

    /// Active recorded-holiday state for this day (PWA day-editor holiday controls).
    private(set) var isHoliday = false
    private(set) var holidayName: String?
    private(set) var holidayWorked = false
    /// The federal-holiday name for this date (whether or not it's recorded yet).
    var federalName: String? { federalHolidayName(date, calendar: calendar) }
    /// Scale for this day's timeline strip (settled on reload, expanded live during a drag).
    private(set) var timelineScale: TimelineScale = .default

    var use24h: Bool { store.use24h }
    var dateTitle: String { formatDateShort(date, calendar: calendar) }
    var isToday: Bool { date == formatLocalDate(Date(), calendar: calendar) }

    /// Drawable entries for the timeline (have a start, not incomplete), sorted by start.
    var drawableEntries: [EntryRecord] {
        entries.filter { $0.startTime != nil && !$0.incomplete }
            .sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
    }

    init(store: TimecardStore, date: String, calendar: Calendar = DomainCalendar.shared) {
        self.store = store
        self.calendar = calendar
        self.date = date
        reload()
    }

    func reload(now: Date = Date()) {
        // Resolve open/forgotten state, marking >16h opens incomplete (PWA parity).
        let scan = scanOpenEntry(store.entries(on: date), now: now)
        for id in scan.forgottenIds {
            if var e = store.entries(on: date).first(where: { $0.id == id }) {
                e.incomplete = true
                e.endTime = nil
                store.upsert(e)
            }
        }
        let dayEntries = store.entries(on: date)
        entries = dayEntries
        let rescan = scanOpenEntry(dayEntries, now: now)
        openEntry = isToday ? dayEntries.first(where: { $0.id == rescan.openId }) : nil

        // Period totals are the single OT authority; fold a running entry in live.
        let anchor = store.anchorDate ?? PeriodViewModel.defaultAnchor(now, calendar: calendar)
        let dayDate = parseLocalDate(date, calendar: calendar)
        let period = payPeriodFor(today: dayDate, anchor: anchor, calendar: calendar)
        let dayset = Set(period.days)
        let periodEntries = store.allEntries().filter { dayset.contains($0.date) }
        var leaveByDate: [String: Double] = [:]
        for l in store.allLeave() where dayset.contains(l.date) { leaveByDate[l.date] = l.hours }

        var open: OpenEntry?
        if let o = openEntry, let start = o.startTime {
            open = OpenEntry(date: o.date, startTime: start, payKind: o.payKind)
        }
        let totals = periodTotals(period: period, entries: periodEntries, leaveByDate: leaveByDate,
                                  schedule: store.defaultSchedule(),
                                  otMode: store.otMode(forPeriodStart: period.days.first ?? ""),
                                  hourlyRate: store.hourlyRate,
                                  holidays: store.holidays(),
                                  openEntry: open,
                                  creditEnabled: store.creditHoursEnabled,
                                  now: now, calendar: calendar)
        worked = totals.byDate[date] ?? 0
        ot = totals.otByDate[date] ?? 0
        leaveMinutes = store.leaveMinutes(on: date)
        leave = Double(leaveMinutes) / 60
        leaveGranular = store.leaveGranularMinutes
        leaveStartMin = store.leaveStart(on: date)
        // The day's scheduled start (for filling a whole day off with leave).
        scheduledStartMin = nil
        if let i = period.days.firstIndex(of: date) {
            let sched = store.defaultSchedule()
            if i >= 0, i < sched.count, let slot = sched[i], slot.enabled {
                scheduledStartMin = slot.startMin
            }
        }

        if let rec = store.holidayRecord(on: date) {
            isHoliday = true; holidayName = rec.name; holidayWorked = rec.doubleTime
        } else {
            isHoliday = false; holidayName = nil; holidayWorked = false
        }

        // Settle the strip's scale to the tight fit over this day's bars + leave.
        var bars = drawableEntries.compactMap { entryBarSpan($0, now: now, calendar: calendar) }
        if let lv = leaveSegment(entries: drawableEntries, dayLeave: leave,
                                 leaveStartMin: store.leaveStart(on: date),
                                 fallbackStartMin: leaveFallbackStartMin, now: now, calendar: calendar) {
            bars.append(lv)
        }
        timelineScale = fitScale(bars: bars)
    }

    /// Widen the strip scale to keep a live drag on-screen (expand-only).
    func expandScale(toInclude span: TimelineSegment) {
        timelineScale = fitScale(bars: [span], base: timelineScale)
    }

    /// Persist a dragged entry edit (lunch already resolved by the strip), then refresh.
    func commitDraggedEntry(_ entry: EntryRecord) {
        store.upsert(entry)
        reload()
    }

    // MARK: - Clock in / out

    func clockIn(now: Date = Date()) {
        guard isToday else { return }
        store.clockIn(now: now, calendar: calendar)
        reload(now: now)
        refreshReminders(now: now)
    }

    func clockOut(now: Date = Date()) {
        guard isToday else { return }
        store.clockOut(now: now, calendar: calendar)
        reload(now: now)
        refreshReminders(now: now)
    }

    /// Re-evaluate local reminders after a clock change (the forgotten-clock-out
    /// timer in particular depends on the open entry). No-op when reminders are off.
    private func refreshReminders(now: Date) {
        let store = self.store
        Task { await ReminderScheduler.refresh(store: store, now: now) }
    }

    // MARK: - Entry CRUD

    /// Create (id nil) or update an entry from picker minutes-since-midnight.
    /// `lunchMinutes` is the user-confirmed value from the editor (auto-computed
    /// by default, but editable — mirrors the PWA's lunch select), persisted
    /// verbatim rather than re-derived.
    func saveEntry(id: String?, startMin: Int, endMin: Int, lunchMinutes: Int, payKind: PayKind) {
        let start = buildDateTime(date, hour24: startMin / 60, minute: startMin % 60, calendar: calendar)
        let end = buildDateTime(date, hour24: endMin / 60, minute: endMin % 60, calendar: calendar)
        let entry = EntryRecord(id: id ?? UUID().uuidString, date: date,
                                startTime: start, endTime: end,
                                lunchMinutes: max(0, lunchMinutes),
                                payKind: payKind)
        store.upsert(entry)
        reload()
    }

    /// Master credit-hours switch — when false, the entry editor shows a simple
    /// Overtime toggle and all credit surfaces are hidden.
    var creditHoursEnabled: Bool { store.creditHoursEnabled }

    /// Default classification stamped on a new entry: this day's period default
    /// (credit when the period is flagged a flex period, else auto→OT). The toggle
    /// only seeds new entries — it never reclassifies existing ones. Always
    /// `auto` when the credit-hours feature is off.
    var newEntryDefaultKind: PayKind {
        guard store.creditHoursEnabled else { return .auto }
        let anchor = store.anchorDate ?? PeriodViewModel.defaultAnchor(Date(), calendar: calendar)
        let period = payPeriodFor(today: parseLocalDate(date, calendar: calendar), anchor: anchor, calendar: calendar)
        return store.creditDefault(forPeriodStart: period.days.first ?? "") ? .autoCredit : .auto
    }

    func deleteEntry(id: String) {
        store.deleteEntry(id: id)
        reload()
    }

    // MARK: - Leave

    func setLeave(_ hours: Int) {
        store.setLeave(on: date, hours: max(0, hours))
        reload()
    }

    /// Set leave precisely (minutes), clamped 0…24h. Used by the granular stepper.
    func setLeaveMinutes(_ minutes: Int) {
        store.setLeave(on: date, minutes: max(0, min(24 * 60, minutes)))
        reload()
    }

    /// Persist a long-press-dragged leave placement (minute-of-day start). The
    /// store splits/trims any work entries under the block so the day wraps
    /// around the leave (LOGIC-FREEZE §3).
    func placeLeave(startMin: Int) {
        store.placeLeave(on: date, startMin: startMin, calendar: calendar)
        reload()
    }

    /// Toggle the 15-minute-step leave setting (a per-app setting, surfaced here
    /// in the day editor).
    func setLeaveGranular(_ on: Bool) {
        store.leaveGranularMinutes = on
        reload()
    }

    // MARK: - Credit hours spent (Phase 2)

    /// Credit hours spent as time off on this day (drawn from the credit bank).
    var creditUsed: Double { store.creditUsed(forDate: date) }

    func setCreditUsed(_ hours: Double) {
        store.setCreditUsed(max(0, hours), forDate: date)
        reload()
    }

    // MARK: - Holiday

    func markHoliday() {
        store.markHoliday(date, calendar: calendar)
        reload()
    }

    func removeHoliday() {
        store.removeHoliday(date)
        reload()
    }

    func setHolidayWorked(_ on: Bool) {
        store.setHolidayWorked(date, on: on)
        reload()
    }
}
