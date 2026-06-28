import SwiftUI

/// The thin, **non-interactive** calendar-event overlay drawn on top of the day's
/// work timeline (`DayTimelineView`) on the Period screen. It's the iOS mirror of
/// the PWA's `buildCalLanes`: events ride three tiers relative to the work bar —
///
///   • `.above` — stacked just above the bar (partner / other calendars),
///   • `.on`    — over the bar's own band ("my time": work + personal),
///   • `.below` — just under the bar (tasks),
///
/// each overlapping the timeline so you can see *when* things are at a glance.
/// Names aren't shown here — tapping the day expands the `DayActionsPanel`, whose
/// `DayEventStrip` lists the events by tier with titles. This view never takes
/// touches (`allowsHitTesting(false)`) so it can't interfere with the signature
/// entry-drag gesture underneath.
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

    private var barMidY: CGFloat { barTop + barHeight / 2 }

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

    /// Center-Y for a tier+lane: above-tier stacks upward, below-tier downward,
    /// on-tier rides the bar band.
    private func centerY(_ tier: CalendarTier, lane: Int) -> CGFloat {
        switch tier {
        case .above: return barTop - 3 - CGFloat(lane) * laneStep
        case .on:    return barMidY
        case .below: return barTop + barHeight + 3 + CGFloat(lane) * laneStep
        }
    }

    private func pip(_ item: LaidOutEvent, width: CGFloat) -> some View {
        let x0 = leftX(item.event.startMin, width)
        let x1 = leftX(item.event.endMin, width)
        let w = max(3, x1 - x0)
        let color = colorFor(item.event)
        // "On the line" events ride translucent over the work bar so the bar still
        // reads through; the above/below tiers are solid thin pips.
        let onBar = item.tier == .on
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color.opacity(onBar ? 0.55 : 0.9))
            .frame(width: w, height: onBar ? barHeight - 2 : pipHeight)
            .position(x: x0 + w / 2, y: centerY(item.tier, lane: item.lane))
    }

    private func allDayPip(_ ev: CalEvent, index: Int, width: CGFloat) -> some View {
        // All-day events: a short colored chip at the very top, stacked left→right.
        Circle()
            .fill(colorFor(ev))
            .frame(width: 5, height: 5)
            .position(x: 6 + CGFloat(index) * 8, y: 4)
    }
}
