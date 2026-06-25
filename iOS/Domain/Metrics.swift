import Foundation

/// Pure helpers backing the Metrics screen. No SwiftUI/Charts — unit-tested.

/// One day's bar in the daily-hours chart: worked hours split regular / OT /
/// credit, plus leave. `regular + ot + credit == worked`.
struct DayBar: Equatable, Identifiable {
    var id: String { date }
    var date: String          // "YYYY-MM-DD"
    var label: String         // day-of-month, e.g. "4"
    var regular: Double
    var ot: Double
    var credit: Double = 0
    var leave: Double
    var isToday: Bool
}

/// Build the 14 daily bars for a period from its computed totals.
func dailyBars(period: PayPeriod, totals: PeriodTotals, todayStr: String,
               calendar: Calendar = DomainCalendar.shared) -> [DayBar] {
    period.days.map { d in
        let worked = totals.byDate[d] ?? 0
        let ot = min(worked, totals.otByDate[d] ?? 0)
        let credit = min(max(0, worked - ot), totals.creditByDate[d] ?? 0)
        let regular = max(0, worked - ot - credit)
        let leave = totals.leaveByDate[d] ?? 0
        let dayNum = calendar.component(.day, from: parseLocalDate(d, calendar: calendar))
        return DayBar(date: d, label: "\(dayNum)", regular: regular, ot: ot, credit: credit,
                      leave: leave, isToday: d == todayStr)
    }
}

// MARK: - Second chart (recent-OT bars / cumulative pace)

/// Range selector for the recent-overtime history chart (8-hour mode). Persisted
/// as `metricsRange`. Mirrors the PWA's `8pp | ytd | 6mo | 1yr`.
enum MetricsRange: String, CaseIterable, Identifiable {
    case eightPP = "8pp"
    case ytd
    case sixMonths = "6mo"
    case oneYear = "1yr"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .eightPP: return "8 PP"
        case .ytd: return "YTD"
        case .sixMonths: return "6 mo"
        case .oneYear: return "1 yr"
        }
    }
}

/// One bar in the recent-overtime chart: a past period's OT under its own mode.
struct OtBar: Identifiable, Equatable {
    var id: String { periodStart }
    var periodStart: String   // anchor-aligned Sunday "YYYY-MM-DD" (stable id + jump key)
    var label: String         // short axis label, "M/d" of the period start
    var ot: Double
}

/// One point in the cumulative-pace line (Maxiflex mode).
struct PacePoint: Identifiable, Equatable {
    var id: Int { dayIndex }
    var dayIndex: Int         // 0..13
    var value: Double         // cumulative hours (actual) or ideal target at that day
}

/// Distinct anchor-aligned pay periods that contain at least one entry, sorted
/// ascending by start. The candidate set for the recent-OT chart.
func periodStartsWithData(entryDates: [String], anchor: String,
                          calendar: Calendar = DomainCalendar.shared) -> [PayPeriod] {
    var starts = Set<String>()
    for d in entryDates {
        let p = payPeriodFor(today: parseLocalDate(d, calendar: calendar), anchor: anchor, calendar: calendar)
        if let s = p.days.first { starts.insert(s) }
    }
    return starts.sorted().map {
        payPeriodFor(today: parseLocalDate($0, calendar: calendar), anchor: anchor, calendar: calendar)
    }
}

/// Filter the candidate periods (sorted ascending) down to the chosen range.
/// `8pp` = the last 8; `ytd` = paydate-year == this year; `6mo`/`1yr` = start on
/// or after the cutoff. Mirrors `buildRecentOTChart` in the PWA.
func selectRange(_ all: [PayPeriod], range: MetricsRange, today: Date,
                 calendar: Calendar = DomainCalendar.shared) -> [PayPeriod] {
    let t = startOfDay(today, calendar: calendar)
    switch range {
    case .eightPP:
        return Array(all.suffix(8))
    case .ytd:
        let year = calendar.component(.year, from: t)
        return all.filter { paydateYear($0, calendar: calendar) == year }
    case .sixMonths:
        let cutoff = calendar.date(byAdding: .month, value: -6, to: t) ?? t
        return all.filter { $0.start >= cutoff }
    case .oneYear:
        let cutoff = calendar.date(byAdding: .year, value: -1, to: t) ?? t
        return all.filter { $0.start >= cutoff }
    }
}

/// A short "M/d" axis label for a period (from its start date).
func shortPeriodLabel(_ period: PayPeriod, calendar: Calendar = DomainCalendar.shared) -> String {
    let c = calendar.dateComponents([.month, .day], from: period.start)
    return "\(c.month ?? 0)/\(c.day ?? 0)"
}

/// The ideal-pace line: 80 × (N+1)/14 for each day-of-period N (0..13).
func paceIdealSeries() -> [PacePoint] {
    (0..<TimeConstants.payPeriodDays).map {
        PacePoint(dayIndex: $0,
                  value: TimeConstants.payPeriodTarget * Double($0 + 1) / Double(TimeConstants.payPeriodDays))
    }
}

/// The actual cumulative-hours line, summed (worked + leave) through `dayIndex`.
func paceActualSeries(bars: [DayBar], dayIndex: Int) -> [PacePoint] {
    guard dayIndex >= 0 else { return [] }
    var cum = 0.0
    var out: [PacePoint] = []
    for (i, b) in bars.enumerated() where i <= dayIndex {
        cum += b.regular + b.ot + b.credit + b.leave
        out.append(PacePoint(dayIndex: i, value: cum))
    }
    return out
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
