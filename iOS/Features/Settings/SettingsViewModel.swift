import Foundation
import Observation

/// Drives the Settings screen. Values load from `TimecardStore` in `init`; each
/// `set…` writes through to the store immediately (explicit setters rather than
/// `didSet`, to avoid relying on property-observer behavior under `@Observable`).
/// The anchor is validated as a Sunday before it's saved, surfacing `anchorError`
/// inline otherwise (mirrors the PWA's `setAnchor`).
@MainActor
@Observable
final class SettingsViewModel {
    private let store: TimecardStore
    private let calendar: Calendar

    private(set) var anchor: Date
    private(set) var eightHourDefault: Bool
    /// Master switch for the credit-hours feature (default off).
    private(set) var creditHoursEnabled: Bool
    /// Local reminders master switch (default off).
    private(set) var remindersEnabled: Bool
    private(set) var use24h: Bool
    private(set) var hourlyRate: Double
    private(set) var anchorError: String?
    /// Timecard-validation deadline as a day-of-period index (0..13), or nil.
    private(set) var validationDay: Int?

    // Calendar (EventKit) two-way sync.
    let sync: EventKitSync
    private(set) var calendars: [EventKitSync.CalendarInfo] = []
    private(set) var selectedCalendarId: String
    private(set) var syncStatus: String?
    private(set) var isSyncing = false

    // Optional work-schedule sync (off by default; bounded forward window).
    private(set) var scheduleSyncEnabled: Bool
    private(set) var scheduleCalendarId: String
    private(set) var schedulePeriodsAhead: Int
    private(set) var scheduleSyncLeave: Bool
    private(set) var scheduleLeaveCalendarId: String

    init(store: TimecardStore, calendar: Calendar = DomainCalendar.shared) {
        self.store = store
        self.calendar = calendar
        let anchorStr = store.anchorDate ?? PeriodViewModel.defaultAnchor(Date(), calendar: calendar)
        self.anchor = parseLocalDate(anchorStr, calendar: calendar)
        self.eightHourDefault = store.overtimeModeDefault
        self.creditHoursEnabled = store.creditHoursEnabled
        self.remindersEnabled = store.remindersEnabled
        self.use24h = store.use24h
        self.hourlyRate = store.hourlyRate
        self.anchorError = nil
        self.validationDay = store.validationDay()
        self.sync = EventKitSync(store: store, calendar: calendar)
        self.selectedCalendarId = store.stringSetting("eventKitCalendarId") ?? ""
        self.scheduleSyncEnabled = store.boolSetting("scheduleSyncEnabled", default: false)
        self.scheduleCalendarId = store.stringSetting("scheduleSyncCalendarId") ?? ""
        self.schedulePeriodsAhead = max(1, Int(store.doubleSetting("scheduleSyncPeriodsAhead", default: 2)))
        self.scheduleSyncLeave = store.boolSetting("scheduleSyncLeave", default: true)
        self.scheduleLeaveCalendarId = store.stringSetting("scheduleSyncLeaveCalendarId") ?? ""
        refreshCalendars()
    }

    // MARK: - Calendar sync

    var calendarAuthorized: Bool { sync.authorized }

    func refreshCalendars() {
        guard sync.authorized else { calendars = []; return }
        calendars = sync.availableCalendars()
        // Default the selection to the system default if none chosen yet.
        if selectedCalendarId.isEmpty, let def = sync.defaultCalendarId {
            selectedCalendarId = def
        }
    }

    func requestCalendarAccess() async {
        let granted = await sync.requestAccess()
        if granted { refreshCalendars() }
        else { syncStatus = "Access denied. Enable it in Settings › Privacy › Calendars." }
    }

    func setCalendar(_ id: String) {
        selectedCalendarId = id
        store.setStringSetting("eventKitCalendarId", id)
    }

    // MARK: - Work-schedule sync

    func setScheduleSyncEnabled(_ value: Bool) {
        scheduleSyncEnabled = value
        store.setBoolSetting("scheduleSyncEnabled", value)
        Task { await syncNow() }     // push the schedule (or tear it down) now
    }

    /// "" → use the events target calendar.
    func setScheduleCalendar(_ id: String) {
        scheduleCalendarId = id
        store.setStringSetting("scheduleSyncCalendarId", id)
        if scheduleSyncEnabled { Task { await syncNow() } }
    }

    func setSchedulePeriodsAhead(_ n: Int) {
        let clamped = min(26, max(1, n))
        schedulePeriodsAhead = clamped
        store.setDoubleSetting("scheduleSyncPeriodsAhead", Double(clamped))
        if scheduleSyncEnabled { Task { await syncNow() } }
    }

    /// Sentinel picker tag meaning "don't sync leave at all".
    static let leaveSyncOff = "__off__"

    /// One control for leave: `""` = same calendar as the work schedule (default),
    /// a calendar id = that calendar, `leaveSyncOff` = don't sync leave.
    var leaveSyncSelection: String {
        scheduleSyncLeave ? scheduleLeaveCalendarId : Self.leaveSyncOff
    }

