import XCTest
@testable import Timecard

final class MetricsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    func testDailyBarsSplitRegularOtLeave() {
        let period = payPeriodFor(today: parseLocalDate("2026-05-04"), anchor: "2026-05-03")
        let mon = period.days[1]
        let totals = PeriodTotals(worked: 0, ot: 0, leave: 0, total: 0,
                                  byDate: [mon: 9.0], otByDate: [mon: 1.0], leaveByDate: [mon: 2.0],
                                  otDollars: 0)
        let bars = dailyBars(period: period, totals: totals, todayStr: mon)
        XCTAssertEqual(bars.count, 14)
        XCTAssertEqual(bars[1].regular, 8.0, accuracy: 1e-9, "regular = worked − OT")
        XCTAssertEqual(bars[1].ot, 1.0, accuracy: 1e-9)
        XCTAssertEqual(bars[1].leave, 2.0, accuracy: 1e-9)
        XCTAssertTrue(bars[1].isToday)
        XCTAssertFalse(bars[0].isToday)
        XCTAssertEqual(bars[0].regular, 0, accuracy: 1e-9)
    }

    func testDailyBarsClampsOtToWorked() {
        let period = payPeriodFor(today: parseLocalDate("2026-05-04"), anchor: "2026-05-03")
        let d = period.days[0]
        // A holiday day: all worked is OT (worked == ot) → regular 0, never negative.
        let totals = PeriodTotals(worked: 0, ot: 0, leave: 0, total: 0,
                                  byDate: [d: 8.0], otByDate: [d: 8.0], leaveByDate: [:], otDollars: 0)
        let bars = dailyBars(period: period, totals: totals, todayStr: "")
        XCTAssertEqual(bars[0].regular, 0, accuracy: 1e-9)
        XCTAssertEqual(bars[0].ot, 8.0, accuracy: 1e-9)
    }

    func testPeriodsWithPaydateInYearBucketByPaydate() {
        let anchor = "2026-05-03"   // a Sunday
        let periods = periodsWithPaydateInYear(2026, anchor: anchor)
        for p in periods {
            XCTAssertEqual(paydateYear(p), 2026, "every returned period pays in 2026")
        }
        // A federal year has 26 (sometimes 27) paydates.
        XCTAssertTrue((25...27).contains(periods.count), "unexpected count: \(periods.count)")
        // The period ending 2025-12-27 pays 2026-01-08 → counts toward 2026.
        let hasDec27 = periods.contains { formatLocalDate($0.end) == "2025-12-27" }
        XCTAssertTrue(hasDec27, "period ending 2025-12-27 should bucket into 2026")
        // ascending by start
        let starts = periods.map { $0.start }
        XCTAssertEqual(starts, starts.sorted())
    }
}
