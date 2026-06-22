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

    init(store: TimecardStore, calendar: Calendar = DomainCalendar.shared) {
        self.store = store
        self.calendar = calendar
        let anchorStr = store.anchorDate ?? PeriodViewModel.defaultAnchor(Date(), calendar: calendar)
        self.anchor = parseLocalDate(anchorStr, calendar: calendar)
        self.eightHourDefault = store.overtimeModeDefault
        self.use24h = store.use24h
        self.hourlyRate = store.hourlyRate
        self.anchorError = nil
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

    func makeScheduleModel() -> ScheduleViewModel { ScheduleViewModel(store: store) }
}
