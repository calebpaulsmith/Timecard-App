import SwiftUI
import SwiftData

/// Settings › Calendars — the multi-calendar registry editor. For every device
/// calendar the user can: include it in the app (sync), choose where its events
/// ride on the timeline (above / on / below the work bar), pick a color, decide
/// whether it shows on the timeline page or only on the Calendar page, and mark
/// the default calendar for new tasks.
struct CalendarsView: View {
    @Environment(\.modelContext) private var context
    @State private var model: CalendarsViewModel?

    /// A small override palette (label → hex). "Calendar color" (nil) keeps the
    /// calendar's own device color.
    private static let presets: [(String, String?)] = [
        ("Calendar color", nil),
        ("Blue", "#0A6CFF"), ("Teal", "#0E9AA7"), ("Green", "#16A34A"),
        ("Orange", "#E8920C"), ("Red", "#DC2626"), ("Pink", "#DB2777"),
        ("Purple", "#8B5CF6"), ("Gray", "#8E8E93"),
    ]

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        .navigationTitle("Calendars")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil { model = CalendarsViewModel(store: TimecardStore(context: context)) }
            else { model?.reload() }
        }
    }

    @ViewBuilder
    private func content(_ model: CalendarsViewModel) -> some View {
        List {
            if !model.authorized {
                Section {
                    Button {
                        Task { await model.requestAccess() }
                    } label: {
                        Label("Connect device calendar", systemImage: "calendar.badge.plus")
                    }
                } footer: {
                    Text("Grant calendar access to choose which calendars appear and how.")
                }
            } else if model.rows.isEmpty {
                Section {
                    Text("No calendars found. Add a Google/iCloud account in iOS Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.rows) { row in calendarSection(model, row) }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func calendarSection(_ model: CalendarsViewModel, _ row: CalendarsViewModel.Row) -> some View {
        Section {
            Toggle(isOn: Binding(get: { row.config.synced },
                                 set: { model.setSynced(row.id, $0) })) {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: row.config.effectiveColorHex ?? "#8E8E93"))
                        .frame(width: 12, height: 12)
                    Text("Use this calendar")
                }
            }

            if row.config.synced {
                Picker("Position", selection: Binding(get: { row.config.tier },
                                                      set: { model.setTier(row.id, $0) })) {
                    ForEach(CalendarTier.allCases, id: \.self) { t in Text(t.label).tag(t) }
                }

                Picker("Color", selection: Binding(get: { row.config.colorHex },
                                                   set: { model.setColorOverride(row.id, $0) })) {
                    ForEach(Self.presets, id: \.0) { name, hex in
                        Label {
                            Text(name)
                        } icon: {
                            Circle().fill(Color(hex: hex ?? row.config.deviceColorHex ?? "#8E8E93"))
                                .frame(width: 12, height: 12)
                        }
                        .tag(hex)
                    }
                }

                Toggle("Show on timeline", isOn: Binding(get: { row.config.showOnTimeline },
                                                         set: { model.setShowOnTimeline(row.id, $0) }))

                if row.isWritable {
                    Toggle("Default for new tasks", isOn: Binding(get: { row.config.isTaskDefault },
                                                                  set: { model.setTaskDefault(row.id, $0) }))
                }
            }
        } header: {
            Text("\(row.account) · \(row.title)")
        } footer: {
            if row.config.synced && !row.config.showOnTimeline {
                Text("Hidden from the timeline — shows only on the Calendar tab.")
            }
        }
    }
}
