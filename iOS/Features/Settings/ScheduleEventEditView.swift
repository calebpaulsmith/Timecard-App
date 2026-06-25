import SwiftUI

/// Add/edit a **recurring schedule event** from the default-schedule editor — a
/// biweekly series (`FREQ=WEEKLY;INTERVAL=2`) anchored to a day-of-period in the
/// current pay period. Purpose-built around the day-of-period picker (which the
/// generic `EventEditView` doesn't have); writes through the same event store, so
/// the result is an ordinary biweekly event everywhere else (Timecard + Calendar
/// tabs). Calendar-mode only.
struct ScheduleEventEditView: View {
    let existing: CalEvent?
    let model: ScheduleViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var dayIndex: Int
    @State private var title: String
    @State private var allDay: Bool
    @State private var startMin: Int
    @State private var endMin: Int
    @State private var color: EventColor

    init(existing: CalEvent?, initialDayIndex: Int, model: ScheduleViewModel) {
        self.existing = existing
        self.model = model
        _dayIndex = State(initialValue: initialDayIndex)
        _title = State(initialValue: existing?.title ?? "")
        _allDay = State(initialValue: existing?.allDay ?? false)
        _startMin = State(initialValue: existing?.startMin ?? 9 * 60)
        _endMin = State(initialValue: existing?.endMin ?? 10 * 60)
        _color = State(initialValue: existing?.color ?? .personal)
    }

    private var valid: Bool { allDay || endMin > startMin }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Title", text: $title) }

                Section("Day") {
                    Picker("Repeats on", selection: $dayIndex) {
                        ForEach(Array(model.currentPeriodDays.enumerated()), id: \.offset) { i, d in
                            Text(model.dayLabel(d)).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text("Repeats every 2 weeks on this day.")
                }

                Section("Color") {
                    Picker("Color", selection: $color) {
                        ForEach(EventColor.allCases, id: \.self) { c in
                            Label { Text(c.label) } icon: {
                                Circle().fill(eventColor(c)).frame(width: 12, height: 12)
                            }.tag(c)
                        }
                    }
                    .pickerStyle(.menu)
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

                if existing != nil {
                    Section {
                        Button(role: .destructive) { delete() } label: { Text("Delete Event") }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Recurring Event" : "Edit Recurring Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(); dismiss() }
                        .disabled(!valid || model.currentPeriodDays.isEmpty)
                }
            }
        }
    }

    private func save() {
        let days = model.currentPeriodDays
        guard !days.isEmpty else { return }
        let date = days[min(max(dayIndex, 0), days.count - 1)]

        var ev = existing ?? CalEvent(source: "local")
        let dateChanged = ev.date != date
        ev.date = date
        ev.title = title
        ev.allDay = allDay
        ev.startMin = startMin
        ev.endMin = endMin
        ev.color = color
        ev.rrule = "FREQ=WEEKLY;INTERVAL=2"
        ev.needsScheduling = false
        ev.source = "local"
        // Re-anchoring to a different day resets the series start; stale exdates
        // (cancellations against the old anchor) no longer apply.
        if dateChanged { ev.exdates = [] }
        model.saveScheduleEvent(ev)
    }

    private func delete() {
        if let ev = existing { model.deleteScheduleEvent(ev) }
        dismiss()
    }
}
