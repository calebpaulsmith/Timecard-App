import Foundation
import Observation

/// Drives the Settings › Calendars screen — the multi-calendar registry editor.
/// It overlays the live device (EventKit) calendar list onto the stored
/// `CalendarConfig`s, so the user can choose which calendars the app uses, set
/// each one's color, line tier (above / on / below), timeline visibility, and the
/// default "Add task" target.
@MainActor
@Observable
final class CalendarsViewModel {
    private let store: TimecardStore
    let sync: EventKitSync
    private(set) var rows: [Row] = []

    struct Row: Identifiable {
        var id: String
        var title: String
        var account: String
        var isWritable: Bool
        var config: CalendarConfig
    }

    init(store: TimecardStore, calendar: Calendar = DomainCalendar.shared) {
        self.store = store
        self.sync = EventKitSync(store: store, calendar: calendar)
        reload()
    }

    var authorized: Bool { sync.authorized }

    func requestAccess() async {
        _ = await sync.requestAccess()
        reload()
    }

    func reload() {
        let stored = Dictionary(store.calendarConfigs().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let device = sync.authorized ? sync.allCalendars() : []
        rows = device.map { d in
            // Start from the stored config (if any), else a sensible default, then
            // refresh the device-sourced fields (title / account / device color).
            var c = stored[d.id] ?? CalendarConfig(
                id: d.id, title: d.title, account: d.account,
                deviceColorHex: d.colorHex,
                tier: defaultTier(forTitle: d.title),
                showOnTimeline: true, synced: false, isTaskDefault: false)
            c.title = d.title
            c.account = d.account
            c.deviceColorHex = d.colorHex
            return Row(id: d.id, title: d.title, account: d.account, isWritable: d.isWritable, config: c)
        }
    }

    // MARK: - Edits (persist + reload)

    func setSynced(_ id: String, _ on: Bool) { update(id) { $0.synced = on } }
    func setTier(_ id: String, _ tier: CalendarTier) { update(id) { $0.tier = tier } }
    func setShowOnTimeline(_ id: String, _ on: Bool) { update(id) { $0.showOnTimeline = on } }
    func setTaskDefault(_ id: String, _ on: Bool) { update(id) { $0.isTaskDefault = on } }
    /// nil hex = use the calendar's own device color.
    func setColorOverride(_ id: String, _ hex: String?) { update(id) { $0.colorHex = hex } }

    private func update(_ id: String, _ mutate: (inout CalendarConfig) -> Void) {
        guard var c = rows.first(where: { $0.id == id })?.config else { return }
        mutate(&c)
        store.upsertCalendarConfig(c)
        reload()
    }
}
