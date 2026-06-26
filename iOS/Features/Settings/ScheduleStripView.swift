import SwiftUI
import UIKit

/// A draggable strip for ONE default-schedule slot — the schedule editor's answer
/// to `DayTimelineView`. It draws the day's work bar with two drag handles and,
/// crucially, renders the slot's **recurring leave** as a teal segment ON the
/// same band, so it's obvious which day the leave belongs to and how much it is.
///
/// Mirrors the PWA's `buildScheduleStrip` (a mini drag handler that saves via a
/// callback rather than to an entry). All time math reuses the pure
/// `Domain/TimelineScale` helpers; the view owns only geometry + gestures.
/// Native touches: haptic snap ticks (`.sensoryFeedback(.selection)`) while
/// dragging and a release thump (`.impact`).
struct ScheduleStripView: View {
    @Environment(\.palette) private var palette
    let startMin: Int
    let endMin: Int
    let leaveHours: Int
    let enabled: Bool
    let use24h: Bool
    /// The shared schedule-wide scale (read every render so all 14 strips stay in
    /// sync and comparable).
    let scale: TimelineScale
    /// Widen the shared scale to keep a live drag on-screen (expand-only).
    var onExpand: (TimelineSegment) -> Void = { _ in }
    /// Persist the dragged start/end (snapped minutes-of-day).
    var onCommit: (_ startMin: Int, _ endMin: Int) -> Void = { _, _ in }

    // MARK: Layout constants (points) — slimmer than the day strip; no OT/lunch.
    private let stripHeight: CGFloat = 56
    private let barTop: CGFloat = 20
    private let barHeight: CGFloat = 12
    private let leaveHeight: CGFloat = 12
    private let handleSize: CGFloat = 11
    private let hitWidth: CGFloat = 44

    private var barMidY: CGFloat { barTop + barHeight / 2 }
    private var tickTopY: CGFloat { barTop + barHeight + 6 }
    private var labelY: CGFloat { stripHeight - 6 }

    private enum Side: Equatable { case start, end }
    private struct DragState: Equatable {
        var startMin: Int
        var endMin: Int
        var tipMin: Int
        var side: Side
    }
    @State private var drag: DragState?
    @State private var commitTick = 0
    // Incremental-drag bookkeeping (same approach as DayTimelineView): drive the
    // drag by per-frame delta in the current scale, not absolute pointer→minute,
    // so the handle stays stable while the shared scale expands underfoot.
    @State private var dragLastPct: Double?
    @State private var dragAccMin: Double?

    // Edge auto-expand bookkeeping (mirrors DayTimelineView): while a handle is
    // parked within `edgeZone` of an edge, a background loop advances it outward
    // one snap-tick every `autoStepInterval`, growing the scale on its own.
    private struct AutoContext: Equatable {
        var side: Side
        var entryStart: Int
        var entryEnd: Int
    }
    @State private var autoDir = 0
    @State private var autoCtx: AutoContext?
    @State private var autoTask: Task<Void, Never>?

    private static let space = "sched-strip"
    private static let edgeZone: CGFloat = 36
    private static let autoStepInterval: UInt64 = 90_000_000  // 90 ms

    // Committed values clamped into the strip bounds; a live drag overrides them.
    private var curStart: Int { drag?.startMin ?? clampToAbsolute(startMin) }
    private var curEnd: Int { drag?.endMin ?? clampToAbsolute(endMin) }

