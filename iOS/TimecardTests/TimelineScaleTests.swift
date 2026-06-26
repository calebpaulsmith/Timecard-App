import XCTest
@testable import Timecard

/// Parity tests for the day-timeline scale math (`Domain/TimelineScale.swift`),
/// the heart of the draggable pay-period strip. Expected values are computed by
/// hand from the PWA's `app.js` for the default scale {345, 1095}:
///   cs=540, ce=870, preMin=195, coreMin=330, postMin=225, nonCore=420
///   coreW=30, preW=32.5, postW=37.5  (preW+coreW+postW = 100)
final class TimelineScaleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    private let scale = TimelineScale.default
    private let eps = 1e-9

    // MARK: - minToPct boundaries + known points

    func testMinToPctBoundaries() {
        XCTAssertEqual(minToPct(345, scale), 0, accuracy: eps, "at window start")
        XCTAssertEqual(minToPct(300, scale), 0, accuracy: eps, "before window clamps to 0")
        XCTAssertEqual(minToPct(1095, scale), 100, accuracy: eps, "at window end")
        XCTAssertEqual(minToPct(1200, scale), 100, accuracy: eps, "after window clamps to 100")
    }

    func testMinToPctKnownPoints() {
        XCTAssertEqual(minToPct(540, scale), 32.5, accuracy: eps, "core start = end of pre band")
        XCTAssertEqual(minToPct(870, scale), 62.5, accuracy: eps, "core end = pre+core")
        XCTAssertEqual(minToPct(442.5, scale), 16.25, accuracy: eps, "mid pre band")
        XCTAssertEqual(minToPct(705, scale), 47.5, accuracy: eps, "mid core band")
    }

    func testMinToPctMonotonic() {
        var prev = -1.0
        for m in stride(from: 345, through: 1095, by: 5) {
            let p = minToPct(Double(m), scale)
            XCTAssertGreaterThanOrEqual(p, prev, "non-decreasing at \(m)")
            prev = p
        }
    }

    func testCoreIsCompressed() {
        // 1 minute in the core occupies less width than 1 minute in the edges.
        let corePerMin = minToPct(541, scale) - minToPct(540, scale)
        let edgePerMin = minToPct(346, scale) - minToPct(345, scale)
        XCTAssertLessThan(corePerMin, edgePerMin, "core minutes are visually compressed")
    }

    // MARK: - pctToMin inverse

    func testPctToMinKnownPoints() {
        XCTAssertEqual(pctToMin(0, scale), 345, accuracy: eps)
        XCTAssertEqual(pctToMin(100, scale), 1095, accuracy: eps)
        XCTAssertEqual(pctToMin(32.5, scale), 540, accuracy: eps)
        XCTAssertEqual(pctToMin(62.5, scale), 870, accuracy: eps)
        XCTAssertEqual(pctToMin(16.25, scale), 442.5, accuracy: eps)
        XCTAssertEqual(pctToMin(47.5, scale), 705, accuracy: eps)
    }

    func testRoundTripMinPctMin() {
        for m in [346, 442, 540, 600, 705, 870, 1000, 1094] {
            let back = pctToMin(minToPct(Double(m), scale), scale)
            XCTAssertEqual(back, Double(m), accuracy: 1e-6, "round trip at \(m)")
        }
    }

    // MARK: - clamp + snap

    func testClampToAbsolute() {
        XCTAssertEqual(clampToAbsolute(100), 270, "below 4:30 AM clamps up")
        XCTAssertEqual(clampToAbsolute(2000), 1440, "after midnight clamps down")
        XCTAssertEqual(clampToAbsolute(600), 600, "in-range unchanged")
    }

    func testSnapToQuarter() {
        XCTAssertEqual(snapToQuarter(502), 495, "rounds down to nearest 15")
        XCTAssertEqual(snapToQuarter(503), 510, "rounds up to nearest 15")
        XCTAssertEqual(snapToQuarter(7.5), 15, ".5 rounds away from zero")
        XCTAssertEqual(snapToQuarter(600), 600, "already on a tick")
    }

    // MARK: - resolveHandleDrag (the live drag rule)

    func testHandleDragStartCappedBelowEnd() {
        // Drag start toward/over the end (1020); it stays one tick (15) below.
        XCTAssertEqual(resolveHandleDrag(targetMin: 1100, opposite: 1020, isStart: true), 1005)
        XCTAssertEqual(resolveHandleDrag(targetMin: 600.4, opposite: 1020, isStart: true), 600)
        XCTAssertEqual(resolveHandleDrag(targetMin: 100, opposite: 1020, isStart: true), 270,
                       "clamps to absolute start")
    }

    func testHandleDragEndCappedAboveStartAndShortOfMidnight() {
        XCTAssertEqual(resolveHandleDrag(targetMin: 200, opposite: 480, isStart: false), 495,
                       "stays one tick above start")
        XCTAssertEqual(resolveHandleDrag(targetMin: 2000, opposite: 480, isStart: false), 1425,
                       "caps one snap-tick short of midnight (1440-15)")
    }

    // MARK: - resolveBarMove (additive whole-bar drag)

    func testBarMoveKeepsWidthAndClamps() {
        let m1 = resolveBarMove(targetStartMin: 502, widthMin: 240)
        XCTAssertEqual(m1.startMin, 495)
        XCTAssertEqual(m1.endMin, 735, "width preserved")

        let early = resolveBarMove(targetStartMin: 100, widthMin: 120)
        XCTAssertEqual(early.startMin, 270, "clamps to absolute start")
        XCTAssertEqual(early.endMin, 390)

        let late = resolveBarMove(targetStartMin: 1430, widthMin: 120)
        XCTAssertEqual(late.endMin, 1425, "end caps one tick short of midnight")
        XCTAssertEqual(late.startMin, 1305)
    }

    // MARK: - entry geometry

    func testEntryEndMinutesRollover() {
        let e = EntryRecord(id: "x", date: "2026-05-04",
                            startTime: buildDateTime("2026-05-04", hour24: 22, minute: 0),
                            endTime: buildDateTime("2026-05-05", hour24: 0, minute: 0))
        XCTAssertEqual(entryEndMinutes(e), 1440, "next-day end reads as midnight (24:00)")
    }

    func testEntryEndMinutesSameDay() {
        let e = EntryRecord(id: "x", date: "2026-05-04",
                            startTime: buildDateTime("2026-05-04", hour24: 8, minute: 0),
                            endTime: buildDateTime("2026-05-04", hour24: 16, minute: 30))
        XCTAssertEqual(entryEndMinutes(e), 16 * 60 + 30)
    }

    func testEntryBarSpan() {
        let e = EntryRecord(id: "x", date: "2026-05-04",
                            startTime: buildDateTime("2026-05-04", hour24: 8, minute: 0),
                            endTime: buildDateTime("2026-05-04", hour24: 17, minute: 0))
        XCTAssertEqual(entryBarSpan(e), TimelineSegment(startMin: 480, widthMin: 540))
    }

    // MARK: - otSegments

    func testOtSegmentSingleEntry() {
        let e = entry("2026-05-04", 8, 0, 17, 0)
        XCTAssertEqual(otSegments([e], dayOt: 2), [TimelineSegment(startMin: 900, widthMin: 120)],
                       "rightmost 2h of an 8–17 day")
    }

    func testOtSegmentZeroOT() {
        let e = entry("2026-05-04", 8, 0, 17, 0)
        XCTAssertEqual(otSegments([e], dayOt: 0), [])
    }

    func testOtSegmentSpillsAcrossEntries() {
        let a = entry("2026-05-04", 8, 0, 10, 0)   // 480–600 (span 120)
        let b = entry("2026-05-04", 13, 0, 17, 0)  // 780–1020 (span 240)
        // 5h OT = 300 min: 240 from the later entry, 60 from the earlier one.
        XCTAssertEqual(otSegments([a, b], dayOt: 5),
                       [TimelineSegment(startMin: 780, widthMin: 240),
                        TimelineSegment(startMin: 540, widthMin: 60)])
    }

    // MARK: - leaveSegment

    func testLeaveSegmentExtendsPastLastEnd() {
        let e = entry("2026-05-04", 8, 0, 15, 30)  // ends 930
        XCTAssertEqual(leaveSegment(entries: [e], dayLeave: 1),
                       TimelineSegment(startMin: 930, widthMin: 60))
    }

    func testLeaveSegmentNilWhenNoEntriesOrNoLeave() {
        XCTAssertNil(leaveSegment(entries: [], dayLeave: 4))
        XCTAssertNil(leaveSegment(entries: [entry("2026-05-04", 8, 0, 16, 0)], dayLeave: 0))
    }

    func testLeaveSegmentExplicitPlacement() {
        // With a placement, the block starts there (ignoring work entries) and
        // renders even on a leave-only day. 2h leave at 10:00 → 600..720.
        XCTAssertEqual(leaveSegment(entries: [], dayLeave: 2, leaveStartMin: 600),
                       TimelineSegment(startMin: 600, widthMin: 120))
        let e = entry("2026-05-04", 8, 0, 15, 30)  // ends 930 — overridden by placement
        XCTAssertEqual(leaveSegment(entries: [e], dayLeave: 1, leaveStartMin: 480),
                       TimelineSegment(startMin: 480, widthMin: 60))
    }

    // MARK: - fitScale + expandedScale

    func testFitScaleUnchangedForTypicalDay() {
        let bars = [TimelineSegment(startMin: 480, widthMin: 540)]  // 8–17, inside default
        XCTAssertEqual(fitScale(bars: bars), .default)
    }

    func testFitScaleExtendsForLateBar() {
        let bars = [TimelineSegment(startMin: 1140, widthMin: 120)]  // 19:00–21:00
        let s = fitScale(bars: bars)
        XCTAssertEqual(s.startMin, 345, "start unchanged")
        XCTAssertEqual(s.endMin, 1290, "extends to 21:00 + 30 pad")
    }

    func testFitScaleExtendsForEarlyBarClampedToAbsolute() {
        let bars = [TimelineSegment(startMin: 300, widthMin: 60)]  // 5:00–6:00
        let s = fitScale(bars: bars)
        XCTAssertEqual(s.startMin, 270, "5:00 − 30 pad clamps to absolute start 4:30")
    }

    func testExpandedScaleNeverContracts() {
        let current = TimelineScale(startMin: 300, endMin: 1200)
        let tighter = TimelineScale(startMin: 345, endMin: 1095)
        XCTAssertEqual(expandedScale(tighter, notSmallerThan: current), current,
                       "during a drag the scale only expands")
    }

    // MARK: - helpers

    private func entry(_ date: String, _ sh: Int, _ sm: Int, _ eh: Int, _ em: Int) -> EntryRecord {
        EntryRecord(id: UUID().uuidString, date: date,
                    startTime: buildDateTime(date, hour24: sh, minute: sm),
                    endTime: buildDateTime(date, hour24: eh, minute: em))
    }
}
