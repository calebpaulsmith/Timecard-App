import SwiftUI

/// The **expanded**, interactive events view for a day on the Period screen. When
/// a day card is tapped open in calendar mode, its events grow from the thin
/// collapsed pips (`DayTimelineEventsOverlay`) into a stack of **equal-height
/// lanes** — one row per event, tall enough to show the title, touching but not
/// overlapping. Each lane:
///   • shows the event **title**,
///   • is **tappable** → opens the event editor,
///   • is **drag-to-move** (hold ~0.4s, then drag) for a local, non-recurring,
///     timed event — 15-min snapped, mirroring the leave-bar drag.
///
/// Horizontal positions use the same shared `TimelineScale` as the work strip, so
/// a lane lines up in time with the work bar. `PeriodView` renders it as TWO
/// groups so the lines expand **in place** — the above-bar bands (all-day, others,
/// close, mine) render just above the strip; tasks render just below it — instead
/// of teleporting every event into one block under the timeline. This replaces the
/// old tier-labeled `DayEventStrip` list.
struct DayEventLanesView: View {
    @Environment(\.palette) private var palette
    let date: String
    /// Events for this day (all-day first, then by start) — already resolved.
    let events: [CalEvent]
    /// Shared period-wide scale (read every render so lanes line up with the bar).
    let scale: TimelineScale
    let use24h: Bool
    /// Resolve an event → its render color (per-calendar config, theme fallback).
    var colorFor: (CalEvent) -> Color = { _ in .accentColor }
    /// Resolve an event → its band (for stack ordering: others → close → mine →
    /// tasks, top to bottom, so the lanes keep the collapsed band order).
    var tierFor: (CalEvent) -> CalendarTier = { _ in .mine }
    /// Widen the shared scale to keep a live drag on-screen (expand-only).
    var onExpandScale: (TimelineSegment) -> Void = { _ in }
    /// A tap on a lane — open the editor for that event.
    var onTapEvent: (CalEvent) -> Void = { _ in }
    /// Persist a dragged move: the event and its new start minute (duration kept).
    var onMoveEvent: (CalEvent, Int) -> Void = { _, _ in }

    private let laneHeight: CGFloat = 26
    private let laneGap: CGFloat = 2

    // Drag state (one lane at a time), mirroring the leave-bar drag.
    @State private var dragId: String?
    @State private var dragStartMin: Int?
    @State private var dragAcc: Double?
    @State private var dragLastPct: Double?
    @State private var grabTick = 0
    @State private var commitTick = 0

    private static let space = "event-lanes"

    /// Vertical rank so lanes keep the collapsed band order top→bottom: all-day
    /// chips first, then others → close → mine → tasks.
    private func rank(_ ev: CalEvent) -> Int {
        if ev.allDay { return -1 }
        switch tierFor(ev) {
        case .others: return 0
        case .close:  return 1
        case .mine:   return 2
        case .tasks:  return 3
        }
    }

