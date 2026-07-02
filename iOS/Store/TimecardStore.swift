import Foundation
import SwiftData

/// Repository over a SwiftData `ModelContext`, mirroring the PWA's `DB.*` helpers.
/// Maps persisted `@Model` rows ↔ pure `BackupData` value types and drives the
/// CSV migration bridge. `@MainActor` because it touches the (main-actor)
/// `ModelContext`; the pure codec it calls is concurrency-free.
@MainActor
final class TimecardStore {
    let context: ModelContext

    init(context: ModelContext) { self.context = context }

    /// Keys never written to a CSV backup (and preserved across an import wipe):
    /// connection secrets that would be meaningless/insecure in an exported file.
    static let localOnlySettings: Set<String> = [
        "googleClientId", "googleToken", "apiKey",
        // Device-specific calendar-sync state — meaningless on another device.
        "eventKitCalendarId", "eventKitLastSync", "eventKitSyncEnabled",
        // Optional work-schedule sync: config + per-calendar reconciliation map.
        "scheduleSyncEnabled", "scheduleSyncCalendarId", "scheduleSyncPeriodsAhead", "scheduleSyncMap",
        // Multi-calendar registry: per-device-calendar color/tier/visibility.
        "calendarConfigs",
    ]

    /// Setting keys emitted (in this order) at the top of the SETTINGS section,
    /// matching the PWA for a human-readable, diff-stable file.
    private static let knownSettings = [
        "anchorDate", "overtimeModeDefault", "overtimeModeOverrides",
        "overtime8hMode", "hourlyRate", "use24h", "autoHolidays", "holidays",
    ]

    // MARK: - Container factory

