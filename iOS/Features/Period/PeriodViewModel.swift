import Foundation
import Observation

/// Drives the Period view: resolves the viewed pay period, pulls its data from
/// `TimecardStore`, and runs the pure `periodTotals` engine to produce per-day
/// rows + header stats. UI is dumb; all the math lives in Domain.
@MainActor
@Observable
final class PeriodViewModel {
    private let store: TimecardStore
    private let calendar: Calendar

    /// 0 = current period, −1 = previous, +1 = next.
    private(set) var offset = 0
    private(set) var anchor: String
    private(set) var period: PayPeriod
    private(set) var totals: PeriodTotals
    private(set) var rows: [DayRow] = []

    /// One horizontal scale shared by every day's timeline in the period, so the
    /// bars are visually comparable. Settled to the tight fit on `reload`;
    /// expanded (never contracted) live during a drag via `expandScale`.
    private(set) var timelineScale: TimelineScale = .default

    /// The viewed period's resolved OT mode (per-period override beats default).
    /// `true` = 8-hour OT, `false` = Maxiflex.
    private(set) var otMode = true
    /// Master credit-hours switch (Settings). When false, all credit surfaces
    /// are hidden and extra hours pay overtime.
    private(set) var creditHoursEnabled = false
    /// When on, leave +/− steps by 15 minutes instead of whole hours.
    private(set) var leaveGranular = false
    /// Maxiflex-only flex default: when true, NEW entries in this period bank
    /// their beyond-schedule hours as **credit** instead of overtime. Never
    /// reclassifies existing entries. Meaningless in 8-hour mode.
    private(set) var creditDefault = false
    /// Whether to show the per-period Overtime|Credit control: Maxiflex + the
    /// master switch on.
    var showsCreditControl: Bool { !otMode && creditHoursEnabled }
    /// Day-of-period index (0..13) of the timecard-validation deadline, or nil.
    private(set) var validationIndex: Int?

    /// Week selector for the 2-page swipe carousel: 0 = Week 1 (days 0..6),
    /// 1 = Week 2. Driven by the paging swipe (and tappable dots) in `PeriodView`.
    var weekPage = 0
    /// The 7 day rows for a given week page. Both pages render at once inside the
    /// paging carousel, so callers pass the page rather than reading `weekPage`.
    func weekRows(_ page: Int) -> [DayRow] {
        let lo = page * 7
        return Array(rows.dropFirst(lo).prefix(7))
    }

    /// A pending OT-mode change awaiting the OT-erasure confirmation.
    struct PendingModeChange: Equatable {
        var wantOt: Bool
        var lostHours: Double
        var lostDollars: Double
        var fromHours: Double
        var toHours: Double
        var periodName: String
    }
    var pendingModeChange: PendingModeChange?

    struct DayRow: Identifiable {
        var id: String { date }
        var date: String
        var index: Int
        var weekday: String
        var dayLabel: String     // e.g. "Mon May 4"
        var worked: Double
        var ot: Double
        var leave: Double
        var isToday: Bool
        var isWeekend: Bool
        /// This day is the timecard-validation deadline (warning border + ✓).
        var isValidation: Bool
        /// An active recorded holiday's name for this day, else nil.
        var holidayName: String?
        /// Drawable entries for this day (has a start, not incomplete), sorted by
        /// start — what the timeline strip renders + drags.
        var entries: [EntryRecord]
        /// Calendar-mode events for this day (recurring series expanded on read),
        /// all-day first then by start. Rendered only when the day is expanded in
        /// calendar mode; ignored entirely by timecard math.
        var events: [CalEvent] = []
        /// Placement of this day's leave block (minute-of-day), or nil = auto-place
        /// after the last worked entry (Phase 2 drag-to-place).
        var leaveStartMin: Int? = nil
        /// The day's scheduled work start (minute-of-day) from the default schedule,
        /// or nil if unscheduled. Anchors a leave-only day's bar so a whole day off
        /// fills from the scheduled start.
        var scheduledStartMin: Int? = nil
        /// Leave anchor used to render/scale a leave-only day's bar — the scheduled
        /// start, falling back to the timeline's left edge.
        var leaveFallbackStartMin: Int { scheduledStartMin ?? TimelineConstants.absoluteStart }
        /// Hours that count toward the period for this day = worked + leave (leave
        /// counts toward the 80). The number shown on the right of the day row.
        var countedHours: Double { worked + leave }
    }

