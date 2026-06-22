import Foundation

/// Pure helpers backing the Metrics screen. No SwiftUI/Charts — unit-tested.

/// One day's bar in the daily-hours chart: worked hours split regular vs OT,
/// plus leave. `regular + ot == worked`.
struct DayBar: Equatable, Identifiable {
    var id: String { date }
    var date: String          // "YYYY-MM-DD"
    var label: String         // day-of-month, e.g. "4"
    var regular: Double
    var ot: Double
    var leave: Double
    var isToday: Bool
}

/// Build the 14 daily bars for a period from its computed totals.
func dailyBars(period: PayPeriod, totals: PeriodTotals, todayStr: String,
               calendar: Calendar = DomainCalendar.shared) -> [DayBar] {
    period.days.map { d in
        let worked = totals.byDate[d] ?? 0
        let ot = min(worked, totals.otByDate[d] ?? 0)
        let regular = max(0, worked - ot)
        let leave = totals.leaveByDate[d] ?? 0
        let dayNum = calendar.component(.day, from: parseLocalDate(d, calendar: calendar))
        return DayBar(date: d, label: "\(dayNum)", regular: regular, ot: ot, leave: leave,
                      isToday: d == todayStr)
    }
}

/// All anchor-aligned pay periods whose PAYDATE falls in `year` (the YTD
/// bucketing rule: a period counts toward the year its check lands in, so the
/// period ending 2025-12-27 counts toward 2026). Iterates offsets around the
/// period containing Jan 1 with slack on both ends.
func periodsWithPaydateInYear(_ year: Int, anchor: String,
                              calendar: Calendar = DomainCalendar.shared) -> [PayPeriod] {
    let jan1 = dateFrom(year: year, month: 1, day: 1, calendar: calendar)
    let base = payPeriodFor(today: jan1, anchor: anchor, calendar: calendar)
    var out: [PayPeriod] = []
    for k in -3...28 {
        let p = payPeriodOffset(today: base.start, anchor: anchor, offset: k, calendar: calendar)
        if paydateYear(p, calendar: calendar) == year { out.append(p) }
    }
    return out
}
