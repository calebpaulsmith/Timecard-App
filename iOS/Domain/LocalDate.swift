import Foundation

/// The calendar used for all domain date math. Settable so tests can pin a
/// timezone for deterministic DST cases; the app uses the device's current zone.
/// Domain functions also accept an explicit `calendar:` param (defaulted to
/// this) so they remain pure and injectable.
enum DomainCalendar {
    static var shared: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()
}

// MARK: - Integer division matching JS Math.floor / Math.ceil

/// Floor division (rounds toward −∞), matching JS `Math.floor(a / b)`.
/// Swift's `/` truncates toward zero, which differs for negative operands —
/// required for correct negative-offset pay-period math.
func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    let r = a % b
    return (r != 0 && ((r < 0) != (b < 0))) ? q - 1 : q
}

/// Ceil division (rounds toward +∞), matching JS `Math.ceil(a / b)`.
func ceilDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    let r = a % b
    return (r != 0 && ((r < 0) == (b < 0))) ? q + 1 : q
}

// MARK: - Local date helpers (DST-safe; never divide intervals to count days)

/// Parse "YYYY-MM-DD" as a local Date at midnight (not UTC).
func parseLocalDate(_ yyyymmdd: String, calendar: Calendar = DomainCalendar.shared) -> Date {
    let parts = yyyymmdd.split(separator: "-").map { Int($0) ?? 0 }
    var c = DateComponents()
    c.year = parts.count > 0 ? parts[0] : 0
    c.month = parts.count > 1 ? parts[1] : 1
    c.day = parts.count > 2 ? parts[2] : 1
    return calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
}

/// Format a Date as "YYYY-MM-DD" in local time.
func formatLocalDate(_ date: Date, calendar: Calendar = DomainCalendar.shared) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

func startOfDay(_ date: Date, calendar: Calendar = DomainCalendar.shared) -> Date {
    calendar.startOfDay(for: date)
}

func addDays(_ date: Date, _ n: Int, calendar: Calendar = DomainCalendar.shared) -> Date {
    calendar.date(byAdding: .day, value: n, to: date) ?? date
}

/// Whole calendar days from `from` to `to` (DST-safe). Counts day boundaries,
/// so it never drifts by an hour across a DST transition the way ms division does.
func daysBetween(_ from: Date, _ to: Date, calendar: Calendar = DomainCalendar.shared) -> Int {
    let a = calendar.startOfDay(for: from)
    let b = calendar.startOfDay(for: to)
    return calendar.dateComponents([.day], from: a, to: b).day ?? 0
}

/// JS-style day-of-week: 0=Sun .. 6=Sat (the holiday rules were written against
/// `Date.getDay()`). Calendar's `.weekday` is 1=Sun .. 7=Sat.
func dow0(_ date: Date, calendar: Calendar = DomainCalendar.shared) -> Int {
    calendar.component(.weekday, from: date) - 1
}

func dateFrom(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0,
              calendar: Calendar = DomainCalendar.shared) -> Date {
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
    return calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
}

/// True if a "YYYY-MM-DD" string is a Sunday.
func isSunday(_ yyyymmdd: String, calendar: Calendar = DomainCalendar.shared) -> Bool {
    dow0(parseLocalDate(yyyymmdd, calendar: calendar), calendar: calendar) == 0
}

/// Build a Date on a given "YYYY-MM-DD" with hour (0-23) and minute.
func buildDateTime(_ yyyymmdd: String, hour24: Int, minute: Int,
                   calendar: Calendar = DomainCalendar.shared) -> Date {
    let base = parseLocalDate(yyyymmdd, calendar: calendar)
    return calendar.date(bySettingHour: hour24, minute: minute, second: 0, of: base) ?? base
}
