import XCTest
@testable import Timecard

/// Pure CSV-codec tests — no SwiftData. Verifies parity with the PWA backup
/// format and a clean round-trip of the four timecard sections.
final class CsvBackupTests: XCTestCase {
    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    private func sampleBackup() -> BackupData {
        var schedule = [ScheduleSlot?](repeating: nil, count: 14)
        // Mon/Tue of week 1 (period-day 1,2) as 9:00–17:30 work with 2h leave on Tue.
        schedule[1] = ScheduleSlot(enabled: true, startMin: 9 * 60, endMin: 17 * 60 + 30, leaveHours: 0)
        schedule[2] = ScheduleSlot(enabled: true, startMin: 9 * 60, endMin: 17 * 60 + 30, leaveHours: 2)
        // A disabled slot that still carries its remembered times.
        schedule[8] = ScheduleSlot(enabled: false, startMin: 8 * 60, endMin: 16 * 60, leaveHours: 0)

        let e1 = EntryRecord(
            id: "e1", date: "2026-05-04",
            startTime: buildDateTime("2026-05-04", hour24: 9, minute: 0),
            endTime: buildDateTime("2026-05-04", hour24: 17, minute: 30),
            lunchMinutes: 30, payKind: .auto, incomplete: false, fromDefault: true)
        // An overnight entry: end on the next day.
        let e2 = EntryRecord(
            id: "e2", date: "2026-05-05",
            startTime: buildDateTime("2026-05-05", hour24: 22, minute: 0),
            endTime: buildDateTime("2026-05-06", hour24: 2, minute: 0),
            lunchMinutes: 0, payKind: .overtime, incomplete: false, fromDefault: false)

        let settings = [
            SettingRecord(key: "anchorDate", value: "\"2026-05-03\""),
            SettingRecord(key: "overtimeModeDefault", value: "true"),
            SettingRecord(key: "hourlyRate", value: "42"),
            // A value containing commas + quotes — exercises CSV escaping.
            SettingRecord(key: "holidays",
                          value: "{\"2026-01-01\":{\"name\":\"New Year's Day\",\"doubleTime\":false}}"),
        ]

        return BackupData(settings: settings, schedule: schedule,
                          entries: [e1, e2],
                          leave: [LeaveRecord(date: "2026-05-04", minutes: 240)])
    }

    func testRoundTrip() {
        let original = sampleBackup()
        let csv = CsvBackup.export(original)
        let parsed = CsvBackup.parse(csv)

        XCTAssertEqual(parsed.settings, original.settings)
        XCTAssertEqual(parsed.schedule, original.schedule)
        XCTAssertEqual(Set(parsed.entries.map(\.id)), ["e1", "e2"])
        XCTAssertEqual(parsed.entries.sorted { $0.id < $1.id }, original.entries.sorted { $0.id < $1.id })
        XCTAssertEqual(parsed.leave, original.leave)
    }

    func testCsvEscapingForCommaAndQuote() {
        let row = CsvBackup.csvRow(["key", "{\"a\":1,\"b\":\"x,y\"}"])
        // The whole value is quoted and inner quotes doubled.
        XCTAssertTrue(row.contains("\"{\"\"a\"\":1,\"\"b\"\":\"\"x,y\"\"}\""))
        let back = CsvBackup.parseCsv(row)
        XCTAssertEqual(back.first?.last, "{\"a\":1,\"b\":\"x,y\"}")
    }

    func testHoursAndDayColumnsAreComputedOnExport() {
        let csv = CsvBackup.export(sampleBackup())
        // 9:00–17:30 minus 30m lunch = 8.0 paid hours; Monday May 4 2026 is "Mon".
        XCTAssertTrue(csv.contains("2026-05-04,Mon,09:00,17:30,,8,yes,30,no,no,yes,e1"))
        // Overnight entry carries the EndDate column.
        XCTAssertTrue(csv.contains("2026-05-05,Tue,22:00,02:00,2026-05-06,4,no,0,yes,no,no,e2"))
    }

    func testParseIgnoresCalendarSections() {
        let csv = """
        # Section: SETTINGS
        Key,Value
        hourlyRate,42
        # Section: ENTRIES
        Date,Day,StartTime,EndTime,EndDate,Hours,Lunch,LunchMin,Overtime,Incomplete,FromDefault,ID
        2026-05-04,Mon,09:00,17:30,,8,yes,30,no,no,no,abc
        # Section: LEAVE
        Date,Day,Hours
        2026-05-04,Mon,4
        # Section: EVENTS
        Date,Title,AllDay,Start,End,Color,Location,Notes,RRule,Exdates,SeriesId,NeedsScheduling,Source,GoogleId,ID
        2026-05-04,Dentist,no,10:00,11:00,work,,,,,,no,local,,ev1
        """
        let parsed = CsvBackup.parse(csv)
        XCTAssertEqual(parsed.settings, [SettingRecord(key: "hourlyRate", value: "42")])
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertEqual(parsed.entries.first?.id, "abc")
        XCTAssertEqual(parsed.entries.first?.lunchMinutes, 30)
        // Old 3-column LEAVE (no Minutes) imports via the Hours fallback.
        XCTAssertEqual(parsed.leave, [LeaveRecord(date: "2026-05-04", minutes: 240)])
    }

    func testLeaveFractionalRoundTrip() {
        // 75 minutes = 1.25h: precise value must survive export → parse.
        let backup = BackupData(leave: [LeaveRecord(date: "2026-05-04", minutes: 75)])
        let parsed = CsvBackup.parse(CsvBackup.export(backup))
        XCTAssertEqual(parsed.leave, [LeaveRecord(date: "2026-05-04", minutes: 75)])
    }

    func testLeavePlacementRoundTrip() {
        // The StartMin placement survives export → parse; absent → nil.
        let backup = BackupData(leave: [
            LeaveRecord(date: "2026-05-04", minutes: 120, startMin: 600),
            LeaveRecord(date: "2026-05-05", minutes: 60, startMin: nil),
        ])
        let parsed = CsvBackup.parse(CsvBackup.export(backup)).leave.sorted { $0.date < $1.date }
        XCTAssertEqual(parsed, [
            LeaveRecord(date: "2026-05-04", minutes: 120, startMin: 600),
            LeaveRecord(date: "2026-05-05", minutes: 60, startMin: nil),
        ])
    }

    func testLegacySevenRowScheduleMirrorsBothWeeks() {
        let csv = """
        # Section: DEFAULT_SCHEDULE
        Weekday,Enabled,StartTime,EndTime
        Monday,yes,09:00,17:00
        """
        let parsed = CsvBackup.parse(csv)
        // Legacy Monday (period-day 1) is mirrored to day 8 (week 2 Monday).
        XCTAssertEqual(parsed.schedule[1], ScheduleSlot(enabled: true, startMin: 540, endMin: 1020, leaveHours: 0))
        XCTAssertEqual(parsed.schedule[8], ScheduleSlot(enabled: true, startMin: 540, endMin: 1020, leaveHours: 0))
        XCTAssertNil(parsed.schedule[2])
    }
}
