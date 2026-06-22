import Foundation

/// Dependency-free RRULE recurrence engine + lane packing, ported verbatim from
/// the PWA `calendar.js`. Pure (no SwiftData/SwiftUI). Supports the subset the
/// app emits: FREQ=DAILY|WEEKLY|MONTHLY|YEARLY with INTERVAL, BYDAY (weekly),
/// COUNT and UNTIL. Stored as a standard RRULE string on the series master so it
/// round-trips through `.ics` and EventKit.

/// RRULE day-of-week codes, indexed 0=Sun .. 6=Sat (matches `dow0`).
let rruleDow = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

struct RecurrenceRule: Equatable, Sendable {
    var freq: String          // DAILY | WEEKLY | MONTHLY | YEARLY
    var interval: Int
    var byday: [String]
    var count: Int?
    var until: String?        // "YYYYMMDD"
}

/// Parse an RRULE body into a `RecurrenceRule`, or `nil` if there's no FREQ.
func parseRRule(_ str: String?) -> RecurrenceRule? {
    guard let str, !str.isEmpty else { return nil }
    var freq: String? = nil
    var interval = 1
    var byday: [String] = []
    var count: Int? = nil
    var until: String? = nil
    for part in str.split(separator: ";") {
        let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2, !kv[1].isEmpty else { continue }
        let key = kv[0].uppercased()
        let v = kv[1]
        switch key {
        case "FREQ": freq = v.uppercased()
        case "INTERVAL": interval = max(1, Int(v) ?? 1)
        case "BYDAY":
            byday = v.uppercased().split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        case "COUNT": count = max(1, Int(v) ?? 1)
        case "UNTIL": until = String(v.prefix(8))   // drop any time part
        default: break
        }
    }
    guard let f = freq else { return nil }
    return RecurrenceRule(freq: f, interval: interval, byday: byday, count: count, until: until)
}

/// Serialize a `RecurrenceRule` back to an RRULE body, or `nil` if no FREQ.
func formatRRule(_ rule: RecurrenceRule?) -> String? {
    guard let rule, !rule.freq.isEmpty else { return nil }
    var parts = ["FREQ=" + rule.freq]
    if rule.interval > 1 { parts.append("INTERVAL=\(rule.interval)") }
    if rule.freq == "WEEKLY", !rule.byday.isEmpty { parts.append("BYDAY=" + rule.byday.joined(separator: ",")) }
    if let c = rule.count { parts.append("COUNT=\(c)") }
    else if let u = rule.until { parts.append("UNTIL=" + u) }
    return parts.joined(separator: ";")
}

/// Expand a recurrence into the "YYYY-MM-DD" occurrence dates inside
/// `[winStart, winEnd]` (inclusive). `startDate` is the series anchor (DTSTART).
/// COUNT/UNTIL are honored from the anchor (occurrences before the window still
/// consume the count); `exdates` removes cancelled occurrences.
func expandRRule(startDate: String, ruleStr: String?, winStart: String, winEnd: String,
                 exdates: [String] = [], calendar: Calendar = DomainCalendar.shared) -> [String] {
    let ex = Set(exdates)
    var res: [String] = []
    guard let rule = parseRRule(ruleStr) else {
        if startDate >= winStart && startDate <= winEnd && !ex.contains(startDate) { res.append(startDate) }
        return res
    }
    let start = parseLocalDate(startDate, calendar: calendar)
    let wStart = parseLocalDate(winStart, calendar: calendar)
    let wEnd = parseLocalDate(winEnd, calendar: calendar)
    let until: Date? = rule.until.flatMap { u -> Date? in
        guard u.count >= 8 else { return nil }
        let y = String(u.prefix(4)), m = String(u.dropFirst(4).prefix(2)), d = String(u.dropFirst(6).prefix(2))
        return parseLocalDate("\(y)-\(m)-\(d)", calendar: calendar)
    }
    let interval = max(1, rule.interval)
    let maxCount = rule.count ?? Int.max
    var count = 0
    let cap = 5000
    var iter = 0

    // Returns false to signal termination (past UNTIL / COUNT).
    func emit(_ dt: Date) -> Bool {
        if let until, dt > until { return false }
        if count >= maxCount { return false }
        count += 1
        if dt > wEnd { return false }
        if dt >= wStart {
            let s = formatLocalDate(dt, calendar: calendar)
            if !ex.contains(s) { res.append(s) }
        }
        return true
    }

    if rule.freq == "WEEKLY" && !rule.byday.isEmpty {
        var bydays = rule.byday.compactMap { rruleDow.firstIndex(of: $0) }.sorted()
        if bydays.isEmpty { bydays = [dow0(start, calendar: calendar)] }
        var weekStart = addDays(start, -dow0(start, calendar: calendar), calendar: calendar) // Sunday of anchor's week
        while iter < cap {
            iter += 1
            var alive = true
            for dow in bydays {
                let occ = addDays(weekStart, dow, calendar: calendar)
                if occ < start { continue }
                if !emit(occ) { alive = false; break }
            }
            if !alive { break }
            weekStart = addDays(weekStart, 7 * interval, calendar: calendar)
            if weekStart > wEnd { break }
            if count >= maxCount { break }
        }
        return res
    }

    var cur = start
    while iter < cap {
        iter += 1
        if !emit(cur) { break }
        switch rule.freq {
        case "DAILY": cur = addDays(cur, interval, calendar: calendar)
        case "WEEKLY": cur = addDays(cur, 7 * interval, calendar: calendar)
        case "MONTHLY": cur = calendar.date(byAdding: .month, value: interval, to: cur) ?? cur
        case "YEARLY": cur = calendar.date(byAdding: .year, value: interval, to: cur) ?? cur
        default: return res
        }
    }
    return res
}

/// Expand a stored series row into concrete occurrence instances over a window.
/// Each instance is a copy carrying the occurrence `date` plus markers
/// (`occurrenceOf`, `seriesDate`) so the editor can offer this/all choices.
func expandSeries(_ series: CalEvent, winStart: String, winEnd: String,
                  calendar: Calendar = DomainCalendar.shared) -> [CalEvent] {
    guard let anchor = series.date else { return [] }
    let dates = expandRRule(startDate: anchor, ruleStr: series.rrule, winStart: winStart, winEnd: winEnd,
                            exdates: series.exdates, calendar: calendar)
    return dates.map { d in
        var copy = series
        copy.date = d
        copy.occurrenceOf = series.id
        copy.seriesDate = anchor
        return copy
    }
}

/// Greedy interval lane packing for timed events: assign each event the lowest
/// lane index that doesn't overlap an already-placed event in that lane. Returns
/// a map of event id → lane index and the lane count. Pure & unit-testable.
func stackEvents(_ events: [CalEvent]) -> (laneOf: [String: Int], laneCount: Int) {
    let sorted = events.sorted { a, b in
        a.startMin != b.startMin ? a.startMin < b.startMin : a.endMin < b.endMin
    }
    var laneEnds: [Int] = []          // laneEnds[i] = endMin of last event in lane i
    var laneOf: [String: Int] = [:]
    for ev in sorted {
        var placed = -1
        for i in laneEnds.indices where ev.startMin >= laneEnds[i] { placed = i; break }
        if placed == -1 { placed = laneEnds.count; laneEnds.append(0) }
        laneEnds[placed] = ev.endMin
        laneOf[ev.id] = placed
    }
    return (laneOf, laneEnds.count)
}
