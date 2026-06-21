import Foundation

/// Round a Date to the nearest 15 minutes (seconds zeroed). Returns a new Date.
func roundToQuarter(_ date: Date, calendar: Calendar = DomainCalendar.shared) -> Date {
    var c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let minutes = Double(c.minute ?? 0)
    let rounded = Int((minutes / Double(TimeConstants.quarterMinutes)).rounded()) * TimeConstants.quarterMinutes
    c.minute = 0
    c.second = 0
    let base = calendar.date(from: c) ?? date
    // `rounded` may be 60 → adding minutes rolls the hour, matching JS setMinutes(60,…).
    return calendar.date(byAdding: .minute, value: rounded, to: base) ?? date
}

/// Pretty-print decimal hours. 0.75 → "0.75", 0.5 → "0.5", 8 → "8",
/// 0.8333 → "0.83", 0 → "0".
func formatHours(_ n: Double) -> String {
    if !n.isFinite || n == 0 { return "0" }
    let rounded = (n * 100).rounded() / 100
    if rounded == 0 { return "0" }
    var s = String(format: "%.2f", rounded)
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    return s.isEmpty ? "0" : s
}

/// Format a number as "$1,234.56" (negatives as "-$5.00").
func formatMoney(_ n: Double) -> String {
    if !n.isFinite { return "$0.00" }
    let sign = n < 0 ? "-" : ""
    let absVal = abs(n)
    let s = String(format: "%.2f", absVal)
    let dotParts = s.split(separator: ".", maxSplits: 1).map(String.init)
    let intPart = dotParts[0]
    let frac = dotParts.count > 1 ? dotParts[1] : "00"
    var grouped = ""
    let chars = Array(intPart)
    for (i, ch) in chars.enumerated() {
        if i != 0 && (chars.count - i) % 3 == 0 { grouped.append(",") }
        grouped.append(ch)
    }
    return "\(sign)$\(grouped).\(frac)"
}

private func formatHourMinute(_ h: Int, _ m: Int, use24h: Bool) -> String {
    if use24h { return String(format: "%02d:%02d", h, m) }
    let ampm = h >= 12 ? "PM" : "AM"
    var h12 = h % 12
    if h12 == 0 { h12 = 12 }
    return "\(h12):\(String(format: "%02d", m)) \(ampm)"
}

/// Format a Date as "h:mm AM/PM" (12h) or "HH:mm" (24h) in local time.
func formatTime(_ date: Date, use24h: Bool = false, calendar: Calendar = DomainCalendar.shared) -> String {
    let c = calendar.dateComponents([.hour, .minute], from: date)
    return formatHourMinute(c.hour ?? 0, c.minute ?? 0, use24h: use24h)
}

/// Convert minutes-since-midnight to a display string honoring 24h mode.
func formatMinutes(_ mins: Int, use24h: Bool = false) -> String {
    let h = (mins / 60) % 24
    let m = ((mins % 60) + 60) % 60
    return formatHourMinute(h, m, use24h: use24h)
}

/// Format a "YYYY-MM-DD" as a short "Mon, Apr 21"-style string (localized).
func formatDateShort(_ yyyymmdd: String, calendar: Calendar = DomainCalendar.shared,
                     locale: Locale = .current) -> String {
    let date = parseLocalDate(yyyymmdd, calendar: calendar)
    let f = DateFormatter()
    f.calendar = calendar
    f.locale = locale
    f.timeZone = calendar.timeZone
    f.setLocalizedDateFormatFromTemplate("EEE MMM d")
    return f.string(from: date)
}
