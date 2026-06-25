import XCTest
@testable import Timecard

/// The Default-Schedule editor's "Recurring events" section manages only the
/// biweekly pay-period series it creates. Regression guard: EventKit-synced
/// device events (all stored `source:"local"`) like yearly Google birthdays were
/// leaking into this list and getting mislabeled "Every 2 weeks".
@MainActor
final class ScheduleEventFilterTests: XCTestCase {

    func testOnlyBiweeklySeriesCountAsScheduleEvents() {
        let biweekly = CalEvent(date: "2026-05-04", rrule: "FREQ=WEEKLY;INTERVAL=2")
        let biweeklyByday = CalEvent(date: "2026-05-04", rrule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO")
        let yearlyBirthday = CalEvent(date: "2026-05-04", allDay: true, rrule: "FREQ=YEARLY")
        let weekly = CalEvent(date: "2026-05-04", rrule: "FREQ=WEEKLY")           // interval 1
        let monthly = CalEvent(date: "2026-05-04", rrule: "FREQ=MONTHLY;INTERVAL=2")
        let nonRecurring = CalEvent(date: "2026-05-04")

        XCTAssertTrue(ScheduleViewModel.isBiweeklySchedule(biweekly))
        XCTAssertTrue(ScheduleViewModel.isBiweeklySchedule(biweeklyByday))
        XCTAssertFalse(ScheduleViewModel.isBiweeklySchedule(yearlyBirthday),
                       "yearly Google birthdays must not show as biweekly schedule events")
        XCTAssertFalse(ScheduleViewModel.isBiweeklySchedule(weekly))
        XCTAssertFalse(ScheduleViewModel.isBiweeklySchedule(monthly))
        XCTAssertFalse(ScheduleViewModel.isBiweeklySchedule(nonRecurring))
    }
}
