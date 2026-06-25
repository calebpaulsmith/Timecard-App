import SwiftUI
import SwiftData

/// Settings: anchor (Sunday), default overtime mode, hourly rate, 24-hour time,
/// and a link to the default-schedule editor. Each control writes through to the
/// store immediately.
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var model: SettingsViewModel?
    @AppStorage("calendarMode") private var calendarMode = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    form(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Settings")
        }
        .onAppear {
            if model == nil { model = SettingsViewModel(store: TimecardStore(context: context)) }
        }
    }

    private func form(_ model: SettingsViewModel) -> some View {
        Form {
            Section("Pay period") {
                DatePicker("Anchor (a Sunday)",
                           selection: Binding(get: { model.anchor }, set: { model.setAnchor($0) }),
                           displayedComponents: .date)
                if let err = model.anchorError {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            }

            Section("Overtime") {
                Picker("Default mode",
                       selection: Binding(get: { model.eightHourDefault }, set: { model.setEightHourDefault($0) })) {
                    Text("Maxiflex").tag(false)
                    Text("8-hour OT").tag(true)
                }
                .pickerStyle(.segmented)
                Text(model.eightHourDefault
                     ? "Hours beyond each day's scheduled hours are overtime."
                     : "Overtime is explicit-OT entries plus work beyond schedule once the period passes 80h.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Credit hours (Maxiflex)",
                       isOn: Binding(get: { model.creditHoursEnabled },
                                     set: { model.setCreditHoursEnabled($0) }))
                Text("Off by default. When on, classify each entry's beyond-schedule hours as banked credit instead of overtime, with a per-period Overtime/Credit default and credit stats. When off, all extra hours pay overtime and every credit control is hidden. Stored classifications are kept either way.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Pay") {
                HStack {
                    Text("Hourly rate")
                    Spacer()
                    Text("$")
                    TextField("0.00",
                              value: Binding(get: { model.hourlyRate }, set: { model.setHourlyRate($0) }),
                              format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                }
            }

            Section {
                Picker("Validation deadline",
                       selection: Binding(get: { model.validationDay ?? -1 },
                                          set: { model.setValidationDay($0 < 0 ? nil : $0) })) {
                    Text("None").tag(-1)
                    ForEach(Array(model.validationDayLabels.enumerated()), id: \.offset) { i, label in
                        Text(label).tag(i)
                    }
                }
            } footer: {
                Text("Marks one day of the pay period with a ✓ and a warning border — the deadline to validate your timecard.")
            }

            Section("Display") {
                Toggle("24-hour time", isOn: Binding(get: { model.use24h }, set: { model.setUse24h($0) }))
            }

            Section("Schedule") {
                NavigationLink {
                    ScheduleEditorView(model: model.makeScheduleModel())
                } label: {
                    Label("Default schedule", systemImage: "calendar")
                }
            }

            Section {
                Toggle("Calendar mode", isOn: $calendarMode)
            } footer: {
                Text("Off: the calm, work-shareable timecard. On: adds the Calendar tab (home-calendar events + two-way device-calendar sync).")
            }

            if calendarMode {
                calendarSyncSection(model)
            }
        }
    }

    @ViewBuilder
    private func calendarSyncSection(_ model: SettingsViewModel) -> some View {
        Section {
            if model.calendarAuthorized {
                if model.calendars.isEmpty {
                    Text("No writable calendars found. Add a Google (or iCloud) account in iOS Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Calendar", selection: Binding(
                        get: { model.selectedCalendarId },
                        set: { model.setCalendar($0) })) {
                        ForEach(model.calendars) { cal in
                            Text("\(cal.account) · \(cal.title)").tag(cal.id)
                        }
                    }
                }
                Button {
                    Task { await model.syncNow() }
                } label: {
                    HStack {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        if model.isSyncing { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.isSyncing)
            } else {
                Button {
                    Task { await model.requestCalendarAccess() }
                } label: {
                    Label("Connect device calendar", systemImage: "calendar.badge.plus")
                }
            }
            if let status = model.syncStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            } else if let last = model.lastSyncText {
                Text(last).font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("Calendar sync")
        } footer: {
            Text("Two-way sync of your events with a device calendar — including any Google calendar you've added to this iPhone in Settings. No password or login needed here.")
        }
    }
}