    func setLeaveSyncSelection(_ value: String) {
        if value == Self.leaveSyncOff {
            scheduleSyncLeave = false
            store.setBoolSetting("scheduleSyncLeave", false)
        } else {
            scheduleSyncLeave = true
            store.setBoolSetting("scheduleSyncLeave", true)
            scheduleLeaveCalendarId = value
            store.setStringSetting("scheduleSyncLeaveCalendarId", value)
        }
        if scheduleSyncEnabled { Task { await syncNow() } }
    }

    func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        if !sync.authorized {
            await requestCalendarAccess()
            if !sync.authorized { return }
        }
        let outcome = await sync.sync()
        switch outcome {
        case .ok(let pushed, let pulled, let deleted):
            syncStatus = "Synced — \(pushed) up, \(pulled) down" + (deleted > 0 ? ", \(deleted) removed" : "")
        case .needsAccess: syncStatus = "Calendar access is required."
        case .noCalendar: syncStatus = "Pick a calendar to sync with."
        }
    }

    var lastSyncText: String? {
        guard let d = sync.lastSync else { return nil }
        let f = DateFormatter()
        f.calendar = calendar
        f.dateStyle = .short
        f.timeStyle = .short
        return "Last synced \(f.string(from: d))"
    }

    func setAnchor(_ date: Date) {
        anchor = date
        let str = formatLocalDate(date, calendar: calendar)
        if isSunday(str, calendar: calendar) {
            anchorError = nil
            store.setStringSetting("anchorDate", str)
        } else {
            anchorError = "The anchor must be a Sunday — pick the Sunday that began a known pay period."
        }
    }

    func setEightHourDefault(_ value: Bool) {
        eightHourDefault = value
        store.setBoolSetting("overtimeModeDefault", value)
    }

    func setCreditHoursEnabled(_ value: Bool) {
        creditHoursEnabled = value
        store.creditHoursEnabled = value
    }

    func setRemindersEnabled(_ value: Bool) {
        remindersEnabled = value
        store.remindersEnabled = value
        let store = self.store
        Task {
            if value { await ReminderScheduler.requestAuthorization() }
            await ReminderScheduler.refresh(store: store)
        }
    }

    func setUse24h(_ value: Bool) {
        use24h = value
        store.setBoolSetting("use24h", value)
    }

    // MARK: - CSV backup / restore

    /// The full timecard backup as PWA-compatible CSV text.
    func exportCsvText() -> String { store.exportCsv() }

    /// The default schedule as an RFC-5545 `.ics`, anchored to the current pay
    /// period (biweekly-recurring work/leave events for import into a calendar).
    func exportScheduleIcsText() -> String {
        let anchorStr = store.anchorDate ?? PeriodViewModel.defaultAnchor(Date(), calendar: calendar)
        let periodStart = payPeriodFor(today: Date(), anchor: anchorStr, calendar: calendar).start
        return buildScheduleIcs(schedule: store.defaultSchedule(), periodStart: periodStart, calendar: calendar)
    }

    /// Restore from a CSV file (wipe-and-restore). Reads the security-scoped URL,
    /// applies it, then re-reads cached settings + reschedules reminders.
    /// Returns true on success.
    @discardableResult
    func importCsv(from url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        store.importCsv(text)
        reloadFromStore()
        let store = self.store
        Task { await ReminderScheduler.refresh(store: store) }
        return true
    }

    /// Re-read everything this view model caches from the store (after an import
    /// replaces all data).
    func reloadFromStore() {
        let anchorStr = store.anchorDate ?? PeriodViewModel.defaultAnchor(Date(), calendar: calendar)
        anchor = parseLocalDate(anchorStr, calendar: calendar)
        eightHourDefault = store.overtimeModeDefault
        creditHoursEnabled = store.creditHoursEnabled
        remindersEnabled = store.remindersEnabled
        use24h = store.use24h
        hourlyRate = store.hourlyRate
        validationDay = store.validationDay()
        scheduleSyncEnabled = store.boolSetting("scheduleSyncEnabled", default: false)
        scheduleCalendarId = store.stringSetting("scheduleSyncCalendarId") ?? ""
        schedulePeriodsAhead = max(1, Int(store.doubleSetting("scheduleSyncPeriodsAhead", default: 2)))
        scheduleSyncLeave = store.boolSetting("scheduleSyncLeave", default: true)
        scheduleLeaveCalendarId = store.stringSetting("scheduleSyncLeaveCalendarId") ?? ""
        anchorError = nil
    }

    func setHourlyRate(_ value: Double) {
        hourlyRate = max(0, value)
        store.setDoubleSetting("hourlyRate", hourlyRate)
    }

    func setValidationDay(_ index: Int?) {
        validationDay = index
        store.setValidationDay(index)
    }

    /// Labels for the 14 day-of-period slots, e.g. "Week 1 · Mon". The anchor is a
    /// Sunday, so index `i` maps to weekday `i % 7` (0 = Sun).
    var validationDayLabels: [String] {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return (0..<TimeConstants.payPeriodDays).map { i in
            "Week \(i / 7 + 1) · \(names[i % 7])"
        }
    }

    func makeScheduleModel() -> ScheduleViewModel { ScheduleViewModel(store: store) }
}
