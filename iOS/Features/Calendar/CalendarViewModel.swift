import Foundation
import Observation

/// Drives the Calendar tab: resolves the viewed pay-period window, groups events
/// by day (series expanded on read), exposes the backlog, and wraps the EventKit
/// two-way sync. UI is dumb; all recurrence/expansion math lives in Domain.
@MainActor
@Observable
final class CalendarViewModel {
    private let store: TimecardStore
    let sync: EventKitSync
    private let calendar: Calendar

    private(set) var offset = 0
    private(set) var anchor: String
    private(set) var period: PayPeriod
    private(set) var rows: [DayEvents] = []
    private(set) var backlog: [CalEvent] = []

    /// Transient status line shown after a sync (success or failure).
    var statusMessage: String?
    var isSyncing = false

    struct DayEvents: Identifiable {
        var id: String { date }
        var date: String
        var label: String
        var isToday: Bool
        var events: [CalEvent]
    }

    init(store: TimecardStore, calendar: Calendar = DomainCalendar.shared, today: Date = Date()) {
        self.store = store
        self.calendar = calendar
        self.sync = EventKitSync(store: store, calendar: calendar)
        let resolved = store.anchorDate ?? PeriodViewModel.defaultAnchor(today, calendar: calendar)
        self.anchor = resolved
        self.period = payPeriodFor(today: today, anchor: resolved, calendar: calendar)
        reload(today: today)
    }

    var periodName: String { payPeriodName(period, anchor: anchor, calendar: calendar) }
    var dateRange: String {
        "\(formatDateShort(period.days.first ?? "", calendar: calendar)) – \(formatDateShort(period.days.last ?? "", calendar: calendar))"
    }
    var use24h: Bool { store.use24h }
    var lastSyncText: String? {
        guard let d = sync.lastSync else { return nil }
        let f = DateFormatter()
        f.calendar = calendar
        f.dateStyle = .short
        f.timeStyle = .short
        return "Last synced \(f.string(from: d))"
    }

    func previous() { offset -= 1; reload() }
    func next() { offset += 1; reload() }

    func reload(today: Date = Date()) {
        anchor = store.anchorDate ?? PeriodViewModel.defaultAnchor(today, calendar: calendar)
        period = payPeriodOffset(today: today, anchor: anchor, offset: offset, calendar: calendar)

        let resolved = store.resolveEvents(forDays: period.days)
        var byDate: [String: [CalEvent]] = [:]
        for ev in resolved {
            guard let d = ev.date else { continue }
            byDate[d, default: []].append(ev)
        }
        let todayStr = formatLocalDate(today, calendar: calendar)
        rows = period.days.map { d in
            let evs = (byDate[d] ?? []).sorted { a, b in
                if a.allDay != b.allDay { return a.allDay }   // all-day first
                return a.startMin < b.startMin
            }
            return DayEvents(date: d, label: formatDateShort(d, calendar: calendar),
                             isToday: d == todayStr, events: evs)
        }
        backlog = store.backlogEvents()
    }

    // MARK: - Editing (EventEditing)

    func saveEvent(_ ev: CalEvent) {
        var e = ev
        e.updatedAt = Date()
        store.upsertEvent(e)
        reload()
        refreshEventReminders()
    }

    // MARK: - Multi-calendar resolution

    var calendarOptions: [CalendarConfig] { store.calendarConfigs().filter { $0.synced } }
    var taskCalendarId: String? { store.taskCalendarId() }
    func eventColorHex(_ ev: CalEvent) -> String? { store.colorHex(forEvent: ev) }
    func tier(_ ev: CalEvent) -> CalendarTier { store.tier(forEvent: ev) }

    /// Delete an event. For a recurring occurrence, "this" cancels just that day
    /// (adds an exdate); otherwise the whole row is removed.
    func deleteEvent(_ ev: CalEvent, thisOccurrenceOnly: Bool) {
        if ev.isOccurrence, thisOccurrenceOnly, let sid = ev.occurrenceOf, let d = ev.date {
            store.addExdate(seriesId: sid, date: d)
        } else if let sid = ev.occurrenceOf {
            store.deleteEvent(id: sid)            // delete the whole series
        } else {
            store.deleteEvent(id: ev.id)
        }
        reload()
        refreshEventReminders()
    }

    /// Schedule a backlog item onto a date.
    func schedule(_ ev: CalEvent, on date: String) {
        var e = ev
        e.date = date
        e.needsScheduling = false
        e.updatedAt = Date()
        store.upsertEvent(e)
        reload()
        refreshEventReminders()
    }

    // MARK: - Sync

    func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        if !sync.authorized {
            let granted = await sync.requestAccess()
            if !granted { statusMessage = "Calendar access denied. Enable it in Settings › Privacy › Calendars."; return }
        }
        let outcome = await sync.sync()
        switch outcome {
        case .ok(let pushed, let pulled, let deleted):
            statusMessage = "Synced — \(pushed) up, \(pulled) down" + (deleted > 0 ? ", \(deleted) removed" : "")
        case .needsAccess:
            statusMessage = "Calendar access is required to sync."
        case .noCalendar:
            statusMessage = "Pick a calendar to sync with in Settings."
        }
        reload()
        // A sync can flip an event between unsynced (local notification) and
        // synced (native EKAlarm), or pull back a device-set alarm — re-resolve.
        await EventReminderScheduler.refresh(store: store)
    }

    /// Re-evaluate event reminders after an edit (fire-and-forget; UI doesn't wait).
    private func refreshEventReminders() {
        let store = self.store
        Task { await EventReminderScheduler.refresh(store: store) }
    }
}

extension CalendarViewModel: EventEditing {}
