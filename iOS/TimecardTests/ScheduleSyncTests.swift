import XCTest
@testable import Timecard

/// Parity tests for the limited-window work-schedule materializer
/// (`buildScheduleSyncItems`), mirroring the PWA's `T.buildScheduleSyncEvents`.
final class ScheduleSyncTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    /// Default Mon–Fri 9:00–17:30 schedule, plus a recurring-leave workday, a
    /// pure-leave off day, and a holiday override.
    private func sampleSchedule() -> [ScheduleSlot?] {
        var s = [ScheduleSlot?](repeating: nil, count: TimeConstants.payPeriodDays)
        for i in [1, 2, 3, 4, 5, 8, 9, 10, 11, 12] {
            s[i] = ScheduleSlot(enabled: true, startMin: 540, endMin: 1050, leaveHours: 0)
        }
        s[3] = ScheduleSlot(enabled: true, startMin: 540, endMin: 1050, leaveHours: 2)  // workday + 2h leave
        s[6] = ScheduleSlot(enabled: false, startMin: 540, endMin: 1050, leaveHours: 4) // pure-leave off day
        return s
    }

    func testWindowSpansExactlyNPeriods() {
        let items = buildScheduleSyncItems(
            schedule: sampleSchedule(), periodStart: parseLocalDate("2026-06-21"),
            periodsAhead: 2, holidays: [:])
        // 2 periods = 28 days; the last scheduled weekday is Fri 2026-07-17.
        XCTAssertEqual(items.map(\.date).max(), "2026-07-17")
        // Nothing lands before the window start or after start+27 days.
        XCTAssertTrue(items.allSatisfy { $0.date >= "2026-06-21" && $0.date <= "2026-07-18" })
    }

    func testWorkAndLeaveItems() {
        let items = buildScheduleSyncItems(
            schedule: sampleSchedule(), periodStart: parseLocalDate("2026-06-21"),
            periodsAhead: 1, holidays: [:])
        // Monday (index 1) → a timed Work item.
        let mon = items.first { $0.key == "w:2026-06-22" }
        XCTAssertEqual(mon?.allDay, false)
        XCTAssertEqual(mon?.startMin, 540)
        XCTAssertEqual(mon?.endMin, 1050)
        XCTAssertEqual(mon?.title, "Work")
        // Wednesday (index 3) → Work AND an all-day 2h leave item.
        XCTAssertNotNil(items.first { $0.key == "w:2026-06-24" })
        let lv = items.first { $0.key == "l:2026-06-24" }
        XCTAssertEqual(lv?.allDay, true)
        XCTAssertEqual(lv?.title, "Leave (2h)")
        // Saturday (index 6) → pure-leave off day: leave only, no work.
        XCTAssertNotNil(items.first { $0.key == "l:2026-06-27" })
        XCTAssertNil(items.first { $0.key == "w:2026-06-27" })
    }

    func testHolidayOverridesWork() {
        // 2026-06-29 is index 8 (a normal Monday workday); a holiday cancels work.
        let items = buildScheduleSyncItems(
            schedule: sampleSchedule(), periodStart: parseLocalDate("2026-06-21"),
            periodsAhead: 1, holidays: ["2026-06-29": "Test Holiday"])
        XCTAssertNil(items.first { $0.key == "w:2026-06-29" })
        let hol = items.first { $0.key == "h:2026-06-29" }
        XCTAssertEqual(hol?.allDay, true)
        XCTAssertEqual(hol?.title, "Holiday — Test Holiday")
    }

    func testPeriodsAheadFloorsAtOne() {
        let items = buildScheduleSyncItems(
            schedule: sampleSchedule(), periodStart: parseLocalDate("2026-06-21"),
            periodsAhead: 0, holidays: [:])
        // Clamped to 1 period — still produces the first week's items.
        XCTAssertFalse(items.isEmpty)
        XCTAssertEqual(items.map(\.date).max(), "2026-07-03")
    }
}
