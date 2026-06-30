import XCTest
@testable import Timecard

/// Tests for the multi-calendar layout: the three-tier day-event layout
/// (`layoutDayEvents`) and the per-calendar config defaults.
final class CalendarLayoutTests: XCTestCase {

    private func ev(_ id: String, _ start: Int, _ end: Int, calendarId: String? = nil,
                    allDay: Bool = false) -> CalEvent {
        CalEvent(id: id, date: "2026-06-01", allDay: allDay,
                 startMin: start, endMin: end, calendarId: calendarId)
    }

    func testDefaultTierHeuristic() {
        XCTAssertEqual(defaultTier(forTitle: "Tasks"), .tasks)
        XCTAssertEqual(defaultTier(forTitle: "My To-Do list"), .tasks)
        XCTAssertEqual(defaultTier(forTitle: "Reminders"), .tasks)
        XCTAssertEqual(defaultTier(forTitle: "Work"), .mine)
        XCTAssertEqual(defaultTier(forTitle: "Family"), .mine)
    }

    func testLegacyTierRawValuesDecode() {
        // Configs persisted under the old three-tier names must keep working.
        XCTAssertEqual(CalendarTier(stored: "on"), .mine)
        XCTAssertEqual(CalendarTier(stored: "above"), .others)
        XCTAssertEqual(CalendarTier(stored: "below"), .tasks)
        // New names round-trip; unknown falls back to .mine.
        XCTAssertEqual(CalendarTier(stored: "close"), .close)
        XCTAssertEqual(CalendarTier(stored: "mine"), .mine)
        XCTAssertEqual(CalendarTier(stored: "???"), .mine)
    }

    func testTiersAreSeparatedAndMineTierOverlaps() {
        let a = ev("a", 540, 600, calendarId: "work")   // mine
        let b = ev("b", 555, 615, calendarId: "work")   // mine, overlaps a
        let c = ev("c", 540, 600, calendarId: "ptnr")   // others
        let d = ev("d", 540, 600, calendarId: "task")   // tasks
        let tierOf: (CalEvent) -> CalendarTier = { e in
            switch e.calendarId {
            case "ptnr": return .others
            case "task": return .tasks
            default: return .mine
            }
        }
        let layout = layoutDayEvents([a, b, c, d], tierOf: tierOf)

        // "mine" tier: both events overlap on lane 0 (a single shared lane).
        XCTAssertEqual(layout.laneCount(.mine), 1)
        for item in layout.timed where item.tier == .mine { XCTAssertEqual(item.lane, 0) }
        // others / tasks each have one event.
        XCTAssertEqual(layout.laneCount(.others), 1)
        XCTAssertEqual(layout.laneCount(.tasks), 1)
        XCTAssertEqual(layout.timed.count, 4)
        XCTAssertTrue(layout.allDay.isEmpty)
    }

    func testNonMineTierStacksConcurrentEvents() {
        // Two overlapping others-tier events need two lanes (unlike the mine tier).
        let a = ev("a", 540, 600, calendarId: "p")
        let b = ev("b", 555, 615, calendarId: "p")
        let layout = layoutDayEvents([a, b], tierOf: { _ in .others })
        XCTAssertEqual(layout.laneCount(.others), 2)
        let lanes = Set(layout.timed.map { $0.lane })
        XCTAssertEqual(lanes, [0, 1])
    }

    func testAllDayAndDegenerateGoToAllDayBand() {
        let allDay = ev("a", 0, 1440, allDay: true)
        let zeroLen = ev("z", 600, 600)             // end <= start → treated as all-day band
        let layout = layoutDayEvents([allDay, zeroLen], tierOf: { _ in .mine })
        XCTAssertEqual(layout.allDay.count, 2)
        XCTAssertTrue(layout.timed.isEmpty)
    }

    func testEffectiveColorPrefersOverride() {
        var c = CalendarConfig(id: "x", deviceColorHex: "#111111")
        XCTAssertEqual(c.effectiveColorHex, "#111111")
        c.colorHex = "#ABCDEF"
        XCTAssertEqual(c.effectiveColorHex, "#ABCDEF")
    }
}
