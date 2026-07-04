import SwiftUI

/// Add/edit draft for the event sheet. `existing` carries an event id when
/// editing; otherwise it's a new event seeded on a date (or a backlog item).
struct EventDraft: Identifiable {
    let id = UUID()
    var existing: CalEvent?
    var date: String?
    var title: String
    var allDay: Bool
    var startMin: Int
    var endMin: Int
    var color: EventColor
    /// Owning device calendar (nil = in-app/local-only). Drives color + tier.
    var calendarId: String?
    var location: String
    var notes: String
    var repeatPreset: RepeatPreset
    var isOccurrence: Bool
    /// Minutes before start to remind (nil = no reminder). See
    /// `CalEvent.reminderMinutesBefore`.
    var reminderMinutesBefore: Int?

    /// A new event on a given date.
    init(onDate date: String) {
        self.existing = nil
        self.date = date
        self.title = ""
        self.allDay = false
        self.startMin = 9 * 60
        self.endMin = 10 * 60
        self.color = .personal
        self.calendarId = nil
        self.location = ""
        self.notes = ""
        self.repeatPreset = .none
        self.isOccurrence = false
        self.reminderMinutesBefore = nil
    }

    /// A new **task** on a given date, pre-routed to the task calendar.
    init(taskOnDate date: String, calendarId: String?) {
        self.init(onDate: date)
        self.calendarId = calendarId
    }

    /// Edit an existing event (or a recurring occurrence).
    init(from ev: CalEvent) {
        self.existing = ev
        self.date = ev.date
        self.title = ev.title
        self.allDay = ev.allDay
        self.startMin = ev.startMin
        self.endMin = ev.endMin
        self.color = ev.color
        self.calendarId = ev.calendarId
        self.location = ev.location
        self.notes = ev.notes
        self.repeatPreset = RepeatPreset.from(rrule: ev.rrule)
        self.isOccurrence = ev.isOccurrence
        self.reminderMinutesBefore = ev.reminderMinutesBefore
    }
}

/// A small set of recurrence presets (the engine supports more; this is the UI).
enum RepeatPreset: String, CaseIterable, Identifiable {
    case none, daily, weekly, biweekly, monthly, yearly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Does not repeat"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    var rrule: String? {
        switch self {
        case .none: return nil
        case .daily: return "FREQ=DAILY"
        case .weekly: return "FREQ=WEEKLY"
        case .biweekly: return "FREQ=WEEKLY;INTERVAL=2"
        case .monthly: return "FREQ=MONTHLY"
        case .yearly: return "FREQ=YEARLY"
        }
    }

    static func from(rrule: String?) -> RepeatPreset {
        guard let r = parseRRule(rrule) else { return .none }
        switch r.freq {
        case "DAILY": return .daily
        case "WEEKLY": return r.interval >= 2 ? .biweekly : .weekly
        case "MONTHLY": return .monthly
        case "YEARLY": return .yearly
        default: return .none
        }
    }
}

/// A shortcut list of common reminder lead times for the picker; any other
/// non-negative minute count (e.g. read back from a device alarm someone set in
/// Apple Calendar) resolves to `.custom` and shows a stepper with the exact value.
enum ReminderPreset: Hashable, CaseIterable, Identifiable {
    case none, atTime, min5, min15, min30, hour1, hour2, day1, custom
    var id: Self { self }

    static let dayMinutes = 24 * 60

    /// The fixed minute value for every case except `.custom` (resolved
    /// separately from the stepper's live value).
    var minutes: Int? {
        switch self {
        case .none: return nil
        case .atTime: return 0
        case .min5: return 5
        case .min15: return 15
        case .min30: return 30
        case .hour1: return 60
        case .hour2: return 120
        case .day1: return Self.dayMinutes
        case .custom: return nil
        }
    }

    var label: String {
        switch self {
        case .none: return "None"
        case .atTime: return "At time of event"
        case .min5: return "5 minutes before"
        case .min15: return "15 minutes before"
        case .min30: return "30 minutes before"
        case .hour1: return "1 hour before"
        case .hour2: return "2 hours before"
        case .day1: return "1 day before"
        case .custom: return "Custom…"
        }
    }

    /// Resolve a stored minute count back to a preset; any value outside the
    /// fixed list (a custom pick, or an imported device alarm) becomes `.custom`.
    static func from(_ value: Int?) -> ReminderPreset {
        guard let value else { return .none }
        return allCases.first { $0 != .none && $0 != .custom && $0.minutes == value } ?? .custom
    }
}

/// Lets the event editor sheet drive either view model that owns events — the
/// Calendar tab (`CalendarViewModel`) or the Period view's expand-in-place
/// (`PeriodViewModel`). Both already implement these; conformance is declared
/// in an extension next to each.
@MainActor
protocol EventEditing {
    func saveEvent(_ ev: CalEvent)
    func deleteEvent(_ ev: CalEvent, thisOccurrenceOnly: Bool)
}

/// Event editor sheet — title, color, all-day, quarter-hour start/end, repeat,
/// location, notes, and delete (with this-vs-all for recurring occurrences).
struct EventEditView: View {
    let draft: EventDraft
    let model: any EventEditing
    /// Synced calendars the event can be assigned to (empty = no device calendars
    /// configured → fall back to the in-app color picker).
    let calendars: [CalendarConfig]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @State private var title: String
    @State private var allDay: Bool
    @State private var startMin: Int
    @State private var endMin: Int
    @State private var color: EventColor
    @State private var calendarId: String?
    @State private var location: String
    @State private var notes: String
    @State private var repeatPreset: RepeatPreset
    @State private var reminderPreset: ReminderPreset
    @State private var customReminderMinutes: Int
    @State private var showDeleteChoice = false

