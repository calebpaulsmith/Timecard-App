import SwiftUI

/// The thin, **non-interactive** calendar-event overlay drawn on top of the day's
/// work timeline (`DayTimelineView`) on the Period screen. It's the iOS mirror of
/// the PWA's `buildCalLanes`: events ride a layered vertical stack around the
/// work bar —
///
///   • `.mine`   — the top half of the bar ("my time"), translucent over work,
///   • `.close`  — straddling the top quarter of the bar and rising above it,
///   • `.others` — stacked fully above the bar,
///   • `.tasks`  — just under the bar.
///
/// (Leave rides the bar's bottom half, drawn by `DayTimelineView` itself.) Each
/// overlaps the timeline so you can see *when* things are at a glance.
/// Names aren't shown here — this is the **collapsed** indicator; tapping the day
/// expands it into `DayEventLanesView`, where each event becomes a full-height,
/// titled, tappable, draggable lane. This view never takes touches
/// (`allowsHitTesting(false)`) so it can't interfere with the signature entry-drag
/// gesture underneath.
///
/// It shares `DayTimelineView`'s geometry constants + the same `TimelineScale`, so
/// a bar here lines up horizontally with the work bar below it.
struct DayTimelineEventsOverlay: View {
    let events: [CalEvent]
    let scale: TimelineScale
    /// Resolve an event → its render color (per-calendar config, theme fallback).
    var colorFor: (CalEvent) -> Color
    /// Resolve an event → its tier (above / on / below).
    var tierFor: (CalEvent) -> CalendarTier

    // Mirror DayTimelineView's layout constants so the overlay aligns with the bar.
    private let stripHeight: CGFloat = 64
    private let barTop: CGFloat = 24
    private let barHeight: CGFloat = 12
    private let pipHeight: CGFloat = 4
    private let laneStep: CGFloat = 5

    private var layout: DayEventLayout { layoutDayEvents(events, tierOf: tierFor) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.allDay.enumerated()), id: \.offset) { i, ev in
                    allDayPip(ev, index: i, width: width)
                }
                ForEach(Array(layout.timed.enumerated()), id: \.offset) { _, item in
                    pip(item, width: width)
                }
            }
            .frame(width: width, height: stripHeight)
        }
        .frame(height: stripHeight)
        .allowsHitTesting(false)
    }

    private func leftX(_ m: Int, _ width: CGFloat) -> CGFloat {
        CGFloat(minToPct(Double(m), scale) / 100) * width
    }

    // Vertical anchors within the bar band (bar spans barTop…barTop+barHeight).
    private var barQuarterTop: CGFloat { barTop + barHeight / 4 }   // 1/4 down from the top
    private let closeHeight: CGFloat = 9

    /// Height + center-Y for a tier+lane, laying the bands out around the work bar:
    ///  • `.mine`   — top half of the bar (translucent over work),
    ///  • `.close`  — bottom edge on the bar's top-quarter line, rising above it,
    ///  • `.others` — thin pips fully above the bar, stacking upward,
    ///  • `.tasks`  — thin pips just below the bar, stacking downward.
    private func geometry(_ tier: CalendarTier, lane: Int) -> (height: CGFloat, centerY: CGFloat) {
        switch tier {
        case .mine:
            return (barHeight / 2, barTop + barHeight / 4)
        case .close:
            let bottom = barQuarterTop - CGFloat(lane) * laneStep
            return (closeHeight, bottom - closeHeight / 2)
        case .others:
            return (pipHeight, (barTop - 8) - CGFloat(lane) * laneStep)
        case .tasks:
            return (pipHeight, barTop + barHeight + 3 + CGFloat(lane) * laneStep)
        }
    }

    private func pip(_ item: LaidOutEvent, width: CGFloat) -> some View {
        let x0 = leftX(item.event.startMin, width)
        let x1 = leftX(item.event.endMin, width)
        let w = max(3, x1 - x0)
        let color = colorFor(item.event)
        // "Mine" events ride translucent over the work bar's top half so the bar
        // still reads through; the other tiers are more solid.
        let onBar = item.tier == .mine
        let g = geometry(item.tier, lane: item.lane)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color.opacity(onBar ? 0.55 : 0.9))
            .frame(width: w, height: g.height)
            .position(x: x0 + w / 2, y: g.centerY)
    }

    private func allDayPip(_ ev: CalEvent, index: Int, width: CGFloat) -> some View {
        // All-day events: a short colored chip at the very top, stacked left→right.
        Circle()
            .fill(colorFor(ev))
            .frame(width: 5, height: 5)
            .position(x: 6 + CGFloat(index) * 8, y: 4)
    }
}
