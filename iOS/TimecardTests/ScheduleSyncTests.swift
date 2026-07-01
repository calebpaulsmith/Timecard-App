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
        // Wednesday (index 3) → Work AND a 2h leave item. 2h (< 8h) alongside work
        // is a TIMED block placed right after the work day, not an all-day event.
        XCTAssertNotNil(items.first { $0.key == "w:2026-06-24" })
        let lv = items.first { $0.key == "l:2026-06-24" }
        XCTAssertEqual(lv?.allDay, false)
        XCTAssertEqual(lv?.startMin, 1050)
        XCTAssertEqual(lv?.endMin, 1170)
        XCTAssertEqual(lv?.title, "Leave (2h)")
        // Saturday (index 6) → 4h leave, no work → still timed (under the 8h
        // whole-day threshold), anchored at the slot's scheduled start.
        let sat = items.first { $0.key == "l:2026-06-27" }
        XCTAssertEqual(sat?.allDay, false)
        XCTAssertEqual(sat?.startMin, 540)
        XCTAssertNil(items.first { $0.key == "w:2026-06-27" })
    }

    /// A day the user has actually edited (touched) wins over the default slot:
    /// leave-only actual data → the schedule syncs leave, not the default shift.
    func testActualDataOverridesDefaultSchedule() {
        let mon = "2026-06-22"     // index 1: default is a 540–1050 work day
        let items = buildScheduleSyncItems(
            schedule: sampleSchedule(), periodStart: parseLocalDate("2026-06-21"),
            periodsAhead: 1, holidays: [:],
            actualLeave: [mon: ScheduleLeaveInput(minutes: 480, startMin: nil)],
            touchedDates: [mon])
        // No work (the actual day has none) and an all-day 8h Leave block.
        XCTAssertNil(items.first { $0.key == "w:\(mon)" })
        let lv = items.first { $0.key == "l:\(mon)" }
        XCTAssertEqual(lv?.allDay, true)
        XCTAssertEqual(lv?.title, "Leave (8h)")
        XCTAssertEqual(lv?.isLeave, true)
    }

    /// A full day off = 8h+ leave and no work → all-day; a partial 1h leave at a
    /// set time → a timed block at that time.
    func testFullDayVsPartialLeave() {
        let full = "2026-06-22", part = "2026-06-23"
        let items = buildScheduleSyncItems(
            schedule: sampleSchedule(), periodStart: parseLocalDate("2026-06-21"),
            periodsAhead: 1, holidays: [:],
            actualLeave: [full: ScheduleLeaveInput(minutes: 600, startMin: nil),
                          part: ScheduleLeaveInput(minutes: 60, startMin: 990)],  // 4:30pm
            touchedDates: [full, part])
        XCTAssertEqual(items.first { $0.key == "l:\(full)" }?.allDay, true)
        let p = items.first { $0.key == "l:\(part)" }
        XCTAssertEqual(p?.allDay, false)
        XCTAssertEqual(p?.startMin, 990)
        XCTAssertEqual(p?.endMin, 1050)
        XCTAssertEqual(p?.title, "Leave (1h)")
    }

    /// `includeLeave: false` drops every leave item (work + holidays remain).
    func testLeaveCanBeSuppressed() {
        let items = buildScheduleSyncItems(
            schedule: sampleSchedule(), periodStart: parseLocalDate("2026-06-21"),
            periodsAhead: 1, holidays: [:], includeLeave: false)
        XCTAssertTrue(items.allSatisfy { !$0.key.hasPrefix("l:") })
        XCTAssertFalse(items.contains { $0.isLeave })
        XCTAssertNotNil(items.first { $0.key == "w:2026-06-22" })   // work still syncs
    }

    /// Two actual entries on one day → two work items with distinct keys.
    func testMultipleWorkBlocksGetDistinctKeys() {
        let d = "2026-06-22"
        let items = buildScheduleSyncItems(
            schedule: sampleSchedule(), periodStart: parseLocalDate("2026-06-21"),
            periodsAhead: 1, holidays: [:],
            actualWork: [d: [ScheduleWorkBlock(startMin: 540, endMin: 720),
                             ScheduleWorkBlock(startMin: 780, endMin: 1020)]],
            touchedDates: [d])
        XCTAssertEqual(items.first { $0.key == "w:\(d)" }?.endMin, 720)
        XCTAssertEqual(items.first { $0.key == "w:\(d)#1" }?.startMin, 780)
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