    /// The leave segment: rides the right edge of the work bar on an enabled day,
    /// or anchors at the left edge for a pure-leave off day (so the whole strip
    /// reads as "this day is leave"). Mirrors the PWA's schedule leave bar.
    private var leaveSeg: TimelineSegment? {
        guard leaveHours > 0 else { return nil }
        let s = enabled ? curEnd : TimelineConstants.absoluteStart
        let end = min(TimelineConstants.absoluteEnd, s + leaveHours * 60)
        guard end > s else { return nil }
        return TimelineSegment(startMin: s, widthMin: end - s)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                track(width)
                ticks(width)
                workBar(width)
                if let leave = leaveSeg { leaveBar(leave, width) }
                timePills(width)
                handle(.start, atMin: curStart, width: width)
                handle(.end, atMin: curEnd, width: width)
                if let d = drag { tooltip(d, width) }
            }
            .frame(width: width, height: stripHeight)
            .coordinateSpace(name: Self.space)
        }
        .frame(height: stripHeight)
        .sensoryFeedback(.selection, trigger: drag?.tipMin)
        .sensoryFeedback(.impact(weight: .medium), trigger: commitTick)
    }

    private func leftX(_ m: Int, _ width: CGFloat) -> CGFloat {
        CGFloat(minToPct(Double(m), scale) / 100) * width
    }
    private func clampedX(_ m: Int, _ width: CGFloat) -> CGFloat {
        min(max(leftX(m, width), width * 0.08), width * 0.92)
    }

    // MARK: - Pieces

    private func track(_ width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(.secondarySystemFill))
                .frame(width: width, height: barHeight + 2)
                .position(x: width / 2, y: barMidY)
            Rectangle()
                .fill(Color(.separator))
                .frame(width: width, height: 1)
                .position(x: width / 2, y: tickTopY + 14)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func ticks(_ width: CGFloat) -> some View {
        let first = Int((ceil(Double(TimelineConstants.absoluteStart) / 60)) * 60)
        ForEach(Array(stride(from: first, through: TimelineConstants.absoluteEnd, by: 60)), id: \.self) { m in
            if m >= scale.startMin && m <= scale.endMin {
                let major = (m % 180 == 0)
                Rectangle()
                    .fill(major ? Color(.tertiaryLabel) : Color(.separator))
                    .frame(width: 1, height: major ? 7 : 5)
                    .position(x: leftX(m, width), y: tickTopY + (major ? 3.5 : 2.5))
                if major {
                    Text(hourLabel(m))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: leftX(m, width), y: labelY)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func workBar(_ width: CGFloat) -> some View {
        let x0 = leftX(curStart, width)
        let w = max(2, leftX(curEnd, width) - x0)
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(enabled ? AnyShapeStyle(workGradient) : AnyShapeStyle(offGradient))
            .frame(width: w, height: barHeight)
            .opacity(enabled ? 1 : 0.55)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
            .position(x: x0 + w / 2, y: barMidY)
            .allowsHitTesting(false)
    }

    private func leaveBar(_ seg: TimelineSegment, _ width: CGFloat) -> some View {
        let x0 = leftX(seg.startMin, width)
        let w = max(2, leftX(seg.startMin + seg.widthMin, width) - x0)
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(palette.leave)
            .frame(width: w, height: leaveHeight)
            .position(x: x0 + w / 2, y: barMidY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func timePills(_ width: CGFloat) -> some View {
        pill(clockLabel(curStart), x: clampedX(curStart, width))
        pill(clockLabel(curEnd), x: clampedX(curEnd, width))
    }

    private func pill(_ text: String, x: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color(.systemBackground)))
            .overlay(Capsule().stroke(Color(.separator), lineWidth: 0.5))
            .fixedSize()
            .position(x: x, y: 7)
            .allowsHitTesting(false)
    }

    private func handle(_ side: Side, atMin: Int, width: CGFloat) -> some View {
        let isDragging = drag?.side == side && drag != nil
        return ZStack {
            Circle()
                .fill(isDragging ? Color.accentColor : Color(.systemBackground))
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                .frame(width: handleSize, height: handleSize)
                .scaleEffect(isDragging ? 1.4 : 1)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            Rectangle().fill(Color.clear).frame(width: hitWidth, height: stripHeight)
                .contentShape(Rectangle())
        }
        .frame(width: hitWidth, height: stripHeight)
        .position(x: leftX(atMin, width), y: barMidY)
        .gesture(handleGesture(side, width))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
    }

    private func tooltip(_ d: DragState, _ width: CGFloat) -> some View {
        Text(clockLabel(d.tipMin))
            .font(.system(size: 10, weight: .heavy).monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary))
            .foregroundStyle(Color(.systemBackground))
            .fixedSize()
            .position(x: clampedX(d.tipMin, width), y: -6)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: - Gestures

    private func handleGesture(_ side: Side, _ width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { v in
                let entryStart = clampToAbsolute(startMin)
                let entryEnd = clampToAbsolute(endMin)
                let handleEdge = side == .start ? entryStart : entryEnd
                let opp = side == .start ? entryEnd : entryStart
                let w = max(width, 1)
                let curPct = Double(v.location.x / w) * 100
                // Per-frame delta drive (see DayTimelineView for the rationale):
                // mapping the absolute pointer through an expanding scale feeds
                // back on itself and the handle sticks near the window edge.
                if drag == nil {
                    dragLastPct = Double(v.startLocation.x / w) * 100
                    dragAccMin = Double(handleEdge)
                }
                let last = dragLastPct ?? curPct
                var acc = (dragAccMin ?? Double(handleEdge)) + (pctToMin(curPct, scale) - pctToMin(last, scale))
                acc = min(Double(TimelineConstants.absoluteEnd), max(Double(TimelineConstants.absoluteStart), acc))
                dragLastPct = curPct
                dragAccMin = acc
                let m = resolveHandleDrag(targetMin: acc, opposite: opp, isStart: side == .start)
                let s = side == .start ? m : entryStart
                let en = side == .end ? m : entryEnd
                drag = DragState(startMin: s, endMin: en, tipMin: m, side: side)
                onExpand(TimelineSegment(startMin: min(s, en), widthMin: abs(en - s)))
                updateAuto(dir: edgeDirection(locationX: v.location.x, width: w, side: side),
                           ctx: AutoContext(side: side, entryStart: entryStart, entryEnd: entryEnd))
            }
            .onEnded { _ in commitDrag(); dragLastPct = nil; dragAccMin = nil; stopAuto() }
    }

    // MARK: - Edge auto-expand (mirrors DayTimelineView)

    private func edgeDirection(locationX: CGFloat, width: CGFloat, side: Side) -> Int {
        if side == .end && locationX > width - Self.edgeZone { return 1 }
        if side == .start && locationX < Self.edgeZone { return -1 }
        return 0
    }

    private func updateAuto(dir: Int, ctx: AutoContext) {
        autoDir = dir
        autoCtx = ctx
        if dir == 0 {
            stopAuto()
        } else if autoTask == nil {
            autoTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: Self.autoStepInterval)
                    if Task.isCancelled || drag == nil || autoDir == 0 { break }
                    autoStep()
                }
            }
        }
    }

    private func stopAuto() {
        autoTask?.cancel()
        autoTask = nil
        autoDir = 0
        autoCtx = nil
    }

    private func autoStep() {
        guard let ctx = autoCtx, autoDir != 0, let acc0 = dragAccMin else { return }
        var acc = acc0 + Double(autoDir * TimelineConstants.snap)
        acc = min(Double(TimelineConstants.absoluteEnd), max(Double(TimelineConstants.absoluteStart), acc))
        dragAccMin = acc
        let opp = ctx.side == .start ? ctx.entryEnd : ctx.entryStart
        let m = resolveHandleDrag(targetMin: acc, opposite: opp, isStart: ctx.side == .start)
        let s = ctx.side == .start ? m : ctx.entryStart
        let en = ctx.side == .end ? m : ctx.entryEnd
        drag = DragState(startMin: s, endMin: en, tipMin: m, side: ctx.side)
        onExpand(TimelineSegment(startMin: min(s, en), widthMin: abs(en - s)))
    }

    private func commitDrag() {
        defer { drag = nil }
        guard let d = drag else { return }
        commitTick &+= 1
        onCommit(d.startMin, d.endMin)
    }

    // MARK: - Formatting (compact, matches DayTimelineView pills)

    private func clockLabel(_ m: Int) -> String {
        let mm = ((m % 1440) + 1440) % 1440
        let h24 = mm / 60, min = mm % 60
        if use24h { return String(format: "%02d:%02d", h24, min) }
        let isPM = h24 >= 12
        var h12 = h24 % 12; if h12 == 0 { h12 = 12 }
        return min == 0 ? "\(h12)\(isPM ? "p" : "a")" : String(format: "%d:%02d%@", h12, min, isPM ? "p" : "a")
    }

    private func hourLabel(_ m: Int) -> String {
        let h = (m / 60) % 24
        if use24h { return String(format: "%02d", h) }
        if h == 0 || h == 12 { return "12" }
        return String(h <= 12 ? h : h - 12)
    }

    // MARK: - Styling

    private var workGradient: LinearGradient { palette.workGradient }
    private var offGradient: LinearGradient {
        LinearGradient(colors: [Color(white: 0.72), Color(white: 0.53)],
                       startPoint: .top, endPoint: .bottom)
    }
}
