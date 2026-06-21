import XCTest
@testable import Maxiflex

final class FormattingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    func testFormatHours() {
        XCTAssertEqual(formatHours(0.75), "0.75")
        XCTAssertEqual(formatHours(0.5), "0.5")
        XCTAssertEqual(formatHours(8), "8")
        XCTAssertEqual(formatHours(0.8333), "0.83")
        XCTAssertEqual(formatHours(0), "0")
        XCTAssertEqual(formatHours(80), "80")
    }

    func testFormatMoney() {
        XCTAssertEqual(formatMoney(1234.56), "$1,234.56")
        XCTAssertEqual(formatMoney(5), "$5.00")
        XCTAssertEqual(formatMoney(-5), "-$5.00")
        XCTAssertEqual(formatMoney(0), "$0.00")
        XCTAssertEqual(formatMoney(1234567.8), "$1,234,567.80")
    }

    func testFormatTimeAndMinutes() {
        let d = buildDateTime("2026-04-20", hour24: 13, minute: 5)
        XCTAssertEqual(formatTime(d), "1:05 PM")
        XCTAssertEqual(formatTime(d, use24h: true), "13:05")
        XCTAssertEqual(formatMinutes(0), "12:00 AM")
        XCTAssertEqual(formatMinutes(13 * 60 + 5), "1:05 PM")
        XCTAssertEqual(formatMinutes(13 * 60 + 5, use24h: true), "13:05")
    }

    func testBuildScheduleIcs() {
        var schedule: [ScheduleSlot?] = Array(repeating: nil, count: 14)
        schedule[0] = ScheduleSlot(enabled: true, startMin: 540, endMin: 1050, leaveHours: 0) // 9:00–17:30
        let ics = buildScheduleIcs(schedule: schedule,
                                   periodStart: parseLocalDate("2026-04-19"),
                                   now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(ics.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(ics.contains("RRULE:FREQ=WEEKLY;INTERVAL=2"))
        XCTAssertTrue(ics.contains("DTSTART:20260419T090000"))
        XCTAssertTrue(ics.contains("DTEND:20260419T173000"))
        XCTAssertTrue(ics.contains("UID:tc-sched-work-0@timecard-app"))
        XCTAssertTrue(ics.hasSuffix("END:VCALENDAR\r\n"))
    }

    func testIcsEscapeAndFold() {
        XCTAssertEqual(icsEscape("a,b;c\\d"), "a\\,b\\;c\\\\d")
        let long = String(repeating: "x", count: 200)
        let folded = foldIcsLine(long)
        XCTAssertTrue(folded.contains("\r\n "))
        // Unfolding (strip CRLF+space) restores the original.
        XCTAssertEqual(folded.replacingOccurrences(of: "\r\n ", with: ""), long)
    }
}
