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
        var leaveByDate: [String: Int] = [:]
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
                                  openEntry: open, now: now, calendar: calendar)
        worked = totals.byDate[date] ?? 0
        ot = totals.otByDate[date] ?? 0
        leave = Double(store.leaveHours(on: date))

        if let rec = store.holidayRecord(on: date) {
            isHoliday = true; holidayName = rec.name; holidayWorked = rec.doubleTime
        } else {
            isHoliday = false; holidayName = nil; holidayWorked = false
        }

        // Settle the strip's scale to the tight fit over this day's bars + leave.
        var bars = drawableEntries.compactMap { entryBarSpan($0, now: now, calendar: calendar) }
        if let lv = leaveSegment(entries: drawableEntries, dayLeave: leave, now: now, calendar: calendar) {
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
        guard isToday, openEntry == nil else { return }
        let start = roundToQuarter(now, calendar: calendar)
        store.upsert(EntryRecord(date: date, startTime: start, endTime: nil))
        reload(now: now)
    }

    func clockOut(now: Date = Date()) {
        guard var e = openEntry, let start = e.startTime else { return }
        var end = roundToQuarter(now, calendar: calendar)
        if end <= start { end = start }          // same-quarter in/out → 0 hours
        e.endTime = end
        e.lunchMinutes = autoLunchMinutes(start: start, end: end)
        store.upsert(e)
        reload(now: now)
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

    /// Default classification stamped on a new entry: this day's period default
    /// (credit when the period is flagged a flex period, else auto→OT). The toggle
    /// only seeds new entries — it never reclassifies existing ones.
    var newEntryDefaultKind: PayKind {
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
