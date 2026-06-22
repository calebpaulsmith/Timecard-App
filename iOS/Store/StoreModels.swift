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
    var isOvertime: Bool = false
    var incomplete: Bool = false
    var fromDefault: Bool = false

    init(id: String = UUID().uuidString, date: String = "",
         startTime: Date? = nil, endTime: Date? = nil,
         lunchMinutes: Int = 0, isOvertime: Bool = false,
         incomplete: Bool = false, fromDefault: Bool = false) {
        self.id = id
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.lunchMinutes = lunchMinutes
        self.isOvertime = isOvertime
        self.incomplete = incomplete
        self.fromDefault = fromDefault
    }
}

@Model
final class StoredLeave {
    var date: String = ""              // "YYYY-MM-DD" (logical key)
    var hours: Int = 0

    init(date: String = "", hours: Int = 0) {
        self.date = date
        self.hours = hours
    }
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
    var needsScheduling: Bool = false
    var externalId: String?
    var externalUpdated: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(id: String = UUID().uuidString, date: String? = nil, title: String = "",
         allDay: Bool = false, startMin: Int = 540, endMin: Int = 600,
         color: String = "personal", notes: String = "", location: String = "",
         rrule: String? = nil, exdatesJoined: String = "", seriesId: String? = nil,
         source: String = "local", needsScheduling: Bool = false,
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
