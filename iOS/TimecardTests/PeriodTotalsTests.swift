import XCTest
@testable import Timecard

final class PeriodTotalsTests: XCTestCase {
    let anchor = "2026-05-03"   // a Sunday

    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    /// Mon–Fri (period-day 1–5 and 8–12) scheduled 9:00–17:30 = 8.0h; weekends nil.
    private func weekdaySchedule() -> [ScheduleSlot?] {
        var s = [ScheduleSlot?](repeating: nil, count: 14)
        for i in [1, 2, 3, 4, 5, 8, 9, 10, 11, 12] {
            s[i] = ScheduleSlot(enabled: true, startMin: 9 * 60, endMin: 17 * 60 + 30, leaveHours: 0)
        }
        return s
    }

    private func period() -> PayPeriod {
        payPeriodFor(today: parseLocalDate("2026-05-04"), anchor: anchor)
    }

    /// Build an entry the way the app's creation flow would store it: a concrete
    /// `lunchMinutes` (30 when the span is ≥ 4h, else 0). The totals engine
    /// deducts from the *stored* value — it does not re-derive lunch — so tests
    /// must model that, mirroring how the PWA persists entries.
    private func entry(_ date: String, _ sh: Int, _ sm: Int, _ eh: Int, _ em: Int,
                       ot: Bool = false) -> EntryRecord {
        let start = buildDateTime(date, hour24: sh, minute: sm)
        let end = buildDateTime(date, hour24: eh, minute: em)
        let spanHours = end.timeIntervalSince(start) / 3600
        let lunch = spanHours >= TimeConstants.lunchThresholdHours ? 30 : 0
        return EntryRecord(id: date + "-\(sh)\(sm)", date: date,
                           startTime: start, endTime: end,
                           lunchMinutes: lunch, isOvertime: ot)
    }

    func testEightHourModeOTIsWorkBeyondScheduled() {
        let entries = [
            entry("2026-05-04", 9, 0, 18, 30),   // Mon: 9.0 paid, sched 8 → 1.0 OT
            entry("2026-05-05", 9, 0, 17, 30),   // Tue: 8.0 paid, sched 8 → 0 OT
            entry("2026-05-09", 10, 0, 13, 0),   // Sat: 3.0 paid, unscheduled → all 3 OT
        ]
        let t = periodTotals(period: period(), entries: entries, leaveByDate: [:],
                             schedule: weekdaySchedule(), otMode: true)
        XCTAssertEqual(t.worked, 20, accuracy: 1e-9)
        XCTAssertEqual(t.ot, 4, accuracy: 1e-9)
        XCTAssertEqual(t.otByDate["2026-05-04"], 1)
        XCTAssertEqual(t.otByDate["2026-05-05"], 0)
        XCTAssertEqual(t.otByDate["2026-05-09"], 3)
    }

    func testMaxiflexAutoOTGatedUntil80() {
        let entries = [entry("2026-05-04", 9, 0, 18, 30)]  // 9h on an 8h day, period < 80
        let t = periodTotals(period: period(), entries: entries, leaveByDate: [:],
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.worked, 9, accuracy: 1e-9)
        XCTAssertEqual(t.ot, 0, accuracy: 1e-9, "auto OT is gated until the period exceeds 80h")
    }

    func testMaxiflexExplicitOTAlwaysCounts() {
        let entries = [
            entry("2026-05-04", 9, 0, 17, 30),            // 8.0 regular
            entry("2026-05-04", 19, 0, 21, 0, ot: true),  // 2.0 explicit OT
        ]
        let t = periodTotals(period: period(), entries: entries, leaveByDate: [:],
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.worked, 10, accuracy: 1e-9)
        XCTAssertEqual(t.ot, 2, accuracy: 1e-9, "explicit OT counts even below 80h")
        XCTAssertEqual(t.otByDate["2026-05-04"], 2)
    }

    func testWorkedHolidayIsAllOTAndDoubleTimePays2x() {
        let entries = [entry("2026-05-04", 9, 0, 17, 30)]  // 8.0 paid on a holiday
        let t = periodTotals(period: period(), entries: entries, leaveByDate: [:],
                             schedule: weekdaySchedule(), otMode: true,
                             hourlyRate: 10,
                             holidays: ["2026-05-04": HolidayInfo(doubleTime: true)])
        XCTAssertEqual(t.ot, 8, accuracy: 1e-9, "all worked-holiday hours are OT")
        XCTAssertEqual(t.otDollars, 160, accuracy: 1e-9, "8h × $10 × 2.0 double-time")
    }

    func testLeaveSummedAndIncompleteIgnored() {
        var incomplete = entry("2026-05-06", 9, 0, 17, 0)
        incomplete.incomplete = true
        let t = periodTotals(period: period(),
                             entries: [entry("2026-05-04", 9, 0, 17, 30), incomplete],
                             leaveByDate: ["2026-05-04": 2, "2026-05-07": 8],
                             schedule: weekdaySchedule(), otMode: true)
        XCTAssertEqual(t.worked, 8, accuracy: 1e-9, "incomplete entry contributes 0")
        XCTAssertEqual(t.leave, 10, accuracy: 1e-9)
        XCTAssertEqual(t.total, 18, accuracy: 1e-9)
    }

