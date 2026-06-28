import Foundation
import SwiftData

/// SwiftData persisted models, mirroring the PWA's Dexie tables
/// (`entries` / `leave` / `settings`). Mapped to/from the pure `EntryRecord` /
/// `LeaveRecord` / `SettingRecord` value types by `TimecardStore`.
///
/// **CloudKit-readiness (deliberate, per `research/RESEARCH-ios-timecard.md`):**
/// every property has a default and there is **no** `@Attribute(.unique)` — both
/// are hard requirements for a future CloudKit (private DB) mirror, and they are
/// "incredibly painful" to retrofit, so they're baked in from Phase 2. Upserts
/// dedupe by `id`/`key`/`date` in the repository instead of a unique constraint.

@Model
final class StoredEntry {
    var id: String = ""
    var date: String = ""              // "YYYY-MM-DD"
    var startTime: Date?
    var endTime: Date?
    var lunchMinutes: Int = 0
    var isOvertime: Bool = false       // legacy; migrated into payKind on read
    var payKind: String = "auto"       // PayKind raw value
    var incomplete: Bool = false
    var fromDefault: Bool = false

    init(id: String = UUID().uuidString, date: String = "",
         startTime: Date? = nil, endTime: Date? = nil,
         lunchMinutes: Int = 0, isOvertime: Bool = false, payKind: String = "auto",
         incomplete: Bool = false, fromDefault: Bool = false) {
        self.id = id
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.lunchMinutes = lunchMinutes
        self.isOvertime = isOvertime
        self.payKind = payKind
        self.incomplete = incomplete
        self.fromDefault = fromDefault
    }
}

@Model
final class StoredLeave {
    var date: String = ""              // "YYYY-MM-DD" (logical key)
    /// Legacy whole-hours field. Kept in sync (rounded) for back-compat readers
    /// (old app versions / CloudKit); `minutes` is the precise source of truth.
    var hours: Int = 0
    /// Precise leave minutes (15-minute granularity). `0` means "not set" — fall
    /// back to `hours * 60` (un-migrated legacy rows). Added as a defaulted
    /// property so SwiftData lightweight-migrates existing stores.
    var minutes: Int = 0
    /// Optional placement on the day (minute-of-day the leave block starts at).
    /// `-1` = unset → auto-place after the last worked entry (Phase 2). Defaulted
    /// for lightweight migration.
    var startMin: Int = -1

    init(date: String = "", hours: Int = 0, minutes: Int = 0, startMin: Int = -1) {
        self.date = date
        self.hours = hours
        self.minutes = minutes
        self.startMin = startMin
    }

    /// Effective leave minutes: the precise field, falling back to legacy hours.
    var effectiveMinutes: Int { minutes != 0 ? minutes : hours * 60 }
    /// Effective placement, or nil when unset (auto-place).
    var effectiveStart: Int? { startMin >= 0 ? startMin : nil }
}

@Model
final class StoredSetting {
    var key: String = ""
    /// JSON-encoded value (same form as the CSV SETTINGS cell): a string is
    /// quoted, a number/bool bare, an object `{...}`. See `SettingRecord`.
    var value: String = ""

    init(key: String = "", value: String = "") {
        self.key = key
        self.value = value
    }
}

/// A calendar-mode event (Phase 5). Mirrors the PWA `events` Dexie row, mapped
/// to/from the pure `CalEvent` value type by `TimecardStore`. CloudKit-shaped
/// like the rest (every prop defaulted, no `.unique`). `exdatesJoined` stores the
/// EXDATE list as a comma-separated "YYYY-MM-DD,…" string (kept scalar for a
/// clean CloudKit mirror). `externalId` links to an `EKEvent.eventIdentifier`.
@Model
final class StoredEvent {
    var id: String = ""
    var date: String?               // "YYYY-MM-DD"; nil = backlog
    var title: String = ""
    var allDay: Bool = false
    var startMin: Int = 540         // 9:00
    var endMin: Int = 600           // 10:00
    var color: String = "personal"
    var notes: String = ""
    var location: String = ""
    var rrule: String?              // RRULE body; non-nil = series master
    var exdatesJoined: String = ""  // "YYYY-MM-DD,YYYY-MM-DD"
    var seriesId: String?
    var source: String = "local"
    /// `EKCalendar.calendarIdentifier` of the owning device calendar (nil = local).
    var calendarId: String?
    var needsScheduling: Bool = false
    var externalId: String?
    var externalUpdated: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(id: String = UUID().uuidString, date: String? = nil, title: String = "",
         allDay: Bool = false, startMin: Int = 540, endMin: Int = 600,
         color: String = "personal", notes: String = "", location: String = "",
         rrule: String? = nil, exdatesJoined: String = "", seriesId: String? = nil,
         source: String = "local", calendarId: String? = nil, needsScheduling: Bool = false,
         externalId: String? = nil, externalUpdated: Date? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.date = date
        self.title = title
        self.allDay = allDay
        self.startMin = startMin
        self.endMin = endMin
        self.color = color
        self.notes = notes
        self.location = location
        self.rrule = rrule
        self.exdatesJoined = exdatesJoined
        self.seriesId = seriesId
        self.source = source
        self.calendarId = calendarId
        self.needsScheduling = needsScheduling
        self.externalId = externalId
        self.externalUpdated = externalUpdated
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum TimecardSchema {
    /// All persisted model types — pass to `ModelContainer` / `ModelConfiguration`.
    static let models: [any PersistentModel.Type] = [
        StoredEntry.self, StoredLeave.self, StoredSetting.self, StoredEvent.self,
    ]
}
