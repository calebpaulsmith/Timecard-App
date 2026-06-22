import Foundation
import EventKit

/// Two-way sync between the app's calendar-mode events and a device calendar
/// (Phase 6). On iOS, EventKit reads/writes the device's calendar database, which
/// includes any **Google** (or iCloud / Exchange) account the user has added in
/// iOS Settings — so picking a Google calendar here gives true two-way Google
/// sync with **no** OAuth, server, or token handling (the device account does it).
///
/// Reconciliation mirrors the PWA's Google sync (`app.js` `googleSyncNow`):
/// local-origin events push up (insert new → store `externalId`; patch when the
/// local row changed since last sync), then device events pull down (matched by
/// the indexed `externalId` = `EKEvent.eventIdentifier`; an `externalUpdated`
/// stamp skips unchanged rows to avoid churn). Cancelled remote events tombstone
/// the local copy.
///
/// **Deferred (matching the PWA):** pushing local *deletions* up; recurrence-
/// override push; recurring pull uses the first in-window occurrence as the
/// series anchor.
@MainActor
final class EventKitSync {
    let store: TimecardStore
    let eventStore: EKEventStore
    let calendar: Calendar

    init(store: TimecardStore, calendar: Calendar = DomainCalendar.shared,
         eventStore: EKEventStore = EKEventStore()) {
        self.store = store
        self.calendar = calendar
        self.eventStore = eventStore
    }

    // MARK: - Authorization

    /// True when the app may read AND write events.
    var authorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Prompt for full calendar access (iOS 17 API). Returns whether it was granted.
    func requestAccess() async -> Bool {
        do { return try await eventStore.requestFullAccessToEvents() }
        catch { return false }
    }

    // MARK: - Calendars

    struct CalendarInfo: Identifiable, Equatable, Sendable {
        let id: String          // EKCalendar.calendarIdentifier
        let title: String
        let account: String     // source title (e.g. "Google", "iCloud")
    }

    /// Writable event calendars (the candidates for the sync target). Google
    /// calendars surface here once the account is added in iOS Settings.
    func availableCalendars() -> [CalendarInfo] {
        eventStore.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    /// Identifier of the resolved target calendar (for the Settings picker
    /// default), exposed as a plain String so non-EventKit callers don't need to
    /// import EventKit.
    var defaultCalendarId: String? { targetCalendar()?.calendarIdentifier }

    /// Resolve the configured target calendar, falling back to the default
    /// new-event calendar.
    func targetCalendar() -> EKCalendar? {
        if let id = store.stringSetting("eventKitCalendarId"),
           let cal = eventStore.calendar(withIdentifier: id) {
            return cal
        }
        return eventStore.defaultCalendarForNewEvents
    }

    // MARK: - Sync

    enum SyncOutcome: Equatable {
        case ok(pushed: Int, pulled: Int, deleted: Int)
        case needsAccess
        case noCalendar
    }

    @discardableResult
    func sync(daysBack: Int = 30, daysAhead: Int = 120, now: Date = Date()) async -> SyncOutcome {
        guard authorized else { return .needsAccess }
        guard let target = targetCalendar() else { return .noCalendar }

        let pushed = pushLocalToDevice(target: target)
        let (pulled, deleted) = pullDeviceToLocal(target: target, daysBack: daysBack, daysAhead: daysAhead, now: now)

        store.setRawSetting("eventKitLastSync", JSONValue.encode(now.timeIntervalSince1970))
        return .ok(pushed: pushed, pulled: pulled, deleted: deleted)
    }

    var lastSync: Date? {
        guard let raw = store.rawSetting("eventKitLastSync"),
              let n = JSONValue.decode(raw) as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue)
    }

    // MARK: - Push (local → device)

