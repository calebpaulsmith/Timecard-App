import XCTest
import SwiftData
@testable import Timecard

/// Round-trip + derived-helper tests for the multi-calendar registry stored on
/// `TimecardStore` (the `calendarConfigs` setting), plus event calendarId
/// persistence and tier/color/visibility resolution.
final class CalendarRegistryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    @MainActor
    private func makeStore() throws -> TimecardStore {
        let container = try TimecardStore.makeContainer(inMemory: true)
        return TimecardStore(context: ModelContext(container))
    }

    @MainActor
    func testConfigRoundTrip() throws {
        let store = try makeStore()
        let cfg = CalendarConfig(id: "cal-1", title: "Work", account: "Google",
                                 colorHex: "#0A6CFF", deviceColorHex: "#123456",
                                 tier: .above, showOnTimeline: false, synced: true, isTaskDefault: true)
        store.setCalendarConfigs([cfg])
        let back = store.calendarConfigs()
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first, cfg)
    }

    @MainActor
    func testUpsertEnforcesSingleTaskDefault() throws {
        let store = try makeStore()
        store.setCalendarConfigs([
            CalendarConfig(id: "a", tier: .below, isTaskDefault: true),
            CalendarConfig(id: "b", tier: .below, isTaskDefault: false),
        ])
        store.upsertCalendarConfig(CalendarConfig(id: "b", tier: .below, isTaskDefault: true))
        let configs = store.calendarConfigs()
        XCTAssertEqual(configs.filter { $0.isTaskDefault }.map { $0.id }, ["b"])
        XCTAssertEqual(store.taskCalendarId(), "b")
    }

    @MainActor
    func testSyncedIdsFallBackToLegacyTarget() throws {
        let store = try makeStore()
        // No registry yet → fall back to the single legacy events-target calendar.
        store.setStringSetting("eventKitCalendarId", "legacy-cal")
        XCTAssertEqual(store.syncedCalendarIds(), ["legacy-cal"])
        // Once configs exist, only the synced ones are returned.
        store.setCalendarConfigs([
            CalendarConfig(id: "x", synced: true),
            CalendarConfig(id: "y", synced: false),
        ])
        XCTAssertEqual(store.syncedCalendarIds(), ["x"])
    }

    @MainActor
    func testTierAndVisibilityResolution() throws {
        let store = try makeStore()
        store.setCalendarConfigs([
            CalendarConfig(id: "task", colorHex: "#FF0000", tier: .below,
                           showOnTimeline: false, synced: true),
        ])
        let task = CalEvent(date: "2026-06-01", startMin: 540, endMin: 600, calendarId: "task")
        XCTAssertEqual(store.tier(forEvent: task), .below)
        XCTAssertEqual(store.colorHex(forEvent: task), "#FF0000")
        XCTAssertTrue(store.hiddenFromTimeline(task))

        // An event on an unregistered calendar falls back to the color-token lane
        // and is never hidden from the timeline.
        let legacy = CalEvent(date: "2026-06-01", color: .ritza)
        XCTAssertEqual(store.tier(forEvent: legacy), .above)   // .person → above
        XCTAssertNil(store.colorHex(forEvent: legacy))
        XCTAssertFalse(store.hiddenFromTimeline(legacy))
    }

    @MainActor
    func testEventCalendarIdPersists() throws {
        let store = try makeStore()
        var ev = CalEvent(date: "2026-06-01", title: "Sync me", calendarId: "cal-9")
        store.upsertEvent(ev)
        XCTAssertEqual(store.getEvent(id: ev.id)?.calendarId, "cal-9")
        ev.calendarId = "cal-other"
        store.upsertEvent(ev)
        XCTAssertEqual(store.getEvent(id: ev.id)?.calendarId, "cal-other")
    }
}
