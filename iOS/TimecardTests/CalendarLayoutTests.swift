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
        XCTAssertEqual(defaultTier(forTitle: "Tasks"), .below)
        XCTAssertEqual(defaultTier(forTitle: "My To-Do list"), .below)
        XCTAssertEqual(defaultTier(forTitle: "Reminders"), .below)
        XCTAssertEqual(defaultTier(forTitle: "Work"), .on)
        XCTAssertEqual(defaultTier(forTitle: "Family"), .on)
    }

    func testTiersAreSeparatedAndOnTierOverlaps() {
        let a = ev("a", 540, 600, calendarId: "work")   // on
        let b = ev("b", 555, 615, calendarId: "work")   // on, overlaps a
        let c = ev("c", 540, 600, calendarId: "ptnr")   // above
        let d = ev("d", 540, 600, calendarId: "task")   // below
        let tierOf: (CalEvent) -> CalendarTier = { e in
            switch e.calendarId {
            case "ptnr": return .above
            case "task": return .below
            default: return .on
            }
        }
        let layout = layoutDayEvents([a, b, c, d], tierOf: tierOf)

        // "on" tier: both events overlap on lane 0 (a single shared lane).
        XCTAssertEqual(layout.laneCount(.on), 1)
        for item in layout.timed where item.tier == .on { XCTAssertEqual(item.lane, 0) }
        // above / below each have one event.
        XCTAssertEqual(layout.laneCount(.above), 1)
        XCTAssertEqual(layout.laneCount(.below), 1)
        XCTAssertEqual(layout.timed.count, 4)
        XCTAssertTrue(layout.allDay.isEmpty)
    }

    func testAboveTierStacksConcurrentEvents() {
        // Two overlapping above-tier events need two lanes (unlike the on tier).
        let a = ev("a", 540, 600, calendarId: "p")
        let b = ev("b", 555, 615, calendarId: "p")
        let layout = layoutDayEvents([a, b], tierOf: { _ in .above })
        XCTAssertEqual(layout.laneCount(.above), 2)
        let lanes = Set(layout.timed.map { $0.lane })
        XCTAssertEqual(lanes, [0, 1])
    }

    func testAllDayAndDegenerateGoToAllDayBand() {
        let allDay = ev("a", 0, 1440, allDay: true)
        let zeroLen = ev("z", 600, 600)             // end <= start → treated as all-day band
        let layout = layoutDayEvents([allDay, zeroLen], tierOf: { _ in .on })
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
