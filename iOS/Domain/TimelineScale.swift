import Foundation

/// The day-timeline horizontal scale + the pure mapping math behind the
/// draggable entry strip — the heart of the pay-period view.
///
/// Ported from the PWA's `app.js` (`minToPct` / `pctToMin` / `autoFitScale` /
/// `reflowList` fit / `otSegments` / `clampToAbsolute` / `endMinutesForEntry`).
/// These lived in the UI layer in the web app; here they belong in `Domain/`
/// so the math that "must be right" is unit-tested, leaving the SwiftUI view a
/// dumb renderer of these results. No SwiftUI/SwiftData.
///
/// The timeline is **non-linear**: the core hours (9:00–2:30) are compressed to
/// 30% of the width so the early/late edges get more room. This keeps a typical
/// federal workday legible without wasting space on the small hours.

// MARK: - Constants (verbatim from app.js)

enum TimelineConstants {
    /// Hard left bound — 4:30 AM. The strip never shows anything earlier.
    static let absoluteStart = 4 * 60 + 30        // 270
    /// Hard right bound — midnight. End handles cap one snap-tick short of this.
    static let absoluteEnd = 24 * 60              // 1440
    /// Default visible window start — 5:45 AM (padded so the 6 AM tick isn't clipped).
    static let defaultScaleStart = 5 * 60 + 45    // 345
    /// Default visible window end — 6:15 PM.
    static let defaultScaleEnd = 18 * 60 + 15     // 1095
    /// Padding applied when auto-extending the window to fit a bar.
    static let scalePad = 30
    /// Drag snap granularity (15 minutes).
    static let snap = 15
    /// Core-hours window start — 9:00 AM.
    static let coreStart = 9 * 60                 // 540
    /// Core-hours window end — 2:30 PM.
    static let coreEnd = 14 * 60 + 30             // 870
    /// Fraction of the strip width the core window occupies (compressed).
    static let coreWeight = 0.30
}

// MARK: - Scale

/// A visible time window over the strip, in minutes-since-midnight.
struct TimelineScale: Equatable {
    var startMin: Int
    var endMin: Int

    static let `default` = TimelineScale(startMin: TimelineConstants.defaultScaleStart,
                                         endMin: TimelineConstants.defaultScaleEnd)
}

/// A clock-minute span (used for OT overlay segments and the leave bar).
struct TimelineSegment: Equatable {
    var startMin: Int
    var widthMin: Int
}

// MARK: - Minute <-> percent mapping (non-linear core compression)

/// Map a minute-of-day to a 0...100 horizontal percent within `scale`, with the
/// core hours compressed to `coreWeight` of the width. Mirrors `app.js minToPct`
/// (timecard branch).
func minToPct(_ m: Double, _ scale: TimelineScale) -> Double {
    let startMin = Double(scale.startMin)
    let endMin = Double(scale.endMin)
    if endMin <= startMin { return 0 }
    if m <= startMin { return 0 }
    if m >= endMin { return 100 }
    let cs = max(Double(TimelineConstants.coreStart), startMin)
    let ce = min(Double(TimelineConstants.coreEnd), endMin)
    if ce <= cs { return (m - startMin) / (endMin - startMin) * 100 }
    let preMin = cs - startMin
    let coreMin = ce - cs
    let postMin = endMin - ce
    let nonCore = preMin + postMin
    let coreW = TimelineConstants.coreWeight * 100
    let edgesW = 100 - coreW
    let preW = nonCore > 0 ? (preMin / nonCore) * edgesW : 0
    let postW = nonCore > 0 ? (postMin / nonCore) * edgesW : 0
    if m < cs { return (m - startMin) / preMin * preW }
    if m < ce { return preW + (m - cs) / coreMin * coreW }
    return preW + coreW + (m - ce) / postMin * postW
}