    /// Build a container for the app or tests. `inMemory` → an ephemeral store
    /// (tests). The production store stays on the local default location for now;
    /// the App Group container (`group.com.thegrandpipeline.timecard`) + CloudKit mirror
    /// land with widgets (Phase 7), which is why the models are already
    /// CloudKit-shaped (defaulted props, no unique constraints).
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: StoredEntry.self, StoredLeave.self, StoredSetting.self,
                                  StoredEvent.self, configurations: config)
    }

    /// Process-wide container shared by the app scene and the Clock App Intents
    /// (which run in the app's process), so both read/write a single store.
    static let sharedContainer: ModelContainer = {
        do { return try makeContainer() }
        catch { fatalError("Failed to create the shared ModelContainer: \(error)") }
    }()

    // MARK: - Entries

    func allEntries() -> [EntryRecord] {
        let rows = (try? context.fetch(FetchDescriptor<StoredEntry>())) ?? []
        return rows.map(Self.toRecord).sorted { $0.date < $1.date }
    }

    func entries(on date: String) -> [EntryRecord] {
        var d = FetchDescriptor<StoredEntry>(predicate: #Predicate { $0.date == date })
        d.sortBy = [SortDescriptor(\.startTime)]
        return ((try? context.fetch(d)) ?? []).map(Self.toRecord)
    }

    // MARK: - Clock in / out (shared by the Day editor + the Clock App Intents)

    /// Outcome of a clock action — drives the App Intent's spoken/written dialog.
    enum ClockOutcome: Equatable {
        case clockedIn(Date)
        case clockedOut
        case alreadyClockedIn(Date)
        case notClockedIn
    }

    /// Today's open (running) entry, using the same >16h forgotten-clock-out scan
    /// as the Day editor. `nil` when not clocked in.
    func openEntryToday(now: Date = Date(), calendar: Calendar = DomainCalendar.shared) -> EntryRecord? {
        let today = formatLocalDate(now, calendar: calendar)
        let dayEntries = entries(on: today)
        guard let id = scanOpenEntry(dayEntries, now: now).openId else { return nil }
        return dayEntries.first(where: { $0.id == id })
    }

    func isClockedInToday(now: Date = Date(), calendar: Calendar = DomainCalendar.shared) -> Bool {
        openEntryToday(now: now, calendar: calendar) != nil
    }

    /// Start a new entry at the current rounded quarter-hour, unless already
    /// running (no-op then).
    @discardableResult
    func clockIn(now: Date = Date(), calendar: Calendar = DomainCalendar.shared) -> ClockOutcome {
        if let open = openEntryToday(now: now, calendar: calendar), let start = open.startTime {
            return .alreadyClockedIn(start)
        }
        let today = formatLocalDate(now, calendar: calendar)
        let start = roundToQuarter(now, calendar: calendar)
        upsert(EntryRecord(date: today, startTime: start, endTime: nil))
        return .clockedIn(start)
    }

    /// Close the running entry at the current rounded quarter-hour (auto-lunch
    /// applied), unless not clocked in (no-op then). Same rules as the Day editor.
    @discardableResult
    func clockOut(now: Date = Date(), calendar: Calendar = DomainCalendar.shared) -> ClockOutcome {
        guard var e = openEntryToday(now: now, calendar: calendar), let start = e.startTime else {
            return .notClockedIn
        }
        var end = roundToQuarter(now, calendar: calendar)
        if end <= start { end = start }   // same-quarter in/out → 0 hours
        e.endTime = end
        e.lunchMinutes = autoLunchMinutes(start: start, end: end)
        upsert(e)
        return .clockedOut
    }

    /// Clock out if running, otherwise clock in — the Control / toggle action.
    @discardableResult
    func toggleClock(now: Date = Date(), calendar: Calendar = DomainCalendar.shared) -> ClockOutcome {
        isClockedInToday(now: now, calendar: calendar)
            ? clockOut(now: now, calendar: calendar)
            : clockIn(now: now, calendar: calendar)
    }

    @discardableResult
    func upsert(_ entry: EntryRecord) -> EntryRecord {
        let id = entry.id
        let existing = fetchEntry(id: id)
        let model = existing ?? StoredEntry(id: id)
        model.date = entry.date
        model.startTime = entry.startTime
        model.endTime = entry.endTime
        model.lunchMinutes = entry.lunchMinutes
        model.payKind = entry.payKind.rawValue
        model.isOvertime = entry.payKind == .overtime   // keep legacy column in sync
        model.incomplete = entry.incomplete
        model.fromDefault = entry.fromDefault
        if existing == nil { context.insert(model) }
        try? context.save()
        return entry
    }

    func deleteEntry(id: String) {
        if let m = fetchEntry(id: id) { context.delete(m); try? context.save() }
    }

    private func fetchEntry(id: String) -> StoredEntry? {
        var d = FetchDescriptor<StoredEntry>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: - Leave

    /// Precise effective leave minutes for a date (15-min granularity).
    func leaveMinutes(on date: String) -> Int { fetchLeave(date: date)?.effectiveMinutes ?? 0 }

    /// Whole-hour view (rounded) — kept for the whole-hour callers (holiday seed,
    /// schedule apply). The fractional path uses `leaveMinutes`.
    func leaveHours(on date: String) -> Int { Int((Double(leaveMinutes(on: date)) / 60).rounded()) }

    func allLeave() -> [LeaveRecord] {
        let rows = (try? context.fetch(FetchDescriptor<StoredLeave>())) ?? []
        return rows.map { LeaveRecord(date: $0.date, minutes: $0.effectiveMinutes, startMin: $0.effectiveStart) }
            .sorted { $0.date < $1.date }
    }

    /// Optional placement of the day's leave block (minute-of-day), or nil = auto.
    func leaveStart(on date: String) -> Int? { fetchLeave(date: date)?.effectiveStart }

    /// Whole-hour convenience (back-compat) — routes through the minutes setter.
    func setLeave(on date: String, hours: Int) { setLeave(on: date, minutes: max(0, hours) * 60) }

    /// Set leave minutes for a date. `minutes <= 0` removes the row (matches the
    /// PWA's delete-on-zero). Keeps the legacy `hours` field in sync (rounded) and
    /// PRESERVES any existing placement (changing the amount shouldn't move it).
    func setLeave(on date: String, minutes: Int) {
        let m = max(0, minutes)
        let h = Int((Double(m) / 60).rounded())
        if let existing = fetchLeave(date: date) {
            if m == 0 { context.delete(existing) } else { existing.minutes = m; existing.hours = h }
        } else if m > 0 {
            context.insert(StoredLeave(date: date, hours: h, minutes: m))
        }
        try? context.save()
    }

    /// Place (or clear, with nil) the day's leave block. No-op if there's no leave.
    func setLeaveStart(on date: String, startMin: Int?) {
        guard let existing = fetchLeave(date: date) else { return }
        existing.startMin = startMin ?? -1
        try? context.save()
    }

    /// Place the day's leave block AND reshape the workday around it (the leave
    /// drag-to-place commit, LOGIC-FREEZE §3): entries under the block are
    /// split/trimmed via `leavePlacementPlan`, healing a previous split at the
    /// old placement first so the "hole" follows the block across drags.
    func placeLeave(on date: String, startMin: Int, calendar: Calendar = DomainCalendar.shared) {
        let minutes = leaveMinutes(on: date)
        guard minutes > 0 else { return }
        let plan = leavePlacementPlan(entries: entries(on: date), date: date,
                                      leaveMinutes: minutes, newStartMin: startMin,
                                      oldStartMin: leaveStart(on: date), calendar: calendar)
        for id in plan.deleteIds { deleteEntry(id: id) }
        for e in plan.upserts { upsert(e) }
        setLeaveStart(on: date, startMin: startMin)
    }

    private func fetchLeave(date: String) -> StoredLeave? {
        var d = FetchDescriptor<StoredLeave>(predicate: #Predicate { $0.date == date })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: - Settings (raw + typed)

    func rawSetting(_ key: String) -> String? { fetchSetting(key)?.value }

    func setRawSetting(_ key: String, _ value: String) {
        if let existing = fetchSetting(key) { existing.value = value }
        else { context.insert(StoredSetting(key: key, value: value)) }
        try? context.save()
    }

    private func fetchSetting(_ key: String) -> StoredSetting? {
        var d = FetchDescriptor<StoredSetting>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // Typed accessors — decode the JSON-encoded value (PWA-compatible).
    func stringSetting(_ key: String) -> String? {
        guard let raw = rawSetting(key) else { return nil }
        if let v = JSONValue.decode(raw) as? String { return v }
        return raw                                   // lenient fallback (PWA parity)
    }

    func doubleSetting(_ key: String, default def: Double = 0) -> Double {
        guard let raw = rawSetting(key), let n = JSONValue.decode(raw) as? NSNumber else { return def }
        return n.doubleValue
    }

    func boolSetting(_ key: String, default def: Bool = false) -> Bool {
        guard let raw = rawSetting(key), let n = JSONValue.decode(raw) as? NSNumber else { return def }
        return n.boolValue
    }

    func setStringSetting(_ key: String, _ value: String) { setRawSetting(key, JSONValue.encode(value)) }
    func setDoubleSetting(_ key: String, _ value: Double) { setRawSetting(key, JSONValue.encode(value)) }
    func setBoolSetting(_ key: String, _ value: Bool) { setRawSetting(key, JSONValue.encode(value)) }

    // Convenience for the common timecard settings.
    var anchorDate: String? { stringSetting("anchorDate") }
    var hourlyRate: Double { doubleSetting("hourlyRate", default: 0) }
    var overtimeModeDefault: Bool { boolSetting("overtimeModeDefault", default: true) }
    var use24h: Bool { boolSetting("use24h", default: false) }
    var autoHolidays: Bool { boolSetting("autoHolidays", default: true) }
    /// Master switch for the whole credit-hours feature. Default OFF: all extra
    /// hours pay overtime and every credit surface is hidden. Mirrors the PWA's
    /// `creditHoursEnabled`. Stored so it round-trips via the CSV SETTINGS section.
    var creditHoursEnabled: Bool {
        get { boolSetting("creditHoursEnabled", default: false) }
        set { setBoolSetting("creditHoursEnabled", newValue) }
    }
    /// Local reminders (Phase 7). Default OFF until the user opts in (which also
    /// triggers the system notification-authorization prompt). Stored so it
    /// round-trips via the CSV SETTINGS section.
    var remindersEnabled: Bool {
        get { boolSetting("remindersEnabled", default: false) }
        set { setBoolSetting("remindersEnabled", newValue) }
    }

    /// When on, leave adjusts in **15-minute** steps instead of whole hours.
    /// Default off (whole-hour). Round-trips via the CSV SETTINGS section.
    var leaveGranularMinutes: Bool {
        get { boolSetting("leaveGranularMinutes", default: false) }
        set { setBoolSetting("leaveGranularMinutes", newValue) }
    }

    /// Recorded federal holidays, decoded from the `holidays` setting
    /// (`{ "YYYY-MM-DD": { name, doubleTime } }`) into the domain's pay shape.
    /// Tombstones (`{ removed: true }` — an un-recorded holiday auto-record must
    /// not resurrect) are skipped, matching the PWA's `holidayInfoFor`.
    func holidays() -> [String: HolidayInfo] {
        var out: [String: HolidayInfo] = [:]
        for (date, v) in rawHolidays() {
            if (v["removed"] as? NSNumber)?.boolValue == true { continue }
            out[date] = HolidayInfo(doubleTime: (v["doubleTime"] as? NSNumber)?.boolValue ?? false)
        }
        return out
    }

    /// The raw `holidays` map: `{ "YYYY-MM-DD": { name, doubleTime } | { removed } }`.
    func rawHolidays() -> [String: [String: Any]] {
        guard let raw = rawSetting("holidays"), let obj = JSONValue.decode(raw) as? [String: Any] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for (date, v) in obj { out[date] = (v as? [String: Any]) ?? [:] }
        return out
    }

    func writeHolidays(_ map: [String: [String: Any]]) {
        setRawSetting("holidays", JSONValue.encode(map))
    }

    /// The 14-slot default schedule (stored as the `defaultSchedule` setting JSON,
    /// the same as the PWA). Missing/short → padded with `nil` slots.
    func defaultSchedule() -> [ScheduleSlot?] {
        guard let raw = rawSetting("defaultSchedule"),
              let arr = JSONValue.decode(raw) as? [Any] else {
            return Array(repeating: nil, count: TimeConstants.payPeriodDays)
        }
        return ScheduleCodec.fromJSONArray(arr)
    }

    func setDefaultSchedule(_ schedule: [ScheduleSlot?]) {
        setRawSetting("defaultSchedule", JSONValue.encode(ScheduleCodec.toJSONArray(schedule)))
    }

    /// Seed work entries + recurring leave from the default schedule into
    /// `periodCount` pay periods starting at `startPeriodStart`. Ports the PWA's
    /// `applyDefaultSchedule` (overwrite semantics):
    /// - a **holiday** date drops its `fromDefault` entries and ensures 8h leave;
    /// - an **enabled** slot replaces ALL existing entries on that date with one
    ///   `fromDefault` work entry at the slot's start/end;
    /// - `leaveHours > 0` seeds that day's leave (independent of the work toggle).
    /// Returns counts for a status message. This is the "apply" the schedule
    /// editor's button triggers — editing alone only saves the definition.
    @discardableResult
    func applyDefaultSchedule(startPeriodStart: Date, anchor: String, periodCount: Int = 26,
                              holidays: Set<String> = [],
                              calendar: Calendar = DomainCalendar.shared) -> (written: Int, leaveDays: Int) {
        let schedule = defaultSchedule()
        let holidayLeave = 8
        var written = 0, leaveDays = 0
        var cursor = startPeriodStart
        for _ in 0..<max(0, periodCount) {
            let period = payPeriodFor(today: cursor, anchor: anchor, calendar: calendar)
            for (i, d) in period.days.enumerated() {
                if holidays.contains(d) {
                    for e in entries(on: d) where e.fromDefault { deleteEntry(id: e.id) }
                    if leaveHours(on: d) < holidayLeave { setLeave(on: d, hours: holidayLeave); leaveDays += 1 }
                    continue
                }
                guard i < schedule.count, let slot = schedule[i] else { continue }
                let lv = max(0, slot.leaveHours)
                if lv > 0 { setLeave(on: d, hours: lv); leaveDays += 1 }
                guard slot.enabled, let sm = slot.startMin, let em = slot.endMin else { continue }
                for e in entries(on: d) { deleteEntry(id: e.id) }   // overwrite
                let start = buildDateTime(d, hour24: sm / 60, minute: sm % 60, calendar: calendar)
                let end = buildDateTime(d, hour24: em / 60, minute: em % 60, calendar: calendar)
                if end > start {
                    upsert(EntryRecord(date: d, startTime: start, endTime: end,
                                       lunchMinutes: autoLunchMinutes(start: start, end: end),
                                       payKind: .auto, incomplete: false, fromDefault: true))
                    written += 1
                }
            }
            cursor = addDays(cursor, TimeConstants.payPeriodDays, calendar: calendar)
        }
        return (written, leaveDays)
    }

    // MARK: - Backup bridge

    /// Snapshot the whole store as a `BackupData` (excludes local-only +
    /// `defaultSchedule` from the flat settings; schedule travels in its section).
    func exportBackup() -> BackupData {
        let map = settingsMap()
        var settings: [SettingRecord] = []
        var emitted = Set<String>()
        func emit(_ key: String) {
            guard let v = map[key], !emitted.contains(key) else { return }
            settings.append(SettingRecord(key: key, value: v)); emitted.insert(key)
        }
        for k in Self.knownSettings where !Self.localOnlySettings.contains(k) { emit(k) }
        for k in map.keys.sorted() {
            if Self.knownSettings.contains(k) || Self.localOnlySettings.contains(k) || k == "defaultSchedule" { continue }
            emit(k)
        }
        return BackupData(settings: settings,
                          schedule: defaultSchedule(),
                          entries: allEntries(),
                          leave: allLeave())
    }

    /// Replace ALL data with `data` (the PWA's wipe-and-restore semantics),
    /// preserving local-only settings across the wipe.
    func importBackup(_ data: BackupData) {
        let preserved = settingsMap().filter { Self.localOnlySettings.contains($0.key) }

        try? context.delete(model: StoredEntry.self)
        try? context.delete(model: StoredLeave.self)
        try? context.delete(model: StoredSetting.self)

        for s in data.settings where !Self.localOnlySettings.contains(s.key) && s.key != "defaultSchedule" {
            context.insert(StoredSetting(key: s.key, value: s.value))
        }
        context.insert(StoredSetting(key: "defaultSchedule",
                                     value: JSONValue.encode(ScheduleCodec.toJSONArray(data.schedule))))
        for e in data.entries {
            context.insert(StoredEntry(id: e.id, date: e.date, startTime: e.startTime, endTime: e.endTime,
                                       lunchMinutes: e.lunchMinutes,
                                       isOvertime: e.payKind == .overtime, payKind: e.payKind.rawValue,
                                       incomplete: e.incomplete, fromDefault: e.fromDefault))
        }
        for l in data.leave where l.minutes > 0 {
            context.insert(StoredLeave(date: l.date,
                                       hours: Int((Double(l.minutes) / 60).rounded()),
                                       minutes: l.minutes, startMin: l.startMin ?? -1))
        }
        for (k, v) in preserved { context.insert(StoredSetting(key: k, value: v)) }
        try? context.save()
    }

    func exportCsv(generatedAt: Date = Date()) -> String {
        CsvBackup.export(exportBackup(), generatedAt: generatedAt)
    }

    func importCsv(_ text: String) {
        importBackup(CsvBackup.parse(text))
    }

    // MARK: - Helpers

    private func settingsMap() -> [String: String] {
        let rows = (try? context.fetch(FetchDescriptor<StoredSetting>())) ?? []
        var m: [String: String] = [:]
        for r in rows { m[r.key] = r.value }
        return m
    }

    private static func toRecord(_ e: StoredEntry) -> EntryRecord {
        // Migrate legacy rows: a row written before payKind existed keeps
        // payKind == "auto" but may carry isOvertime == true → treat as forced OT.
        let kind = PayKind(rawValue: e.payKind) ?? .auto
        let resolved = (kind == .auto && e.isOvertime) ? .overtime : kind
        return EntryRecord(id: e.id, date: e.date, startTime: e.startTime, endTime: e.endTime,
                           lunchMinutes: e.lunchMinutes, payKind: resolved,
                           incomplete: e.incomplete, fromDefault: e.fromDefault)
    }
}
