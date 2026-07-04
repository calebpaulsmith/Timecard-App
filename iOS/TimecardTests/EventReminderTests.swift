import XCTest
@testable import Timecard

final class EventReminderTests: XCTestCase {
    var cal = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = cal
    }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func event(reminderMinutesBefore: Int?, startMin: Int = 9 * 60, allDay: Bool = false,
                        externalId: String? = nil, date: String = "2026-05-10") -> CalEvent {
        CalEvent(date: date, title: "Standup", allDay: allDay, startMin: startMin, endMin: startMin + 60,
                 reminderMinutesBefore: reminderMinutesBefore, externalId: externalId)
    }

    func testNoReminderWhenUnset() {
        let now = at(2026, 5, 10, 7)
        let out = buildEventReminders(events: [event(reminderMinutesBefore: nil)], now: now, calendar: cal)
        XCTAssertTrue(out.isEmpty)
    }

    func testFireDateIsMinutesBeforeStart() {
        let now = at(2026, 5, 10, 7)
        let out = buildEventReminders(events: [event(reminderMinutesBefore: 15)], now: now, calendar: cal)
        XCTAssertEqual(out.first?.fireDate, at(2026, 5, 10, 8, 45), "15 min before a 9am start")
    }

    func testAtTimeOfEventFiresExactlyAtStart() {
        let now = at(2026, 5, 10, 7)
        let out = buildEventReminders(events: [event(reminderMinutesBefore: 0)], now: now, calendar: cal)
        XCTAssertEqual(out.first?.fireDate, at(2026, 5, 10, 9))
    }

    func testCustomLeadTimeInMinutes() {
        let now = at(2026, 5, 10, 7)
        let out = buildEventReminders(events: [event(reminderMinutesBefore: 45)], now: now, calendar: cal)
        XCTAssertEqual(out.first?.fireDate, at(2026, 5, 10, 8, 15))
    }

    func testAllDayEventReminderAnchorsAtMidnight() {
        let now = at(2026, 5, 9, 7)
        let out = buildEventReminders(events: [event(reminderMinutesBefore: 60, allDay: true)], now: now, calendar: cal)
        XCTAssertEqual(out.first?.fireDate, at(2026, 5, 9, 23), "1h before midnight on the event's day")
    }

    func testPastFireDateIsDropped() {
        // Now is already past the 15-min-before mark (8:45) for a 9am event.
        let now = at(2026, 5, 10, 8, 50)
        let out = buildEventReminders(events: [event(reminderMinutesBefore: 15)], now: now, calendar: cal)
        XCTAssertTrue(out.isEmpty)
    }

    func testSyncedEventSkipsLocalNotification() {
        // A device-linked event's reminder is an EKAlarm (set by EventKitSync),
        // not a local notification — buildEventReminders must not double-fire it.
        let now = at(2026, 5, 10, 7)
        let out = buildEventReminders(events: [event(reminderMinutesBefore: 15, externalId: "ek-123")],
                                      now: now, calendar: cal)
        XCTAssertTrue(out.isEmpty)
    }

    func testUntitledEventFallsBackToGenericTitle() {
        let now = at(2026, 5, 10, 7)
        var ev = event(reminderMinutesBefore: 15)
        ev.title = ""
        let out = buildEventReminders(events: [ev], now: now, calendar: cal)
        XCTAssertEqual(out.first?.title, "Event")
    }

    func testStableIdIsPerOccurrenceDate() {
        let now = at(2026, 5, 10, 7)
        let out = buildEventReminders(events: [event(reminderMinutesBefore: 15)], now: now, calendar: cal)
        XCTAssertTrue(out.first?.id.hasSuffix("2026-05-10") ?? false)
    }

    // MARK: eventReminderLeadText

    func testLeadTextFormatting() {
        XCTAssertEqual(eventReminderLeadText(0), "At time of event")
        XCTAssertEqual(eventReminderLeadText(5), "5 min before")
        XCTAssertEqual(eventReminderLeadText(45), "45 min before")
        XCTAssertEqual(eventReminderLeadText(60), "1 hour before")
        XCTAssertEqual(eventReminderLeadText(120), "2 hours before")
        XCTAssertEqual(eventReminderLeadText(24 * 60), "1 day before")
        XCTAssertEqual(eventReminderLeadText(2 * 24 * 60), "2 days before")
    }
}
