import XCTest
import SwiftData
@testable import Timecard

/// SwiftData repository tests against an ephemeral in-memory store.
final class TimecardStoreTests: XCTestCase {
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
    func testUpsertUpdatesInPlaceAndDeletes() throws {
        let store = try makeStore()
        let e = EntryRecord(id: "x", date: "2026-05-04",
                            startTime: buildDateTime("2026-05-04", hour24: 9, minute: 0),
                            endTime: buildDateTime("2026-05-04", hour24: 17, minute: 0),
                            lunchMinutes: 30)
        store.upsert(e)
        XCTAssertEqual(store.entries(on: "2026-05-04").count, 1)

        var updated = e
        updated.isOvertime = true
        updated.lunchMinutes = 0
        store.upsert(updated)
        let rows = store.entries(on: "2026-05-04")
        XCTAssertEqual(rows.count, 1, "same id must update, not duplicate")
        XCTAssertEqual(rows.first?.isOvertime, true)
        XCTAssertEqual(rows.first?.lunchMinutes, 0)

        store.deleteEntry(id: "x")
        XCTAssertTrue(store.entries(on: "2026-05-04").isEmpty)
    }

    @MainActor
    func testLeaveSetAndRemove() throws {
        let store = try makeStore()
        store.setLeave(on: "2026-05-04", hours: 4)
        XCTAssertEqual(store.leaveHours(on: "2026-05-04"), 4)
        store.setLeave(on: "2026-05-04", hours: 6)
        XCTAssertEqual(store.leaveHours(on: "2026-05-04"), 6)
        store.setLeave(on: "2026-05-04", hours: 0)   // 0 removes the row
        XCTAssertEqual(store.leaveHours(on: "2026-05-04"), 0)
        XCTAssertTrue(store.allLeave().isEmpty)
    }

    @MainActor
    func testTypedSettingsEncodeAsJSON() throws {
        let store = try makeStore()
        store.setStringSetting("anchorDate", "2026-05-03")
        store.setDoubleSetting("hourlyRate", 42)
        store.setBoolSetting("use24h", true)

        XCTAssertEqual(store.anchorDate, "2026-05-03")
        XCTAssertEqual(store.rawSetting("anchorDate"), "\"2026-05-03\"")  // quoted JSON string
        XCTAssertEqual(store.hourlyRate, 42)
        XCTAssertEqual(store.rawSetting("hourlyRate"), "42")
        XCTAssertTrue(store.use24h)
        XCTAssertEqual(store.rawSetting("use24h"), "true")
        // Defaults when unset.
        XCTAssertTrue(store.overtimeModeDefault)
        XCTAssertTrue(store.autoHolidays)
    }

    @MainActor
    func testDefaultScheduleRoundTrip() throws {
        let store = try makeStore()
        var schedule = [ScheduleSlot?](repeating: nil, count: 14)
        schedule[1] = ScheduleSlot(enabled: true, startMin: 540, endMin: 1050, leaveHours: 0)
        schedule[2] = ScheduleSlot(enabled: false, startMin: 480, endMin: 960, leaveHours: 2)
        store.setDefaultSchedule(schedule)
        XCTAssertEqual(store.defaultSchedule(), schedule)
    }

    @MainActor
    func testCsvImportThenExportIsStable() throws {
        let store = try makeStore()
        var schedule = [ScheduleSlot?](repeating: nil, count: 14)
        schedule[1] = ScheduleSlot(enabled: true, startMin: 540, endMin: 1050, leaveHours: 0)
        let source = BackupData(
            settings: [
                SettingRecord(key: "anchorDate", value: "\"2026-05-03\""),
                SettingRecord(key: "hourlyRate", value: "42"),
            ],
            schedule: schedule,
            entries: [EntryRecord(id: "e1", date: "2026-05-04",
                                  startTime: buildDateTime("2026-05-04", hour24: 9, minute: 0),
                                  endTime: buildDateTime("2026-05-04", hour24: 17, minute: 30),
                                  lunchMinutes: 30, fromDefault: true)],
            leave: [LeaveRecord(date: "2026-05-04", hours: 4)])
        let csv = CsvBackup.export(source)

        store.importCsv(csv)
        let exported = store.exportBackup()

        XCTAssertEqual(exported.settings, source.settings)
        XCTAssertEqual(exported.schedule, source.schedule)
        XCTAssertEqual(exported.entries, source.entries)
        XCTAssertEqual(exported.leave, source.leave)
    }

    @MainActor
    func testLocalOnlySettingPreservedAcrossImport() throws {
        let store = try makeStore()
        store.setRawSetting("apiKey", "\"secret\"")          // a local-only key
        store.setRawSetting("hourlyRate", "10")              // will be replaced by import

        let csv = CsvBackup.export(BackupData(
            settings: [SettingRecord(key: "hourlyRate", value: "42")]))
        store.importCsv(csv)

        XCTAssertEqual(store.rawSetting("apiKey"), "\"secret\"", "local-only key survives the wipe")
        XCTAssertEqual(store.rawSetting("hourlyRate"), "42", "imported value replaces the old one")
        // Local-only keys are never part of an exported backup.
        XCTAssertFalse(store.exportBackup().settings.contains { $0.key == "apiKey" })
    }
}