    private func pushLocalToDevice(target: EKCalendar) -> Int {
        var pushed = 0
        for ev in store.allEvents() {
            guard ev.isLocal, !ev.needsScheduling, ev.date != nil else { continue }
            guard ev.seriesId == nil else { continue }   // override push deferred

            if let ext = ev.externalId {
                guard let ek = eventStore.event(withIdentifier: ext) else { continue } // remote gone → skip (deferred)
                if let eu = ev.externalUpdated, ev.updatedAt <= eu { continue }         // unchanged locally
                apply(ev, to: ek, target: target)
                if save(ek, recurring: ev.isSeries) {
                    var updated = ev
                    updated.externalUpdated = ek.lastModifiedDate ?? Date()
                    store.upsertEvent(updated)
                    pushed += 1
                }
            } else {
                let ek = EKEvent(eventStore: eventStore)
                apply(ev, to: ek, target: target)
                if save(ek, recurring: ev.isSeries) {
                    var updated = ev
                    updated.externalId = ek.eventIdentifier
                    updated.externalUpdated = ek.lastModifiedDate ?? Date()
                    store.upsertEvent(updated)
                    pushed += 1
                }
            }
        }
        return pushed
    }

    private func save(_ ek: EKEvent, recurring: Bool) -> Bool {
        do {
            try eventStore.save(ek, span: recurring ? .futureEvents : .thisEvent, commit: true)
            return true
        } catch { return false }
    }

    /// Write a local event's fields onto an `EKEvent`.
    private func apply(_ ev: CalEvent, to ek: EKEvent, target: EKCalendar) {
        ek.calendar = target
        ek.title = ev.title.isEmpty ? "(untitled)" : ev.title
        ek.notes = ev.notes.isEmpty ? nil : ev.notes
        ek.location = ev.location.isEmpty ? nil : ev.location
        guard let date = ev.date else { return }

        if ev.allDay {
            let day = parseLocalDate(date, calendar: calendar)
            ek.isAllDay = true
            ek.startDate = day
            ek.endDate = day
        } else {
            ek.isAllDay = false
            let start = buildDateTime(date, hour24: ev.startMin / 60, minute: ev.startMin % 60, calendar: calendar)
            var end = buildDateTime(date, hour24: max(0, ev.endMin) / 60, minute: max(0, ev.endMin) % 60, calendar: calendar)
            if end <= start { end = start.addingTimeInterval(3600) }
            ek.startDate = start
            ek.endDate = end
        }

        if let body = ev.rrule, let rule = Self.ekRecurrence(from: body, calendar: calendar) {
            ek.recurrenceRules = [rule]
        } else {
            ek.recurrenceRules = nil
        }
    }

    // MARK: - Pull (device → local)

    private func pullDeviceToLocal(target: EKCalendar, daysBack: Int, daysAhead: Int, now: Date) -> (pulled: Int, deleted: Int) {
        let startDate = addDays(startOfDay(now, calendar: calendar), -daysBack, calendar: calendar)
        let endDate = addDays(startOfDay(now, calendar: calendar), daysAhead, calendar: calendar)
        let startStr = formatLocalDate(startDate, calendar: calendar)
        let endStr = formatLocalDate(endDate, calendar: calendar)

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: [target])
        let ekEvents = eventStore.events(matching: predicate)

        var seen = Set<String>()
        var firstById: [String: EKEvent] = [:]    // dedupe recurring occurrences → earliest
        for ek in ekEvents {
            let id = ek.eventIdentifier ?? ""
            guard !id.isEmpty else { continue }
            seen.insert(id)
            if firstById[id] == nil { firstById[id] = ek }   // events() are start-sorted
        }

        var pulled = 0
        for (id, ek) in firstById {
            if var local = store.eventByExternalId(id) {
                if let lu = local.externalUpdated, let ru = ek.lastModifiedDate, ru <= lu { continue }
                applyRemote(ek, into: &local)
                store.upsertEvent(local)
                pulled += 1
            } else {
                var local = CalEvent(source: "local", externalId: id)
                applyRemote(ek, into: &local)
                store.upsertEvent(local)
                pulled += 1
            }
        }

