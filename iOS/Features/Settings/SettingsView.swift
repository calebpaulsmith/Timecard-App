import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings: anchor (Sunday), default overtime mode, hourly rate, 24-hour time,
/// and a link to the default-schedule editor. Each control writes through to the
/// store immediately.
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var model: SettingsViewModel?
    @AppStorage("calendarMode") private var calendarMode = false
    @AppStorage("appTheme") private var themeId = AppTheme.classic.rawValue
    @AppStorage("appearance") private var appearance = "system"

    // CSV backup / restore.
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var exportDoc = CsvBackupDocument(text: "")
    @State private var importMessage: String?
    // Schedule .ics export.
    @State private var showingIcsExporter = false
    @State private var icsDoc = IcsScheduleDocument(text: "")

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

            Section("Appearance") {
                NavigationLink {
                    ThemePickerView()
                } label: {
                    HStack {
                        Text("Theme")
                        Spacer()
                        Text(AppTheme(rawValue: themeId)?.displayName ?? "Classic")
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Mode", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                Text("Themes are grouped — Everyday, Muted, and Moments (Independence Day, Halloween…). Mode forces light or dark regardless of your phone setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Display") {
                Toggle("24-hour time", isOn: Binding(get: { model.use24h }, set: { model.setUse24h($0) }))
            }

            Section {
                Toggle("Reminders",
                       isOn: Binding(get: { model.remindersEnabled },
                                     set: { model.setRemindersEnabled($0) }))
            } footer: {
                Text("On-device notifications: a timecard validation-deadline nudge, a heads-up the day before the pay period ends if you're short of 80, and a forgotten-clock-out reminder. No account, nothing leaves your phone.")
            }

            Section {
                NavigationLink {
                    ScheduleEditorView(model: model.makeScheduleModel())
                } label: {
                    Label("Default schedule", systemImage: "calendar")
                }
                Button {
                    icsDoc = IcsScheduleDocument(text: model.exportScheduleIcsText())
                    showingIcsExporter = true
                } label: {
                    Label("Export schedule (.ics)", systemImage: "calendar.badge.plus")
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Export your default schedule as a biweekly-recurring calendar file (work + leave) to import into Apple, Google, or Outlook calendars.")
            }

            backupSection(model)

            Section {
                Toggle("Calendar mode", isOn: $calendarMode)
            } footer: {
                Text("Off: the calm, work-shareable timecard. On: adds the Calendar tab (home-calendar events + two-way device-calendar sync).")
            }

            if calendarMode {
                calendarSyncSection(model)
                if model.calendarAuthorized {
                    Section {
                        NavigationLink {
                            CalendarsView()
                        } label: {
                            Label("Calendars", systemImage: "calendar.badge.clock")
                        }
                    } footer: {
                        Text("Choose which calendars appear, set each one's color and line position (above / on / below), pick the default tasks calendar, and hide calendars from the timeline.")
                    }
                    scheduleSyncSection(model)
                }
            }
        }
        .fileExporter(isPresented: $showingExporter, document: exportDoc,
                      contentType: .commaSeparatedText, defaultFilename: "timecard-backup") { _ in }
        .fileExporter(isPresented: $showingIcsExporter, document: icsDoc,
                      contentType: .icsCalendar, defaultFilename: "maxiflex-schedule") { _ in }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            switch result {
            case .success(let url):
                importMessage = model.importCsv(from: url)
                    ? "Backup restored." : "Couldn't read that file."
            case .failure(let err):
                importMessage = err.localizedDescription
            }
        }
        .alert("Import", isPresented: Binding(get: { importMessage != nil },
                                              set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
    }

    @ViewBuilder
    private func backupSection(_ model: SettingsViewModel) -> some View {
        Section {
            Button {
                exportDoc = CsvBackupDocument(text: model.exportCsvText())
                showingExporter = true
            } label: {
                Label("Export backup (CSV)", systemImage: "square.and.arrow.up")
            }
            Button {
                showingImporter = true
            } label: {
                Label("Import backup (CSV)", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Export all your timecard data as a CSV, or restore from one. Importing replaces everything on this device (local-only keys are kept). Same format as the web app, so backups move between them.")
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

    @ViewBuilder
    private func scheduleSyncSection(_ model: SettingsViewModel) -> some View {
        Section {
            Toggle("Sync my work schedule", isOn: Binding(
                get: { model.scheduleSyncEnabled },
                set: { model.setScheduleSyncEnabled($0) }))
            if model.scheduleSyncEnabled {
                if !model.calendars.isEmpty {
                    Picker("Schedule calendar", selection: Binding(
                        get: { model.scheduleCalendarId },
                        set: { model.setScheduleCalendar($0) })) {
                        Text("Same as events").tag("")
                        ForEach(model.calendars) { cal in
                            Text("\(cal.account) · \(cal.title)").tag(cal.id)
                        }
                    }
                }
                Stepper("Pay periods ahead: \(model.schedulePeriodsAhead)",
                        value: Binding(get: { model.schedulePeriodsAhead },
                                       set: { model.setSchedulePeriodsAhead($0) }),
                        in: 1...26)
                Picker("Leave calendar", selection: Binding(
                    get: { model.leaveSyncSelection },
                    set: { model.setLeaveSyncSelection($0) })) {
                    Text("Same as work").tag("")
                    ForEach(model.calendars) { cal in
                        Text("\(cal.account) · \(cal.title)").tag(cal.id)
                    }
                    Text("Don't sync leave").tag(SettingsViewModel.leaveSyncOff)
                }
            }
        } header: {
            Text("Work schedule sync")
        } footer: {
            Text("Optional. Pushes your actual hours (shifts, leave, holidays) onto a calendar for a limited window ahead — 2 = this pay period and the next. Days you've edited use your real hours; untouched days fall back to the default schedule. A full day off (8h+ leave, no work) shows as an all-day Leave block; shorter leave shows at its actual time. Put leave on a separate calendar to give it a different color in Google/Apple Calendar (per-event colors can't be set through this sync). Your one-off events still sync for all time; only the schedule is bounded.")
        }
    }
}
