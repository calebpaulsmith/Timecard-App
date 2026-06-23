import XCTest
@testable import Timecard

final class EntryEditingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    // MARK: - autoLunchMinutes

    func testAutoLunchDeductsAtFourHours() {
        let start = buildDateTime("2026-05-04", hour24: 9, minute: 0)
        XCTAssertEqual(autoLunchMinutes(start: start, end: buildDateTime("2026-05-04", hour24: 13, minute: 0)), 30,
                       "exactly 4h span deducts lunch (>= threshold)")
        XCTAssertEqual(autoLunchMinutes(start: start, end: buildDateTime("2026-05-04", hour24: 18, minute: 30)), 30)
    }

    func testAutoLunchNoneUnderFourHours() {
        let start = buildDateTime("2026-05-04", hour24: 9, minute: 0)
        XCTAssertEqual(autoLunchMinutes(start: start, end: buildDateTime("2026-05-04", hour24: 12, minute: 0)), 0)
    }

    func testAutoLunchFromSpanMinutes() {
        XCTAssertEqual(autoLunchMinutes(spanMinutes: 240), 30, "exactly 4h deducts")
        XCTAssertEqual(autoLunchMinutes(spanMinutes: 239), 0, "just under 4h does not")
        XCTAssertEqual(autoLunchMinutes(spanMinutes: 510), 30, "8.5h deducts 30")
        XCTAssertEqual(autoLunchMinutes(spanMinutes: 0), 0)
    }

    // MARK: - clock <-> minutes round trips

    func testClockMinuteConversions() {
        XCTAssertEqual(minutesFromClock(hour12: 12, minute: 0, isPM: false), 0, "12:00 AM = midnight")
        XCTAssertEqual(minutesFromClock(hour12: 12, minute: 0, isPM: true), 12 * 60, "12:00 PM = noon")
        XCTAssertEqual(minutesFromClock(hour12: 9, minute: 15, isPM: false), 9 * 60 + 15)
        XCTAssertEqual(minutesFromClock(hour12: 6, minute: 45, isPM: true), 18 * 60 + 45)

        for m in [0, 555, 720, 990, 1125, 1439] {
            let p = clockFromMinutes(m)
            XCTAssertEqual(minutesFromClock(hour12: p.hour12, minute: p.minute, isPM: p.isPM), m,
                           "round trip for minute \(m)")
        }
    }

    func testMinutesOfDay() {
        XCTAssertEqual(minutesOfDay(buildDateTime("2026-05-04", hour24: 16, minute: 30)), 16 * 60 + 30)
    }

    // MARK: - scanOpenEntry

    func testScanFindsMostRecentOpenEntry() {
        let now = buildDateTime("2026-05-04", hour24: 12, minute: 0)
        let entries = [
            EntryRecord(id: "done", date: "2026-05-04",
                        startTime: buildDateTime("2026-05-04", hour24: 8, minute: 0),
                        endTime: buildDateTime("2026-05-04", hour24: 9, minute: 0)),
            EntryRecord(id: "open", date: "2026-05-04",
                        startTime: buildDateTime("2026-05-04", hour24: 11, minute: 0)),
        ]
        let scan = scanOpenEntry(entries, now: now)
        XCTAssertEqual(scan.openId, "open")
        XCTAssertTrue(scan.forgottenIds.isEmpty)
    }

    func testScanFlagsForgottenOverSixteenHours() {
        let now = buildDateTime("2026-05-05", hour24: 6, minute: 0)
        let entries = [
            EntryRecord(id: "stale", date: "2026-05-04",
                        startTime: buildDateTime("2026-05-04", hour24: 8, minute: 0)),  // ~22h open
        ]
        let scan = scanOpenEntry(entries, now: now)
        XCTAssertNil(scan.openId, "an entry open > 16h is not the current open entry")
        XCTAssertEqual(scan.forgottenIds, ["stale"])
    }

    func testScanIgnoresCompletedAndIncomplete() {
        let now = buildDateTime("2026-05-04", hour24: 12, minute: 0)
        let entries = [
            EntryRecord(id: "done", date: "2026-05-04",
                        startTime: buildDateTime("2026-05-04", hour24: 8, minute: 0),
                        endTime: buildDateTime("2026-05-04", hour24: 9, minute: 0)),
            EntryRecord(id: "bad", date: "2026-05-04",
                        startTime: buildDateTime("2026-05-04", hour24: 7, minute: 0),
                        incomplete: true),
        ]
        let scan = scanOpenEntry(entries, now: now)
        XCTAssertNil(scan.openId)
        XCTAssertTrue(scan.forgottenIds.isEmpty)
    }
}
