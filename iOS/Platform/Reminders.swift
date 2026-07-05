import Foundation
import UserNotifications

/// Thin platform adapter over `UNUserNotificationCenter`. The *what/when* is
/// computed purely in `Domain/ReminderSchedule.swift` (`buildReminders`); this
/// only requests authorization and (re)schedules the resulting specs. Local
/// notifications need no entitlement or Info.plist key.
@MainActor
enum ReminderScheduler {
    private static var ourIds: [String] { ReminderKind.allCases.map(\.rawValue) }

    /// Ask the system for permission (idempotent — the OS only prompts once).
    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Remove every reminder we own (used when the feature is turned off).
    static func clearAll() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ourIds)
    }

    /// Replace our pending reminders with `specs` (all future-dated). Reusing the
    /// kind's stable id means re-running this never duplicates.
    static func reschedule(_ specs: [ReminderSpec], calendar: Calendar = .current) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ourIds)
        for spec in specs {
            let content = UNMutableNotificationContent()
            content.title = spec.title
            content.body = spec.body
            content.sound = .default
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: spec.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let req = UNNotificationRequest(identifier: spec.id, content: content, trigger: trigger)
            try? await center.add(req)
        }
    }

    /// Gather live inputs from the store and (re)schedule. No-op (and clears any
    /// stale reminders) when the feature is disabled. Call on launch/foreground
    /// and after clock in/out or relevant edits.
    static func refresh(store: TimecardStore, now: Date = Date(),
                        calendar: Calendar = DomainCalendar.shared) async {
        guard store.remindersEnabled else { clearAll(); return }

        let anchor = store.anchorDate ?? PeriodViewModel.defaultAnchor(now, calendar: calendar)
        let period = payPeriodFor(today: now, anchor: anchor, calendar: calendar)
        let dayset = Set(period.days)
        let entries = store.allEntries()

        var leaveByDate: [String: Double] = [:]
        for l in store.allLeave() where dayset.contains(l.date) { leaveByDate[l.date] = l.hours }

        // Live open entry (the running clock), if any.
        let scan = scanOpenEntry(entries, now: now)
        var open: OpenEntry?
        let openStart = scan.openId.flatMap { id in entries.first { $0.id == id }?.startTime }
        if let id = scan.openId, let e = entries.first(where: { $0.id == id }), let start = e.startTime {
            open = OpenEntry(date: e.date, startTime: start, payKind: e.payKind)
        }

        // worked + leave toward the 80 (mode-independent; `total` already sums them).
        let totals = periodTotals(period: period,
                                  entries: entries.filter { dayset.contains($0.date) },
                                  leaveByDate: leaveByDate,
                                  schedule: store.defaultSchedule(),
                                  otMode: store.otMode(forPeriodStart: period.days.first ?? ""),
                                  holidays: store.holidays(),
                                  openEntry: open,
                                  creditEnabled: store.creditHoursEnabled,
                                  now: now, calendar: calendar)

        let specs = buildReminders(now: now,
                                   period: period,
                                   validationDayIndex: store.validationDay(),
                                   workedPlusLeave: totals.total,
                                   openEntryStart: openStart,
                                   calendar: calendar)
        await reschedule(specs, calendar: calendar)
    }
}

/// Companion to `ReminderScheduler` for per-event reminders (calendar mode).
/// Kept as its own scheduler because event reminder ids are dynamic (one per
/// event/occurrence, not one of the fixed `ReminderKind`s) — pending requests we
/// own are discovered by id prefix rather than a static list.
@MainActor
enum EventReminderScheduler {
    private static let idPrefix = "event-reminder-"
    /// How far ahead to resolve events (expanding recurring series) when scanning
    /// for reminders to schedule. Mirrors the bounded-window pattern used
    /// elsewhere (e.g. EventKit sync, schedule sync) rather than an unbounded scan.
    private static let daysAhead = 60

    private static func clearStale() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
    }

    /// Replace our pending event reminders with `specs` (all future-dated).
    static func reschedule(_ specs: [EventReminderSpec], calendar: Calendar = .current) async {
        await clearStale()
        let center = UNUserNotificationCenter.current()
        for spec in specs {
            let content = UNMutableNotificationContent()
            content.title = spec.title
            content.body = spec.body
            content.sound = .default
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: spec.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let req = UNNotificationRequest(identifier: spec.id, content: content, trigger: trigger)
            try? await center.add(req)
        }
    }

    /// Gather live events and (re)schedule. Gated on the same reminders toggle as
    /// `ReminderScheduler` AND on calendar mode being on (no point scheduling
    /// reminders for a hidden feature); clears any stale ones when either is off.
    static func refresh(store: TimecardStore, now: Date = Date(),
                        calendar: Calendar = DomainCalendar.shared) async {
        guard store.remindersEnabled, UserDefaults.standard.bool(forKey: "calendarMode") else {
            await clearStale()
            return
        }
        let start = startOfDay(now, calendar: calendar)
        var days: [String] = []
        var d = start
        for _ in 0...daysAhead {
            days.append(formatLocalDate(d, calendar: calendar))
            d = addDays(d, 1, calendar: calendar)
        }
        let events = store.resolveEvents(forDays: days)
        let specs = buildEventReminders(events: events, now: now, calendar: calendar)
        await reschedule(specs, calendar: calendar)
    }
}
