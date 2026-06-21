import Foundation

/// Pure value types for the CSV backup bridge — the migration format shared with
/// the PWA. These carry NO SwiftData/SwiftUI; the codec (`CsvBackup`) operates on
/// them so it stays unit-testable like the Domain layer, and `TimecardStore` maps
/// them to/from the persisted `@Model` types. (`EntryRecord` itself lives in
/// `Domain/` — it's core vocabulary the totals engine consumes.)

/// One leave-hours record (PWA `leave` table; `date` is the key).
struct LeaveRecord: Equatable, Sendable {
    var date: String          // "YYYY-MM-DD"
    var hours: Int            // whole hours, > 0
}

/// A single key/value setting. `value` is the **JSON-encoded** form (exactly the
/// CSV SETTINGS cell content), matching the PWA's `JSON.stringify(value)` — e.g.
/// a string setting is stored quoted (`"2026-05-03"`), a number as `0`, a bool as
/// `true`, an object as `{...}`. Typed getters on `TimecardStore` JSON-decode it.
struct SettingRecord: Equatable, Sendable {
    var key: String
    var value: String
}

/// A complete backup: the four timecard sections of the CSV. Calendar-mode
/// sections (EVENTS / EVENT_HISTORY) are intentionally NOT modeled here — they're
/// excluded from the sellable timecard MVP — but the parser tolerates and skips
/// them so a full PWA backup still imports its timecard data.
struct BackupData: Equatable, Sendable {
    /// Settings EXCLUDING `defaultSchedule` (which travels as its own section)
    /// and the local-only keys. Order is preserved for stable output.
    var settings: [SettingRecord]
    /// The 14 day-of-period default-schedule slots (DEFAULT_SCHEDULE section);
    /// `nil` = never configured.
    var schedule: [ScheduleSlot?]
    var entries: [EntryRecord]
    var leave: [LeaveRecord]

    init(settings: [SettingRecord] = [],
         schedule: [ScheduleSlot?] = Array(repeating: nil, count: TimeConstants.payPeriodDays),
         entries: [EntryRecord] = [],
         leave: [LeaveRecord] = []) {
        self.settings = settings
        self.schedule = schedule
        self.entries = entries
        self.leave = leave
    }
}
