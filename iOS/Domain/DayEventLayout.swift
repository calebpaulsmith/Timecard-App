import Foundation

/// One event placed into a tier + lane for rendering on a day's timeline overlay.
struct LaidOutEvent: Equatable {
    var event: CalEvent
    var tier: CalendarTier
    /// Lane index within the tier (0 = closest to the bar). For the `.mine` tier
    /// all events share lane 0 (they overlap on the bar, "my time"); the `.close` /
    /// `.others` / `.tasks` tiers stack non-overlapping lanes via `stackEvents`.
    var lane: Int
}

/// The laid-out events for a single day, split into the timed tiers (above / on /
/// below) and the all-day band. Pure result of `layoutDayEvents` — no SwiftUI.
struct DayEventLayout: Equatable {
    var timed: [LaidOutEvent]
    var allDay: [CalEvent]
    /// Number of lanes used per tier (drives the overlay's vertical sizing).
    var laneCount: [CalendarTier: Int]

    func laneCount(_ tier: CalendarTier) -> Int { laneCount[tier] ?? 0 }
}

/// Lay out a day's events into the three timeline tiers, mirroring the PWA's
/// `buildCalLanes`: all-day events go to a separate band; timed events are grouped
/// by their calendar's tier. The `.mine` tier ("my time") all ride lane 0 and
/// overlap on the work bar's top half; the `.close` / `.others` / `.tasks` tiers
/// each lane-pack with the pure `stackEvents` so concurrent events don't collide.
///
/// `tierOf` resolves an event → its tier (from the per-calendar `CalendarConfig`,
/// with a fallback for legacy color-token events). Kept as a closure so this stays
/// Domain-pure and testable without the store.
func layoutDayEvents(_ events: [CalEvent], tierOf: (CalEvent) -> CalendarTier) -> DayEventLayout {
    var allDay: [CalEvent] = []
    var timedByTier: [CalendarTier: [CalEvent]] = [:]
    for ev in events {
        if ev.allDay || ev.endMin <= ev.startMin {
            allDay.append(ev)
        } else {
            timedByTier[tierOf(ev), default: []].append(ev)
        }
    }

    var out: [LaidOutEvent] = []
    var laneCount: [CalendarTier: Int] = [:]
    for tier in CalendarTier.allCases {
        let group = timedByTier[tier] ?? []
        guard !group.isEmpty else { continue }
        if tier == .mine {
            // "My time" — all events overlap on the bar's top half (lane 0).
            for ev in group { out.append(LaidOutEvent(event: ev, tier: tier, lane: 0)) }
            laneCount[tier] = 1
        } else {
            let packing = stackEvents(group)
            for ev in group {
                out.append(LaidOutEvent(event: ev, tier: tier, lane: packing.laneOf[ev.id] ?? 0))
            }
            laneCount[tier] = max(1, packing.laneCount)
        }
    }
    return DayEventLayout(timed: out, allDay: allDay, laneCount: laneCount)
}