    init(draft: EventDraft, model: any EventEditing, calendars: [CalendarConfig] = []) {
        self.draft = draft
        self.model = model
        self.calendars = calendars
        _title = State(initialValue: draft.title)
        _allDay = State(initialValue: draft.allDay)
        _startMin = State(initialValue: draft.startMin)
        _endMin = State(initialValue: draft.endMin)
        _color = State(initialValue: draft.color)
        // New events default to the first synced calendar (so they sync by
        // default); a task draft already carries its target; editing keeps its own.
        let initialCal = draft.calendarId ?? (draft.existing == nil ? calendars.first?.id : nil)
        _calendarId = State(initialValue: initialCal)
        _location = State(initialValue: draft.location)
        _notes = State(initialValue: draft.notes)
        _repeatPreset = State(initialValue: draft.repeatPreset)
        let preset = ReminderPreset.from(draft.reminderMinutesBefore)
        _reminderPreset = State(initialValue: preset)
        _customReminderMinutes = State(initialValue: (preset == .custom ? draft.reminderMinutesBefore : nil) ?? 30)
    }

    private var valid: Bool { allDay || endMin > startMin }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                }

                if calendars.isEmpty {
                    // No device calendars registered → keep the legacy in-app color.
                    Section("Color") {
                        Picker("Color", selection: $color) {
                            ForEach(EventColor.allCases, id: \.self) { c in
                                Label { Text(c.label) } icon: {
                                    Circle().fill(palette.eventColor(c)).frame(width: 12, height: 12)
                                }.tag(c)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } else {
                    Section {
                        Picker("Calendar", selection: $calendarId) {
                            Text("None (local only)").tag(Optional<String>.none)
                            ForEach(calendars) { c in
                                Label { Text(c.title.isEmpty ? c.id : c.title) } icon: {
                                    Circle().fill(Color(hex: c.effectiveColorHex ?? "#8E8E93"))
                                        .frame(width: 12, height: 12)
                                }.tag(Optional(c.id))
                            }
                        }
                        .pickerStyle(.menu)
                    } header: {
                        Text("Calendar")
                    } footer: {
                        Text("Each calendar has its own color and line position (above / on / below). Manage these in Settings › Calendars.")
                    }
                }

                Section("Time") {
                    Toggle("All-day", isOn: $allDay)
                    if !allDay {
                        HStack { Text("Start"); Spacer(); QuarterHourPicker(minutes: $startMin) }
                        HStack { Text("End"); Spacer(); QuarterHourPicker(minutes: $endMin) }
                        if !valid {
                            Text("End time must be after start time.")
                                .font(.footnote).foregroundStyle(.red)
                        }
                    }
                }

                Section("Repeat") {
                    Picker("Repeat", selection: $repeatPreset) {
                        ForEach(RepeatPreset.allCases) { p in Text(p.label).tag(p) }
                    }
                    .pickerStyle(.menu)
                    if draft.isOccurrence {
                        Text("Editing this occurrence updates the whole series.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("Remind me", selection: $reminderPreset) {
                        ForEach(ReminderPreset.allCases) { p in Text(p.label).tag(p) }
                    }
                    .pickerStyle(.menu)
                    if reminderPreset == .custom {
                        Stepper("\(customReminderMinutes) min before",
                                value: $customReminderMinutes, in: 1...(14 * ReminderPreset.dayMinutes), step: 5)
                    }
                } header: {
                    Text("Reminder")
                } footer: {
                    if reminderPreset != .none {
                        if calendarId == nil {
                            Text("Scheduled as a local notification.")
                        } else {
                            Text("Scheduled on the event's calendar, so it fires even if Timecard isn't running.")
                        }
                    }
                }

                Section("Details") {
                    TextField("Location", text: $location)
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
                }

                if draft.existing != nil {
                    Section {
                        Button(role: .destructive) {
                            if draft.isOccurrence { showDeleteChoice = true }
                            else { delete(thisOnly: false) }
                        } label: { Text("Delete Event") }
                    }
                }
            }
            .navigationTitle(draft.existing == nil ? "Add Event" : "Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    // A backlog edit keeps its (nil) date; a new event always has one.
                    Button("Save") { save(); dismiss() }
                        .disabled(!valid || (draft.existing == nil && draft.date == nil))
                }
            }
            .confirmationDialog("Delete recurring event", isPresented: $showDeleteChoice, titleVisibility: .visible) {
                Button("Delete this occurrence", role: .destructive) { delete(thisOnly: true) }
                Button("Delete all occurrences", role: .destructive) { delete(thisOnly: false) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func save() {
        // Start from the existing row (preserving id/externalId/series linkage) or
        // a fresh event on the draft's date.
        var ev = draft.existing ?? CalEvent(date: draft.date, source: "local")
        ev.date = draft.date ?? ev.date
        ev.title = title
        ev.allDay = allDay
        ev.startMin = startMin
        ev.endMin = endMin
        ev.color = color
        ev.calendarId = calendarId
        ev.location = location
        ev.notes = notes
        ev.rrule = repeatPreset.rrule
        ev.reminderMinutesBefore = reminderPreset == .custom ? customReminderMinutes : reminderPreset.minutes
        // A recurring occurrence carries the series id in `occurrenceOf`; route the
        // edit to the master so the rule/fields update for the whole series.
        if let master = ev.occurrenceOf {
            ev.id = master
            ev.date = ev.seriesDate ?? ev.date
            ev.occurrenceOf = nil
            ev.seriesDate = nil
        }
        model.saveEvent(ev)
    }

    private func delete(thisOnly: Bool) {
        if let ev = draft.existing { model.deleteEvent(ev, thisOccurrenceOnly: thisOnly) }
        dismiss()
    }
}