    // MARK: - Refined Maxiflex (leave counts toward the 80 gate; leave fills schedule)

    /// Core fix: 75h worked (all within an 8h/day Mon–Fri schedule + a 3h
    /// unscheduled Saturday) + 8h leave = 83 total. Worked-only (75) is under 80,
    /// so the OLD worked-only gate gave 0 OT; counting leave pushes the period
    /// over 80, unlocking the 3h beyond-schedule Saturday as OT.
    func testMaxiflexLeaveCountsTowardOver80Gate() {
        var entries: [EntryRecord] = []
        for d in ["2026-05-04", "2026-05-05", "2026-05-06", "2026-05-07", "2026-05-08",
                  "2026-05-11", "2026-05-12", "2026-05-13", "2026-05-14"] {
            entries.append(entry(d, 9, 0, 17, 30))      // 8.0 paid, == schedule → 0 beyond
        }
        entries.append(entry("2026-05-09", 10, 0, 13, 0))   // Sat: 3.0 paid, unscheduled → beyond
        let t = periodTotals(period: period(), entries: entries,
                             leaveByDate: ["2026-05-15": 8],
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.worked, 75, accuracy: 1e-9)
        XCTAssertEqual(t.leave, 8, accuracy: 1e-9)
        XCTAssertEqual(t.total, 83, accuracy: 1e-9)
        XCTAssertEqual(t.ot, 3, accuracy: 1e-9, "leave lifts the period over 80, unlocking beyond-schedule OT")
        XCTAssertEqual(t.otByDate["2026-05-09"] ?? 0, 3, accuracy: 1e-9)
    }

    /// Leave alone never manufactures OT: 80h worked all within schedule + 8h
    /// leave = 88 total (>80), but with no beyond-schedule work there is no OT.
    func testMaxiflexLeaveAloneDoesNotCreateOT() {
        var entries: [EntryRecord] = []
        for d in ["2026-05-04", "2026-05-05", "2026-05-06", "2026-05-07", "2026-05-08",
                  "2026-05-11", "2026-05-12", "2026-05-13", "2026-05-14", "2026-05-15"] {
            entries.append(entry(d, 9, 0, 17, 30))      // 8.0 ×10 = 80, all == schedule
        }
        let t = periodTotals(period: period(), entries: entries,
                             leaveByDate: ["2026-05-16": 8],   // Sat leave, unscheduled
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.worked, 80, accuracy: 1e-9)
        XCTAssertEqual(t.total, 88, accuracy: 1e-9)
        XCTAssertEqual(t.ot, 0, accuracy: 1e-9, "over 80 only via leave + no beyond-schedule work → no OT")
    }

    /// Leave fills the schedule: on a scheduled 8h day the user takes 8h leave
    /// AND works 2h; the leave consumes the schedule, so the 2 worked hours are
    /// beyond-schedule OT (period is over 80).
    func testMaxiflexLeaveFillsScheduleSoExtraWorkIsOT() {
        var entries: [EntryRecord] = []
        for d in ["2026-05-04", "2026-05-05", "2026-05-06", "2026-05-07", "2026-05-08",
                  "2026-05-11", "2026-05-12", "2026-05-13", "2026-05-14"] {
            entries.append(entry(d, 9, 0, 17, 30))      // 8.0 ×9 = 72
        }
        entries.append(entry("2026-05-15", 9, 0, 11, 0))   // Fri: 2h worked atop 8h leave
        let t = periodTotals(period: period(), entries: entries,
                             leaveByDate: ["2026-05-15": 8],
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.worked, 74, accuracy: 1e-9)
        XCTAssertEqual(t.total, 82, accuracy: 1e-9)
        XCTAssertEqual(t.otByDate["2026-05-15"] ?? 0, 2, accuracy: 1e-9,
                       "8h leave fills the 8h schedule; the extra 2h worked is beyond-schedule OT")
        XCTAssertEqual(t.ot, 2, accuracy: 1e-9)
    }

    /// Leave counts toward the 80h target in Maxiflex mode too — `total` is
    /// worked + leave regardless of OT mode (the UI's progress/hours-left/pace
    /// read `total`, so leave must be in it). Guards the iOS display fix.
    func testLeaveCountsTowardTotalInMaxiflex() {
        let t = periodTotals(period: period(),
                             entries: [entry("2026-05-04", 9, 0, 17, 30)],   // 8h worked
                             leaveByDate: ["2026-05-05": 8],                  // 8h leave
                             schedule: weekdaySchedule(), otMode: false)      // Maxiflex
        XCTAssertEqual(t.worked, 8, accuracy: 1e-9)
        XCTAssertEqual(t.leave, 8, accuracy: 1e-9)
        XCTAssertEqual(t.total, 16, accuracy: 1e-9, "leave is part of the total in maxiflex")
        XCTAssertEqual(t.ot, 0, accuracy: 1e-9, "leave does not trigger maxiflex OT")
    }
}
