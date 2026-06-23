import Foundation

/// Per-period OT overrides, the timecard-validation deadline, and holiday
/// recording / auto-seeding. Ports the PWA's `overtimeModeOverrides`,
/// `validationDay`, `markHoliday`/`removeHoliday`/`setHolidayWorked`, and
/// `ensureHolidaysSeeded` (app.js + db.js). Kept off `TimecardStore.swift` so the
/// core repo file stays the CSV/entries/leave bridge.
@MainActor
extension TimecardStore {

    // MARK: - Per-period OT override

    /// The `{ "YYYY-MM-DD": Bool }` map of explicit per-period OT choices, keyed
    /// by the anchor-aligned period start. `true` = 8-hour OT, `false` = Maxiflex.
    func overtimeModeOverrides() -> [String: Bool] {
        guard let raw = rawSetting("overtimeModeOverrides"),
              let obj = JSONValue.decode(raw) as? [String: Any] else { return [:] }
        var out: [String: Bool] = [:]
        for (k, v) in obj { if let n = v as? NSNumber { out[k] = n.boolValue } }
        return out
    }

    func setOvertimeModeOverrides(_ map: [String: Bool]) {
        setRawSetting("overtimeModeOverrides", JSONValue.encode(map))
    }

    /// Resolve the OT mode for a period start (override beats the global default).
    func otMode(forPeriodStart periodStart: String) -> Bool {
        resolveOtMode(default: overtimeModeDefault, overrides: overtimeModeOverrides(),
                      periodStart: periodStart)
    }

    /// Set the OT mode for one period. When the chosen mode equals the global
    /// default the override is *cleared* (so a later default change still moves
    /// untouched periods) — exactly the PWA's `applyPeriodMode` semantics.
    func setOvertimeMode(forPeriodStart periodStart: String, mode: Bool) {
        var map = overtimeModeOverrides()
        if mode == overtimeModeDefault { map.removeValue(forKey: periodStart) }
        else { map[periodStart] = mode }
        setOvertimeModeOverrides(map)
    }

    // MARK: - Validation deadline (day-of-period index 0..13, or nil)

    func validationDay() -> Int? {
        guard let raw = rawSetting("validationDay"),
              let n = JSONValue.decode(raw) as? NSNumber else { return nil }
        let i = n.intValue
        return (i >= 0 && i < TimeConstants.payPeriodDays) ? i : nil
    }

    func setValidationDay(_ index: Int?) {
        if let i = index, i >= 0, i < TimeConstants.payPeriodDays {
            setRawSetting("validationDay", JSONValue.encode(i))
        } else {
            setRawSetting("validationDay", "null")
        }
    }

    // MARK: - Holidays

    private static let holidayLeaveHours = 8

    /// Active (non-tombstone) recorded holiday for a date → (name, doubleTime).
    func holidayRecord(on date: String) -> (name: String, doubleTime: Bool)? {
        let v = rawHolidays()[date]
        guard let v, (v["removed"] as? NSNumber)?.boolValue != true else { return nil }
        let name = (v["name"] as? String) ?? "Holiday"
        let dt = (v["doubleTime"] as? NSNumber)?.boolValue ?? false
        return (name, dt)
    }

    /// Dates of all active recorded holidays — the set `applyDefaultSchedule`
    /// takes to override holiday days.
    func holidaySet() -> Set<String> {
        var out: Set<String> = []
        for (date, v) in rawHolidays() where (v["removed"] as? NSNumber)?.boolValue != true {
            out.insert(date)
        }
        return out
    }

    /// Record `date` as a holiday (federal name if it is one, else "Holiday").
    /// On a day with no work — or only schedule-seeded (`fromDefault`) work — the
    /// seeded work is removed and 8h holiday leave is ensured. Mirrors `markHoliday`.
    func markHoliday(_ date: String, calendar: Calendar = DomainCalendar.shared) {
        let name = federalHolidayName(date, calendar: calendar) ?? "Holiday"
        var map = rawHolidays()
        map[date] = ["name": name, "doubleTime": false]
        writeHolidays(map)
        clearForHoliday(date)
    }

    /// Un-record a holiday, leaving any entries/leave as-is. Stored as a tombstone
    /// so auto-record won't resurrect it. Mirrors `removeHoliday`.
    func removeHoliday(_ date: String) {
        var map = rawHolidays()
        map[date] = ["removed": true]
        writeHolidays(map)
    }

    /// Toggle the worked-holiday double-time flag for a recorded holiday.
    func setHolidayWorked(_ date: String, on: Bool) {
        var map = rawHolidays()
        guard var v = map[date], (v["removed"] as? NSNumber)?.boolValue != true else { return }
        v["doubleTime"] = on
        map[date] = v
        writeHolidays(map)
    }

    /// Auto-record any unrecorded federal holiday in a [thisYear−1 .. thisYear+2]
    /// window: add it (doubleTime off) and, on an untouched-or-only-fromDefault
    /// day, drop the seeded work + seed 8h leave. Skips tombstones. Returns true
    /// if anything changed. Mirrors `ensureHolidaysSeeded`.
    @discardableResult
    func ensureHolidaysSeeded(now: Date = Date(), calendar: Calendar = DomainCalendar.shared) -> Bool {
        guard autoHolidays else { return false }
        var map = rawHolidays()
        let thisYear = calendar.component(.year, from: now)
        var added: [String] = []
        for y in [thisYear - 1, thisYear, thisYear + 1, thisYear + 2] {
            for h in federalHolidays(y, calendar: calendar) {
                if map[h.date] != nil { continue }   // already recorded or tombstoned
                map[h.date] = ["name": h.name, "doubleTime": false]
                added.append(h.date)
            }
        }
        guard !added.isEmpty else { return false }
        writeHolidays(map)
        // Seed leave / drop fromDefault work only for the freshly-recorded days.
        for date in added { clearForHoliday(date) }
        return true
    }

    /// On an untouched day (no entries) or one carrying only `fromDefault` work,
    /// delete that work and ensure 8h holiday leave. Days the user has actually
    /// worked are left alone (the holiday still pays their hours 1.5×/2×).
    private func clearForHoliday(_ date: String) {
        let dayEntries = entries(on: date)
        let onlyDefault = !dayEntries.isEmpty && dayEntries.allSatisfy { $0.fromDefault }
        guard dayEntries.isEmpty || onlyDefault else { return }
        for e in dayEntries { deleteEntry(id: e.id) }
        if leaveHours(on: date) < Self.holidayLeaveHours {
            setLeave(on: date, hours: Self.holidayLeaveHours)
        }
    }
}
