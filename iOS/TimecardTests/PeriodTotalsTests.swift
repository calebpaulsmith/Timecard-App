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
}
