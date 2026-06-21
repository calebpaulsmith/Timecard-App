import XCTest
@testable import Timecard

final class HolidayTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    func testFederalHolidays2026() {
        let h = federalHolidays(2026)
        XCTAssertEqual(h.count, 11)
        XCTAssertEqual(h, h.sorted { $0.date < $1.date }, "must be sorted ascending")

        func dateFor(_ prefix: String) -> String? {
            h.first { $0.name.hasPrefix(prefix) }?.date
        }

        XCTAssertEqual(dateFor("New Year's Day"), "2026-01-01")
        XCTAssertEqual(dateFor("Birthday of Martin Luther King"), "2026-01-19")
        XCTAssertEqual(dateFor("Washington's Birthday"), "2026-02-16")
        XCTAssertEqual(dateFor("Memorial Day"), "2026-05-25")
        XCTAssertEqual(dateFor("Juneteenth"), "2026-06-19")
        XCTAssertEqual(dateFor("Labor Day"), "2026-09-07")
        XCTAssertEqual(dateFor("Columbus Day"), "2026-10-12")
        XCTAssertEqual(dateFor("Veterans Day"), "2026-11-11")
        XCTAssertEqual(dateFor("Thanksgiving"), "2026-11-26")
        XCTAssertEqual(dateFor("Christmas"), "2026-12-25")

        // July 4, 2026 is a Saturday → observed Friday July 3.
        let independence = h.first { $0.name.hasPrefix("Independence Day") }
        XCTAssertEqual(independence?.date, "2026-07-03")
        XCTAssertTrue(independence?.name.contains("(observed)") ?? false)
    }
}
