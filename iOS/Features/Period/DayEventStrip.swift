import SwiftUI

/// The read-only events mini-timeline shown inside `DayActionsPanel` when a day
/// is expanded in calendar mode. **Read + tap-to-edit** (no drag). Timed events
/// are grouped into the calendar bands (Others / Close / Mine / Tasks) and each
/// tier renders as a lane-packed mini-timeline (positions via the pure
/// `stackEvents` / `layoutDayEvents`); all-day events render as chips. This is
/// where the names show once a day is tapped open.
///
/// Deliberately a **sibling** of `DayTimelineView` — it never shares the work
/// bar's gesture/coordinate space, so there's no collision with the entry dragger.
struct DayEventStrip: View {
    @Environment(\.palette) private var palette
    let date: String
    let events: [CalEvent]
    var colorFor: (CalEvent) -> Color = { _ in .accentColor }
    var tierFor: (CalEvent) -> CalendarTier = { _ in .on }
    var onTapEvent: (CalEvent) -> Void

    /// Linear day window used to position timed events horizontally. Events
    /// outside it are clamped to the edges so they still read.
    private let windowStart = 6 * 60       // 06:00
    private let windowEnd = 22 * 60        // 22:00
    private let laneHeight: CGFloat = 22
    private let laneGap: CGFloat = 3
    private let minBlockWidth: CGFloat = 22

    private var layout: DayEventLayout { layoutDayEvents(events, tierOf: tierFor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(layout.allDay) { ev in allDayChip(ev) }

            // Tier order top→bottom: others, close, mine, tasks — mirrors the overlay.
            ForEach([CalendarTier.others, .close, .mine, .tasks], id: \.self) { tier in
                let items = layout.timed.filter { $0.tier == tier }
                if !items.isEmpty {
                    tierLabel(tier)
                    tierLanes(items, lanes: layout.laneCount(tier))
                }
            }
        }
    }

    // MARK: - Timed events (per-tier lane-packed mini-timeline)

    private func tierLabel(_ tier: CalendarTier) -> some View {
        Text(tier.label.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
    }

    private func tierLanes(_ items: [LaidOutEvent], lanes: Int) -> some View {
        let count = max(1, lanes)
        let height = CGFloat(count) * laneHeight + CGFloat(count - 1) * laneGap
        return GeometryReader { geo in
            let width = geo.size.width
            ForEach(items, id: \.event.id) { item in
                let span = blockFrame(for: item.event, width: width)
                eventBlock(item.event)
                    .frame(width: span.width, height: laneHeight)
                    .position(x: span.midX,
                              y: CGFloat(item.lane) * (laneHeight + laneGap) + laneHeight / 2)
            }
        }
        .frame(height: height)
    }

    /// Map an event's start/end minutes to an x-span within `width` (clamped to
    /// the day window, floored to a tappable minimum width).
    private func blockFrame(for ev: CalEvent, width: CGFloat) -> (midX: CGFloat, width: CGFloat) {
        let total = CGFloat(windowEnd - windowStart)
        func x(_ min: Int) -> CGFloat {
            CGFloat(Swift.min(Swift.max(min, windowStart), windowEnd) - windowStart) / total * width
        }
        let x0 = x(ev.startMin)
        let x1 = Swift.max(x(ev.endMin), x0 + minBlockWidth)
        return ((x0 + x1) / 2, x1 - x0)
    }

    private func eventBlock(_ ev: CalEvent) -> some View {
        HStack(spacing: 3) {
            Text(ev.title.isEmpty ? "(untitled)" : ev.title)
                .lineLimit(1)
            if ev.isOccurrence || ev.isSeries {
                Image(systemName: "repeat")
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: laneHeight)
        .background(colorFor(ev).opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { onTapEvent(ev) }
    }

    // MARK: - All-day events

    private func allDayChip(_ ev: CalEvent) -> some View {
        HStack(spacing: 6) {
            Circle().fill(colorFor(ev)).frame(width: 7, height: 7)
            Text(ev.title.isEmpty ? "(untitled)" : ev.title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            if ev.isOccurrence || ev.isSeries {
                Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("All-day").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colorFor(ev).opacity(0.12), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { onTapEvent(ev) }
    }
}