/// Inverse of `minToPct`: map a 0...100 percent back to a minute-of-day.
/// Mirrors `app.js pctToMin` (timecard branch).
func pctToMin(_ pct: Double, _ scale: TimelineScale) -> Double {
    let startMin = Double(scale.startMin)
    let endMin = Double(scale.endMin)
    if endMin <= startMin { return startMin }
    if pct <= 0 { return startMin }
    if pct >= 100 { return endMin }
    let cs = max(Double(TimelineConstants.coreStart), startMin)
    let ce = min(Double(TimelineConstants.coreEnd), endMin)
    if ce <= cs { return startMin + (pct / 100) * (endMin - startMin) }
    let preMin = cs - startMin
    let coreMin = ce - cs
    let postMin = endMin - ce
    let nonCore = preMin + postMin
    let coreW = TimelineConstants.coreWeight * 100
    let edgesW = 100 - coreW
    let preW = nonCore > 0 ? (preMin / nonCore) * edgesW : 0
    let postW = nonCore > 0 ? (postMin / nonCore) * edgesW : 0
    if pct < preW { return startMin + (pct / preW) * preMin }
    if pct < preW + coreW { return cs + ((pct - preW) / coreW) * coreMin }
    return ce + ((pct - preW - coreW) / postW) * postMin
}

// MARK: - Clamping / snapping

/// Clamp a minute-of-day into the absolute strip bounds (4:30 AM ... midnight).
func clampToAbsolute(_ m: Int) -> Int {
    max(TimelineConstants.absoluteStart, min(TimelineConstants.absoluteEnd, m))
}

/// Round a (possibly fractional) minute to the nearest 15-minute snap tick.
func snapToQuarter(_ m: Double) -> Int {
    Int((m / Double(TimelineConstants.snap)).rounded()) * TimelineConstants.snap
}

/// Resolve a dragged handle to a snapped, clamped minute given the opposite
/// edge. A start handle stays one snap-tick left of the end; an end handle
/// stays one snap-tick right of the start and one tick short of midnight (so we
/// never write a next-day endTime via the slider). Mirrors `attachHandleDrag`'s
/// `onMove`.
func resolveHandleDrag(targetMin: Double, opposite: Int, isStart: Bool) -> Int {
    var m = clampToAbsolute(snapToQuarter(targetMin))
    if isStart {
        m = min(opposite - TimelineConstants.snap, m)
    } else {
        m = max(opposite + TimelineConstants.snap,
                min(TimelineConstants.absoluteEnd - TimelineConstants.snap, m))
    }
    return m
}

/// Resolve a whole-bar move (drag the body) to a snapped, clamped pair, keeping
/// the entry's duration fixed. The bar is shifted by the snapped delta and then
/// clamped so neither edge escapes the absolute bounds. Not present in the PWA
/// (it only resized via handles) — an additive improvement.
func resolveBarMove(targetStartMin: Double, widthMin: Int, isStart: Bool = true) -> (startMin: Int, endMin: Int) {
    var start = snapToQuarter(targetStartMin)
    // End caps one tick short of midnight, same rule as the end handle.
    let maxStart = TimelineConstants.absoluteEnd - TimelineConstants.snap - widthMin
    start = max(TimelineConstants.absoluteStart, min(maxStart, start))
    return (start, start + widthMin)
}

// MARK: - Entry geometry

/// Minutes-since-midnight of an entry's end, treating a next-day rollover as
/// 24:00 (so a slider ending "next day 00:00" displays at the far right rather
/// than wrapping to 4:30 AM). Open entries fall back to `now`. Mirrors
/// `endMinutesForEntry` + the open-entry case of `drawEntryOnTimeline`.
func entryEndMinutes(_ e: EntryRecord, now: Date = Date(),
                     calendar: Calendar = DomainCalendar.shared) -> Int {
    guard let end = e.endTime else { return minutesOfDay(now, calendar: calendar) }
    if !e.date.isEmpty {
        let endLocal = formatLocalDate(end, calendar: calendar)
        if endLocal != e.date { return 24 * 60 }
    }
    return minutesOfDay(end, calendar: calendar)
}

