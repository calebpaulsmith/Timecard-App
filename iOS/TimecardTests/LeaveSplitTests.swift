import XCTest
@testable import Timecard

/// Tests for `Domain/LeaveSplit.swift` — the "work wraps around leave" plan
/// behind the leave drag-to-place (LOGIC-FREEZE §3): split an entry the block
/// lands inside, trim edge overlaps, delete a fully-covered entry, and heal a
/// previous split when the block moves so the hole follows the leave.
final class LeaveSplitTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    private let date = "2026-05-04"

    private func entry(_ id: String, _ sh: Int, _ sm: Int, _ eh: Int, _ em: Int,
                       lunch: Int = 0, payKind: PayKind = .auto) -> EntryRecord {
        EntryRecord(id: id, date: date,
                    startTime: buildDateTime(date, hour24: sh, minute: sm),
                    endTime: buildDateTime(date, hour24: eh, minute: em),
                    lunchMinutes: lunch, payKind: payKind)
    }

    private func span(_ e: EntryRecord) -> (start: Int, end: Int) {
        (minutesOfDay(e.startTime!), entryEndMinutes(e))
    }

    // MARK: - Split (the headline case)

    /// The user's exact scenario: working 8:00–4:30 (30 lunch → 8h paid), drag
    /// 2h of leave onto 9–11 → work splits to 8–9 and 11–4:30 = 6h paid.
    func testLeaveInsideWorkdaySplitsIt() {
        let e = entry("a", 8, 0, 16, 30, lunch: 30)
        let plan = leavePlacementPlan(entries: [e], date: date, leaveMinutes: 120,
                                      newStartMin: 9 * 60, makeId: { "\($0)2" })
        XCTAssertEqual(plan.deleteIds, [])
        XCTAssertEqual(plan.upserts.count, 2)
        let first = plan.upserts[0], second = plan.upserts[1]
        XCTAssertEqual(first.id, "a", "first piece keeps the entry's id")
        XCTAssertEqual(span(first).start, 480)
        XCTAssertEqual(span(first).end, 540)
        XCTAssertEqual(first.lunchMinutes, 0, "lunch band (mid-entry) is in the later piece")
        XCTAssertEqual(second.id, "a2")
        XCTAssertEqual(span(second).start, 660)
        XCTAssertEqual(span(second).end, 990)
        XCTAssertEqual(second.lunchMinutes, 30, "the single lunch deduction is preserved")
        XCTAssertEqual(first.paidHours + second.paidHours, 6, accuracy: 1e-9,
                       "1h + (5.5h − 0.5 lunch) = 6h worked around 2h of leave")
    }

    /// When the leave swallows the lunch midpoint, the lunch goes to the longer piece.
    func testSplitLunchFallsToLongerPieceWhenMidpointCovered() {
        let e = entry("a", 8, 0, 16, 30, lunch: 30)   // mid 12:15
        let plan = leavePlacementPlan(entries: [e], date: date, leaveMinutes: 120,
                                      newStartMin: 12 * 60, makeId: { "\($0)2" })
        XCTAssertEqual(plan.upserts.count, 2)
        XCTAssertEqual(plan.upserts[0].lunchMinutes, 30, "8–12 (4h) outweighs 14–16:30 (2.5h)")
        XCTAssertEqual(plan.upserts[1].lunchMinutes, 0)
    }

    /// Pieces inherit the entry's classification (a credit entry splits into
    /// two credit pieces).
    func testSplitPreservesPayKind() {
        let e = entry("a", 8, 0, 16, 0, payKind: .credit)
        let plan = leavePlacementPlan(entries: [e], date: date, leaveMinutes: 60,
                                      newStartMin: 10 * 60, makeId: { "\($0)2" })
        XCTAssertEqual(plan.upserts.map(\.payKind), [.credit, .credit])
    }

    // MARK: - Trim / cover / miss

    func testLeaveOverStartTrimsEntryStart() {
        let e = entry("a", 8, 0, 16, 0, lunch: 30)
        let plan = leavePlacementPlan(entries: [e], date: date, leaveMinutes: 120,
                                      newStartMin: 7 * 60)
        XCTAssertEqual(plan.upserts.count, 1)
        XCTAssertEqual(span(plan.upserts[0]).start, 540, "work starts when the leave ends")
        XCTAssertEqual(span(plan.upserts[0]).end, 960)
        XCTAssertEqual(plan.upserts[0].lunchMinutes, 30, "trim keeps the lunch")
    }

    func testLeaveOverEndTrimsEntryEnd() {
        let e = entry("a", 8, 0, 16, 0)
        let plan = leavePlacementPlan(entries: [e], date: date, leaveMinutes: 120,
                                      newStartMin: 15 * 60)
        XCTAssertEqual(plan.upserts.count, 1)
        XCTAssertEqual(span(plan.upserts[0]).end, 900, "work ends where the leave starts")
    }

    func testLeaveCoveringEntryDeletesIt() {
        let e = entry("a", 9, 0, 10, 0)
        let plan = leavePlacementPlan(entries: [e], date: date, leaveMinutes: 480,
                                      newStartMin: 8 * 60)
        XCTAssertEqual(plan.upserts, [])
        XCTAssertEqual(plan.deleteIds, ["a"])
    }

    func testNoOverlapMakesNoChanges() {
        let e = entry("a", 8, 0, 12, 0)
        // Abutting exactly at the end (12:00–14:00) is not an overlap.
        let plan = leavePlacementPlan(entries: [e], date: date, leaveMinutes: 120,
                                      newStartMin: 12 * 60)
        XCTAssertTrue(plan.isEmpty)
    }

    /// Open (in-progress) and incomplete entries have no fixed span — never touched.
    func testOpenAndIncompleteEntriesUntouched() {
        var open = entry("open", 8, 0, 16, 0)
        open.endTime = nil
        var bad = entry("bad", 8, 0, 16, 0)
        bad.incomplete = true
        let plan = leavePlacementPlan(entries: [open, bad], date: date, leaveMinutes: 120,
                                      newStartMin: 9 * 60)
        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: - Heal (moving the block off a previous split)

    func testMovingLeaveHealsOldSplitThenCarvesNew() {
        // A previous drop at 9:00 split the 8–16:30 day into 8–9 + 11–16:30.
        let p1 = entry("a", 8, 0, 9, 0)
        let p2 = entry("a2", 11, 0, 16, 30, lunch: 30)
        // Move the 2h block to 14:00: the old hole closes, a new one opens.
        let plan = leavePlacementPlan(entries: [p1, p2], date: date, leaveMinutes: 120,
                                      newStartMin: 14 * 60, oldStartMin: 9 * 60,
                                      makeId: { "\($0)-new" })
        XCTAssertEqual(plan.deleteIds, ["a2"], "the healed-away second piece is removed")
        XCTAssertEqual(plan.upserts.count, 2)
        let first = plan.upserts[0], second = plan.upserts[1]
        XCTAssertEqual(first.id, "a")
        XCTAssertEqual(span(first).start, 480)
        XCTAssertEqual(span(first).end, 840, "merged day re-split at the new spot")
        XCTAssertEqual(first.lunchMinutes, 30, "merged lunch rides the piece with the lunch band")
        XCTAssertEqual(second.id, "a-new")
        XCTAssertEqual(span(second).start, 960)
        XCTAssertEqual(span(second).end, 990)
        XCTAssertEqual(first.paidHours + second.paidHours, 6, accuracy: 1e-9,
                       "still 6h worked — the hole moved instead of multiplying")
    }

    func testHealSkippedWhenPiecesNoLongerAbut() {
        // The user dragged a handle since the split — the signature is gone.
        let p1 = entry("a", 8, 0, 8, 45)
        let p2 = entry("a2", 11, 0, 16, 30)
        XCTAssertNil(healAroundLeave(entries: [p1, p2], leaveStartMin: 540, leaveEndMin: 660))
    }

    func testHealRequiresMatchingPayKind() {
        let p1 = entry("a", 8, 0, 9, 0, payKind: .auto)
        let p2 = entry("a2", 11, 0, 16, 30, payKind: .overtime)
        XCTAssertNil(healAroundLeave(entries: [p1, p2], leaveStartMin: 540, leaveEndMin: 660))
    }

    // MARK: - Preview application

    func testApplyPlanReplacesAndSorts() {
        let a = entry("a", 8, 0, 16, 30, lunch: 30)
        let b = entry("b", 6, 0, 7, 0)
        let plan = leavePlacementPlan(entries: [a, b], date: date, leaveMinutes: 120,
                                      newStartMin: 9 * 60, makeId: { "\($0)2" })
        let out = applyLeavePlacementPlan(plan, to: [a, b])
        XCTAssertEqual(out.map(\.id), ["b", "a", "a2"], "untouched b stays; a is split in place")
        XCTAssertEqual(applyLeavePlacementPlan(LeavePlacementPlan(), to: [a, b]).map(\.id), ["a", "b"],
                       "empty plan returns the list untouched")
    }
}