    var hourlyRate: Double { store.hourlyRate }
    var use24h: Bool { store.use24h }
    var showsMoney: Bool { store.hourlyRate > 0 && totals.otDollars > 0 }
    var periodName: String { payPeriodName(period, anchor: anchor, calendar: calendar) }
    var dateRange: String {
        "\(formatDateShort(period.days.first ?? "", calendar: calendar)) – \(formatDateShort(period.days.last ?? "", calendar: calendar))"
    }

    init(store: TimecardStore, calendar: Calendar = DomainCalendar.shared, today: Date = Date()) {
        self.store = store
        self.calendar = calendar
        // Use a local for the resolved anchor: under @Observable, `anchor` is a
        // computed accessor, so `self.anchor` can't be read until every stored
        // property is initialized.
        let resolvedAnchor = store.anchorDate ?? Self.defaultAnchor(today, calendar: calendar)
        self.anchor = resolvedAnchor
        // Seeded below by reload(); placeholder values keep the initializer total.
        self.period = payPeriodFor(today: today, anchor: resolvedAnchor, calendar: calendar)
        self.totals = PeriodTotals(worked: 0, ot: 0, leave: 0, total: 0,
                                   byDate: [:], otByDate: [:], leaveByDate: [:], otDollars: 0)
        // Auto-record federal holidays once per launch (idempotent; mirrors the
        // PWA's load-time `ensureHolidaysSeeded`).
        store.ensureHolidaysSeeded(now: today, calendar: calendar)
        reload()
        // Land the carousel on whichever week contains today (mirrors the PWA's
        // boot-time `viewedPage` pick). Only for the current period — other
        // periods don't contain today and stay on Week 1.
        if let idx = period.days.firstIndex(of: formatLocalDate(today, calendar: calendar)) {
            weekPage = idx >= 7 ? 1 : 0
        }
    }

    func go(to offset: Int) { self.offset = offset; reload() }
    func previous() { offset -= 1; reload() }
    func next() { offset += 1; reload() }

