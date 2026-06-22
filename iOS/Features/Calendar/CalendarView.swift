import SwiftUI
import SwiftData

/// SwiftUI Color for an event color token (the Features-layer swatch; Domain only
/// knows the meaning).
func eventColor(_ token: EventColor) -> Color {
    switch token {
    case .work: return .blue
    case .personal: return .indigo
    case .ritza: return .pink
    case .amelia: return .green
    }
}

/// The Calendar tab: a pay-period-aligned list of events (recurring series
/// expanded on read), the backlog, and a two-way EventKit sync action. Tapping a
/// day's event opens the editor; "+" on a day adds a new event there.
struct CalendarView: View {
    @Environment(\.modelContext) private var context
    @State private var model: CalendarViewModel?
    @State private var draft: EventDraft?

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
                if let model { EventEditView(draft: d, model: model) }
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

            ForEach(model.rows) { row in
                Section {
                    ForEach(row.events) { ev in eventRow(model, ev) }
                    Button {
                        draft = EventDraft(onDate: row.date)
                    } label: {
                        Label("Add event", systemImage: "plus").font(.callout)
                    }
                } header: {
                    HStack {
                        Text(row.label)
                        if row.isToday {
                            Text("Today").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            if !model.backlog.isEmpty {
                Section("Backlog") {
                    ForEach(model.backlog) { ev in
                        Button { draft = EventDraft(from: ev) } label: {
                            HStack {
                                Circle().fill(eventColor(ev.color)).frame(width: 8, height: 8)
                                Text(ev.title.isEmpty ? "(untitled)" : ev.title)
                                Spacer()
                                Text("No date").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
    private func eventRow(_ model: CalendarViewModel, _ ev: CalEvent) -> some View {
        Button { draft = EventDraft(from: ev) } label: {
            HStack(spacing: 10) {
                Circle().fill(eventColor(ev.color)).frame(width: 8, height: 8)
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
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                model.deleteEvent(ev, thisOccurrenceOnly: ev.isOccurrence)
            } label: { Label("Delete", systemImage: "trash") }
        }
    }
}
