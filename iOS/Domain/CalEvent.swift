import Foundation

/// Calendar-mode event color tokens — the "Me line" work/personal pair plus one
/// color per tracked person. Ports `calendar.js` `COLORS` / `COLOR_ORDER`. The
/// concrete swatch hex lives in the Features layer; Domain only knows the meaning.
enum EventColor: String, CaseIterable, Sendable, Equatable {
    case work, personal, ritza, amelia

    /// Display name (also the ICS `CATEGORIES` value, for round-tripping).
    var label: String {
        switch self {
        case .work: return "Work"
        case .personal: return "Personal"
        case .ritza: return "Ritza"
        case .amelia: return "Amelia"
        }
    }

    /// Which tier the color rides on: `.me` (work/personal, the main bar) or
    /// `.person` (the thin lanes above).
    var lane: EventLane { (self == .work || self == .personal) ? .me : .person }

    /// Resolve an ICS `CATEGORIES` label (case-insensitive) back to a token.
    static func from(label: String) -> EventColor? {
        let l = label.trimmingCharacters(in: .whitespaces).lowercased()
        return EventColor.allCases.first { $0.label.lowercased() == l }
    }
}

enum EventLane: Sendable, Equatable { case me, person }

/// A home-calendar event — Domain vocabulary shared by the store, the recurrence
/// engine, the ICS codec, and the EventKit sync. Mirrors the PWA `events` row
/// (`{ id, date, needsScheduling, title, allDay, startMin, endMin, color, notes,
/// location, rrule, exdates[], seriesId, source, createdAt, updatedAt }`). The
/// PWA's `googleId` becomes `externalId` here (an `EKEvent.eventIdentifier`),
/// with `externalUpdated` carrying the device event's last-modified stamp so a
/// re-pull can skip unchanged rows (the anti-churn guard).
struct CalEvent: Identifiable, Equatable, Sendable {
    var id: String
    /// "YYYY-MM-DD". `nil` = a backlog item (no date yet).
    var date: String?
    var title: String
    var allDay: Bool
    var startMin: Int          // minutes since midnight
    var endMin: Int
    var color: EventColor
    var notes: String
    var location: String
    /// RRULE body (no "RRULE:" prefix), e.g. "FREQ=WEEKLY;INTERVAL=2". A row with
    /// a non-nil `rrule` is a recurring **series** master.
    var rrule: String?
    /// Cancelled occurrence dates ("YYYY-MM-DD") removed from a series.
    var exdates: [String]
    /// An **override** row points at its series master via `seriesId`.
    var seriesId: String?
    /// "local" = your event (synced two-way); other values are read-only mirrors.
    var source: String
    /// The device (EventKit) calendar this event belongs to
    /// (`EKCalendar.calendarIdentifier`), or nil for an in-app/local-only event.
    /// Drives which calendar the event syncs to and — via the per-calendar
    /// `CalendarConfig` — its color and timeline tier (above / on / below the
    /// work bar). Distinct from `externalId`, which links the individual event row.
    var calendarId: String?
    /// Backlog flag (no date; surfaced for scheduling).
    var needsScheduling: Bool
    /// `EKEvent.eventIdentifier` once this row is linked to a device event.
    var externalId: String?
    /// The linked device event's last-modified stamp (skip unchanged re-pulls).
    var externalUpdated: Date?
    var createdAt: Date
    var updatedAt: Date

    // Transient occurrence markers (set by `expandSeries`, never persisted): when
    // this value is a virtual instance of a recurring series, `occurrenceOf` is
    // the master id and `seriesDate` is the master's anchor date.
    var occurrenceOf: String?
    var seriesDate: String?

    init(id: String = UUID().uuidString,
         date: String? = nil,
         title: String = "",
         allDay: Bool = false,
         startMin: Int = 9 * 60,
         endMin: Int = 10 * 60,
         color: EventColor = .personal,
         notes: String = "",
         location: String = "",
         rrule: String? = nil,
         exdates: [String] = [],
         seriesId: String? = nil,
         source: String = "local",
         calendarId: String? = nil,
         needsScheduling: Bool = false,
         externalId: String? = nil,
         externalUpdated: Date? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         occurrenceOf: String? = nil,
         seriesDate: String? = nil) {
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
        self.exdates = exdates
        self.seriesId = seriesId
        self.source = source
        self.calendarId = calendarId
        self.needsScheduling = needsScheduling
        self.externalId = externalId
        self.externalUpdated = externalUpdated
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.occurrenceOf = occurrenceOf
        self.seriesDate = seriesDate
    }

    /// True when this row is a recurring series master.
    var isSeries: Bool { (rrule?.isEmpty == false) }
    /// True when this is a virtual occurrence produced by `expandSeries`.
    var isOccurrence: Bool { occurrenceOf != nil }
    /// Local-origin events sync two-way; mirrors are read-only.
    var isLocal: Bool { source == "local" }
}