/// The clamped [startMin, endMin] a drawable entry occupies on the strip.
func entryBarSpan(_ e: EntryRecord, now: Date = Date(),
                  calendar: Calendar = DomainCalendar.shared) -> TimelineSegment? {
    guard let start = e.startTime else { return nil }
    let startMin = clampToAbsolute(minutesOfDay(start, calendar: calendar))
    let endMin = clampToAbsolute(entryEndMinutes(e, now: now, calendar: calendar))
    let width = endMin - startMin
    guard width > 0 else { return nil }
    return TimelineSegment(startMin: startMin, widthMin: width)
}

// MARK: - Overtime overlay segments

/// Given a day's drawable entries (sorted ascending by start) and the day's
/// total OT hours, return the clock-minute spans covering the rightmost
/// `dayOt` worked-minutes — the part of the day that reads as overtime. Walks
/// from the last clock-out backward, splitting across entries as needed.
/// Mirrors `app.js otSegments`.
func otSegments(_ sorted: [EntryRecord], dayOt: Double, now: Date = Date(),
                calendar: Calendar = DomainCalendar.shared) -> [TimelineSegment] {
    var remaining = Int((dayOt * 60).rounded())
    if remaining <= 0 { return [] }
    var segs: [TimelineSegment] = []
    for e in sorted.reversed() {
        if remaining <= 0 { break }
        guard let span = entryBarSpan(e, now: now, calendar: calendar) else { continue }
        let take = min(span.widthMin, remaining)
        segs.append(TimelineSegment(startMin: span.startMin + span.widthMin - take, widthMin: take))
        remaining -= take
    }
    return segs
}

// MARK: - Leave bar

/// The leave segment: a bar extending right from the last work-entry end, length
/// = `dayLeave` hours, clamped to midnight. Returns nil when there's no leave or
/// no work entries (leave-only days fall back to a text summary in the UI).
/// Mirrors the `leaveSeg` computation in `buildDayTimeline`.
func leaveSegment(entries: [EntryRecord], dayLeave: Double, now: Date = Date(),
                  calendar: Calendar = DomainCalendar.shared) -> TimelineSegment? {
    guard dayLeave > 0, !entries.isEmpty else { return nil }
    var lastEnd = TimelineConstants.absoluteStart
    for e in entries {
        let em = clampToAbsolute(entryEndMinutes(e, now: now, calendar: calendar))
        if em > lastEnd { lastEnd = em }
    }
    let leaveStart = lastEnd
    let leaveEnd = min(TimelineConstants.absoluteEnd, leaveStart + Int((dayLeave * 60).rounded()))
    guard leaveEnd > leaveStart else { return nil }
    return TimelineSegment(startMin: leaveStart, widthMin: leaveEnd - leaveStart)
}

// MARK: - Scale fitting

/// Fit a scale around a set of bars, starting from the default window and
/// extending (clamped to the absolute bounds) by `scalePad` on each side.
/// Mirrors the fit pass in `app.js reflowList`. Pass every drawable bar across
/// all the days that share a strip (the whole pay period) so they share one
/// comparable horizontal scale.
func fitScale(bars: [TimelineSegment], base: TimelineScale = .default) -> TimelineScale {
    var startMin = base.startMin
    var endMin = base.endMin
    for b in bars {
        startMin = min(startMin, max(TimelineConstants.absoluteStart, b.startMin - TimelineConstants.scalePad))
        endMin = max(endMin, min(TimelineConstants.absoluteEnd, b.startMin + b.widthMin + TimelineConstants.scalePad))
    }
    return TimelineScale(startMin: startMin, endMin: endMin)
}

/// During an active drag the scale must only ever expand (never contract), so
/// the page doesn't shift under the user's finger; it settles to the tight fit
/// on release. Mirrors `reflowList`'s `allowContract: false` branch.
func expandedScale(_ fit: TimelineScale, notSmallerThan current: TimelineScale) -> TimelineScale {
    TimelineScale(startMin: min(fit.startMin, current.startMin),
                  endMin: max(fit.endMin, current.endMin))
}
