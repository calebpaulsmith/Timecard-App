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
    private let barHeight: CGFloat = 18
    private let leaveHeight: CGFloat = 6
    private let handleSize: CGFloat = 14
    private let hitWidth: CGFloat = 44

    private var barMidY: CGFloat { barTop + barHeight / 2 }
    private var leaveMidY: CGFloat { barTop + barHeight + 3 + leaveHeight / 2 }
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
        // Keep pills/tooltip fully on-strip at the extremes (~8%..92%).
        min(max(leftX(m, width), width * 0.08), width * 0.92)
    }

    // MARK: - Pieces

    private func track(_ width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(.secondarySystemFill))
                .frame(width: width, height: barHeight + 2)
                .position(x: width / 2, y: barTop + barHeight / 2)
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
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
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
            .position(x: x, y: 7)
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
                let w = max(width, 1)
                // Grab offset (in minutes): the gap between where the finger landed
                // and the handle's edge, held constant so the handle doesn't jump
                // under the finger — pointer drift translates 1:1. Mirrors the PWA's
                // grabOffsetMin.
                let handleEdge = side == .start ? entryStart : entryEnd
                let grabOffset = pctToMin(Double(v.startLocation.x / w) * 100, scale) - Double(handleEdge)
                let target = pctToMin(Double(v.location.x / w) * 100, scale) - grabOffset
                let opp = side == .start ? entryEnd : entryStart
                let m = resolveHandleDrag(targetMin: target, opposite: opp, isStart: side == .start)
                let s = side == .start ? m : entryStart
                let en = side == .end ? m : entryEnd
                drag = DragState(id: e.id, startMin: s, endMin: en, tipMin: m, side: side)
                onExpand(TimelineSegment(startMin: s, widthMin: en - s))
            }
            .onEnded { _ in commitDrag(entry) }
    }

    private func moveGesture(_ r: Rendered, _ width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.space))
            .onChanged { v in
                guard let e = entries.first(where: { $0.id == r.id }), let span = entryBarSpan(e) else { return }
                // Anchor the bar's start under the finger, offset by where it was grabbed.
                let pct = Double(v.location.x / max(width, 1)) * 100
                let pointerMin = pctToMin(pct, scale)
                let grabOffset = Double(span.startMin) - pctToMin(Double((v.startLocation.x) / max(width, 1)) * 100, scale)
                let moved = resolveBarMove(targetStartMin: pointerMin + grabOffset, widthMin: span.widthMin)
                drag = DragState(id: e.id, startMin: moved.startMin, endMin: moved.endMin,
                                 tipMin: moved.startMin, side: .start)
                onExpand(TimelineSegment(startMin: moved.startMin, widthMin: moved.endMin - moved.startMin))
            }
            .onEnded { _ in commitDrag(entries.first { $0.id == r.id }) }
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
