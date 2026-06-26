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
    /// Worked + leave — the value that counts toward the 80h target (leave counts
    /// toward maxiflex hours), matching the PWA's `totals.total`.
    private(set) var total = 0.0
    private(set) var ot = 0.0
    /// Banked credit hours this period (Maxiflex only; 1:1, no premium).
    private(set) var credit = 0.0
    private(set) var otDollars = 0.0
    private(set) var hoursLeft = 0.0
    private(set) var pacePerDay = 0.0
    private(set) var status: PaceStatus = .onPace
    private(set) var dayIndex = 0
    private(set) var bars: [DayBar] = []
    private(set) var ytdYear = 0
    private(set) var ytdHours = 0.0
    private(set) var ytdOtDollars = 0.0
    /// Year-to-date banked credit hours (paydate-year bucketed, like OT $).
    private(set) var ytdCredit = 0.0
    /// Whether the credit-hours feature is on (gates all credit surfaces).
    private(set) var creditEnabled = false
    /// Running credit-hour bank as of the current period (Phase 2, §4.6):
    /// carried balance + the over-24h-cap forfeiture warning.
    private(set) var creditBalance = 0.0        // hours carried into the next period (≤ cap)
    private(set) var creditBalanceRaw = 0.0     // carryIn + earned − used, before the cap
    private(set) var creditLost = 0.0           // hours forfeited over the cap this period
    private(set) var creditUsedThisPeriod = 0.0 // credit hours spent this period
    var creditOverCap: Bool { creditLost > 0.0001 }
    let creditCap = TimeConstants.creditCarryoverCap
    /// The current period's resolved OT mode (per-period override beats default).
    private(set) var eightHourMode = true

    // Second chart (mode-dependent): recent-OT bars in 8h mode, cumulative pace
    // line in Maxiflex.
    private(set) var metricsRange: MetricsRange = .eightPP
    private(set) var recentOt: [OtBar] = []
    private(set) var paceIdeal: [PacePoint] = []
    private(set) var paceActual: [PacePoint] = []

    var showsMoney: Bool { store.hourlyRate > 0 }

    init(store: TimecardStore, calendar: Calendar = DomainCalendar.shared) {
        self.store = store
        self.calendar = calendar
        reload()
    }

    /// Change the recent-OT history range, persist it, and recompute.
    func setRange(_ range: MetricsRange) {
        guard range != metricsRange else { return }
        metricsRange = range
        store.setStringSetting("metricsRange", range.rawValue)
        reload()
    }

    func reload(today: Date = Date()) {
        metricsRange = MetricsRange(rawValue: store.stringSetting("metricsRange") ?? "8pp") ?? .eightPP
        let anchor = store.anchorDate ?? PeriodViewModel.defaultAnchor(today, calendar: calendar)
        let period = payPeriodFor(today: today, anchor: anchor, calendar: calendar)
        let schedule = store.defaultSchedule()
        let holidays = store.holidays()
        let otMode = store.otMode(forPeriodStart: period.days.first ?? "")
        eightHourMode = otMode
        let rate = store.hourlyRate
        let allEntries = store.allEntries()
        let allLeave = store.allLeave()

        // Fold a running clock-in into the current period (live worked/OT).
        let todayStr = formatLocalDate(today, calendar: calendar)
        var open: OpenEntry?
        let scan = scanOpenEntry(allEntries.filter { $0.date == todayStr }, now: today)
        if let id = scan.openId,
           let e = allEntries.first(where: { $0.id == id }), let start = e.startTime {
            open = OpenEntry(date: e.date, startTime: start, payKind: e.payKind)
        }

        let totals = totalsFor(period, allEntries: allEntries, allLeave: allLeave,
                               schedule: schedule, otMode: otMode, rate: rate, holidays: holidays,
                               openEntry: open, today: today)
        worked = totals.worked
        total = totals.total
        ot = totals.ot
        credit = totals.credit
        otDollars = totals.otDollars
        // Leave counts toward the 80h target, so progress / hours-left / pace all
        // run off `total` (worked + leave) — the PWA's behavior.
        hoursLeft = max(0, TimeConstants.payPeriodTarget - total)
        dayIndex = min(max(period.dayIndex, 0), TimeConstants.payPeriodDays - 1)
        let remaining = max(0, TimeConstants.payPeriodDays - 1 - dayIndex)
        pacePerDay = pace(hoursWorked: total, daysRemaining: remaining)
        status = paceStatus(hoursWorked: total, dayIndex: dayIndex)
        bars = dailyBars(period: period, totals: totals, todayStr: todayStr, calendar: calendar)
        periodName = payPeriodName(period, anchor: anchor, calendar: calendar)
        dateRange = "\(formatDateShort(period.days.first ?? "", calendar: calendar)) – \(formatDateShort(period.days.last ?? "", calendar: calendar))"

        // YTD roll-up, bucketed by paydate year.
        ytdYear = calendar.component(.year, from: today)
        var hours = 0.0
        var dollars = 0.0
        var creditHours = 0.0
        for p in periodsWithPaydateInYear(ytdYear, anchor: anchor, calendar: calendar) {
            let t = totalsFor(p, allEntries: allEntries, allLeave: allLeave,
                              schedule: schedule,
                              otMode: store.otMode(forPeriodStart: p.days.first ?? ""),
                              rate: rate, holidays: holidays,
                              openEntry: nil, today: today)
            hours += t.worked
            dollars += t.otDollars
            creditHours += t.credit
        }
        ytdHours = hours
        ytdOtDollars = dollars
        ytdCredit = creditHours

        // Credit-hour bank (Phase 2). Only meaningful when the feature is on.
        creditEnabled = store.creditHoursEnabled
        if creditEnabled {
            reloadCreditBank(currentStart: period.days.first ?? "", anchor: anchor,
                             allEntries: allEntries, allLeave: allLeave, schedule: schedule,
                             rate: rate, holidays: holidays, today: today)
        } else {
            creditBalance = 0; creditBalanceRaw = 0; creditLost = 0; creditUsedThisPeriod = 0
        }

        // Second chart. 8h mode → recent-OT bars over the chosen range (each
        // period under its own resolved mode); Maxiflex → cumulative pace line.
        let withData = periodStartsWithData(entryDates: allEntries.map { $0.date },
                                            anchor: anchor, calendar: calendar)
        recentOt = selectRange(withData, range: metricsRange, today: today, calendar: calendar).map { p in
            let m = store.otMode(forPeriodStart: p.days.first ?? "")
            let t = totalsFor(p, allEntries: allEntries, allLeave: allLeave, schedule: schedule,
                              otMode: m, rate: rate, holidays: holidays, openEntry: nil, today: today)
            return OtBar(periodStart: p.days.first ?? "", label: shortPeriodLabel(p, calendar: calendar), ot: t.ot)
        }
        paceIdeal = paceIdealSeries()
        paceActual = paceActualSeries(bars: bars, dayIndex: dayIndex)
    }

    /// Fold the credit-hour bank across every credit-relevant period up to and
    /// including the current one, then read off the current period's slot
    /// (balance carried forward + any over-cap forfeiture). Periods that neither
    /// earn nor spend credit are no-ops for the cap, so only credit-relevant
    /// periods need folding.
    private func reloadCreditBank(currentStart: String, anchor: String,
                                  allEntries: [EntryRecord], allLeave: [LeaveRecord],
                                  schedule: [ScheduleSlot?], rate: Double,
                                  holidays: [String: HolidayInfo], today: Date) {
        let usedMap = store.creditUsedMap()
        // Distinct period starts that hold entries OR credit spend, on/before now.
        var starts = Set<String>()
        func addPeriod(for date: String) {
            let p = payPeriodFor(today: parseLocalDate(date, calendar: calendar),
                                 anchor: anchor, calendar: calendar)
            if let s = p.days.first, s <= currentStart { starts.insert(s) }
        }
        for e in allEntries { addPeriod(for: e.date) }
        for (date, h) in usedMap where h > 0 { addPeriod(for: date) }
        starts.insert(currentStart)

        var byPeriod: [(start: String, earned: Double, used: Double)] = []
        for s in starts.sorted() {
            let p = payPeriodFor(today: parseLocalDate(s, calendar: calendar),
                                 anchor: anchor, calendar: calendar)
            let t = totalsFor(p, allEntries: allEntries, allLeave: allLeave, schedule: schedule,
                              otMode: store.otMode(forPeriodStart: s), rate: rate,
                              holidays: holidays, openEntry: nil, today: today)
            let used = p.days.reduce(0.0) { $0 + (usedMap[$1] ?? 0) }
            // Keep credit-relevant periods + always the current one (so it has a slot).
            if t.credit > 0.0001 || used > 0.0001 || s == currentStart {
                byPeriod.append((s, t.credit, used))
            }
        }

        let folded = creditBankFold(byPeriod: byPeriod)
        let slot = creditBankSlot(forPeriodStart: currentStart, in: folded)
        creditBalance = slot.carryOut
        creditBalanceRaw = slot.balance
        creditLost = slot.lost
        creditUsedThisPeriod = slot.used
    }

    private func totalsFor(_ period: PayPeriod, allEntries: [EntryRecord], allLeave: [LeaveRecord],
                           schedule: [ScheduleSlot?], otMode: Bool, rate: Double,
                           holidays: [String: HolidayInfo], openEntry: OpenEntry?,
                           today: Date) -> PeriodTotals {
        let dayset = Set(period.days)
        let entries = allEntries.filter { dayset.contains($0.date) }
        var leaveByDate: [String: Double] = [:]
        for l in allLeave where dayset.contains(l.date) { leaveByDate[l.date] = l.hours }
        return periodTotals(period: period, entries: entries, leaveByDate: leaveByDate,
                            schedule: schedule, otMode: otMode, hourlyRate: rate,
                            holidays: holidays, openEntry: openEntry,
                            creditEnabled: store.creditHoursEnabled,
                            now: today, calendar: calendar)
    }
}
