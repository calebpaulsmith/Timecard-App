import XCTest
@testable import Timecard

final class ReminderScheduleTests: XCTestCase {
    let anchor = "2026-05-03"   // a Sunday
    var cal = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = cal
    }

    private func period() -> PayPeriod {
        // 2026-05-03 .. 2026-05-16 (index 0..13).
        payPeriodFor(today: parseLocalDate("2026-05-10", calendar: cal), anchor: anchor, calendar: cal)
    }

    /// A local wall-clock Date in the pinned timezone.
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func specs(now: Date, validation: Int?, workedPlusLeave: Double,
                       openStart: Date?) -> [ReminderSpec] {
        buildReminders(now: now, period: period(), validationDayIndex: validation,
                       workedPlusLeave: workedPlusLeave, openEntryStart: openStart, calendar: cal)
    }

    // MARK: Validation deadline

    func testValidationDeadlineFutureFiresAt9am() {
        let now = at(2026, 5, 10, 12)
        let s = specs(now: now, validation: 12, workedPlusLeave: 80, openStart: nil)
            .first { $0.kind == .validationDeadline }
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.fireDate, at(2026, 5, 15, 9), "fires 9am on the validation day (index 12 = 2026-05-15)")
    }

    func testValidationDeadlinePastIsDropped() {
        let now = at(2026, 5, 10, 12)
        let s = specs(now: now, validation: 3, workedPlusLeave: 80, openStart: nil)
            .first { $0.kind == .validationDeadline }
        XCTAssertNil(s, "a deadline earlier in the period is not re-scheduled")
    }

    func testNoValidationDayNoReminder() {
        let now = at(2026, 5, 10, 12)
        XCTAssertNil(specs(now: now, validation: nil, workedPlusLeave: 80, openStart: nil)
            .first { $0.kind == .validationDeadline })
    }

    // MARK: Pay period ending

    func testPeriodEndingShortFires() {
        let now = at(2026, 5, 10, 12)
        let s = specs(now: now, validation: nil, workedPlusLeave: 73.5, openStart: nil)
            .first { $0.kind == .periodEnding }
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.fireDate, at(2026, 5, 15, 9), "fires 9am the second-to-last day")
        XCTAssertTrue(s?.body.contains("6.5") ?? false, "reports hours short of 80")
    }

    func testPeriodEndingMetIsSilent() {
        let now = at(2026, 5, 10, 12)
        XCTAssertNil(specs(now: now, validation: nil, workedPlusLeave: 80, openStart: nil)
            .first { $0.kind == .periodEnding }, "no nudge once the 80 is met")
    }

    func testPeriodEndingPastIsDropped() {
        let now = at(2026, 5, 16, 12)   // already on the last day
        XCTAssertNil(specs(now: now, validation: nil, workedPlusLeave: 50, openStart: nil)
            .first { $0.kind == .periodEnding })
    }

    // MARK: Forgotten clock-out

    func testForgottenClockOutFires9hAfterStart() {
        let now = at(2026, 5, 10, 12)
        let start = at(2026, 5, 10, 8)          // clocked in at 8am
        let s = specs(now: now, validation: nil, workedPlusLeave: 80, openStart: start)
            .first { $0.kind == .forgottenClockOut }
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.fireDate, at(2026, 5, 10, 17), "9h after an 8am clock-in")
    }

    func testForgottenClockOutAlreadyPastIsDropped() {
        let now = at(2026, 5, 10, 18)
        let start = at(2026, 5, 10, 8)          // 9h mark (5pm) already passed
        XCTAssertNil(specs(now: now, validation: nil, workedPlusLeave: 80, openStart: start)
            .first { $0.kind == .forgottenClockOut })
    }

    func testNoOpenEntryNoForgottenReminder() {
        let now = at(2026, 5, 10, 12)
        XCTAssertNil(specs(now: now, validation: nil, workedPlusLeave: 80, openStart: nil)
            .first { $0.kind == .forgottenClockOut })
    }
}
