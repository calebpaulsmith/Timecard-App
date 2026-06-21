import Foundation

/// A 14-day pay-period window aligned to a Sunday anchor.
struct PayPeriod: Equatable {
    var start: Date
    var end: Date
    /// Index of "today" within the window (0..13); may be outside that range if
    /// the reference date is outside the period (mirrors the PWA).
    var dayIndex: Int
    /// The 14 "YYYY-MM-DD" day strings of the period, in order.
    var days: [String]
}

/// The pay-period window containing `today`, aligned to the anchor Sunday.
func payPeriodFor(today: Date, anchor anchorStr: String,
                  calendar: Calendar = DomainCalendar.shared) -> PayPeriod {
    let anchor = parseLocalDate(anchorStr, calendar: calendar)
    let t = calendar.startOfDay(for: today)
    let diffDays = daysBetween(anchor, t, calendar: calendar)
    let periodIndex = floorDiv(diffDays, TimeConstants.payPeriodDays)
    let start = addDays(anchor, periodIndex * TimeConstants.payPeriodDays, calendar: calendar)
    let end = addDays(start, TimeConstants.payPeriodDays - 1, calendar: calendar)
    let dayIndex = daysBetween(start, t, calendar: calendar)
    var days: [String] = []
    days.reserveCapacity(TimeConstants.payPeriodDays)
    for i in 0..<TimeConstants.payPeriodDays {
        days.append(formatLocalDate(addDays(start, i, calendar: calendar), calendar: calendar))
    }
    return PayPeriod(start: start, end: end, dayIndex: dayIndex, days: days)
}

/// The period `offset` periods from the one containing `today`
/// (0 = current, −1 = previous, +1 = next).
func payPeriodOffset(today: Date, anchor anchorStr: String, offset: Int,
                     calendar: Calendar = DomainCalendar.shared) -> PayPeriod {
    let base = payPeriodFor(today: today, anchor: anchorStr, calendar: calendar)
    let start = addDays(base.start, offset * TimeConstants.payPeriodDays, calendar: calendar)
    return payPeriodFor(today: start, anchor: anchorStr, calendar: calendar)
}

/// Pay-period name "YYYY-PPNN". YYYY = the year the period starts in;
/// NN = sequential index within that year (PP01 = first anchor-aligned period
/// whose start is on/after Jan 1). E.g. anchor 2026-04-19 → 2026-PP08; the
/// period ending 2025-12-27 → 2025-PP25.
func payPeriodName(_ period: PayPeriod, anchor anchorStr: String,
                   calendar: Calendar = DomainCalendar.shared) -> String {
    let startYear = calendar.component(.year, from: period.start)
    let anchor = parseLocalDate(anchorStr, calendar: calendar)
    let yearStart = dateFrom(year: startYear, month: 1, day: 1, calendar: calendar)
    // Whole-day counting (DST-safe), replacing the JS Math.round(ms/day) hack.
    let diffDays = daysBetween(anchor, yearStart, calendar: calendar)
    let periodsFromAnchor = ceilDiv(diffDays, TimeConstants.payPeriodDays)
    let firstOfYear = addDays(anchor, periodsFromAnchor * TimeConstants.payPeriodDays, calendar: calendar)
    let ppNum = daysBetween(firstOfYear, period.start, calendar: calendar) / TimeConstants.payPeriodDays + 1
    return String(format: "%04d-PP%02d", startYear, ppNum)
}

/// Paydate for a period: period.end + 12 days (used for YTD bucketing).
func paydateFor(_ period: PayPeriod, calendar: Calendar = DomainCalendar.shared) -> Date {
    startOfDay(addDays(period.end, TimeConstants.paydateOffsetDays, calendar: calendar), calendar: calendar)
}

/// Calendar year of the paydate — the year this period's earnings count toward.
func paydateYear(_ period: PayPeriod, calendar: Calendar = DomainCalendar.shared) -> Int {
    calendar.component(.year, from: paydateFor(period, calendar: calendar))
}
