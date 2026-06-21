import XCTest
@testable import Maxiflex

final class PayPeriodTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    func testCurrentPeriodWindow() {
        let p = payPeriodFor(today: parseLocalDate("2026-04-25"), anchor: "2026-04-19")
        XCTAssertEqual(formatLocalDate(p.start), "2026-04-19")
        XCTAssertEqual(formatLocalDate(p.end), "2026-05-02")
        XCTAssertEqual(p.days.first, "2026-04-19")
        XCTAssertEqual(p.days.last, "2026-05-02")
        XCTAssertEqual(p.days.count, 14)
        XCTAssertEqual(p.dayIndex, 6)
    }

    // Documented parity example: anchor 2026-04-19 → that period is 2026-PP08.
    func testNamingPP08() {
        let p = payPeriodFor(today: parseLocalDate("2026-04-19"), anchor: "2026-04-19")
        XCTAssertEqual(payPeriodName(p, anchor: "2026-04-19"), "2026-PP08")
    }

    // Documented parity example: period ending 2025-12-27 → 2025-PP25,
    // paydate 2026-01-08 (counts toward 2026 YTD).
    func testNamingPP25AndPaydate() {
        let p = payPeriodFor(today: parseLocalDate("2025-12-20"), anchor: "2026-04-19")
        XCTAssertEqual(formatLocalDate(p.start), "2025-12-14")
        XCTAssertEqual(formatLocalDate(p.end), "2025-12-27")
        XCTAssertEqual(payPeriodName(p, anchor: "2026-04-19"), "2025-PP25")
        XCTAssertEqual(formatLocalDate(paydateFor(p)), "2026-01-08")
        XCTAssertEqual(paydateYear(p), 2026)
    }

    func testOffset() {
        let prev = payPeriodOffset(today: parseLocalDate("2026-04-25"), anchor: "2026-04-19", offset: -1)
        XCTAssertEqual(formatLocalDate(prev.start), "2026-04-05")
        let next = payPeriodOffset(today: parseLocalDate("2026-04-25"), anchor: "2026-04-19", offset: 1)
        XCTAssertEqual(formatLocalDate(next.start), "2026-05-03")
    }

    func testIsSunday() {
        XCTAssertTrue(isSunday("2026-04-19"))
        XCTAssertFalse(isSunday("2026-04-20"))
    }

    // A period spanning US spring-forward (2026-03-08) must still be 14 whole days.
    func testDSTSpanCountsWholeDays() {
        let p = payPeriodFor(today: parseLocalDate("2026-03-10"), anchor: "2026-04-19")
        XCTAssertEqual(formatLocalDate(p.start), "2026-03-08")
        XCTAssertEqual(formatLocalDate(p.end), "2026-03-21")
        XCTAssertEqual(p.days.count, 14)
        XCTAssertEqual(daysBetween(p.start, p.end), 13)
        XCTAssertEqual(p.dayIndex, 2)
    }

    func testFloorAndCeilDiv() {
        XCTAssertEqual(floorDiv(-1, 14), -1)
        XCTAssertEqual(floorDiv(-40, 14), -3)
        XCTAssertEqual(floorDiv(40, 14), 2)
        XCTAssertEqual(ceilDiv(-108, 14), -7)
        XCTAssertEqual(ceilDiv(15, 14), 2)
    }
}
