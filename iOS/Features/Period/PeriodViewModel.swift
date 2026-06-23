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
        /// Drawable entries for this day (has a start, not incomplete), sorted by
        /// start — what the timeline strip renders + drags.
        var entries: [EntryRecord]
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
        reload()
    }

    func go(to offset: Int) { self.offset = offset; reload() }
    func previous() { offset -= 1; reload() }
    func next() { offset += 1; reload() }

    func reload(today: Date = Date()) {
        anchor = store.anchorDate ?? Self.defaultAnchor(today, calendar: calendar)
        period = payPeriodOffset(today: today, anchor: anchor, offset: offset, calendar: calendar)

        let dayset = Set(period.days)
        let entries = store.allEntries().filter { dayset.contains($0.date) }
        var leaveByDate: [String: Int] = [:]
        for l in store.allLeave() where dayset.contains(l.date) { leaveByDate[l.date] = l.hours }

        totals = periodTotals(period: period, entries: entries, leaveByDate: leaveByDate,
                              schedule: store.defaultSchedule(),
                              otMode: store.overtimeModeDefault,
                              hourlyRate: store.hourlyRate,
                              holidays: store.holidays(),
                              calendar: calendar)

        // Group drawable entries by day for the timeline strips.
        var byDay: [String: [EntryRecord]] = [:]
        for e in entries where e.startTime != nil && !e.incomplete {
            byDay[e.date, default: []].append(e)
        }
        for k in byDay.keys {
            byDay[k]?.sort { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
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
                          entries: byDay[d] ?? [])
        }

        timelineScale = fitScale(bars: allDrawableBars)
    }

    /// Every bar (work entries + the leave tail) across the whole period — the
    /// input to the shared-scale fit, so a late entry on any day widens them all.
    private var allDrawableBars: [TimelineSegment] {
        rows.flatMap { row -> [TimelineSegment] in
            var bars = row.entries.compactMap { entryBarSpan($0, calendar: calendar) }
            if let leave = leaveSegment(entries: row.entries, dayLeave: row.leave, calendar: calendar) {
                bars.append(leave)
            }
            return bars
        }
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

    private static let weekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Most recent Sunday on/before `today` — a sane default until the user sets
    /// a real anchor in Settings.
    static func defaultAnchor(_ today: Date, calendar: Calendar) -> String {
        let d = dow0(today, calendar: calendar)
        return formatLocalDate(addDays(startOfDay(today, calendar: calendar), -d, calendar: calendar),
                               calendar: calendar)
    }
}
