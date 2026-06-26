import Foundation

/// Pure CSV backup codec — the migration bridge to/from PWA backups. A faithful
/// port of the PWA's `exportToCsv` / `importFromCsv` (`db.js`): one `.csv` split
/// into `# Section: NAME` blocks. Handles the four **timecard** sections
/// (SETTINGS, DEFAULT_SCHEDULE, ENTRIES, LEAVE); calendar-mode sections
/// (EVENTS / EVENT_HISTORY) are skipped, not an error, so a full PWA backup still
/// imports its timecard data. No SwiftData/SwiftUI — operates on `BackupData`.
enum CsvBackup {
    private static let daysLong = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                   "Thursday", "Friday", "Saturday"]
    private static let daysShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    // MARK: - Export

    static func export(_ data: BackupData, generatedAt: Date = Date(),
                       calendar: Calendar = DomainCalendar.shared) -> String {
        var lines: [String] = []
        lines.append("# Timecard App Export")
        lines.append("# Generated: " + iso8601(generatedAt))
        lines.append("# This file is a complete backup of your timecard data. Sections below")
        lines.append("# can be edited by hand; on import, ALL existing data is replaced with")
        lines.append("# whatever is in this file. Hours are computed from Start/End and reflect")
        lines.append("# the 30-min lunch auto-deduction when a span is >= 4 hours.")
        lines.append("")

        // SETTINGS
        lines.append("# Section: SETTINGS")
        lines.append("Key,Value")
        for s in data.settings {
            lines.append(csvRow([s.key, s.value]))
        }
        lines.append("")

        // DEFAULT_SCHEDULE — 14 rows by day-of-period.
        lines.append("# Section: DEFAULT_SCHEDULE")
        lines.append("PeriodDay,Weekday,Enabled,StartTime,EndTime,Leave")
        for i in 0..<TimeConstants.payPeriodDays {
            let weekday = daysLong[i % 7]
            if i < data.schedule.count, let slot = data.schedule[i] {
                let en = slot.enabled ? "yes" : "no"
                let lv = max(0, slot.leaveHours)
                let st = slot.startMin.map(minToHHMM) ?? ""
                let et = slot.endMin.map(minToHHMM) ?? ""
                lines.append(csvRow([String(i), weekday, en, st, et, String(lv)]))
            } else {
                lines.append(csvRow([String(i), weekday, "no", "", "", "0"]))
            }
        }
        lines.append("")

        // ENTRIES
        lines.append("# Section: ENTRIES")
        lines.append("Date,Day,StartTime,EndTime,EndDate,Hours,Lunch,LunchMin,Overtime,Incomplete,FromDefault,ID,PayKind")
        for e in data.entries.sorted(by: { $0.date < $1.date }) {
            let startDateStr = e.date
            let endDateStr = e.endTime.map { formatLocalDate($0, calendar: calendar) } ?? ""
            let endDateCol = (!endDateStr.isEmpty && endDateStr != startDateStr) ? endDateStr : ""
            let dayName = e.startTime.map { daysShort[dow0($0, calendar: calendar)] } ?? ""
            let startTime = e.startTime.map { hhmm($0, calendar: calendar) } ?? ""
            let endTime = e.endTime.map { hhmm($0, calendar: calendar) } ?? ""
            let lm = max(0, e.lunchMinutes)
            let hours = (e.startTime != nil && e.endTime != nil)
                ? hoursForEntry(start: e.startTime, end: e.endTime, lunchMinutes: Double(lm)).hours
                : 0
            lines.append(csvRow([
                startDateStr, dayName, startTime, endTime, endDateCol,
                formatNumber(hours),
                lm > 0 ? "yes" : "no",
                String(lm),
                e.payKind == .overtime ? "yes" : "no",
                e.incomplete ? "yes" : "no",
                e.fromDefault ? "yes" : "no",
                e.id,
                e.payKind.rawValue,
            ]))
        }
        lines.append("")

        // LEAVE — `Hours` stays for back-compat (old/ PWA readers); `Minutes` is
        // the precise 15-min-granular value, preferred by readers that know it.
        lines.append("# Section: LEAVE")
        lines.append("Date,Day,Hours,Minutes")
        for l in data.leave.sorted(by: { $0.date < $1.date }) {
            let d = parseLocalDate(l.date, calendar: calendar)
            let hoursCell = l.minutes % 60 == 0 ? String(l.minutes / 60)
                                                : String(format: "%g", l.hours)
            lines.append(csvRow([l.date, daysShort[dow0(d, calendar: calendar)],
                                 hoursCell, String(l.minutes)]))
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Import

    static func parse(_ text: String, calendar: Calendar = DomainCalendar.shared) -> BackupData {
        let rows = parseCsv(text)
        // Split into sections by `# Section: NAME` markers in column 0.
        var sections: [String: [[String]]] = [:]
        var curName: String? = nil
        var curRows: [[String]] = []
        for row in rows {
            let first = (row.first ?? "").trimmingCharacters(in: .whitespaces)
            if first.hasPrefix("# Section:") {
                if let name = curName { sections[name] = curRows }
                curName = String(first.dropFirst("# Section:".count))
                    .trimmingCharacters(in: .whitespaces).uppercased()
                curRows = []
                continue
            }
            if first.hasPrefix("#") { continue }          // comment
            if row.allSatisfy({ $0.isEmpty }) { continue } // blank
            if curName == nil { continue }                 // before first section
            curRows.append(row)
        }
        if let name = curName { sections[name] = curRows }

        var data = BackupData()
        if let rows = sections["SETTINGS"] { data.settings = parseSettings(rows) }
        if let rows = sections["DEFAULT_SCHEDULE"] { data.schedule = parseSchedule(rows) }
        if let rows = sections["ENTRIES"] { data.entries = parseEntries(rows, calendar: calendar) }
        if let rows = sections["LEAVE"] { data.leave = parseLeave(rows) }
        return data
    }

    private static func parseSettings(_ rows: [[String]]) -> [SettingRecord] {
        guard rows.count > 1 else { return [] }
        var out: [SettingRecord] = []
        for r in rows.dropFirst() {                         // drop header
            let key = (r.first ?? "").trimmingCharacters(in: .whitespaces)
            let raw = (r.count > 1 ? r[1] : "").trimmingCharacters(in: .whitespaces)
            if key.isEmpty || raw.isEmpty { continue }
            // defaultSchedule travels as its own section, never the SETTINGS blob.
            if key == "defaultSchedule" { continue }
            out.append(SettingRecord(key: key, value: raw))
        }
        return out
    }

    private static func parseSchedule(_ rows: [[String]]) -> [ScheduleSlot?] {
        var sched = [ScheduleSlot?](repeating: nil, count: TimeConstants.payPeriodDays)
        guard let header = rows.first else { return sched }
        let h = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let isNewFormat = h.first == "periodday"
        var dowMap: [String: Int] = [:]
        for i in 0..<7 { dowMap[daysLong[i].lowercased()] = i }

        for r in rows.dropFirst() {
            let idx: Int
            let enabledCol: String, startCol: String, endCol: String
            var leaveCol: String = ""
            if isNewFormat {
                guard let parsed = Int((r.first ?? "").trimmingCharacters(in: .whitespaces)),
                      parsed >= 0, parsed < TimeConstants.payPeriodDays else { continue }
                idx = parsed
                enabledCol = r.count > 2 ? r[2] : ""
                startCol = r.count > 3 ? r[3] : ""
                endCol = r.count > 4 ? r[4] : ""
                leaveCol = r.count > 5 ? r[5] : ""
            } else {
                // Legacy 7-row Weekday-keyed format.
                guard let dow = dowMap[(r.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()]
                else { continue }
                idx = dow
                enabledCol = r.count > 1 ? r[1] : ""
                startCol = r.count > 2 ? r[2] : ""
                endCol = r.count > 3 ? r[3] : ""
            }
            let enabled = enabledCol.trimmingCharacters(in: .whitespaces).lowercased() == "yes"
            let leaveHours = max(0, Int(roundedNumber(leaveCol)))
            if let sm = hhmmToMin(startCol), let em = hhmmToMin(endCol) {
                let slot = ScheduleSlot(enabled: enabled, startMin: sm, endMin: em, leaveHours: leaveHours)
                sched[idx] = slot
                if !isNewFormat, idx + 7 < TimeConstants.payPeriodDays { sched[idx + 7] = slot }
            }
        }
        return sched
    }

    private static func parseEntries(_ rows: [[String]], calendar: Calendar) -> [EntryRecord] {
        guard let header = rows.first else { return [] }
        var col: [String: Int] = [:]
        for (i, name) in header.enumerated() {
            col[name.trimmingCharacters(in: .whitespaces).lowercased()] = i
        }
        func get(_ r: [String], _ name: String) -> String {
            guard let i = col[name.lowercased()], i < r.count else { return "" }
            return r[i]
        }
        var out: [EntryRecord] = []
        for r in rows.dropFirst() {
            let date = get(r, "date").trimmingCharacters(in: .whitespaces)
            if date.isEmpty { continue }
            let startStr = get(r, "starttime").trimmingCharacters(in: .whitespaces)
            let endStr = get(r, "endtime").trimmingCharacters(in: .whitespaces)
            let endDate = { () -> String in
                let v = get(r, "enddate").trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? date : v
            }()
            let startTime = dateOn(date, startStr, calendar: calendar)
            let endTime = dateOn(endDate, endStr, calendar: calendar)
            let lunchMinRaw = get(r, "lunchmin").trimmingCharacters(in: .whitespaces)
            let lunchYes = get(r, "lunch").trimmingCharacters(in: .whitespaces).lowercased() == "yes"
            let lunchMinutes = lunchMinRaw.isEmpty
                ? (lunchYes ? 30 : 0)
                : max(0, Int(roundedNumber(lunchMinRaw)))
            let incomplete = get(r, "incomplete").trimmingCharacters(in: .whitespaces).lowercased() == "yes"
            let fromDefault = get(r, "fromdefault").trimmingCharacters(in: .whitespaces).lowercased() == "yes"
            let isOvertime = get(r, "overtime").trimmingCharacters(in: .whitespaces).lowercased() == "yes"
            // New PayKind column wins; older exports fall back to the Overtime flag.
            let kindRaw = get(r, "paykind").trimmingCharacters(in: .whitespaces)
            let payKind = PayKind(rawValue: kindRaw) ?? (isOvertime ? .overtime : .auto)
            let idCol = get(r, "id").trimmingCharacters(in: .whitespaces)
            let id = idCol.isEmpty ? UUID().uuidString : idCol
            out.append(EntryRecord(id: id, date: date, startTime: startTime, endTime: endTime,
                                   lunchMinutes: lunchMinutes, payKind: payKind,
                                   incomplete: incomplete, fromDefault: fromDefault))
        }
        return out
    }

    private static func parseLeave(_ rows: [[String]]) -> [LeaveRecord] {
        guard rows.count > 1 else { return [] }
        var out: [LeaveRecord] = []
        for r in rows.dropFirst() {
            let date = (r.first ?? "").trimmingCharacters(in: .whitespaces)
            // Prefer the precise Minutes column; fall back to Hours (old 3-col CSV).
            var minutes = Int(roundedNumber(r.count > 3 ? r[3] : ""))
            if minutes <= 0 {
                let h = Double((r.count > 2 ? r[2] : "").trimmingCharacters(in: .whitespaces)) ?? 0
                minutes = Int((h * 60).rounded())
            }
            if date.isEmpty || minutes <= 0 { continue }
            out.append(LeaveRecord(date: date, minutes: minutes))
        }
        return out
    }

    // MARK: - CSV primitives (ported from db.js)

    /// Quote a cell if it contains `"`, comma, or a newline; double internal quotes.
    static func csvEscape(_ v: String) -> String {
        if v.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" || $0 == "\r" }) {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }

    static func csvRow(_ cells: [String]) -> String { cells.map(csvEscape).joined(separator: ",") }

    /// RFC-4180 parse into rows of cells (state machine, mirrors `db.js parseCsv`).
    static func parseCsv(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { cell.append(ch) }
            } else {
                if ch == "\"" { inQuotes = true }
                else if ch == "," { row.append(cell); cell = "" }
                else if ch == "\n" { row.append(cell); rows.append(row); row = []; cell = "" }
                else if ch == "\r" { /* skip */ }
                else { cell.append(ch) }
            }
            i += 1
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }

    // MARK: - Small helpers

    static func minToHHMM(_ m: Int) -> String {
        let h = (m / 60) % 24
        return String(format: "%02d:%02d", h, m % 60)
    }

    static func hhmmToMin(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              !parts[0].isEmpty, parts[1].count == 2 else { return nil }
        return h * 60 + m
    }

    private static func dateOn(_ dateStr: String, _ hhmm: String, calendar: Calendar) -> Date? {
        guard let min = hhmmToMin(hhmm) else { return nil }
        return buildDateTime(dateStr, hour24: min / 60, minute: min % 60, calendar: calendar)
    }

    private static func hhmm(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func formatNumber(_ n: Double) -> String {
        if n == n.rounded() { return String(Int(n)) }
        return String(n)
    }

    /// `Number(x) || 0` then round — matches the PWA's lenient numeric parse.
    private static func roundedNumber(_ s: String) -> Double {
        (Double(s.trimmingCharacters(in: .whitespaces)) ?? 0).rounded()
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
