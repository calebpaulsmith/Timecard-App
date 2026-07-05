import Foundation
import Observation

/// Handles an **opened activity** — a calendar event brought into Timecard from
/// outside the app: a `.ics` file ("Open in / Copy to Timecard" from Mail, Files,
/// Safari, Messages) or a `webcal://` / http(s) `.ics` link. It parses the file
/// (`parseEventsIcs`) and walks the user through the add flow, presenting the
/// shared `EventEditView` prefilled for each event so they can pick the day,
/// calendar, and reminder before saving. Saving stores a local event which then
/// syncs to the chosen device calendar via EventKit — i.e. it lands on "the
/// calendar." Conforms to `EventEditing` so the same editor sheet drives it.
///
/// Note: iOS's native data-detector "create event" affordance always targets
/// Apple Calendar and can't be redirected to a third-party app, so this handles
/// the shareable-file/link path instead (the confirmed fallback).
@MainActor
@Observable
final class ActivityOpener: EventEditing {
    /// Set once the view has an environment `modelContext` (see `RootView`).
    var store: TimecardStore?

    /// The event currently being confirmed in the editor sheet (nil = none).
    var current: EventDraft?
    /// A transient error to surface (bad file, no events, failed download).
    var message: String?

    /// Remaining parsed events to walk through after `current` (a multi-event
    /// `.ics` presents one editor at a time).
    private var queue: [EventDraft] = []

    /// Nonisolated so it can be a plain `@State` default value in `RootView`
    /// (constructing a `@MainActor` type in a View's nonisolated init otherwise
    /// trips strict concurrency). All stored props have defaults; the body is empty.
    nonisolated init() {}

    /// Synced device calendars the imported event can be assigned to (so it lands
    /// on a real calendar). Empty → the editor falls back to the in-app color.
    var calendars: [CalendarConfig] { store?.calendarConfigs().filter { $0.synced } ?? [] }

    /// Entry point from `.onOpenURL`. Reads a file directly or downloads a link,
    /// then parses + starts the add flow.
    func open(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                message = "Couldn't read that file."
                return
            }
            ingest(text)
        } else if scheme == "webcal" || scheme == "http" || scheme == "https" {
            // webcal is just http(s) for an .ics subscription — swap the scheme.
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if scheme == "webcal" { comps?.scheme = "https" }
            guard let fetchURL = comps?.url else { message = "That link looks invalid."; return }
            Task { await fetchAndIngest(fetchURL) }
        }
        // Unknown schemes (e.g. a future timecard:// deep link) are ignored.
    }

    private func fetchAndIngest(_ url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            ingest(String(decoding: data, as: UTF8.self))
        } catch {
            message = "Couldn't download that calendar link. Check your connection and try again."
        }
    }

    private func ingest(_ text: String) {
        let events = parseEventsIcs(text)
        guard !events.isEmpty else {
            message = "No calendar events were found in that file."
            return
        }
        queue = events.map { EventDraft(importing: $0) }
        presentNext()
    }

    /// Advance to the next parsed event (called on sheet dismiss). Clears the sheet
    /// when the queue is empty.
    func presentNext() {
        current = queue.isEmpty ? nil : queue.removeFirst()
    }

    // MARK: - EventEditing

    func saveEvent(_ ev: CalEvent) {
        guard let store else { return }
        var e = ev
        e.updatedAt = Date()
        store.upsertEvent(e)
        Task { await EventReminderScheduler.refresh(store: store) }
    }

    func deleteEvent(_ ev: CalEvent, thisOccurrenceOnly: Bool) {
        // Import flow only ever creates events, but conformance needs this.
        store?.deleteEvent(id: ev.id)
    }
}
