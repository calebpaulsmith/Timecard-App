import XCTest
@testable import Timecard

/// Round-trip tests for the events `.ics` codec ported from `calendar.js`.
final class EventsIcsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    func testTimedEventRoundTrip() {
        let ev = CalEvent(id: "e1", date: "2026-06-15", title: "Lunch with Sam",
                          allDay: false, startMin: 12 * 60, endMin: 13 * 60,
                          color: .personal, notes: "bring; the, plan", location: "Cafe")
        let ics = buildEventsIcs([ev])
        XCTAssertTrue(ics.contains("BEGIN:VEVENT"))
        XCTAssertTrue(ics.contains("DTSTART:20260615T120000"))
        XCTAssertTrue(ics.contains("DTEND:20260615T130000"))
        XCTAssertTrue(ics.contains("CATEGORIES:Personal"))

        let parsed = parseEventsIcs(ics)
        XCTAssertEqual(parsed.count, 1)
        let p = parsed[0]
        XCTAssertEqual(p.title, "Lunch with Sam")
        XCTAssertEqual(p.date, "2026-06-15")
        XCTAssertFalse(p.allDay)
        XCTAssertEqual(p.startMin, 12 * 60)
        XCTAssertEqual(p.endMin, 13 * 60)
        XCTAssertEqual(p.color, .personal)
        XCTAssertEqual(p.notes, "bring; the, plan")
        XCTAssertEqual(p.location, "Cafe")
    }

    func testAllDayRoundTrip() {
        let ev = CalEvent(id: "e2", date: "2026-07-04", title: "Holiday", allDay: true, color: .work)
        let ics = buildEventsIcs([ev])
        XCTAssertTrue(ics.contains("DTSTART;VALUE=DATE:20260704"))
        XCTAssertTrue(ics.contains("DTEND;VALUE=DATE:20260705"))   // exclusive next day
        let p = parseEventsIcs(ics)
        XCTAssertEqual(p.count, 1)
        XCTAssertTrue(p[0].allDay)
        XCTAssertEqual(p[0].date, "2026-07-04")
    }

    func testRecurringWithExdate() {
        let ev = CalEvent(id: "e3", date: "2026-06-01", title: "Standup",
                          startMin: 9 * 60, endMin: 9 * 60 + 15,
                          rrule: "FREQ=WEEKLY;BYDAY=MO", exdates: ["2026-06-08"])
        let ics = buildEventsIcs([ev])
        XCTAssertTrue(ics.contains("RRULE:FREQ=WEEKLY;BYDAY=MO"))
        XCTAssertTrue(ics.contains("EXDATE:20260608T090000"))
        let p = parseEventsIcs(ics)
        XCTAssertEqual(p[0].rrule, "FREQ=WEEKLY;BYDAY=MO")
        XCTAssertEqual(p[0].exdates, ["2026-06-08"])
    }

    func testBacklogItemsSkipped() {
        let dated = CalEvent(id: "a", date: "2026-06-01", title: "Has date")
        let backlog = CalEvent(id: "b", date: nil, title: "No date", needsScheduling: true)
        let p = parseEventsIcs(buildEventsIcs([dated, backlog]))
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].title, "Has date")
    }
}
