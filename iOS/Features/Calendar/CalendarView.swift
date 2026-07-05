import SwiftUI
import SwiftData

/// The Calendar tab: a **day-by-day agenda** of the pay period — a section per
/// day (recurring series expanded on read), the backlog, and a two-way EventKit
/// sync action. **Every** day of the period is shown (including empty ones) so
/// each is a visible drop target. Tapping an event opens the editor (where the
/// event's **day** can now be changed directly); an event row can also be
/// **dragged onto another day's section** to re-date it, and a backlog item
/// dragged onto a day to schedule it. Swipe-to-delete stays for quick cleanup.
struct CalendarView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.palette) private var palette
    @State private var model: CalendarViewModel?
    @State private var draft: EventDraft?
    /// The day currently under a drag (for drop highlighting).
    @State private var dropTargetDate: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model { content(model) } else { ProgressView() }
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let model {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await model.syncNow() }
                        } label: {
                            if model.isSyncing { ProgressView() }
                            else { Image(systemName: "arrow.triangle.2.circlepath") }
                        }
                        .disabled(model.isSyncing)
                    }
                }
            }
            .sheet(item: $draft) { d in
                if let model { EventEditView(draft: d, model: model, calendars: model.calendarOptions) }
            }
        }
        .onAppear {
            if model == nil { model = CalendarViewModel(store: TimecardStore(context: context)) }
            else { model?.reload() }
        }
    }

    private func content(_ model: CalendarViewModel) -> some View {
        List {
            Section { header(model) }

            // Every day in the pay period is shown — including empty ones — so any
            // day is a visible drop target for dragging an event between days. An
            // event row drags (hold + move); dropping it on another day's section
            // re-dates it. Tapping an event still opens the editor (where the day
            // can also be changed directly), and swipe-to-delete stays. (When the
            // period is completely empty and the backlog too, show a hint instead
            // of 14 vacant sections — there'd be nothing to drag.)
            let hasAny = model.rows.contains { !$0.events.isEmpty } || !model.backlog.isEmpty
            if !hasAny {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No events this pay period")
                            .font(.callout.weight(.medium))
                        Text("Add events from a day on the Timecard tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(model.rows) { row in
                    Section {
                        if row.events.isEmpty {
                            emptyDayRow(model, row)
                        } else {
                            ForEach(row.events) { ev in eventRow(model, ev, date: row.date) }
                        }
                    } header: {
                        dayHeader(row)
                    }
                }
            }

            if !model.backlog.isEmpty {
                Section {
                    ForEach(model.backlog) { ev in
                        Button { draft = EventDraft(from: ev) } label: {
                            HStack {
                                Circle().fill(palette.eventColor(ev, configHex: model.eventColorHex(ev)))
                                    .frame(width: 8, height: 8)
                                Text(ev.title.isEmpty ? "(untitled)" : ev.title)
                                Spacer()
                                Text("No date").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .draggable(ev.id)
                        .swipeActions {
                            Button(role: .destructive) {
                                model.deleteEvent(ev, thisOccurrenceOnly: false)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("Backlog")
                } footer: {
                    Text("Drag a backlog item onto a day to schedule it.")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func dayHeader(_ row: CalendarViewModel.DayEvents) -> some View {
        HStack {
            Text(row.label)
            if row.isToday {
                Text("Today").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
            Spacer()
            if dropTargetDate == row.date {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            }
        }
    }

    /// A placeholder for a day with no events — still a drop target so an event can
    /// be dragged onto an otherwise-empty day.
    private func emptyDayRow(_ model: CalendarViewModel, _ row: CalendarViewModel.DayEvents) -> some View {
        HStack {
            Text(dropTargetDate == row.date ? "Drop to move here" : "No events")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .listRowBackground(dropTargetDate == row.date ? Color.accentColor.opacity(0.12) : nil)
        .dayDropTarget(model: model, date: row.date, targeted: $dropTargetDate)
    }

    private func header(_ model: CalendarViewModel) -> some View {
        VStack(spacing: 6) {
            HStack {
                Button { model.previous() } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(model.periodName).font(.title3.monospaced().weight(.semibold))
                Spacer()
                Button { model.next() } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)
            Text(model.dateRange).font(.footnote).foregroundStyle(.secondary)
            if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if let last = model.lastSyncText {
                Text(last).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func eventRow(_ model: CalendarViewModel, _ ev: CalEvent, date: String) -> some View {
        let movable = model.movableEvents[ev.id] != nil
        let row = Button { draft = EventDraft(from: ev) } label: {
            HStack(spacing: 10) {
                Circle().fill(palette.eventColor(ev, configHex: model.eventColorHex(ev)))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(ev.title.isEmpty ? "(untitled)" : ev.title)
                        if ev.isOccurrence || ev.isSeries {
                            Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary)
                        }
                        if ev.externalId != nil {
                            Image(systemName: "calendar.badge.checkmark").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if !ev.location.isEmpty {
                        Text(ev.location).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(ev.allDay ? "All-day"
                     : "\(formatMinutes(ev.startMin, use24h: model.use24h))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(dropTargetDate == date ? Color.accentColor.opacity(0.12) : nil)
        .swipeActions {
            Button(role: .destructive) {
                model.deleteEvent(ev, thisOccurrenceOnly: ev.isOccurrence)
            } label: { Label("Delete", systemImage: "trash") }
        }
        // A day's rows are all drop targets for that day, so dropping anywhere in
        // the section re-dates the dragged event onto this day.
        .dayDropTarget(model: model, date: date, targeted: $dropTargetDate)

        // Only re-datable rows drag; recurring/read-only rows are tap-only.
        if movable {
            row.draggable(ev.id)
        } else {
            row
        }
    }
}

private extension View {
    /// Make a row a drop target for an event id → move it onto `date`, with
    /// live targeting feedback written to `targeted`.
    func dayDropTarget(model: CalendarViewModel, date: String, targeted: Binding<String?>) -> some View {
        self.dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            model.moveEvent(id: id, toDate: date)
            return true
        } isTargeted: { isIn in
            if isIn { targeted.wrappedValue = date }
            else if targeted.wrappedValue == date { targeted.wrappedValue = nil }
        }
    }
}
