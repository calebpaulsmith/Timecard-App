import XCTest
@testable import Timecard

final class PeriodTotalsTests: XCTestCase {
    let anchor = "2026-05-03"   // a Sunday

    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        DomainCalendar.shared = c
    }

    /// Mon–Fri (period-day 1–5 and 8–12) scheduled 9:00–17:30 = 8.0h; weekends nil.
    private func weekdaySchedule() -> [ScheduleSlot?] {
        var s = [ScheduleSlot?](repeating: nil, count: 14)
        for i in [1, 2, 3, 4, 5, 8, 9, 10, 11, 12] {
            s[i] = ScheduleSlot(enabled: true, startMin: 9 * 60, endMin: 17 * 60 + 30, leaveHours: 0)
        }
        return s
    }

    private func period() -> PayPeriod {
        payPeriodFor(today: parseLocalDate("2026-05-04"), anchor: anchor)
    }

    /// Build an entry the way the app's creation flow would store it: a concrete
    /// `lunchMinutes` (30 when the span is ≥ 4h, else 0). The totals engine
    /// deducts from the *stored* value — it does not re-derive lunch — so tests
    /// must model that, mirroring how the PWA persists entries.
    private func entry(_ date: String, _ sh: Int, _ sm: Int, _ eh: Int, _ em: Int,
                       ot: Bool = false, kind: PayKind? = nil) -> EntryRecord {
        let start = buildDateTime(date, hour24: sh, minute: sm)
        let end = buildDateTime(date, hour24: eh, minute: em)
        let spanHours = end.timeIntervalSince(start) / 3600
        let lunch = spanHours >= TimeConstants.lunchThresholdHours ? 30 : 0
        return EntryRecord(id: date + "-\(sh)\(sm)", date: date,
                           startTime: start, endTime: end,
                           lunchMinutes: lunch, payKind: kind ?? (ot ? .overtime : .auto))
    }

    func testEightHourModeOTIsWorkBeyondScheduled() {
        let entries = [
            entry("2026-05-04", 9, 0, 18, 30),   // Mon: 9.0 paid, sched 8 → 1.0 OT
            entry("2026-05-05", 9, 0, 17, 30),   // Tue: 8.0 paid, sched 8 → 0 OT
            entry("2026-05-09", 10, 0, 13, 0),   // Sat: 3.0 paid, unscheduled → all 3 OT
        ]
        let t = periodTotals(period: period(), entries: entries, leaveByDate: [:],
                             schedule: weekdaySchedule(), otMode: true)
        XCTAssertEqual(t.worked, 20, accuracy: 1e-9)
        XCTAssertEqual(t.ot, 4, accuracy: 1e-9)
        XCTAssertEqual(t.otByDate["2026-05-04"], 1)
        XCTAssertEqual(t.otByDate["2026-05-05"], 0)
        XCTAssertEqual(t.otByDate["2026-05-09"], 3)
    }

    func testMaxiflexAutoOTGatedUntil80() {
        let entries = [entry("2026-05-04", 9, 0, 18, 30)]  // 9h on an 8h day, period < 80
        let t = periodTotals(period: period(), entries: entries, leaveByDate: [:],
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.worked, 9, accuracy: 1e-9)
        XCTAssertEqual(t.ot, 0, accuracy: 1e-9, "auto OT is gated until the period exceeds 80h")
    }

    func testMaxiflexExplicitOTAlwaysCounts() {
        let entries = [
            entry("2026-05-04", 9, 0, 17, 30),            // 8.0 regular
            entry("2026-05-04", 19, 0, 21, 0, ot: true),  // 2.0 explicit OT
        ]
        let t = periodTotals(period: period(), entries: entries, leaveByDate: [:],
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.worked, 10, accuracy: 1e-9)
        XCTAssertEqual(t.ot, 2, accuracy: 1e-9, "explicit OT counts even below 80h")
        XCTAssertEqual(t.otByDate["2026-05-04"], 2)
    }

    func testWorkedHolidayIsAllOTAndDoubleTimePays2x() {
        let entries = [entry("2026-05-04", 9, 0, 17, 30)]  // 8.0 paid on a holiday
        let t = periodTotals(period: period(), entries: entries, leaveByDate: [:],
                             schedule: weekdaySchedule(), otMode: true,
                             hourlyRate: 10,
                             holidays: ["2026-05-04": HolidayInfo(doubleTime: true)])
        XCTAssertEqual(t.ot, 8, accuracy: 1e-9, "all worked-holiday hours are OT")
        XCTAssertEqual(t.otDollars, 160, accuracy: 1e-9, "8h × $10 × 2.0 double-time")
    }

    func testLeaveSummedAndIncompleteIgnored() {
        var incomplete = entry("2026-05-06", 9, 0, 17, 0)
        incomplete.incomplete = true
        let t = periodTotals(period: period(),
                             entries: [entry("2026-05-04", 9, 0, 17, 30), incomplete],
                             leaveByDate: ["2026-05-04": 2, "2026-05-07": 8],
                             schedule: weekdaySchedule(), otMode: true)
        XCTAssertEqual(t.worked, 8, accuracy: 1e-9, "incomplete entry contributes 0")
        XCTAssertEqual(t.leave, 10, accuracy: 1e-9)
        XCTAssertEqual(t.total, 18, accuracy: 1e-9)
    }

    // MARK: - Refined Maxiflex (leave counts toward the 80 gate; leave fills schedule)

    /// Core fix: 75h worked (all within an 8h/day Mon–Fri schedule + a 3h
    /// unscheduled Saturday) + 8h leave = 83 total. Worked-only (75) is under 80,
    /// so the OLD worked-only gate gave 0 OT; counting leave pushes the period
    /// over 80, unlocking the 3h beyond-schedule Saturday as OT.
    func testMaxiflexLeaveCountsTowardOver80Gate() {
        var entries: [EntryRecord] = []
        for d in ["2026-05-04", "2026-05-05", "2026-05-06", "2026-05-07", "2026-05-08",
                  "2026-05-11", "2026-05-12", "2026-05-13", "2026-05-14"] {
            entries.append(entry(d, 9, 0, 17, 30))      // 8.0 paid, == schedule → 0 beyond
        }
        entries.append(entry("2026-05-09", 10, 0, 13, 0))   // Sat: 3.0 paid, unscheduled → beyond
        let t = periodTotals(period: period(), entries: entries,
                             leaveByDate: ["2026-05-15": 8],
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.worked, 75, accuracy: 1e-9)
        XCTAssertEqual(t.leave, 8, accuracy: 1e-9)
        XCTAssertEqual(t.total, 83, accuracy: 1e-9)
        XCTAssertEqual(t.ot, 3, accuracy: 1e-9, "leave lifts the period over 80, unlocking beyond-schedule OT")
        XCTAssertEqual(t.otByDate["2026-05-09"] ?? 0, 3, accuracy: 1e-9)
    }

    /// Leave alone never manufactures OT: 80h worked all within schedule + 8h
    /// leave = 88 total (>80), but with no beyond-schedule work there is no OT.
    func testMaxiflexLeaveAloneDoesNotCreateOT() {
        var entries: [EntryRecord] = []
        for d in ["2026-05-04", "2026-05-05", "2026-05-06", "2026-05-07", "2026-05-08",
                  "2026-05-11", "2026-05-12", "2026-05-13", "2026-05-14", "2026-05-15"] {
            entries.append(entry(d, 9, 0, 17, 30))      // 8.0 ×10 = 80, all == schedule
        }
        let t = periodTotals(period: period(), entries: entries,
                             leaveByDate: ["2026-05-16": 8],   // Sat leave, unscheduled
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.worked, 80, accuracy: 1e-9)
        XCTAssertEqual(t.total, 88, accuracy: 1e-9)
        XCTAssertEqual(t.ot, 0, accuracy: 1e-9, "over 80 only via leave + no beyond-schedule work → no OT")
    }

    /// Leave fills the schedule: on a scheduled 8h day the user takes 8h leave
    /// AND works 2h; the leave consumes the schedule, so the 2 worked hours are
    /// beyond-schedule OT (period is over 80).
    func testMaxiflexLeaveFillsScheduleSoExtraWorkIsOT() {
        var entries: [EntryRecord] = []
        for d in ["2026-05-04", "2026-05-05", "2026-05-06", "2026-05-07", "2026-05-08",
                  "2026-05-11", "2026-05-12", "2026-05-13", "2026-05-14"] {
            entries.append(entry(d, 9, 0, 17, 30))      // 8.0 ×9 = 72
        }
        entries.append(entry("2026-05-15", 9, 0, 11, 0))   // Fri: 2h worked atop 8h leave
        let t = periodTotals(period: period(), entries: entries,
                             leaveByDate: ["2026-05-15": 8],
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.worked, 74, accuracy: 1e-9)
        XCTAssertEqual(t.total, 82, accuracy: 1e-9)
        XCTAssertEqual(t.otByDate["2026-05-15"] ?? 0, 2, accuracy: 1e-9,
                       "8h leave fills the 8h schedule; the extra 2h worked is beyond-schedule OT")
        XCTAssertEqual(t.ot, 2, accuracy: 1e-9)
    }

    /// Leave counts toward the 80h target in Maxiflex mode too — `total` is
    /// worked + leave regardless of OT mode (the UI's progress/hours-left/pace
    /// read `total`, so leave must be in it). Guards the iOS display fix.
    func testLeaveCountsTowardTotalInMaxiflex() {
        let t = periodTotals(period: period(),
                             entries: [entry("2026-05-04", 9, 0, 17, 30)],   // 8h worked
                             leaveByDate: ["2026-05-05": 8],                  // 8h leave
                             schedule: weekdaySchedule(), otMode: false)      // Maxiflex
        XCTAssertEqual(t.worked, 8, accuracy: 1e-9)
        XCTAssertEqual(t.leave, 8, accuracy: 1e-9)
        XCTAssertEqual(t.total, 16, accuracy: 1e-9, "leave is part of the total in maxiflex")
        XCTAssertEqual(t.ot, 0, accuracy: 1e-9, "leave does not trigger maxiflex OT")
    }

    // MARK: - Per-entry pay classification (auto / credit / overtime / regular)

    /// Same over-80 setup (74h worked within schedule + 8h leave = 82; a 3h
    /// unscheduled Saturday is the only beyond-schedule work). The Saturday
    /// entry's `payKind` decides where its 3 beyond-schedule hours land.
    private func classifyingTotals(_ kind: PayKind, creditEnabled: Bool = true) -> PeriodTotals {
        var entries: [EntryRecord] = []
        for d in ["2026-05-04", "2026-05-05", "2026-05-06", "2026-05-07", "2026-05-08",
                  "2026-05-11", "2026-05-12", "2026-05-13", "2026-05-14"] {
            entries.append(entry(d, 9, 0, 17, 30))            // 8.0 ×9 = 72, within schedule
        }
        entries.append(entry("2026-05-09", 10, 0, 13, 0, kind: kind))   // Sat 3h, unscheduled
        return periodTotals(period: period(),
                            entries: entries,
                            leaveByDate: ["2026-05-15": 8],   // → total 83 > 80
                            schedule: weekdaySchedule(), otMode: false,
                            creditEnabled: creditEnabled)
    }

    func testPayKindAutoExtraIsOvertime() {
        let t = classifyingTotals(.auto)
        XCTAssertEqual(t.ot, 3, accuracy: 1e-9)
        XCTAssertEqual(t.credit, 0, accuracy: 1e-9)
    }

    func testPayKindAutoCreditBanksInsteadOfOT() {
        let t = classifyingTotals(.autoCredit)
        XCTAssertEqual(t.ot, 0, accuracy: 1e-9, "beyond-schedule hours bank as credit, not OT")
        XCTAssertEqual(t.credit, 3, accuracy: 1e-9)
        XCTAssertEqual(t.creditByDate["2026-05-09"] ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(t.otDollars, 0, accuracy: 1e-9, "credit hours carry no premium")
    }

    func testPayKindRegularForcesNoPremium() {
        let t = classifyingTotals(.regular)
        XCTAssertEqual(t.ot, 0, accuracy: 1e-9, "forced regular never pays premium even beyond schedule")
        XCTAssertEqual(t.credit, 0, accuracy: 1e-9)
    }

    func testPayKindOvertimeForcesWholeEntryOT() {
        let t = classifyingTotals(.overtime)
        XCTAssertEqual(t.ot, 3, accuracy: 1e-9, "forced OT pays the whole entry")
        XCTAssertEqual(t.credit, 0, accuracy: 1e-9)
    }

    /// Master switch OFF: credit classifications collapse to overtime, so the
    /// same autoCredit / credit entries pay OT and bank no credit.
    func testCreditDisabledCollapsesToOvertime() {
        let ac = classifyingTotals(.autoCredit, creditEnabled: false)
        XCTAssertEqual(ac.ot, 3, accuracy: 1e-9, "autoCredit → auto → OT when feature off")
        XCTAssertEqual(ac.credit, 0, accuracy: 1e-9, "no credit banked when feature off")
        let c = classifyingTotals(.credit, creditEnabled: false)
        XCTAssertEqual(c.ot, 3, accuracy: 1e-9, "forced credit → overtime when feature off")
        XCTAssertEqual(c.credit, 0, accuracy: 1e-9)
    }

    /// Classification only pays premium once the period is over 80: the same
    /// `autoCredit` Saturday with no leave (total 75 < 80) banks nothing.
    func testPayKindCreditGatedByOver80() {
        var entries: [EntryRecord] = []
        for d in ["2026-05-04", "2026-05-05", "2026-05-06", "2026-05-07", "2026-05-08",
                  "2026-05-11", "2026-05-12", "2026-05-13", "2026-05-14"] {
            entries.append(entry(d, 9, 0, 17, 30))            // 72h
        }
        entries.append(entry("2026-05-09", 10, 0, 13, 0, kind: .autoCredit))   // 3h → 75 total
        let t = periodTotals(period: period(), entries: entries, leaveByDate: [:],
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.credit, 0, accuracy: 1e-9, "under 80 → no credit banked")
        XCTAssertEqual(t.ot, 0, accuracy: 1e-9)
    }

    /// **The screenshot bug.** Auto OT is capped at the hours actually over 80,
    /// not the full sum of every beyond-schedule hour. Nine weekday slots worked
    /// 9h each (8h scheduled → 1h beyond/day = 9h beyond total), no leave → 81h
    /// worked, only **1h over 80**. OT must be 1, not 9.
    func testMaxiflexAutoOTCappedAtHoursOver80() {
        var entries: [EntryRecord] = []
        for d in ["2026-05-04", "2026-05-05", "2026-05-06", "2026-05-07", "2026-05-08",
                  "2026-05-11", "2026-05-12", "2026-05-13", "2026-05-14"] {
            entries.append(entry(d, 9, 0, 18, 30))   // 9.0 paid; sched 8 → 1h beyond
        }
        let t = periodTotals(period: period(), entries: entries, leaveByDate: [:],
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.worked, 81, accuracy: 1e-9)
        XCTAssertEqual(t.ot, 1, accuracy: 1e-9,
                       "auto OT capped at the 1h over 80, not the 9h sum of beyond-schedule")
    }

    /// Leave can't manufacture more OT than the hours over 80: 70h worked (incl.
    /// some beyond-schedule) + 12h leave = 82 total. Beyond-schedule may sum to
    /// more, but OT is capped at 2h (the amount over 80). Mirrors the live
    /// screenshot (81.75/80 showing only the over-80 amount, not 5.75).
    func testMaxiflexLeaveDoesNotInflateOTPastOver80Cap() {
        var entries: [EntryRecord] = []
        // 7 weekday slots at 10h (sched 8 → 2h beyond each = 14h beyond), 70h worked.
        for d in ["2026-05-04", "2026-05-05", "2026-05-06", "2026-05-07", "2026-05-08",
                  "2026-05-11", "2026-05-12"] {
            entries.append(entry(d, 9, 0, 19, 30))   // 10.0 paid; sched 8 → 2h beyond
        }
        let t = periodTotals(period: period(), entries: entries,
                             leaveByDate: ["2026-05-13": 8, "2026-05-14": 4],   // 12h leave → total 82
                             schedule: weekdaySchedule(), otMode: false)
        XCTAssertEqual(t.worked, 70, accuracy: 1e-9)
        XCTAssertEqual(t.total, 82, accuracy: 1e-9)
        XCTAssertEqual(t.ot, 2, accuracy: 1e-9, "capped at 2h over 80, not the 14h beyond schedule")
    }
}
