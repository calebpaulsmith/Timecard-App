import SwiftUI
import UIKit

/// The draggable day-timeline strip — the heart of the pay-period view. A dumb
/// renderer of the pure results in `Domain/TimelineScale.swift`: it draws the
/// hour ticks, the blue work bar(s), the hatched lunch break, the golden OT
/// overlay, the teal leave bar, and persistent edge time-pills; and it turns
/// finger drags on the end handles (or the bar body) into 15-min-snapped time
/// edits with live haptics + a tooltip.
///
/// All time math goes through Domain. The view owns only geometry (minute →
/// point via `minToPct`) and gesture plumbing. Mirrors the PWA's
/// `buildDayTimeline` + `attachHandleDrag`, with two native upgrades the web
/// app couldn't have: haptic snap ticks and whole-bar move.
struct DayTimelineView: View {
    let date: String
    /// Drawable entries (have a start, not incomplete), sorted by start.
    let entries: [EntryRecord]
    let dayLeave: Double
    let dayOt: Double
    let use24h: Bool
    let isToday: Bool
    /// The shared period-wide scale (read every render so all strips stay in sync).
    let scale: TimelineScale
    /// Widen the shared scale to keep a live drag on-screen (expand-only).
    var onExpand: (TimelineSegment) -> Void = { _ in }
    /// Persist a dragged entry edit.
    var onCommit: (EntryRecord) -> Void = { _ in }
    /// A tap (no drag) on the strip — opens the day editor.
    var onTap: () -> Void = {}

    // MARK: Layout constants (points)
    private let stripHeight: CGFloat = 64
    private let barTop: CGFloat = 24
    private let barHeight: CGFloat = 12
    private let leaveHeight: CGFloat = 12
    private let handleSize: CGFloat = 11
    // Narrower invisible grab target than before (was 44) — the wide target made
    // it easy to grab a handle by accident when tapping/scrolling near it.
    private let hitWidth: CGFloat = 30

    private var barMidY: CGFloat { barTop + barHeight / 2 }
    // Leave rides the SAME band as the work bar (in line with the worked hours),
    // reading as a teal continuation to the right of the last entry.
    private var leaveMidY: CGFloat { barMidY }
    private var tickTopY: CGFloat { barTop + barHeight + 6 }
    private var labelY: CGFloat { stripHeight - 6 }

    private enum Side: Equatable { case start, end }
    private struct DragState: Equatable {
        var id: String
        var startMin: Int
        var endMin: Int
        var tipMin: Int
        var side: Side
    }
    @State private var drag: DragState?
    @State private var commitTick = 0
    // Incremental-drag bookkeeping: the last pointer % and the accumulated
    // (unsnapped) minute, so a drag advances by per-frame delta and stays stable
    // while the shared scale expands underfoot.
    @State private var dragLastPct: Double?
    @State private var dragAccMin: Double?

