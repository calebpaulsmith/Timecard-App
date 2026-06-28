import Foundation

/// Where a calendar's events ride relative to the work timeline bar — the three
/// visual tiers the PWA's `buildCalLanes` produces ("me" on the bar, "person"
/// lanes above), extended here with a **task** tier below the bar.
///
///   • `.above` — stacked just above the work bar, overlapping it, so the events
///      read as a separate layer (the PWA's Ritza/Amelia "person" lanes).
///   • `.on`    — overlapping the work bar's own band ("my time" — work +
///      personal events that share the bar).
///   • `.below` — stacked just below the work bar, overlapping but still leaving
///      the timeline visible (tasks).
enum CalendarTier: String, CaseIterable, Sendable, Codable, Equatable {
    case above
    case on
    case below

    var label: String {
        switch self {
        case .above: return "Above the line"
        case .on:    return "On the line"
        case .below: return "Below the line (tasks)"
        }
    }
}

/// Per-calendar configuration for the multi-calendar timeline. One row per device
/// (EventKit) calendar the user has opted into. Persisted as a JSON array in the
/// `calendarConfigs` setting (see `TimecardStore+Calendars`). Pure value type —
/// no SwiftData / SwiftUI — so the layout + resolution logic stays unit-testable.
///
/// This generalizes the old fixed `EventColor` token set (work/personal/ritza/
/// amelia): instead of four hardcoded colors + a two-tier lane, each real
/// calendar carries its own color, tier, and visibility.
struct CalendarConfig: Identifiable, Equatable, Sendable, Codable {
    /// `EKCalendar.calendarIdentifier`.
    var id: String
    var title: String
    /// Source/account title (e.g. "Google", "iCloud") — for grouping in the UI.
    var account: String
    /// User color override (`#RRGGBB`); when nil, `deviceColorHex` is used.
    var colorHex: String?
    /// The calendar's own color from the device (`EKCalendar.cgColor`), captured
    /// when the calendar is registered. The default unless overridden.
    var deviceColorHex: String?
    /// Which tier this calendar's events ride on.
    var tier: CalendarTier
    /// When true, this calendar's events appear on the **timeline** (Period view)
    /// overlay. When false, they only show on the **Calendar** page. Always shown
    /// on the Calendar page regardless.
    var showOnTimeline: Bool
    /// Whether the app reads/writes this calendar at all (include in sync + UI).
    var synced: Bool
    /// The default target for the "Add task" affordance (at most one). Such a
    /// calendar is conventionally `.below`.
    var isTaskDefault: Bool

    init(id: String,
         title: String = "",
         account: String = "",
         colorHex: String? = nil,
         deviceColorHex: String? = nil,
         tier: CalendarTier = .on,
         showOnTimeline: Bool = true,
         synced: Bool = true,
         isTaskDefault: Bool = false) {
        self.id = id
        self.title = title
        self.account = account
        self.colorHex = colorHex
        self.deviceColorHex = deviceColorHex
        self.tier = tier
        self.showOnTimeline = showOnTimeline
        self.synced = synced
        self.isTaskDefault = isTaskDefault
    }

    /// The color to render this calendar's events with — the override if set, else
    /// the device color.
    var effectiveColorHex: String? { colorHex ?? deviceColorHex }
}

/// A heuristic default tier for a newly-registered calendar from its title:
/// calendars that look task-like default to the `.below` task tier; everything
/// else rides on the line. (The user can always change it.)
func defaultTier(forTitle title: String) -> CalendarTier {
    let t = title.lowercased()
    for needle in ["task", "to-do", "todo", "to do", "reminder", "chore"] {
        if t.contains(needle) { return .below }
    }
    return .on
}
