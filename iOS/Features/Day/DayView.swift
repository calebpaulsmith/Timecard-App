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

            if !model.drawableEntries.isEmpty {
                Section {
                    DayTimelineView(
                        date: date,
                        entries: model.drawableEntries,
                        dayLeave: model.leave,
                        dayOt: model.ot,
                        use24h: model.use24h,
                        isToday: model.isToday,
                        scale: model.timelineScale,
                        onExpand: { model.expandScale(toInclude: $0) },
                        onCommit: { model.commitDraggedEntry($0) },
                        onTap: {}
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }

            if model.isToday {
                Section { clockButton(model) }
            }

            Section("Entries") {
                if model.entries.isEmpty {
                    Text("No entries").foregroundStyle(.secondary)
                }
                ForEach(model.entries) { e in entryRow(model, e) }
                Button {
                    let s = 8 * 60, e = 16 * 60 + 30
                    draft = EntryDraft(existingId: nil, startMin: s, endMin: e,
                                       lunchMinutes: autoLunchMinutes(spanMinutes: e - s),
                                       payKind: model.newEntryDefaultKind)
                } label: {
                    Label("Add Entry", systemImage: "plus")
                }
            }

            Section("Leave") {
                Stepper(value: Binding(get: { Int(model.leave) }, set: { model.setLeave($0) }), in: 0...24) {
                    Text("Leave: \(Int(model.leave)) h")
                }
            }

            holidaySection(model)
        }
    }

    @ViewBuilder
    private func holidaySection(_ model: DayViewModel) -> some View {
        Section {
            if model.isHoliday {
                HStack {
                    Label(model.holidayName ?? "Holiday", systemImage: "star.fill")
                        .foregroundStyle(.pink)
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeHoliday() }
                        .buttonStyle(.borderless)
                }
                Toggle("Worked holiday → double time (2×)",
                       isOn: Binding(get: { model.holidayWorked }, set: { model.setHolidayWorked($0) }))
            } else {
                Button {
                    model.markHoliday()
                } label: {
                    Label(model.federalName.map { "Mark holiday — \($0)" } ?? "Mark as holiday",
                          systemImage: "star")
                }
            }
        } header: {
            Text("Holiday")
        } footer: {
            Text(model.isHoliday
                 ? "Worked hours on a holiday are overtime — paying 2× when double time is on, else 1.5×."
                 : "Records 8h holiday leave on an otherwise-untouched day; worked hours then pay as overtime.")
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
            if let tag = payKindTag(e.payKind) {
                Text(tag.label).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tag.color.opacity(0.15), in: Capsule())
                    .foregroundStyle(tag.color)
            }
            if e.endTime != nil, !e.incomplete {
                Text(formatHours(e.paidHours) + "h")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Small badge for an entry's pay classification (none for plain auto/regular).
    private func payKindTag(_ k: PayKind) -> (label: String, color: Color)? {
        switch k {
        case .overtime:           return ("OT", .orange)
        case .credit, .autoCredit: return ("Credit", .purple)
        case .auto, .regular:     return nil
        }
    }
}

/// A draft entry passed to the editor sheet. `existingId == nil` → a new entry.
struct EntryDraft: Identifiable {
    let id = UUID()
    var existingId: String?
    var startMin: Int
    var endMin: Int
    var lunchMinutes: Int
    var payKind: PayKind

    init(existingId: String?, startMin: Int, endMin: Int, lunchMinutes: Int, payKind: PayKind) {
        self.existingId = existingId
        self.startMin = startMin
        self.endMin = endMin
        self.lunchMinutes = lunchMinutes
        self.payKind = payKind
    }

    /// Seed from an existing completed entry.
    init(from e: EntryRecord, calendar: Calendar = DomainCalendar.shared) {
        self.existingId = e.id
        self.startMin = e.startTime.map { minutesOfDay($0, calendar: calendar) } ?? 8 * 60
        self.endMin = e.endTime.map { minutesOfDay($0, calendar: calendar) } ?? 16 * 60 + 30
        self.lunchMinutes = e.lunchMinutes
        self.payKind = e.payKind
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
    @State private var lunchMin: Int
    /// While true, lunch tracks the span automatically (≥4h → 30). Flips off the
    /// moment the user adjusts lunch, so their override sticks. Starts off when
    /// editing an existing entry (its stored lunch is respected).
    @State private var lunchAuto: Bool
    @State private var payKind: PayKind

    init(date: String, draft: EntryDraft, model: DayViewModel) {
        self.date = date
        self.draft = draft
        self.model = model
        _startMin = State(initialValue: draft.startMin)
        _endMin = State(initialValue: draft.endMin)
        _lunchMin = State(initialValue: draft.lunchMinutes)
        _lunchAuto = State(initialValue: draft.existingId == nil)
        _payKind = State(initialValue: draft.payKind)
    }

    private var valid: Bool { endMin > startMin }

    /// Tooltip explaining the picked classification (Maxiflex only).
    private var payKindHelp: String {
        switch payKind {
        case .auto:       return "Hours beyond your schedule (once the period passes 80, leave included) pay overtime."
        case .autoCredit: return "Like Auto, but those beyond-schedule hours bank as credit hours (1:1, no premium)."
        case .overtime:   return "Force the whole entry to overtime (1.5×) — for ordered/approved OT."
        case .credit:     return "Force the whole entry to credit hours — banked 1:1, no premium."
        case .regular:    return "Force regular — never overtime or credit, even beyond schedule."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Start") { QuarterHourPicker(minutes: $startMin) }
                Section("End") { QuarterHourPicker(minutes: $endMin) }
                Section {
                    Stepper(value: lunchBinding, in: 0...180, step: 15) {
                        HStack {
                            Text("Lunch")
                            Spacer()
                            Text("\(lunchMin) min").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(lunchAuto ? "Auto from hours (≥4h deducts 30 min). Adjust to override."
                                   : "Manual override.")
                }
                Section {
                    Picker("Pay classification", selection: $payKind) {
                        Text("Auto").tag(PayKind.auto)
                        Text("Auto → Credit").tag(PayKind.autoCredit)
                        Text("All Overtime").tag(PayKind.overtime)
                        Text("All Credit").tag(PayKind.credit)
                        Text("All Regular").tag(PayKind.regular)
                    }
                } footer: {
                    Text(payKindHelp)
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
            .onChange(of: startMin) { syncAutoLunch() }
            .onChange(of: endMin) { syncAutoLunch() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveEntry(id: draft.existingId, startMin: startMin, endMin: endMin,
                                        lunchMinutes: lunchMin, payKind: payKind)
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
        }
    }

    /// Stepper binding that records a manual override the instant the user taps.
    private var lunchBinding: Binding<Int> {
        Binding(
            get: { lunchMin },
            set: { lunchMin = max(0, min(180, $0)); lunchAuto = false }
        )
    }

    /// When still in auto mode, keep lunch in step with the picked span.
    private func syncAutoLunch() {
        guard lunchAuto else { return }
        lunchMin = autoLunchMinutes(spanMinutes: max(0, endMin - startMin))
    }
}
