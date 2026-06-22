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

    var use24h: Bool { store.use24h }
    var dateTitle: String { formatDateShort(date, calendar: calendar) }
    var isToday: Bool { date == formatLocalDate(Date(), calendar: calendar) }

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
            open = OpenEntry(date: o.date, startTime: start, isOvertime: o.isOvertime)
        }
        let totals = periodTotals(period: period, entries: periodEntries, leaveByDate: leaveByDate,
                                  schedule: store.defaultSchedule(),
                                  otMode: store.overtimeModeDefault,
                                  hourlyRate: store.hourlyRate,
                                  holidays: store.holidays(),
                                  openEntry: open, now: now, calendar: calendar)
        worked = totals.byDate[date] ?? 0
        ot = totals.otByDate[date] ?? 0
        leave = Double(store.leaveHours(on: date))
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
    func saveEntry(id: String?, startMin: Int, endMin: Int, isOvertime: Bool) {
        let start = buildDateTime(date, hour24: startMin / 60, minute: startMin % 60, calendar: calendar)
        let end = buildDateTime(date, hour24: endMin / 60, minute: endMin % 60, calendar: calendar)
        let entry = EntryRecord(id: id ?? UUID().uuidString, date: date,
                                startTime: start, endTime: end,
                                lunchMinutes: autoLunchMinutes(start: start, end: end),
                                isOvertime: isOvertime)
        store.upsert(entry)
        reload()
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
}