    // Edge auto-expand bookkeeping (see "Edge auto-expand" below): the current
    // outward direction (-1 left / 0 none / +1 right), the drag context the
    // background loop needs to keep advancing, and the loop task itself.
    private struct AutoContext: Equatable {
        var id: String
        var isMove: Bool
        var side: Side
        var widthMin: Int
        var entryStart: Int
        var entryEnd: Int
    }
    @State private var autoDir = 0
    @State private var autoCtx: AutoContext?
    @State private var autoTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                track(width)
                ticks(width)
                if isToday { nowLine(width) }
                ForEach(rendered, id: \.id) { r in
                    workBar(r, width)
                    if r.lunchMinutes > 0 { lunchBar(r, width) }
                }
                ForEach(Array(otSegs.enumerated()), id: \.offset) { item in
                    otBar(item.element, width)
                }
                if let leave = leaveSeg { leaveBar(leave, width) }
                ForEach(rendered, id: \.id) { r in
                    timePills(r, width)
                    // Completed entries get both handles; an in-progress entry gets
                    // an end handle only — dragging it sets the end time (a drag
                    // clock-out), mirroring the PWA's drawEntryOnTimeline.
                    if r.inProgress {
                        handle(r, .end, atMin: r.endMin, width: width)
                    } else {
                        handles(r, width)
                    }
                }
                if let d = drag { tooltip(d, width) }
            }
            .frame(width: width, height: stripHeight)
            .coordinateSpace(name: Self.space)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
        }
        .frame(height: stripHeight)
        .sensoryFeedback(.selection, trigger: drag?.tipMin)
        .sensoryFeedback(.impact(weight: .medium), trigger: commitTick)
    }

    private static let space = "tl-strip"

    // MARK: - Derived geometry

    private struct Rendered: Identifiable {
        var id: String
        var startMin: Int
        var endMin: Int
        var lunchMinutes: Int
        var inProgress: Bool
    }

    private var rendered: [Rendered] {
        entries.compactMap { e in
            guard let span = entryBarSpan(e) else { return nil }
            var s = span.startMin
            var en = span.startMin + span.widthMin
            if let d = drag, d.id == e.id { s = d.startMin; en = d.endMin }
            return Rendered(id: e.id, startMin: s, endMin: en,
                            lunchMinutes: e.lunchMinutes, inProgress: e.endTime == nil)
        }
    }

    private var otSegs: [TimelineSegment] {
        // OT overlay is recomputed on commit (not live mid-drag), matching the PWA.
        drag == nil ? otSegments(entries, dayOt: dayOt) : []
    }
    private var leaveSeg: TimelineSegment? {
        leaveSegment(entries: entries, dayLeave: dayLeave)
    }

    private func leftX(_ m: Int, _ width: CGFloat) -> CGFloat {
        CGFloat(minToPct(Double(m), scale) / 100) * width
    }
    private func clampedX(_ m: Int, _ width: CGFloat) -> CGFloat {
        // Keep the time pills / tooltip pulled well in from the card edges so they
        // never crowd the rounded corners (was 8/92, too close to the edge).
        min(max(leftX(m, width), width * 0.13), width * 0.87)
    }

    // MARK: - Pieces

    private func track(_ width: CGFloat) -> some View {
        // Just the rounded trough the work bar sits in. The full-width baseline
        // separator under the ticks was removed — the hour ticks + labels carry
        // the axis on their own and it reads cleaner without the rule.
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(.secondarySystemFill))
            .frame(width: width, height: barHeight + 2)
            .position(x: width / 2, y: barTop + barHeight / 2)
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

    private func nowLine(_ width: CGFloat) -> some View {
        let nowMin = clampToAbsolute(minutesOfDay(Date()))
        return Rectangle()
            .fill(Color.red)
            .frame(width: 1, height: barHeight + 8)
            .position(x: leftX(nowMin, width), y: barMidY + 2)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func workBar(_ r: Rendered, _ width: CGFloat) -> some View {
        let x0 = leftX(r.startMin, width)
        let w = max(2, leftX(r.endMin, width) - x0)
        let bar = RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(r.inProgress ? inProgressGradient : workGradient)
            .frame(width: w, height: barHeight)
            .overlay(alignment: .trailing) {
                if r.inProgress {
                    Rectangle().fill(.black.opacity(0.25)).frame(width: 2)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
            .position(x: x0 + w / 2, y: barMidY)
        // Whole-bar move (additive vs the PWA, which only resized via handles).
        if r.inProgress {
            bar
        } else {
            bar.gesture(moveGesture(r, width))
        }
    }

    private func lunchBar(_ r: Rendered, _ width: CGFloat) -> some View {
        let mid = Double(r.startMin + r.endMin) / 2
        let half = Double(r.lunchMinutes) / 2
        let x0 = leftX(Int((mid - half).rounded()), width)
        let x1 = leftX(Int((mid + half).rounded()), width)
        let w = max(2, x1 - x0)
        return Hatch()
            .frame(width: w, height: barHeight)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .position(x: x0 + w / 2, y: barMidY)
            .allowsHitTesting(false)
    }

    private func otBar(_ seg: TimelineSegment, _ width: CGFloat) -> some View {
        let x0 = leftX(seg.startMin, width)
        let w = max(2, leftX(seg.startMin + seg.widthMin, width) - x0)
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(otGradient)
            .frame(width: w, height: barHeight)
            .overlay(Shimmer().clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous)))
            .shadow(color: Color.orange.opacity(0.5), radius: 4)
            .position(x: x0 + w / 2, y: barMidY)
            .allowsHitTesting(false)
    }

    private func leaveBar(_ seg: TimelineSegment, _ width: CGFloat) -> some View {
        let x0 = leftX(seg.startMin, width)
        let w = max(2, leftX(seg.startMin + seg.widthMin, width) - x0)
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.teal)
            .frame(width: w, height: leaveHeight)
            .position(x: x0 + w / 2, y: leaveMidY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func timePills(_ r: Rendered, _ width: CGFloat) -> some View {
        pill(clockLabel(r.startMin), x: clampedX(r.startMin, width))
        if !r.inProgress {
            pill(clockLabel(r.endMin), x: clampedX(r.endMin, width))
        }
    }

    private func pill(_ text: String, x: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color(.systemBackground)))
            .overlay(Capsule().stroke(Color(.separator), lineWidth: 0.5))
            .fixedSize()
            // Sit just above the bar (was up at y:7, floating high and detached).
            .position(x: x, y: 16)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func handles(_ r: Rendered, _ width: CGFloat) -> some View {
        handle(r, .start, atMin: r.startMin, width: width)
        handle(r, .end, atMin: r.endMin, width: width)
    }

    private func handle(_ r: Rendered, _ side: Side, atMin: Int, width: CGFloat) -> some View {
        let isDragging = drag?.id == r.id && drag?.side == side
        let entry = entries.first { $0.id == r.id }
        return ZStack {
            Circle()
                .fill(isDragging ? Color.accentColor : Color(.systemBackground))
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                .frame(width: handleSize, height: handleSize)
                .scaleEffect(isDragging ? 1.4 : 1)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            // Invisible wide hit target for the finger.
            Rectangle().fill(Color.clear).frame(width: hitWidth, height: stripHeight)
                .contentShape(Rectangle())
        }
        .frame(width: hitWidth, height: stripHeight)
        .position(x: leftX(atMin, width), y: barMidY)
        .gesture(handleGesture(entry, side, width))
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

    private func handleGesture(_ entry: EntryRecord?, _ side: Side, _ width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { v in
                guard let e = entry, let span = entryBarSpan(e) else { return }
                let entryStart = span.startMin
                let entryEnd = span.startMin + span.widthMin
                let handleEdge = side == .start ? entryStart : entryEnd
                let opp = side == .start ? entryEnd : entryStart
                let w = max(width, 1)
                let curPct = Double(v.location.x / w) * 100
                // Drive the drag by INCREMENTAL per-frame delta, not absolute
                // pointer→minute. Mapping the absolute pointer through a scale that
                // is itself expanding (onExpand) feeds back on itself and the handle
                // sticks/oscillates near the window edge (~6–7pm). Per-frame delta in
                // the current scale is stable: a still finger = 0 move at any zoom.
                if drag?.id != e.id {
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
                drag = DragState(id: e.id, startMin: s, endMin: en, tipMin: m, side: side)
                onExpand(TimelineSegment(startMin: min(s, en), widthMin: abs(en - s)))
                // Hand off to the auto-expand loop when the finger reaches the edge,
                // so the scale keeps growing while the finger is held still.
                updateAuto(dir: edgeDirection(locationX: v.location.x, width: w, side: side, isMove: false),
                           ctx: AutoContext(id: e.id, isMove: false, side: side, widthMin: 0,
                                            entryStart: entryStart, entryEnd: entryEnd))
            }
            .onEnded { _ in commitDrag(entry); dragLastPct = nil; dragAccMin = nil; stopAuto() }
    }

    private func moveGesture(_ r: Rendered, _ width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.space))
            .onChanged { v in
                guard let e = entries.first(where: { $0.id == r.id }), let span = entryBarSpan(e) else { return }
                let w = max(width, 1)
                let curPct = Double(v.location.x / w) * 100
                // Same incremental-delta drive as the handles (see note above).
                if drag?.id != e.id {
                    dragLastPct = Double(v.startLocation.x / w) * 100
                    dragAccMin = Double(span.startMin)
                }
                let last = dragLastPct ?? curPct
                let maxStart = Double(TimelineConstants.absoluteEnd - TimelineConstants.snap - span.widthMin)
                var acc = (dragAccMin ?? Double(span.startMin)) + (pctToMin(curPct, scale) - pctToMin(last, scale))
                acc = min(maxStart, max(Double(TimelineConstants.absoluteStart), acc))
                dragLastPct = curPct
                dragAccMin = acc
                let moved = resolveBarMove(targetStartMin: acc, widthMin: span.widthMin)
                drag = DragState(id: e.id, startMin: moved.startMin, endMin: moved.endMin,
                                 tipMin: moved.startMin, side: .start)
                onExpand(TimelineSegment(startMin: moved.startMin, widthMin: moved.endMin - moved.startMin))
                updateAuto(dir: edgeDirection(locationX: v.location.x, width: w, side: .start, isMove: true),
                           ctx: AutoContext(id: e.id, isMove: true, side: .start, widthMin: span.widthMin,
                                            entryStart: 0, entryEnd: 0))
            }
            .onEnded { _ in commitDrag(entries.first { $0.id == r.id }); dragLastPct = nil; dragAccMin = nil; stopAuto() }
    }

    // MARK: - Edge auto-expand
    //
    // SwiftUI's DragGesture only fires `onChanged` when the finger MOVES, so
    // holding a handle at the strip edge did nothing — the user had to jiggle
    // back and forth to fire fresh callbacks and grow the scale a tick at a
    // time. This background loop fixes that: while a handle/bar is parked within
    // `edgeZone` of an edge, it advances the drag outward one snap-tick every
    // `autoStepInterval`, expanding the shared scale on its own. Mirrors the
    // PWA's requestAnimationFrame edge loop in `attachHandleDrag`.

    private static let edgeZone: CGFloat = 36
    private static let autoStepInterval: UInt64 = 90_000_000  // 90 ms

    /// +1 to push the right/end edge later, -1 to push the left/start edge
    /// earlier, 0 when the finger isn't parked in an outward edge zone.
    private func edgeDirection(locationX: CGFloat, width: CGFloat, side: Side, isMove: Bool) -> Int {
        let nearRight = locationX > width - Self.edgeZone
        let nearLeft = locationX < Self.edgeZone
        if isMove {
            if nearRight { return 1 }
            if nearLeft { return -1 }
            return 0
        }
        if side == .end && nearRight { return 1 }
        if side == .start && nearLeft { return -1 }
        return 0
    }

    /// Record the current edge direction + context and start (or stop) the loop.
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

    /// One auto-advance tick: nudge the accumulated minute one snap outward and
    /// re-apply exactly like a synthetic drag frame (same resolve + onExpand).
    private func autoStep() {
        guard let ctx = autoCtx, autoDir != 0, let acc0 = dragAccMin else { return }
        var acc = acc0 + Double(autoDir * TimelineConstants.snap)
        if ctx.isMove {
            let maxStart = Double(TimelineConstants.absoluteEnd - TimelineConstants.snap - ctx.widthMin)
            acc = min(maxStart, max(Double(TimelineConstants.absoluteStart), acc))
            dragAccMin = acc
            let moved = resolveBarMove(targetStartMin: acc, widthMin: ctx.widthMin)
            drag = DragState(id: ctx.id, startMin: moved.startMin, endMin: moved.endMin,
                             tipMin: moved.startMin, side: .start)
            onExpand(TimelineSegment(startMin: moved.startMin, widthMin: moved.endMin - moved.startMin))
        } else {
            acc = min(Double(TimelineConstants.absoluteEnd), max(Double(TimelineConstants.absoluteStart), acc))
            dragAccMin = acc
            let opp = ctx.side == .start ? ctx.entryEnd : ctx.entryStart
            let m = resolveHandleDrag(targetMin: acc, opposite: opp, isStart: ctx.side == .start)
            let s = ctx.side == .start ? m : ctx.entryStart
            let en = ctx.side == .end ? m : ctx.entryEnd
            drag = DragState(id: ctx.id, startMin: s, endMin: en, tipMin: m, side: ctx.side)
            onExpand(TimelineSegment(startMin: min(s, en), widthMin: abs(en - s)))
        }
    }

    private func commitDrag(_ entry: EntryRecord?) {
        defer { drag = nil }
        guard let e = entry, let d = drag, d.id == e.id else { return }
        let start = buildDateTime(date, hour24: d.startMin / 60, minute: d.startMin % 60)
        let end = buildDateTime(date, hour24: d.endMin / 60, minute: d.endMin % 60)
        var ne = e
        ne.startTime = start
        ne.endTime = end
        ne.incomplete = false
        // Lunch is PRESERVED on drag — the PWA's drag (attachHandleDrag.onUp) writes
        // only start/end and leaves lunchMinutes user-controlled. Dragging never
        // adds/removes a lunch deduction.
        commitTick &+= 1
        onCommit(ne)
    }

    // MARK: - Formatting

    /// Compact clock label for the edge pills / tooltip ("9a", "4:30p", "13:00").
    /// Deliberately tighter than Domain's `formatMinutes` so it fits the strip.
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

    private var workGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.31, green: 0.63, blue: 1.0), Color.accentColor],
                       startPoint: .top, endPoint: .bottom)
    }
    private var inProgressGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 1.0, green: 0.77, blue: 0.29), Color.orange],
                       startPoint: .top, endPoint: .bottom)
    }
    private var otGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 1.0, green: 0.88, blue: 0.48),
                                Color(red: 1.0, green: 0.70, blue: 0.0),
                                Color(red: 0.90, green: 0.52, blue: 0.0)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// Diagonal hatch fill for the lunch break, over the work bar.
private struct Hatch: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(.systemBackground).opacity(0.85)))
            var path = Path()
            let step: CGFloat = 4
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            ctx.stroke(path, with: .color(.black.opacity(0.18)), lineWidth: 1.2)
        }
    }
}

/// A slow diagonal sheen sweeping across the OT bar, so overtime visibly
/// shimmers (the PWA's `ot-shimmer`). Honors Reduce Motion.
private struct Shimmer: View {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            LinearGradient(
                colors: [.clear, .white.opacity(0.55), .clear],
                startPoint: .leading, endPoint: .trailing)
            .frame(width: w * 0.6)
            .offset(x: phase * w * 1.6)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
        .allowsHitTesting(false)
    }
}
