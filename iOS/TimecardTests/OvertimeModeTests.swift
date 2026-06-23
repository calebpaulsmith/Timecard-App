import XCTest
@testable import Timecard

/// Pure helpers backing the per-period OT control and holiday-day cues.
final class OvertimeModeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    func testResolveOtModeOverrideBeatsDefault() {
        let overrides = ["2026-04-19": false]   // Maxiflex override on one period
        XCTAssertFalse(resolveOtMode(default: true, overrides: overrides, periodStart: "2026-04-19"))
        // An un-overridden period falls back to the default.
        XCTAssertTrue(resolveOtMode(default: true, overrides: overrides, periodStart: "2026-05-03"))
        XCTAssertFalse(resolveOtMode(default: false, overrides: [:], periodStart: "2026-05-03"))
    }

    func testFederalHolidayName() {
        // Christmas 2026 falls on a Friday — no observed shift.
        XCTAssertEqual(federalHolidayName("2026-12-25"), "Christmas Day")
        // A plain workday is not a federal holiday.
        XCTAssertNil(federalHolidayName("2026-05-04"))
    }
}
