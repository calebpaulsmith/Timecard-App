import SwiftUI
import SwiftData

/// The main pay-period screen: a 3-line header (period name · date range · stat
/// strip) over the 14 day rows. Reads from `TimecardStore` via the view model;
/// day editing / clock-in land in the next Phase 3 increment.
struct PeriodView: View {
    @Environment(\.modelContext) private var context
    @State private var model: PeriodViewModel?
    @State private var openDate: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            if model == nil { model = PeriodViewModel(store: TimecardStore(context: context)) }
        }
    }

    private func content(_ model: PeriodViewModel) -> some View {
        List {
            Section { header(model) }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            Section {
                ForEach(model.weekRows) { row in
                    dayCard(model, row)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
        }
        .listStyle(.insetGrouped)
        // Programmatic nav so a drag on the strip never triggers a row push.
        .navigationDestination(item: $openDate) { date in
            DayView(date: date) { model.reload() }
        }
        .alert("Switch \(model.pendingModeChange?.periodName ?? "")?",
               isPresented: Binding(get: { model.pendingModeChange != nil },
                                    set: { if !$0 { model.cancelPendingModeChange() } }),
               presenting: model.pendingModeChange) { change in
            Button("Switch", role: .destructive) { model.confirmPendingModeChange() }
            Button("Cancel", role: .cancel) { model.cancelPendingModeChange() }
        } message: { change in
            Text(modeChangeMessage(model, change))
        }
    }

    private func modeChangeMessage(_ model: PeriodViewModel,
                                   _ change: PeriodViewModel.PendingModeChange) -> String {
        let dollars = model.showsMoney && change.lostDollars > 0
            ? " (\(formatMoney(change.lostDollars)))" : ""
        return "Overtime for this period drops by \(formatHours(change.lostHours)) hrs\(dollars) "
            + "(\(formatHours(change.fromHours)) → \(formatHours(change.toHours))). "
            + "Entries are untouched — you can switch back any time."
    }

    private func header(_ model: PeriodViewModel) -> some View {
        VStack(spacing: 6) {
            HStack {
                Button { model.previous() } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(model.periodName).font(.title3.monospaced().weight(.semibold))
                Spacer()
                Button { model.next() } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)

            Text(model.dateRange)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 18) {
                stat(formatHours(model.totals.total) + " / 80", "hours", .blue)
                if model.totals.ot > 0 {
                    stat(formatHours(model.totals.ot), "overtime", .orange)
                }
                if model.totals.credit > 0 {
                    stat(formatHours(model.totals.credit), "credit", .purple)
                }
                if model.showsMoney {
                    stat(formatMoney(model.totals.otDollars), "OT pay", .orange)
                }
            }
            .padding(.top, 2)

            // Per-period OT mode (override beats the Settings default).
            Picker("Overtime mode",
                   selection: Binding(get: { model.otMode },
                                      set: { model.requestOtMode($0) })) {
                Text("Maxiflex").tag(false)
                Text("8-hour OT").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.top, 4)

            // Per-period flex default — only meaningful in Maxiflex mode. Sets
            // whether NEW entries bank beyond-schedule hours as overtime or
            // credit. Existing entries keep the classification they were created
            // with (this control never reclassifies them).
            if !model.otMode {
                VStack(spacing: 2) {
                    Picker("New-entry default",
                           selection: Binding(get: { model.creditMode },
                                              set: { model.setCreditMode($0) })) {
                        Text("Overtime").tag(false)
                        Text("Credit").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text(model.creditMode
                         ? "New entries bank beyond-schedule hours as credit (1:1, no premium)."
                         : "New entries pay beyond-schedule hours as overtime (1.5×).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 4)
            }

            // Week 1 / Week 2 selector with page dots.
            Picker("Week", selection: Binding(get: { model.weekPage },
                                              set: { model.weekPage = $0 })) {
                Text("Week 1").tag(0)
                Text("Week 2").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.top, 2)

            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .fill(model.weekPage == i ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.headline).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func dayCard(_ model: PeriodViewModel, _ row: PeriodViewModel.DayRow) -> some View {
        HStack(spacing: 8) {
            // Thin warning-colored left border on the validation-deadline day.
            if row.isValidation {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.orange)
                    .frame(width: 3)
            }
            dayCardBody(model, row)
        }
    }

    @ViewBuilder
    private func dayCardBody(_ model: PeriodViewModel, _ row: PeriodViewModel.DayRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            dayHeader(row)
                .contentShape(Rectangle())
                .onTapGesture { openDate = row.date }

            if row.entries.isEmpty {
                Button { openDate = row.date } label: {
                    Label(row.leave > 0 ? "\(formatHours(row.leave))h leave · tap to edit"
                                        : "Add work hours",
                          systemImage: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
            } else {
                DayTimelineView(
                    date: row.date,
                    entries: row.entries,
                    dayLeave: row.leave,
                    dayOt: row.ot,
                    use24h: model.use24h,
                    isToday: row.isToday,
                    scale: model.timelineScale,
                    onExpand: { model.expandScale(toInclude: $0) },
                    onCommit: { model.commitEntry($0) },
                    onTap: { openDate = row.date }
                )
            }
        }
    }

    private func dayHeader(_ row: PeriodViewModel.DayRow) -> some View {
        HStack(spacing: 12) {
            Text(row.dayLabel)
                .font(.subheadline.weight(row.isToday ? .bold : .regular))
                .foregroundStyle(row.isWeekend ? Color.secondary : Color.primary)
            if row.isValidation {
                Image(systemName: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let name = row.holidayName {
                Text(name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.pink.opacity(0.15), in: Capsule())
                    .foregroundStyle(.pink)
            }
            if row.isToday {
                Text("Today")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if row.leave > 0 {
                badge(formatHours(row.leave) + " lv", .teal)
            }
            if row.ot > 0 {
                badge(formatHours(row.ot) + " OT", .orange)
            }
            Text(row.worked > 0 ? formatHours(row.worked) + "h" : "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(row.worked > 0 ? .primary : .secondary)
                .frame(minWidth: 48, alignment: .trailing)
        }
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
