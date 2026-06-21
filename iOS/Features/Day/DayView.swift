import SwiftUI
import SwiftData

/// One day's editor: summary, clock in/out (today only), the entry list with
/// add/edit/delete, and a leave stepper. Pushed from `PeriodView`; on dismiss it
/// calls `onClose` so the period screen refreshes.
struct DayView: View {
    let date: String
    var onClose: () -> Void = {}

    @Environment(\.modelContext) private var context
    @State private var model: DayViewModel?
    @State private var draft: EntryDraft?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model?.dateTitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil {
                model = DayViewModel(store: TimecardStore(context: context), date: date)
            } else {
                model?.reload()
            }
        }
        .onDisappear { onClose() }
        .sheet(item: $draft) { d in
            if let model { EntryEditView(date: date, draft: d, model: model) }
        }
    }

    private func content(_ model: DayViewModel) -> some View {
        List {
            Section { summary(model) }

            if model.isToday {
                Section { clockButton(model) }
            }

            Section("Entries") {
                if model.entries.isEmpty {
                    Text("No entries").foregroundStyle(.secondary)
                }
                ForEach(model.entries) { e in entryRow(model, e) }
                Button {
                    draft = EntryDraft(existingId: nil, startMin: 8 * 60, endMin: 16 * 60 + 30, isOvertime: false)
                } label: {
                    Label("Add Entry", systemImage: "plus")
                }
            }

            Section("Leave") {
                Stepper(value: Binding(get: { Int(model.leave) }, set: { model.setLeave($0) }), in: 0...24) {
                    Text("Leave: \(Int(model.leave)) h")
                }
            }
        }
    }

    private func summary(_ model: DayViewModel) -> some View {
        HStack(spacing: 24) {
            stat(formatHours(model.worked) + "h", "worked", .blue)
            if model.ot > 0 { stat(formatHours(model.ot) + "h", "overtime", .orange) }
            if model.leave > 0 { stat(formatHours(model.leave) + "h", "leave", .teal) }
            Spacer()
        }
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func clockButton(_ model: DayViewModel) -> some View {
        if let open = model.openEntry, let start = open.startTime {
            Button(role: .destructive) {
                model.clockOut()
            } label: {
                Label("Clock Out — running since \(formatTime(start, use24h: model.use24h))",
                      systemImage: "stop.circle.fill")
            }
        } else {
            Button {
                model.clockIn()
            } label: {
                Label("Clock In", systemImage: "play.circle.fill")
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ model: DayViewModel, _ e: EntryRecord) -> some View {
        let editable = e.startTime != nil && e.endTime != nil && !e.incomplete
        Button {
            if editable { draft = EntryDraft(from: e) }
        } label: {
            entryRowLabel(model, e)
        }
        .buttonStyle(.plain)
        .disabled(!editable)
        .swipeActions {
            Button(role: .destructive) { model.deleteEntry(id: e.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func entryRowLabel(_ model: DayViewModel, _ e: EntryRecord) -> some View {
        HStack {
            if e.incomplete {
                Label("Incomplete", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if e.endTime == nil, let start = e.startTime {
                Label("Running since \(formatTime(start, use24h: model.use24h))", systemImage: "clock.fill")
                    .foregroundStyle(.green)
            } else if let start = e.startTime, let end = e.endTime {
                Text("\(formatTime(start, use24h: model.use24h)) – \(formatTime(end, use24h: model.use24h))")
            }
            Spacer()
            if e.isOvertime {
                Text("OT").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }
            if e.endTime != nil, !e.incomplete {
                Text(formatHours(e.paidHours) + "h")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A draft entry passed to the editor sheet. `existingId == nil` → a new entry.
struct EntryDraft: Identifiable {
    let id = UUID()
    var existingId: String?
    var startMin: Int
    var endMin: Int
    var isOvertime: Bool

    init(existingId: String?, startMin: Int, endMin: Int, isOvertime: Bool) {
        self.existingId = existingId
        self.startMin = startMin
        self.endMin = endMin
        self.isOvertime = isOvertime
    }

    /// Seed from an existing completed entry.
    init(from e: EntryRecord, calendar: Calendar = DomainCalendar.shared) {
        self.existingId = e.id
        self.startMin = e.startTime.map { minutesOfDay($0, calendar: calendar) } ?? 8 * 60
        self.endMin = e.endTime.map { minutesOfDay($0, calendar: calendar) } ?? 16 * 60 + 30
        self.isOvertime = e.isOvertime
    }
}

/// Add/Edit entry sheet: quarter-hour start/end + an Overtime toggle.
struct EntryEditView: View {
    let date: String
    let draft: EntryDraft
    let model: DayViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var startMin: Int
    @State private var endMin: Int
    @State private var isOvertime: Bool

    init(date: String, draft: EntryDraft, model: DayViewModel) {
        self.date = date
        self.draft = draft
        self.model = model
        _startMin = State(initialValue: draft.startMin)
        _endMin = State(initialValue: draft.endMin)
        _isOvertime = State(initialValue: draft.isOvertime)
    }

    private var valid: Bool { endMin > startMin }

    var body: some View {
        NavigationStack {
            Form {
                Section("Start") { QuarterHourPicker(minutes: $startMin) }
                Section("End") { QuarterHourPicker(minutes: $endMin) }
                Section {
                    Toggle("Overtime (OT)", isOn: $isOvertime)
                }
                if !valid {
                    Text("End time must be after start time.")
                        .font(.footnote).foregroundStyle(.red)
                }
                if let id = draft.existingId {
                    Section {
                        Button(role: .destructive) {
                            model.deleteEntry(id: id)
                            dismiss()
                        } label: {
                            Text("Delete Entry")
                        }
                    }
                }
            }
            .navigationTitle(draft.existingId == nil ? "Add Entry" : "Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveEntry(id: draft.existingId, startMin: startMin, endMin: endMin, isOvertime: isOvertime)
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
        }
    }
}
