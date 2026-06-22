import XCTest
@testable import Timecard

/// Parity tests for the RRULE engine ported from `calendar.js`. Pins behavior
/// against the PWA's expand semantics (BYDAY, INTERVAL, COUNT, UNTIL, exdates).
final class RecurrenceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    func testParseAndFormatRoundTrip() {
        let r = parseRRule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=5")
        XCTAssertEqual(r?.freq, "WEEKLY")
        XCTAssertEqual(r?.interval, 2)
        XCTAssertEqual(r?.byday, ["MO", "WE"])
        XCTAssertEqual(r?.count, 5)
        XCTAssertEqual(formatRRule(r), "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=5")
    }

    func testNilRuleEmitsLoneAnchorInWindow() {
        let dates = expandRRule(startDate: "2026-06-10", ruleStr: nil,
                                winStart: "2026-06-01", winEnd: "2026-06-30")
        XCTAssertEqual(dates, ["2026-06-10"])
    }

    func testDailyInterval() {
        let dates = expandRRule(startDate: "2026-06-01", ruleStr: "FREQ=DAILY;INTERVAL=3",
                                winStart: "2026-06-01", winEnd: "2026-06-10")
        XCTAssertEqual(dates, ["2026-06-01", "2026-06-04", "2026-06-07", "2026-06-10"])
    }

    func testWeeklyByDayBiweekly() {
        // Anchor Mon 2026-06-01; every 2 weeks on Mon/Wed.
        let dates = expandRRule(startDate: "2026-06-01", ruleStr: "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE",
                                winStart: "2026-06-01", winEnd: "2026-06-30")
        XCTAssertEqual(dates, ["2026-06-01", "2026-06-03", "2026-06-15", "2026-06-17", "2026-06-29"])
    }

    func testCountStopsAfterN() {
        let dates = expandRRule(startDate: "2026-06-01", ruleStr: "FREQ=DAILY;COUNT=3",
                                winStart: "2026-06-01", winEnd: "2026-12-31")
        XCTAssertEqual(dates, ["2026-06-01", "2026-06-02", "2026-06-03"])
    }

    func testUntilBound() {
        let dates = expandRRule(startDate: "2026-06-01", ruleStr: "FREQ=DAILY;UNTIL=20260603",
                                winStart: "2026-06-01", winEnd: "2026-12-31")
        XCTAssertEqual(dates, ["2026-06-01", "2026-06-02", "2026-06-03"])
    }

    func testExdatesRemoved() {
        let dates = expandRRule(startDate: "2026-06-01", ruleStr: "FREQ=DAILY;COUNT=4",
                                winStart: "2026-06-01", winEnd: "2026-12-31",
                                exdates: ["2026-06-02"])
        XCTAssertEqual(dates, ["2026-06-01", "2026-06-03", "2026-06-04"])
    }

    func testCountConsumedBeforeWindow() {
        // 5 daily occurrences from 06-01; window starts 06-03 → only 3 remain.
        let dates = expandRRule(startDate: "2026-06-01", ruleStr: "FREQ=DAILY;COUNT=5",
                                winStart: "2026-06-03", winEnd: "2026-12-31")
        XCTAssertEqual(dates, ["2026-06-03", "2026-06-04", "2026-06-05"])
    }

    func testExpandSeriesCarriesMarkers() {
        let series = CalEvent(id: "s1", date: "2026-06-01", title: "Standup",
                              rrule: "FREQ=DAILY;COUNT=2")
        let occ = expandSeries(series, winStart: "2026-06-01", winEnd: "2026-06-30")
        XCTAssertEqual(occ.count, 2)
        XCTAssertEqual(occ[0].date, "2026-06-01")
        XCTAssertEqual(occ[1].date, "2026-06-02")
        XCTAssertTrue(occ.allSatisfy { $0.occurrenceOf == "s1" && $0.seriesDate == "2026-06-01" })
    }

    func testStackEventsLanes() {
        let a = CalEvent(id: "a", date: "2026-06-01", startMin: 540, endMin: 600)   // 9–10
        let b = CalEvent(id: "b", date: "2026-06-01", startMin: 570, endMin: 630)   // 9:30–10:30 (overlaps a)
        let c = CalEvent(id: "c", date: "2026-06-01", startMin: 600, endMin: 660)   // 10–11 (fits lane 0 after a)
        let (laneOf, count) = stackEvents([a, b, c])
        XCTAssertEqual(count, 2)
        XCTAssertEqual(laneOf["a"], 0)
        XCTAssertEqual(laneOf["b"], 1)
        XCTAssertEqual(laneOf["c"], 0)
    }
}