    func reload(today: Date = Date()) {
        anchor = store.anchorDate ?? Self.defaultAnchor(today, calendar: calendar)
        period = payPeriodOffset(today: today, anchor: anchor, offset: offset, calendar: calendar)

        let dayset = Set(period.days)
        let entries = store.allEntries().filter { dayset.contains($0.date) }
        var leaveByDate: [String: Double] = [:]
        for l in store.allLeave() where dayset.contains(l.date) { leaveByDate[l.date] = l.hours }

        let periodStart = period.days.first ?? ""
        otMode = store.otMode(forPeriodStart: periodStart)
        creditHoursEnabled = store.creditHoursEnabled
        leaveGranular = store.leaveGranularMinutes
        creditDefault = store.creditDefault(forPeriodStart: periodStart)
        validationIndex = store.validationDay()
        let holidays = store.holidays()
        let schedule = store.defaultSchedule()

        totals = periodTotals(period: period, entries: entries, leaveByDate: leaveByDate,
                              schedule: schedule,
                              otMode: otMode,
                              hourlyRate: store.hourlyRate,
                              holidays: holidays,
                              creditEnabled: creditHoursEnabled,
                              calendar: calendar)

        // Group drawable entries by day for the timeline strips.
        var byDay: [String: [EntryRecord]] = [:]
        for e in entries where e.startTime != nil && !e.incomplete {
            byDay[e.date, default: []].append(e)
        }
        for k in byDay.keys {
            byDay[k]?.sort { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
        }

        // Calendar-mode events for the whole period (series expanded once on
        // read), grouped by day. Resolved unconditionally — cheap local fetch —
        // but only rendered when a day is expanded in calendar mode.
        var eventsByDay: [String: [CalEvent]] = [:]
        for ev in store.resolveEvents(forDays: period.days) {
            guard let d = ev.date else { continue }
            // The Period view is the "timeline page": hide events whose calendar is
            // marked calendar-page-only (showOnTimeline == false).
            if store.hiddenFromTimeline(ev) { continue }
            eventsByDay[d, default: []].append(ev)
        }
        for k in eventsByDay.keys {
            eventsByDay[k]?.sort { a, b in
                if a.allDay != b.allDay { return a.allDay }   // all-day first
                return a.startMin < b.startMin
            }
        }

        let todayStr = formatLocalDate(today, calendar: calendar)
        rows = period.days.enumerated().map { i, d in
            let w = dow0(parseLocalDate(d, calendar: calendar), calendar: calendar)
            return DayRow(date: d, index: i,
                          weekday: Self.weekdayShort[w],
                          dayLabel: formatDateShort(d, calendar: calendar),
                          worked: totals.byDate[d] ?? 0,
                          ot: totals.otByDate[d] ?? 0,
                          leave: totals.leaveByDate[d] ?? 0,
                          isToday: d == todayStr,
                          isWeekend: w == 0 || w == 6,
                          isValidation: validationIndex == i,
                          holidayName: store.holidayRecord(on: d)?.name,
                          entries: byDay[d] ?? [],
                          events: eventsByDay[d] ?? [],
                          leaveStartMin: store.leaveStart(on: d),
                          scheduledStartMin: Self.scheduledStart(schedule, i))
        }

        timelineScale = fitScale(bars: allDrawableBars)
    }

    /// Every bar (work entries + the leave tail) across the whole period — the
    /// input to the shared-scale fit, so a late entry on any day widens them all.
    private var allDrawableBars: [TimelineSegment] {
        rows.flatMap { row -> [TimelineSegment] in
            var bars = row.entries.compactMap { entryBarSpan($0, calendar: calendar) }
            if let leave = leaveSegment(entries: row.entries, dayLeave: row.leave,
                                        leaveStartMin: row.leaveStartMin,
                                        fallbackStartMin: row.leaveFallbackStartMin,
                                        calendar: calendar) {
                bars.append(leave)
            }
            return bars
        }
    }

    /// A day-of-period slot's scheduled work start (minute-of-day), or nil when
    /// the slot is disabled / unscheduled.
    private static func scheduledStart(_ schedule: [ScheduleSlot?], _ i: Int) -> Int? {
        guard i >= 0, i < schedule.count, let slot = schedule[i], slot.enabled else { return nil }
        return slot.startMin
    }

    /// Widen the shared scale to keep a live-dragged span on-screen. Only ever
    /// expands (never contracts) so the strip doesn't shift under the finger;
    /// the next `reload` settles it back to the tight fit.
    func expandScale(toInclude span: TimelineSegment) {
        timelineScale = fitScale(bars: [span], base: timelineScale)
    }

    /// Persist a dragged entry edit, then refresh totals + re-settle the scale.
    func commitEntry(_ entry: EntryRecord) {
        store.upsert(entry)
        reload()
    }

    /// Quick per-day leave nudge from the day row / expand panel, in **minutes**
    /// (the caller passes ±60 or ±15 per the granularity setting), clamped 0…24h.
    /// Mirrors the PWA's per-day leave +/− on the day cards.
    func adjustLeave(on date: String, deltaMinutes: Int) {
        let next = max(0, min(24 * 60, store.leaveMinutes(on: date) + deltaMinutes))
        store.setLeave(on: date, minutes: next)
        reload()
    }

    /// Persist a long-press-dragged leave placement (minute-of-day start).
    func placeLeave(on date: String, startMin: Int) {
        store.setLeaveStart(on: date, startMin: startMin)
        reload()
    }

    /// Take the whole day off: remove the day's work entries and fill it with
    /// leave equal to that day's scheduled hours (8h fallback when unscheduled),
    /// anchored at the scheduled start so the leave bar fills the day. Mirrors a
    /// pure-leave off day in the default schedule.
    func takeDayOff(on date: String) {
        guard let i = period.days.firstIndex(of: date) else { return }
        let schedule = store.defaultSchedule()
        var hours = scheduledHoursForIndex(schedule, i, calendar: calendar)
        if hours <= 0 { hours = 8 }
        // Clear the day's work entries (drawable + incomplete).
        for e in store.allEntries() where e.date == date { store.deleteEntry(id: e.id) }
        store.setLeave(on: date, minutes: Int((hours * 60).rounded()))
        if let start = Self.scheduledStart(schedule, i) {
            store.setLeaveStart(on: date, startMin: start)
        }
        reload()
    }

    // MARK: - Per-period OT mode

    /// Request switching the viewed period to `wantOt`. If the switch would erase
    /// overtime, stages a `pendingModeChange` for confirmation instead of applying
    /// immediately (mirrors the PWA's `onTogglePeriodMode` → `modeConfirmModal`).
    func requestOtMode(_ wantOt: Bool) {
        guard wantOt != otMode else { return }
        let periodStart = period.days.first ?? ""
        let dayset = Set(period.days)
        let entries = store.allEntries().filter { dayset.contains($0.date) }
        var leaveByDate: [String: Double] = [:]
        for l in store.allLeave() where dayset.contains(l.date) { leaveByDate[l.date] = l.hours }
        func totals(_ mode: Bool) -> PeriodTotals {
            periodTotals(period: period, entries: entries, leaveByDate: leaveByDate,
                         schedule: store.defaultSchedule(), otMode: mode,
                         hourlyRate: store.hourlyRate, holidays: store.holidays(),
                         creditEnabled: store.creditHoursEnabled,
                         calendar: calendar)
        }
        let cur = totals(otMode), next = totals(wantOt)
        if next.ot < cur.ot - 0.001 {
            pendingModeChange = PendingModeChange(
                wantOt: wantOt,
                lostHours: cur.ot - next.ot,
                lostDollars: cur.otDollars - next.otDollars,
                fromHours: cur.ot, toHours: next.ot,
                periodName: payPeriodName(period, anchor: anchor, calendar: calendar))
        } else {
            applyOtMode(wantOt, periodStart: periodStart)
        }
    }

    /// Apply the staged mode change (called after the user confirms).
    func confirmPendingModeChange() {
        guard let p = pendingModeChange else { return }
        applyOtMode(p.wantOt, periodStart: period.days.first ?? "")
        pendingModeChange = nil
    }

    func cancelPendingModeChange() { pendingModeChange = nil }

    private func applyOtMode(_ wantOt: Bool, periodStart: String) {
        store.setOvertimeMode(forPeriodStart: periodStart, mode: wantOt)
        reload()
    }

    // MARK: - Per-period credit-hours default

    /// Set the viewed period's flex default (OT vs credit for NEW entries). Only
    /// affects entries created afterward — existing classifications are untouched.
    func setCreditDefault(_ on: Bool) {
        guard on != creditDefault else { return }
        store.setCreditDefault(forPeriodStart: period.days.first ?? "", on: on)
        reload()
    }

    // MARK: - Calendar events (EventEditing)
    //
    // Day-centric add/edit from the period view's expand-in-place. Mirrors
    // `CalendarViewModel`'s editing so the shared `EventEditView` sheet drives
    // either screen; both end in `reload()` so the day card refreshes.

    func saveEvent(_ ev: CalEvent) {
        var e = ev
        e.updatedAt = Date()
        store.upsertEvent(e)
        reload()
    }

    // MARK: - Multi-calendar resolution (for the timeline overlay + editor)

    /// Synced calendars available to assign events to (the editor's picker).
    var calendarOptions: [CalendarConfig] { store.calendarConfigs().filter { $0.synced } }
    /// The default calendar new tasks go to (nil if none configured).
    var taskCalendarId: String? { store.taskCalendarId() }
    /// An event's render-color hex (per-calendar config), or nil for the theme swatch.
    func eventColorHex(_ ev: CalEvent) -> String? { store.colorHex(forEvent: ev) }
    /// An event's timeline band (mine / close / others / tasks).
    func tier(_ ev: CalEvent) -> CalendarTier { store.tier(forEvent: ev) }

    /// Delete an event. For a recurring occurrence, "this" cancels just that day
    /// (adds an exdate); otherwise the whole row/series is removed.
    func deleteEvent(_ ev: CalEvent, thisOccurrenceOnly: Bool) {
        if ev.isOccurrence, thisOccurrenceOnly, let sid = ev.occurrenceOf, let d = ev.date {
            store.addExdate(seriesId: sid, date: d)
        } else if let sid = ev.occurrenceOf {
            store.deleteEvent(id: sid)            // delete the whole series
        } else {
            store.deleteEvent(id: ev.id)
        }
        reload()
    }

    private static let weekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Most recent Sunday on/before `today` — a sane default until the user sets
    /// a real anchor in Settings.
    static func defaultAnchor(_ today: Date, calendar: Calendar) -> String {
        let d = dow0(today, calendar: calendar)
        return formatLocalDate(addDays(startOfDay(today, calendar: calendar), -d, calendar: calendar),
                               calendar: calendar)
    }
}

extension PeriodViewModel: EventEditing {}
