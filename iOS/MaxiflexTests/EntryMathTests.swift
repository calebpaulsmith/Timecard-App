import XCTest
@testable import Maxiflex

final class EntryMathTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    func testNineHourDeductsLunch() {
        let s = buildDateTime("2026-04-20", hour24: 9, minute: 0)
        let e = buildDateTime("2026-04-20", hour24: 18, minute: 0)
        let r = hoursForEntry(start: s, end: e)
        XCTAssertEqual(r.rawHours, 9, accuracy: 1e-9)
        XCTAssertEqual(r.hours, 8.5, accuracy: 1e-9)
        XCTAssertTrue(r.lunchDeducted)
        XCTAssertEqual(r.lunchMinutes, 30, accuracy: 1e-9)
    }

    func testShortShiftNoLunch() {
        let s = buildDateTime("2026-04-20", hour24: 9, minute: 0)
        let e = buildDateTime("2026-04-20", hour24: 12, minute: 0)
        let r = hoursForEntry(start: s, end: e)
        XCTAssertEqual(r.hours, 3, accuracy: 1e-9)
        XCTAssertFalse(r.lunchDeducted)
    }

    func testExplicitLunchOverride() {
        let s = buildDateTime("2026-04-20", hour24: 9, minute: 0)
        let e = buildDateTime("2026-04-20", hour24: 18, minute: 0)
        let r = hoursForEntry(start: s, end: e, lunchMinutes: 60)
        XCTAssertEqual(r.hours, 8, accuracy: 1e-9)
        XCTAssertEqual(r.lunchMinutes, 60, accuracy: 1e-9)
    }

    func testZeroAndNegativeSpans() {
        let s = buildDateTime("2026-04-20", hour24: 9, minute: 0)
        XCTAssertEqual(hoursForEntry(start: s, end: s).hours, 0)
        let earlier = buildDateTime("2026-04-20", hour24: 8, minute: 0)
        XCTAssertEqual(hoursForEntry(start: s, end: earlier).hours, 0)
        XCTAssertEqual(hoursForEntry(start: nil, end: s), .zero)
    }

    func testForgotten() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(isForgotten(start: start, now: start.addingTimeInterval(10 * 3600)))
        XCTAssertTrue(isForgotten(start: start, now: start.addingTimeInterval(17 * 3600)))
    }

    func testRoundToQuarter() {
        let a = buildDateTime("2026-04-20", hour24: 9, minute: 8)
        XCTAssertEqual(formatTime(roundToQuarter(a), use24h: true), "09:15")
        let b = buildDateTime("2026-04-20", hour24: 9, minute: 53)
        XCTAssertEqual(formatTime(roundToQuarter(b), use24h: true), "10:00")
        let c = buildDateTime("2026-04-20", hour24: 9, minute: 22)
        XCTAssertEqual(formatTime(roundToQuarter(c), use24h: true), "09:15")
        let d = buildDateTime("2026-04-20", hour24: 9, minute: 7)
        XCTAssertEqual(formatTime(roundToQuarter(d), use24h: true), "09:00")
    }

    func testProjectedClockOut() {
        let inT = buildDateTime("2026-04-20", hour24: 9, minute: 0)
        XCTAssertEqual(formatTime(projectedClockOut(clockIn: inT, targetHours: 8), use24h: true), "17:30")
        XCTAssertEqual(formatTime(projectedClockOut(clockIn: inT, targetHours: 2), use24h: true), "11:00")
    }
}
