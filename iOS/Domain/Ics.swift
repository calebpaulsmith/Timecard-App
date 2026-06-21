import Foundation

/// One of the 14 day-of-period default-schedule slots. `nil` slot = never
/// configured. Mirrors the PWA's `{ enabled, startMin, endMin, leaveHours }`.
struct ScheduleSlot: Equatable {
    var enabled: Bool
    var startMin: Int?
    var endMin: Int?
    var leaveHours: Int

    init(enabled: Bool = true, startMin: Int? = nil, endMin: Int? = nil, leaveHours: Int = 0) {
        self.enabled = enabled
        self.startMin = startMin
        self.endMin = endMin
        self.leaveHours = leaveHours
    }
}

/// Escape a value for an ICS text field (RFC 5545): backslash, semicolon, comma,
/// and newline.
func icsEscape(_ s: String) -> String {
    var out = s.replacingOccurrences(of: "\\", with: "\\\\")
    out = out.replacingOccurrences(of: ";", with: "\\;")
    out = out.replacingOccurrences(of: ",", with: "\\,")
    out = out.replacingOccurrences(of: "\r\n", with: "\\n")
    out = out.replacingOccurrences(of: "\n", with: "\\n")
    return out
}

/// Fold a content line to ≤ 75 chars per RFC 5545 (continuation lines start with
/// a single space). Character-count folding is a safe upper bound for the ASCII
/// content emitted here.
func foldIcsLine(_ line: String) -> String {
    if line.count <= 75 { return line }
    let chars = Array(line)
    var out = String(chars[0..<75])
    var rest = Array(chars[75...])
    while rest.count > 74 {
        out += "\r\n " + String(rest[0..<74])
        rest = Array(rest[74...])
    }
    return out + "\r\n " + String(rest)
}

/// Build an iCalendar (.ics) document from the 14-slot default schedule. Each
/// configured slot becomes a BIWEEKLY-recurring event anchored to its first
/// occurrence inside `periodStart`'s period: enabled work slot → timed event;
/// `leaveHours > 0` → all-day "Leave (Nh)" event. Floating local times (no TZ).
/// Stable UIDs + monotonic SEQUENCE so re-imports UPDATE on compliant clients.
func buildScheduleIcs(schedule: [ScheduleSlot?], periodStart: Date,
                      calName: String = "Maxiflex Work Schedule",
                      workSummary: String = "Work",
                      now: Date = Date(),
                      calendar: Calendar = DomainCalendar.shared) -> String {
    func pad(_ n: Int) -> String { String(format: "%02d", n) }

    func fmtLocal(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return "\(String(format: "%04d", c.year ?? 0))\(pad(c.month ?? 0))\(pad(c.day ?? 0))T\(pad(c.hour ?? 0))\(pad(c.minute ?? 0))00"
    }
    func fmtDate(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return "\(String(format: "%04d", c.year ?? 0))\(pad(c.month ?? 0))\(pad(c.day ?? 0))"
    }

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let u = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
    let dtstamp = "\(String(format: "%04d", u.year ?? 0))\(pad(u.month ?? 0))\(pad(u.day ?? 0))T\(pad(u.hour ?? 0))\(pad(u.minute ?? 0))\(pad(u.second ?? 0))Z"
    // Monotonic minutes-since-epoch so re-import is treated as an UPDATE.
    let seq = Int(now.timeIntervalSince1970 / 60)

    var lines: [String] = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Timecard App//Maxiflex Schedule//EN",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        "X-WR-CALNAME:" + icsEscape(calName),
    ]

    let start = calendar.startOfDay(for: periodStart)

    for i in 0..<TimeConstants.payPeriodDays {
        guard i < schedule.count, let slot = schedule[i] else { continue }
        let day = addDays(start, i, calendar: calendar)

        if slot.enabled, let sm = slot.startMin, let em = slot.endMin, em > sm {
            let s = calendar.date(bySettingHour: sm / 60, minute: sm % 60, second: 0, of: day) ?? day
            let e = calendar.date(bySettingHour: em / 60, minute: em % 60, second: 0, of: day) ?? day
            lines.append(contentsOf: [
                "BEGIN:VEVENT",
                "UID:tc-sched-work-\(i)@timecard-app",
                "DTSTAMP:" + dtstamp,
                "SEQUENCE:\(seq)",
                "DTSTART:" + fmtLocal(s),
                "DTEND:" + fmtLocal(e),
                "RRULE:FREQ=WEEKLY;INTERVAL=2",
                "SUMMARY:" + icsEscape(workSummary),
                "END:VEVENT",
            ])
        }

        let lv = max(0, slot.leaveHours)
        if lv > 0 {
            let next = addDays(day, 1, calendar: calendar)
            lines.append(contentsOf: [
                "BEGIN:VEVENT",
                "UID:tc-sched-leave-\(i)@timecard-app",
                "DTSTAMP:" + dtstamp,
                "SEQUENCE:\(seq)",
                "DTSTART;VALUE=DATE:" + fmtDate(day),
                "DTEND;VALUE=DATE:" + fmtDate(next),
                "RRULE:FREQ=WEEKLY;INTERVAL=2",
                "SUMMARY:" + icsEscape("Leave (\(lv)h)"),
                "END:VEVENT",
            ])
        }
    }

    lines.append("END:VCALENDAR")
    return lines.map(foldIcsLine).joined(separator: "\r\n") + "\r\n"
}