    /// Lanes in stack order: band rank, then by start time.
    private var ordered: [CalEvent] {
        events.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.startMin < b.startMin
        }
    }

    private var totalHeight: CGFloat {
        let n = max(1, ordered.count)
        return CGFloat(n) * laneHeight + CGFloat(n - 1) * laneGap
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { i, ev in
                    lane(ev, index: i, width: width)
                }
            }
            .frame(width: width, height: totalHeight, alignment: .topLeading)
            .coordinateSpace(name: Self.space)
        }
        .frame(height: totalHeight)
        .sensoryFeedback(.impact(flexibility: .rigid), trigger: grabTick)
        .sensoryFeedback(.selection, trigger: dragStartMin)
        .sensoryFeedback(.impact(weight: .medium), trigger: commitTick)
    }

    // MARK: - One lane

    @ViewBuilder
    private func lane(_ ev: CalEvent, index: Int, width: CGFloat) -> some View {
        let dur = max(TimelineConstants.snap, ev.endMin - ev.startMin)
        let liveStart = (dragId == ev.id ? dragStartMin : nil) ?? ev.startMin
        let x0 = ev.allDay ? 0 : leftX(liveStart, width)
        let x1 = ev.allDay ? width : max(leftX(liveStart + dur, width), x0 + 10)
        let w = max(10, x1 - x0)
        let y = CGFloat(index) * (laneHeight + laneGap)
        let color = colorFor(ev)
        let dragging = dragId == ev.id

        let content = ZStack(alignment: .leading) {
            // The colored time bar (full width for all-day).
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.opacity(0.9))
                .frame(width: w, height: laneHeight)
                .glassGloss(cornerRadius: 5)
                .shadow(color: dragging ? color.opacity(0.6) : .clear, radius: dragging ? 4 : 0)
                .offset(x: x0)

            // The title — starts at the bar's leading edge and may extend right over
            // empty timeline so it's always readable even for a short event.
            HStack(spacing: 3) {
                Text(ev.title.isEmpty ? "(untitled)" : ev.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if ev.isOccurrence || ev.isSeries {
                    Image(systemName: "repeat").font(.system(size: 9))
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .padding(.horizontal, 6)
            .frame(width: max(w, width - x0), height: laneHeight, alignment: .leading)
            .offset(x: x0)
            .allowsHitTesting(false)
        }
        .frame(width: width, height: laneHeight, alignment: .leading)
        .contentShape(Rectangle())
        .offset(y: y)
        .onTapGesture { onTapEvent(ev) }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)

        // Only local, non-recurring, timed events get the hold-to-drag gesture;
        // everything else is tap-to-open only.
        if isDraggable(ev) {
            content.gesture(moveGesture(ev, dur: dur, width: width))
        } else {
            content
        }
    }

    /// Only local, non-recurring, timed events can be dragged. Read-only mirrors,
    /// recurring occurrences/series, and all-day events open the editor on tap.
    private func isDraggable(_ ev: CalEvent) -> Bool {
        ev.isLocal && !ev.allDay && !ev.isOccurrence && !ev.isSeries
    }

    // MARK: - Geometry + drag

    private func leftX(_ m: Int, _ width: CGFloat) -> CGFloat {
        CGFloat(minToPct(Double(m), scale) / 100) * width
    }

    /// Hold ~0.4s then drag to move the event in time (15-min snapped), persisted
    /// on release. The long-press start keeps this from fighting the tap-to-open.
    private func moveGesture(_ ev: CalEvent, dur: Int, width: CGFloat) -> some Gesture {
        let w = max(width, 1)
        return LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                guard case .second(true, let dragValue) = value else { return }
                if dragId != ev.id {                 // long-press just armed
                    dragId = ev.id
                    dragStartMin = ev.startMin
                    dragAcc = Double(ev.startMin)
                    dragLastPct = nil
                    grabTick &+= 1
                }
                guard let dv = dragValue else { return }
                let curPct = Double(dv.location.x / w) * 100
                if dragLastPct == nil { dragLastPct = Double(dv.startLocation.x / w) * 100 }
                let last = dragLastPct ?? curPct
                var acc = (dragAcc ?? Double(ev.startMin)) + (pctToMin(curPct, scale) - pctToMin(last, scale))
                let maxStart = Double(TimelineConstants.absoluteEnd - dur)
                acc = min(maxStart, max(Double(TimelineConstants.absoluteStart), acc))
                dragLastPct = curPct
                dragAcc = acc
                let snapped = Int((acc / Double(TimelineConstants.snap)).rounded()) * TimelineConstants.snap
                dragStartMin = snapped
                onExpandScale(TimelineSegment(startMin: snapped, widthMin: dur))
            }
            .onEnded { _ in
                if dragId == ev.id, let s = dragStartMin, s != ev.startMin {
                    onMoveEvent(ev, s); commitTick &+= 1
                }
                dragId = nil; dragStartMin = nil; dragAcc = nil; dragLastPct = nil
            }
    }
}
