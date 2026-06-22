import Foundation
import Observation

/// Drives the Metrics screen for the CURRENT pay period plus year-to-date
/// roll-ups. All math runs through the single `periodTotals` authority; YTD is
/// bucketed by paydate year (the period ending 2025-12-27 counts toward 2026).
@MainActor
@Observable
final class MetricsViewModel {
    private let store: TimecardStore
    private let calendar: Calendar

    private(set) var periodName = ""
    private(set) var dateRange = ""
    private(set) var worked = 0.0
    private(set) var ot = 0.0
    private(set) var otDollars = 0.0
    private(set) var hoursLeft = 0.0
    private(set) var pacePerDay = 0.0
    private(set) var status: PaceStatus = .onPace
    private(set) var dayIndex = 0
    private(set) var bars: [DayBar] = []
    private(set) var ytdYear = 0
    private(set) var ytdHours = 0.0
    private(set) var ytdOtDollars = 0.0

    var eightHourMode: Bool { store.overtimeModeDefault }
    var showsMoney: Bool { store.hourlyRate > 0 }

    init(store: TimecardStore, calendar: Calendar = DomainCalendar.shared) {
        self.store = store
        self.calendar = calendar
        reload()
    }

    func reload(today: Date = Date()) {
        let anchor = store.anchorDate ?? PeriodViewModel.defaultAnchor(today, calendar: calendar)
        let period = payPeriodFor(today: today, anchor: anchor, calendar: calendar)
        let schedule = store.defaultSchedule()
        let holidays = store.holidays()
        let otMode = store.overtimeModeDefault
        let rate = store.hourlyRate
        let allEntries = store.allEntries()
        let allLeave = store.allLeave()

        // Fold a running clock-in into the current period (live worked/OT).
        let todayStr = formatLocalDate(today, calendar: calendar)
        var open: OpenEntry?
        let scan = scanOpenEntry(allEntries.filter { $0.date == todayStr }, now: today)
        if let id = scan.openId,
           let e = allEntries.first(where: { $0.id == id }), let start = e.startTime {
            open = OpenEntry(date: e.date, startTime: start, isOvertime: e.isOvertime)
        }

        let totals = totalsFor(period, allEntries: allEntries, allLeave: allLeave,
                               schedule: schedule, otMode: otMode, rate: rate, holidays: holidays,
                               openEntry: open, today: today)
        worked = totals.worked
        ot = totals.ot
        otDollars = totals.otDollars
        hoursLeft = max(0, TimeConstants.payPeriodTarget - worked)
        dayIndex = min(max(period.dayIndex, 0), TimeConstants.payPeriodDays - 1)
        let remaining = max(0, TimeConstants.payPeriodDays - 1 - dayIndex)
        pacePerDay = pace(hoursWorked: worked, daysRemaining: remaining)
        status = paceStatus(hoursWorked: worked, dayIndex: dayIndex)
        bars = dailyBars(period: period, totals: totals, todayStr: todayStr, calendar: calendar)
        periodName = payPeriodName(period, anchor: anchor, calendar: calendar)
        dateRange = "\(formatDateShort(period.days.first ?? "", calendar: calendar)) – \(formatDateShort(period.days.last ?? "", calendar: calendar))"

        // YTD roll-up, bucketed by paydate year.
        ytdYear = calendar.component(.year, from: today)
        var hours = 0.0
        var dollars = 0.0
        for p in periodsWithPaydateInYear(ytdYear, anchor: anchor, calendar: calendar) {
            let t = totalsFor(p, allEntries: allEntries, allLeave: allLeave,
                              schedule: schedule, otMode: otMode, rate: rate, holidays: holidays,
                              openEntry: nil, today: today)
            hours += t.worked
            dollars += t.otDollars
        }
        ytdHours = hours
        ytdOtDollars = dollars
    }

    private func totalsFor(_ period: PayPeriod, allEntries: [EntryRecord], allLeave: [LeaveRecord],
                           schedule: [ScheduleSlot?], otMode: Bool, rate: Double,
                           holidays: [String: HolidayInfo], openEntry: OpenEntry?,
                           today: Date) -> PeriodTotals {
        let dayset = Set(period.days)
        let entries = allEntries.filter { dayset.contains($0.date) }
        var leaveByDate: [String: Int] = [:]
        for l in allLeave where dayset.contains(l.date) { leaveByDate[l.date] = l.hours }
        return periodTotals(period: period, entries: entries, leaveByDate: leaveByDate,
                            schedule: schedule, otMode: otMode, hourlyRate: rate,
                            holidays: holidays, openEntry: openEntry, now: today, calendar: calendar)
    }
}
