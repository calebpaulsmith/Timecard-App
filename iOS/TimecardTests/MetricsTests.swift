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

    func testDailyBarsSplitsCreditOutOfRegular() {
        let period = payPeriodFor(today: parseLocalDate("2026-05-04"), anchor: "2026-05-03")
        let d = period.days[2]
        // 10h worked: 1h OT + 2h credit → 7h regular, no negatives.
        let totals = PeriodTotals(worked: 0, ot: 0, leave: 0, total: 0,
                                  byDate: [d: 10.0], otByDate: [d: 1.0], leaveByDate: [:],
                                  otDollars: 0, credit: 0, creditByDate: [d: 2.0])
        let bars = dailyBars(period: period, totals: totals, todayStr: "")
        XCTAssertEqual(bars[2].ot, 1.0, accuracy: 1e-9)
        XCTAssertEqual(bars[2].credit, 2.0, accuracy: 1e-9)
        XCTAssertEqual(bars[2].regular, 7.0, accuracy: 1e-9, "regular = worked − OT − credit")
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

    // MARK: - Second chart

    func testPeriodStartsWithDataDedupesAndSorts() {
        let anchor = "2026-05-03"
        // Two dates in the same period + one in the previous period.
        let periods = periodStartsWithData(entryDates: ["2026-05-04", "2026-05-10", "2026-04-25"],
                                           anchor: anchor)
        XCTAssertEqual(periods.count, 2, "two distinct periods")
        let starts = periods.map { formatLocalDate($0.start) }
        XCTAssertEqual(starts, starts.sorted(), "ascending by start")
        XCTAssertEqual(starts.last, "2026-05-03", "the 05-04/05-10 period")
    }

    func testSelectRangeEightPPTakesLastEight() {
        let anchor = "2026-05-03"
        // 10 consecutive periods worth of entry dates (one per period start).
        let dates = (0..<10).map { i -> String in
            let p = payPeriodOffset(today: parseLocalDate("2026-05-04"), anchor: anchor, offset: -i)
            return formatLocalDate(p.start)
        }
        let all = periodStartsWithData(entryDates: dates, anchor: anchor)
        XCTAssertEqual(all.count, 10)
        let chosen = selectRange(all, range: .eightPP, today: parseLocalDate("2026-05-04"))
        XCTAssertEqual(chosen.count, 8, "8 PP keeps the most recent 8")
        XCTAssertEqual(chosen.map { $0.start }, Array(all.suffix(8)).map { $0.start })
    }

    func testSelectRangeYtdBucketsByPaydateYear() {
        let anchor = "2025-12-14" // a Sunday
        // Period ending 2025-12-27 pays 2026-01-08 → YTD 2026 includes it.
        let all = periodStartsWithData(entryDates: ["2025-12-20", "2026-01-10"], anchor: anchor)
        let chosen = selectRange(all, range: .ytd, today: parseLocalDate("2026-02-01"))
        XCTAssertTrue(chosen.allSatisfy { paydateYear($0) == 2026 })
        XCTAssertTrue(chosen.contains { formatLocalDate($0.end) == "2025-12-27" })
    }

    func testPaceSeriesCumulativeAndIdeal() {
        let ideal = paceIdealSeries()
        XCTAssertEqual(ideal.count, 14)
        XCTAssertEqual(ideal.last?.value ?? 0, 80, accuracy: 1e-9, "day 14 ideal = 80")
        XCTAssertEqual(ideal[6].value, 40, accuracy: 1e-9, "day 7 ideal = 40")

        // Two days of 8h worked + 1h leave each → cumulative 9, 18; stops at dayIndex.
        let bars = [
            DayBar(date: "d0", label: "1", regular: 8, ot: 0, credit: 0, leave: 1, isToday: false),
            DayBar(date: "d1", label: "2", regular: 8, ot: 0, credit: 0, leave: 1, isToday: false),
            DayBar(date: "d2", label: "3", regular: 8, ot: 0, credit: 0, leave: 1, isToday: false),
        ]
        let actual = paceActualSeries(bars: bars, dayIndex: 1)
        XCTAssertEqual(actual.count, 2, "only through dayIndex")
        XCTAssertEqual(actual[0].value, 9, accuracy: 1e-9)
        XCTAssertEqual(actual[1].value, 18, accuracy: 1e-9)
    }
}