        // Reconcile deletions: a linked, non-recurring local row whose date is in
        // the synced window but is no longer present remotely was deleted on the
        // device → tombstone the local copy.
        var deleted = 0
        for ev in store.allEvents() {
            guard let ext = ev.externalId, !seen.contains(ext), !ev.isSeries,
                  let d = ev.date, d >= startStr, d <= endStr else { continue }
            store.deleteEvent(id: ev.id)
            deleted += 1
        }
        return (pulled, deleted)
    }

    /// Write a device `EKEvent`'s fields into a local event (preserving the local
    /// color/notes choices only for fields EventKit doesn't carry — color is local).
    private func applyRemote(_ ek: EKEvent, into ev: inout CalEvent) {
        ev.title = ek.title ?? ""
        ev.allDay = ek.isAllDay
        ev.location = ek.location ?? ""
        ev.notes = ek.notes ?? ""
        ev.externalUpdated = ek.lastModifiedDate
        ev.updatedAt = ek.lastModifiedDate ?? Date()

        let start = ek.startDate ?? Date()
        ev.date = formatLocalDate(start, calendar: calendar)
        if ek.isAllDay {
            ev.startMin = 0
            ev.endMin = 24 * 60
        } else {
            ev.startMin = minutesOf(start)
            let end = ek.endDate ?? start.addingTimeInterval(3600)
            // If the event ends on a later day, clamp to end-of-day.
            ev.endMin = (daysBetween(start, end, calendar: calendar) == 0) ? minutesOf(end) : 24 * 60
        }

        if let rule = ek.recurrenceRules?.first, let body = Self.rruleBody(from: rule, calendar: calendar) {
            ev.rrule = body
        } else {
            ev.rrule = nil
        }
    }

    private func minutesOf(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    // MARK: - Recurrence mapping (RRULE ↔ EKRecurrenceRule)

    static func ekRecurrence(from body: String, calendar: Calendar) -> EKRecurrenceRule? {
        guard let r = parseRRule(body) else { return nil }
        let freq: EKRecurrenceFrequency
        switch r.freq {
        case "DAILY": freq = .daily
        case "WEEKLY": freq = .weekly
        case "MONTHLY": freq = .monthly
        case "YEARLY": freq = .yearly
        default: return nil
        }
        var days: [EKRecurrenceDayOfWeek]? = nil
        if freq == .weekly, !r.byday.isEmpty {
            let mapped = r.byday.compactMap { code -> EKRecurrenceDayOfWeek? in
                guard let idx = rruleDow.firstIndex(of: code), let wd = EKWeekday(rawValue: idx + 1) else { return nil }
                return EKRecurrenceDayOfWeek(wd)
            }
            if !mapped.isEmpty { days = mapped }
        }
        var end: EKRecurrenceEnd? = nil
        if let c = r.count {
            end = EKRecurrenceEnd(occurrenceCount: c)
        } else if let u = r.until, u.count >= 8 {
            let y = String(u.prefix(4)), m = String(u.dropFirst(4).prefix(2)), d = String(u.dropFirst(6).prefix(2))
            end = EKRecurrenceEnd(end: parseLocalDate("\(y)-\(m)-\(d)", calendar: calendar))
        }
        return EKRecurrenceRule(recurrenceWith: freq, interval: max(1, r.interval),
                                daysOfTheWeek: days, daysOfTheMonth: nil, monthsOfTheYear: nil,
                                weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
    }

    static func rruleBody(from rule: EKRecurrenceRule, calendar: Calendar) -> String? {
        let freq: String
        switch rule.frequency {
        case .daily: freq = "DAILY"
        case .weekly: freq = "WEEKLY"
        case .monthly: freq = "MONTHLY"
        case .yearly: freq = "YEARLY"
        @unknown default: return nil
        }
        var byday: [String] = []
        if rule.frequency == .weekly, let days = rule.daysOfTheWeek {
            byday = days.compactMap { d in
                let idx = d.dayOfTheWeek.rawValue - 1
                return (idx >= 0 && idx < rruleDow.count) ? rruleDow[idx] : nil
            }
        }
        var count: Int? = nil
        var until: String? = nil
        if let end = rule.recurrenceEnd {
            if end.occurrenceCount > 0 {
                count = end.occurrenceCount
            } else if let d = end.endDate {
                until = formatLocalDate(d, calendar: calendar).replacingOccurrences(of: "-", with: "")
            }
        }
        return formatRRule(RecurrenceRule(freq: freq, interval: max(1, rule.interval),
                                          byday: byday, count: count, until: until))
    }
}
