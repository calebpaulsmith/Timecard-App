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

    init(store: TimecardStore, calendar: Calendar = DomainCalendar.shared) {
        self.store = store
        self.calendar = calendar
        let anchorStr = store.anchorDate ?? PeriodViewModel.defaultAnchor(Date(), calendar: calendar)
        self.anchor = parseLocalDate(anchorStr, calendar: calendar)
        self.eightHourDefault = store.overtimeModeDefault
        self.use24h = store.use24h
        self.hourlyRate = store.hourlyRate
        self.anchorError = nil
        self.validationDay = store.validationDay()
        self.sync = EventKitSync(store: store, calendar: calendar)
        self.selectedCalendarId = store.stringSetting("eventKitCalendarId") ?? ""
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

    func setUse24h(_ value: Bool) {
        use24h = value
        store.setBoolSetting("use24h", value)
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
