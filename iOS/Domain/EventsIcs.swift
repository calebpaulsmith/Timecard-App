import Foundation

/// RFC-5545 export/import for calendar-mode events, ported from `calendar.js`
/// (`buildEventsIcs` / `parseEventsIcs`). Recurrence travels as the stored RRULE
/// string (no expansion) so it round-trips through any compliant client. Times
/// are floating-local (no TZID/Z), matching how events are entered. Reuses
/// `icsEscape` / `foldIcsLine` from `Ics.swift`.

private func icsStamp(_ now: Date = Date()) -> String {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
    func p(_ n: Int) -> String { String(format: "%02d", n) }
    return "\(String(format: "%04d", c.year ?? 0))\(p(c.month ?? 0))\(p(c.day ?? 0))" +
           "T\(p(c.hour ?? 0))\(p(c.minute ?? 0))\(p(c.second ?? 0))Z"
}

private func icsDate(_ ymd: String) -> String { ymd.replacingOccurrences(of: "-", with: "") }

private func icsDateTime(_ ymd: String, _ minutes: Int) -> String {
    let mm = max(0, minutes)
    return "\(icsDate(ymd))T\(String(format: "%02d", mm / 60))\(String(format: "%02d", mm % 60))00"
}

/// Build an iCalendar string from a list of events. Backlog items (no date) are
/// skipped. Recurrence rides as the stored RRULE body verbatim.
func buildEventsIcs(_ events: [CalEvent], calName: String = "Home Calendar",
                    now: Date = Date(), calendar: Calendar = DomainCalendar.shared) -> String {
    let stamp = icsStamp(now)
    var lines: [String] = [
        "BEGIN:VCALENDAR", "VERSION:2.0",
        "PRODID:-//Timecard App//Home Calendar//EN", "CALSCALE:GREGORIAN",
        "X-WR-CALNAME:" + icsEscape(calName),
    ]
    for ev in events {
        guard let date = ev.date else { continue }   // backlog → skip
        lines.append("BEGIN:VEVENT")
        lines.append("UID:" + ev.id + "@timecard-app")
        lines.append("DTSTAMP:" + stamp)
        lines.append("SUMMARY:" + icsEscape(ev.title.isEmpty ? "(untitled)" : ev.title))
        if ev.allDay {
            let next = formatLocalDate(addDays(parseLocalDate(date, calendar: calendar), 1, calendar: calendar), calendar: calendar)
            lines.append("DTSTART;VALUE=DATE:" + icsDate(date))
            lines.append("DTEND;VALUE=DATE:" + icsDate(next))
        } else {
            let sm = ev.startMin
            let em = ev.endMin > sm ? ev.endMin : sm + 60
            lines.append("DTSTART:" + icsDateTime(date, sm))
            lines.append("DTEND:" + icsDateTime(date, em))
        }
        if let rrule = ev.rrule, !rrule.isEmpty { lines.append("RRULE:" + rrule) }
        if !ev.exdates.isEmpty {
            if ev.allDay {
                lines.append("EXDATE;VALUE=DATE:" + ev.exdates.map(icsDate).joined(separator: ","))
            } else {
                lines.append("EXDATE:" + ev.exdates.map { icsDateTime($0, ev.startMin) }.joined(separator: ","))
            }
        }
        if !ev.location.isEmpty { lines.append("LOCATION:" + icsEscape(ev.location)) }
        if !ev.notes.isEmpty { lines.append("DESCRIPTION:" + icsEscape(ev.notes)) }
        lines.append("CATEGORIES:" + icsEscape(ev.color.label))
        lines.append("END:VEVENT")
    }
    lines.append("END:VCALENDAR")
    return lines.map(foldIcsLine).joined(separator: "\r\n") + "\r\n"
}

private func icsUnescape(_ s: String) -> String {
    var out = s.replacingOccurrences(of: "\\n", with: "\n", options: .caseInsensitive)
    out = out.replacingOccurrences(of: "\\,", with: ",")
    out = out.replacingOccurrences(of: "\\;", with: ";")
    out = out.replacingOccurrences(of: "\\\\", with: "\\")
    return out
}

/// Parse one ICS DATE/DATE-TIME token into (date, allDay, minutes). Times are
/// read as wall-clock (floating); a trailing Z is accepted but not converted.
private func parseIcsWhen(_ value: String, isDate: Bool) -> (date: String?, allDay: Bool, minutes: Int?) {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    let chars = Array(trimmed)
    guard chars.count >= 8, let y = Int(String(chars[0..<4])),
          let m = Int(String(chars[4..<6])), let d = Int(String(chars[6..<8])) else {
        return (nil, isDate, nil)
    }
    let date = String(format: "%04d-%02d-%02d", y, m, d)
    // Time part present?  ...T HHMM SS
    if !isDate, chars.count >= 13, chars[8] == "T",
       let hh = Int(String(chars[9..<11])), let mi = Int(String(chars[11..<13])) {
        return (date, false, hh * 60 + mi)
    }
    return (date, true, nil)
}

/// Parse an iCalendar string into events (single + recurring; recurrence kept as
/// the RRULE body). Unknown colors fall back to `.personal`.
func parseEventsIcs(_ text: String) -> [CalEvent] {
    // Unfold RFC-5545 continuation lines (a line starting with space/tab joins
    // the previous), normalizing line endings first.
    let unfolded = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(of: "\n ", with: "")
        .replacingOccurrences(of: "\n\t", with: "")

    var events: [CalEvent] = []
    var cur: CalEvent? = nil
    var haveDate = false

    for line in unfolded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if line == "BEGIN:VEVENT" {
            cur = CalEvent(date: nil, color: .personal)
            haveDate = false
            continue
        }
        if line == "END:VEVENT" {
            if let c = cur, haveDate { events.append(c) }
            cur = nil
            continue
        }
        guard cur != nil, let ci = line.firstIndex(of: ":") else { continue }
        let head = String(line[line.startIndex..<ci])
        let value = String(line[line.index(after: ci)...])
        let params = head.split(separator: ";").map(String.init)
        let name = (params.first ?? "").uppercased()
        let isDate = params.contains { $0.range(of: "VALUE=DATE", options: .caseInsensitive) != nil }

        switch name {
        case "SUMMARY": cur?.title = icsUnescape(value)
        case "LOCATION": cur?.location = icsUnescape(value)
        case "DESCRIPTION": cur?.notes = icsUnescape(value)
        case "RRULE": cur?.rrule = value.trimmingCharacters(in: .whitespaces)
        case "CATEGORIES":
            if let c = EventColor.from(label: icsUnescape(value)) { cur?.color = c }
        case "DTSTART":
            let p = parseIcsWhen(value, isDate: isDate)
            cur?.date = p.date
            cur?.allDay = p.allDay
            if let mins = p.minutes { cur?.startMin = mins }
            haveDate = p.date != nil
        case "DTEND":
            let p = parseIcsWhen(value, isDate: isDate)
            if let mins = p.minutes { cur?.endMin = mins }
        case "EXDATE":
            for part in value.split(separator: ",").map(String.init) {
                let p = parseIcsWhen(part, isDate: isDate)
                if let d = p.date { cur?.exdates.append(d) }
            }
        default: break
        }
    }
    return events
}
