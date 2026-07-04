import Foundation

/// A calendar event's own local-notification reminder. Kept separate from
/// `ReminderSpec`/`ReminderKind` (Domain/ReminderSchedule.swift) — those are the
/// three fixed timecard nudges with static per-kind ids; event reminders are
/// per-event(-occurrence), so they carry their own dynamic id instead.
///
/// Only built for events NOT linked to a device calendar (`externalId == nil`).
/// A synced event's reminder is instead a native `EKAlarm` attached on push (see
/// `EventKitSync.apply`), which the OS fires without our app running — the local
/// notification here is the fallback for events that never reach EventKit.
struct EventReminderSpec: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var body: String
    var fireDate: Date
}

/// Build reminders for `events` (already resolved/expanded by the caller over its
/// window — see `TimecardStore.resolveEvents(forDays:)`) whose
/// `reminderMinutesBefore` is set. Only future fire dates are returned.
func buildEventReminders(events: [CalEvent], now: Date,
                         calendar: Calendar = DomainCalendar.shared) -> [EventReminderSpec] {
    var out: [EventReminderSpec] = []
    for ev in events {
        guard let minutes = ev.reminderMinutesBefore, minutes >= 0 else { continue }
        guard ev.externalId == nil else { continue }   // synced → EKAlarm handles it
        guard let date = ev.date else { continue }

        let startDate = ev.allDay
            ? parseLocalDate(date, calendar: calendar)
            : buildDateTime(date, hour24: ev.startMin / 60, minute: ev.startMin % 60, calendar: calendar)
        let fire = startDate.addingTimeInterval(-Double(minutes) * 60)
        guard fire > now else { continue }

        // Recurring occurrences share the series id (`occurrenceOf`) but each has
        // its own date — key on both so one occurrence's reminder doesn't clobber
        // another's pending request.
        let stableId = ev.occurrenceOf ?? ev.id
        out.append(EventReminderSpec(
            id: "event-reminder-\(stableId)-\(date)",
            title: ev.title.isEmpty ? "Event" : ev.title,
            body: eventReminderLeadText(minutes),
            fireDate: fire))
    }
    return out
}

/// "15 min before" / "2 hours before" / "1 day before" style caption, shared by
/// the reminder picker (Features) and the notification body (Platform).
func eventReminderLeadText(_ minutes: Int) -> String {
    if minutes == 0 { return "At time of event" }
    if minutes % (24 * 60) == 0 {
        let d = minutes / (24 * 60)
        return "\(d) day\(d == 1 ? "" : "s") before"
    }
    if minutes % 60 == 0 {
        let h = minutes / 60
        return "\(h) hour\(h == 1 ? "" : "s") before"
    }
    return "\(minutes) min before"
}
