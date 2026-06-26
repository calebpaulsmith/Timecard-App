import SwiftUI

/// The read-only events mini-timeline shown inside `DayActionsPanel` when a day
/// is expanded in calendar mode. **Read + tap-to-edit** (no drag): timed events
/// render as a lane-packed mini-timeline (positions via the pure `stackEvents`),
/// all-day events as chips. The "Add event" affordance lives in the panel's
/// glass badge row, not here.
///
/// Deliberately a **sibling** of `DayTimelineView` — it never shares the work
/// bar's gesture/coordinate space, so there's no collision with the entry
/// dragger. Event drag is a later phase and would live here, not on the work bar.
struct DayEventStrip: View {
    let date: String
    let events: [CalEvent]
    var onTapEvent: (CalEvent) -> Void

    /// Linear day window used to position timed events horizontally. Events
    /// outside it are clamped to the edges so they still read.
    private let windowStart = 6 * 60       // 06:00
    private let windowEnd = 22 * 60        // 22:00
    private let laneHeight: CGFloat = 22
    private let laneGap: CGFloat = 3
    private let minBlockWidth: CGFloat = 22

    private var timed: [CalEvent] { events.filter { !$0.allDay } }
    private var allDay: [CalEvent] { events.filter { $0.allDay } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(allDay) { ev in allDayChip(ev) }

            if !timed.isEmpty { timedLanes }
        }
    }

    // MARK: - Timed events (lane-packed mini-timeline)

    private var timedLanes: some View {
        let packing = stackEvents(timed)
        let lanes = max(1, packing.laneCount)
        let height = CGFloat(lanes) * laneHeight + CGFloat(lanes - 1) * laneGap
        return GeometryReader { geo in
            let width = geo.size.width
            ForEach(timed) { ev in
                let lane = packing.laneOf[ev.id] ?? 0
                let span = blockFrame(for: ev, width: width)
                eventBlock(ev)
                    .frame(width: span.width, height: laneHeight)
                    .position(x: span.midX,
                              y: CGFloat(lane) * (laneHeight + laneGap) + laneHeight / 2)
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
        .background(eventColor(ev.color).opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { onTapEvent(ev) }
    }

    // MARK: - All-day events

    private func allDayChip(_ ev: CalEvent) -> some View {
        HStack(spacing: 6) {
            Circle().fill(eventColor(ev.color)).frame(width: 7, height: 7)
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
        .background(eventColor(ev.color).opacity(0.12), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { onTapEvent(ev) }
    }
}
