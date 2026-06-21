import XCTest
@testable import Maxiflex

final class OvertimeAndPaceTests: XCTestCase {
    func testOvertimeModeOff() {
        XCTAssertEqual(overtimeSplit(workedHours: 9, otModeEnabled: false),
                       OvertimeSplit(regular: 9, overtime: 0))
    }

    func test8HourMode() {
        XCTAssertEqual(overtimeSplit(workedHours: 9, otModeEnabled: true),
                       OvertimeSplit(regular: 8, overtime: 1))
        XCTAssertEqual(overtimeSplit(workedHours: 6, otModeEnabled: true),
                       OvertimeSplit(regular: 6, overtime: 0))
        XCTAssertEqual(overtimeSplit(workedHours: 8, otModeEnabled: true),
                       OvertimeSplit(regular: 8, overtime: 0))
    }

    func testWeekendAllOvertime() {
        XCTAssertEqual(overtimeSplit(workedHours: 5, otModeEnabled: true, isWeekend: true),
                       OvertimeSplit(regular: 0, overtime: 5))
    }

    func testMaxiflexDayOvertime() {
        XCTAssertEqual(maxiflexDayOvertime(dayRegularWorked: 10, dayScheduledHours: 8, periodOver80: false), 0)
        XCTAssertEqual(maxiflexDayOvertime(dayRegularWorked: 10, dayScheduledHours: 8, periodOver80: true), 2)
        XCTAssertEqual(maxiflexDayOvertime(dayRegularWorked: 5, dayScheduledHours: 8, periodOver80: true), 0)
        // Unscheduled day (weekend / off): all worked hours are "outside schedule".
        XCTAssertEqual(maxiflexDayOvertime(dayRegularWorked: 4, dayScheduledHours: 0, periodOver80: true), 4)
    }

    func testExpectedAndPace() {
        XCTAssertEqual(expectedByDay(13), 80, accuracy: 1e-9)
        XCTAssertEqual(expectedByDay(6), 40, accuracy: 1e-9)
        XCTAssertEqual(pace(hoursWorked: 40, daysRemaining: 5), 8, accuracy: 1e-9)
        XCTAssertEqual(pace(hoursWorked: 90, daysRemaining: 5), 0, accuracy: 1e-9)
        XCTAssertEqual(pace(hoursWorked: 10, daysRemaining: 0), 0, accuracy: 1e-9)
    }

    func testPaceStatusDeadband() {
        // expectedByDay(6) == 40, ±2h deadband.
        XCTAssertEqual(paceStatus(hoursWorked: 43, dayIndex: 6), .ahead)
        XCTAssertEqual(paceStatus(hoursWorked: 36, dayIndex: 6), .behind)
        XCTAssertEqual(paceStatus(hoursWorked: 41, dayIndex: 6), .onPace)
        XCTAssertEqual(paceStatus(hoursWorked: 42, dayIndex: 6), .onPace)
    }
}
