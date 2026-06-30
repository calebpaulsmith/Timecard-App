import Foundation

/// Where a calendar's events ride relative to the work timeline bar — a layered
/// vertical stack (bottom → top) so several kinds of time read at a glance on one
/// strip. Work fills the bar and leave rides its bottom half (both timecard data,
/// not calendar tiers); these four tiers place a *calendar's* events around them:
///
///   • `.mine`   — the **top half** of the work bar ("my time": your own personal
///      calendars), translucent so the work bar still reads beneath.
///   • `.close`  — straddles the **top quarter** of the bar and rises **above** it
///      (a near person whose time overlaps yours — e.g. a partner/child).
///   • `.others` — stacked **fully above** the bar (people/calendars you track but
///      whose time is separate).
///   • `.tasks`  — stacked **below** the bar (tasks / to-dos).
///
/// Ordered top→bottom for the Settings picker. Legacy stored values from the
/// earlier three-tier model (`above`/`on`/`below`) decode via `init(stored:)`.
enum CalendarTier: String, CaseIterable, Sendable, Codable, Equatable {
    case others
    case close
    case mine
    case tasks

    var label: String {
        switch self {
        case .others: return "Others (above the bar)"
        case .close:  return "Close (top of bar + above)"
        case .mine:   return "Mine (top half of bar)"
        case .tasks:  return "Tasks (below the bar)"
        }
    }

    /// Decode a stored raw value, accepting the legacy three-tier names used
    /// before the band model was expanded: `on`→`.mine`, `above`→`.others`,
    /// `below`→`.tasks`.
    init(stored raw: String) {
        switch raw {
        case "mine", "on":      self = .mine
        case "close":           self = .close
        case "others", "above": self = .others
        case "tasks", "below":  self = .tasks
        default:                self = .mine
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
         tier: CalendarTier = .mine,
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
/// calendars that look task-like default to the `.tasks` tier (below the bar);
/// everything else rides as "mine" on the top half of the bar. (The user can
/// always change it in Settings › Calendars.)
func defaultTier(forTitle title: String) -> CalendarTier {
    let t = title.lowercased()
    for needle in ["task", "to-do", "todo", "to do", "reminder", "chore"] {
        if t.contains(needle) { return .tasks }
    }
    return .mine
}
