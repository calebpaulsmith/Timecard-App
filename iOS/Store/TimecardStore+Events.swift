import Foundation
import SwiftData

/// Calendar-mode event repository (Phase 5), mirroring the PWA's event helpers in
/// `db.js` (`eventsForDate/ForPeriod`, `upsertEvent`, `deleteEvent`, `getEvent`,
/// `recurringSeries`, `backlogEvents`, `eventByGoogleId`). Recurring **series**
/// are stored as one row (rrule + exdates) and expanded on read; plain rows and
/// overrides render directly. Lives as an extension so `TimecardStore` stays the
/// single repository facade over the shared `ModelContext`.
extension TimecardStore {

    // MARK: - Mapping

    static func toEvent(_ m: StoredEvent) -> CalEvent {
        CalEvent(
            id: m.id,
            date: m.date,
            title: m.title,
            allDay: m.allDay,
            startMin: m.startMin,
            endMin: m.endMin,
            color: EventColor(rawValue: m.color) ?? .personal,
            notes: m.notes,
            location: m.location,
            rrule: (m.rrule?.isEmpty == false) ? m.rrule : nil,
            exdates: m.exdatesJoined.isEmpty ? [] : m.exdatesJoined.split(separator: ",").map(String.init),
            seriesId: m.seriesId,
            source: m.source,
            needsScheduling: m.needsScheduling,
            externalId: m.externalId,
            externalUpdated: m.externalUpdated,
            createdAt: m.createdAt,
            updatedAt: m.updatedAt
        )
    }

    // MARK: - Reads

    func allEvents() -> [CalEvent] {
        let rows = (try? context.fetch(FetchDescriptor<StoredEvent>())) ?? []
        return rows.map(Self.toEvent)
    }

    func getEvent(id: String) -> CalEvent? {
        fetchEvent(id: id).map(Self.toEvent)
    }

    func eventByExternalId(_ externalId: String) -> CalEvent? {
        var d = FetchDescriptor<StoredEvent>(predicate: #Predicate { $0.externalId == externalId })
        d.fetchLimit = 1
        return (try? context.fetch(d).first).map(Self.toEvent)
    }

    /// Recurring series masters (rows carrying an rrule).
    func recurringSeries() -> [CalEvent] {
        allEvents().filter { $0.isSeries }
    }

    /// Backlog items (no date, flagged for scheduling).
    func backlogEvents() -> [CalEvent] {
        allEvents().filter { $0.needsScheduling && $0.date == nil }
    }

    /// All events that should render across `days` — plain/override rows whose
    /// date is in the window, PLUS series expanded on read (minus exdates). Series
    /// masters are never rendered directly.
    func resolveEvents(forDays days: [String]) -> [CalEvent] {
        guard let first = days.first, let last = days.last else { return [] }
        let set = Set(days)
        let all = allEvents()
        var out: [CalEvent] = []
        for ev in all {
            if ev.isSeries { continue }                 // expanded below
            if ev.needsScheduling || ev.date == nil { continue }
            if let d = ev.date, set.contains(d) { out.append(ev) }
        }
        for series in all where series.isSeries {
            out.append(contentsOf: expandSeries(series, winStart: first, winEnd: last))
        }
        return out
    }

    /// Events resolved for a single day (convenience over `resolveEvents`).
    func resolveEvents(forDay date: String) -> [CalEvent] {
        resolveEvents(forDays: [date]).filter { $0.date == date }
    }

    // MARK: - Writes

    @discardableResult
    func upsertEvent(_ event: CalEvent) -> CalEvent {
        let existing = fetchEvent(id: event.id)
        let model = existing ?? StoredEvent(id: event.id)
        model.date = event.date
        model.title = event.title
        model.allDay = event.allDay
        model.startMin = event.startMin
        model.endMin = event.endMin
        model.color = event.color.rawValue
        model.notes = event.notes
        model.location = event.location
        model.rrule = event.rrule
        model.exdatesJoined = event.exdates.joined(separator: ",")
        model.seriesId = event.seriesId
        model.source = event.source
        model.needsScheduling = event.needsScheduling
        model.externalId = event.externalId
        model.externalUpdated = event.externalUpdated
        model.createdAt = existing?.createdAt ?? event.createdAt
        model.updatedAt = event.updatedAt
        if existing == nil { context.insert(model) }
        try? context.save()
        return event
    }

    func deleteEvent(id: String) {
        if let m = fetchEvent(id: id) { context.delete(m); try? context.save() }
    }

    /// Add an EXDATE to a series (cancel one occurrence) and persist.
    func addExdate(seriesId: String, date: String) {
        guard var series = getEvent(id: seriesId) else { return }
        guard !series.exdates.contains(date) else { return }
        series.exdates.append(date)
        series.updatedAt = Date()
        upsertEvent(series)
    }

    private func fetchEvent(id: String) -> StoredEvent? {
        var d = FetchDescriptor<StoredEvent>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }
}
