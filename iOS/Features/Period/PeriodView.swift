import SwiftUI
import SwiftData

/// The main pay-period screen: a 3-line header (period name · date range · stat
/// strip) over the 14 day rows. Reads from `TimecardStore` via the view model;
/// day editing / clock-in land in the next Phase 3 increment.
struct PeriodView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("calendarMode") private var calendarMode = false
    @State private var model: PeriodViewModel?
    @State private var openDate: String?
    /// The day whose events panel is expanded in place (calendar mode only).
    @State private var expandedDate: String?
    /// Add/edit draft for the shared event editor sheet.
    @State private var eventDraft: EventDraft?

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
        // Two full-week pages in a horizontal swipe carousel — the PWA's Week 1 /
        // Week 2 "switcharoo". Each page carries the (period-level) header so the
        // whole screen slides as a unit, matching the web app. The signature
        // timeline-drag gesture on each day strip uses a 1pt minimumDistance, so a
        // drag that starts on a handle wins over the page swipe (same touch-target
        // disambiguation the PWA relies on).
        TabView(selection: Binding(get: { model.weekPage },
                                   set: { model.weekPage = $0 })) {
            weekPageList(model, page: 0).tag(0)
            weekPageList(model, page: 1).tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // A light tick when the visible week flips (swipe or dot tap).
        .sensoryFeedback(.selection, trigger: model.weekPage)
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
        .sheet(item: $eventDraft) { d in
            EventEditView(draft: d, model: model)
        }
        .onChange(of: calendarMode) { _, on in
            if !on { expandedDate = nil }
        }
    }

    /// One week page of the carousel: the shared period header over that week's
    /// 7 day cards, in an inset-grouped list that scrolls vertically on its own.
    private func weekPageList(_ model: PeriodViewModel, page: Int) -> some View {
        List {
            Section {
                header(model)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(GlassRowBackground(cornerRadius: 22))
                    .listRowSeparator(.hidden)
            }

            Section {
                ForEach(model.weekRows(page)) { row in
                    dayCard(model, row)
                        // Roomier side margins so the date / hours aren't crowded
                        // against the card edges.
                        .listRowInsets(EdgeInsets(top: 6, leading: 24, bottom: 6, trailing: 24))
                        .listRowBackground(GlassRowBackground(
                            leadingAccent: row.isToday ? Color.accentColor
                                         : (row.isValidation ? Color.orange : nil)))
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.insetGrouped)
        // Hide the List's solid grouped fill so the Liquid-Glass row surfaces
        // read as floating cards over the app background.
        .scrollContentBackground(.hidden)
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
                Button { model.previous() } label: {
                    Image(systemName: "chevron.left").frame(width: 22, height: 22)
                }
                .glassChip()
                Spacer()
                Text(model.periodName).font(.title3.monospaced().weight(.semibold))
                Spacer()
                Button { model.next() } label: {
                    Image(systemName: "chevron.right").frame(width: 22, height: 22)
                }
                .glassChip()
            }

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

            // Maxiflex-only flex default (and only when the credit-hours feature
            // is enabled): route NEW entries' beyond-schedule hours to overtime
            // or banked credit (existing entries untouched).
            if model.showsCreditControl {
                Picker("New entries bank as",
                       selection: Binding(get: { model.creditDefault },
                                          set: { model.setCreditDefault($0) })) {
                    Text("Overtime").tag(false)
                    Text("Credit").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.top, 4)

                Text(model.creditDefault
                     ? "New entries bank beyond-schedule hours as credit (1:1, no premium). Existing entries are unchanged."
                     : "New entries pay beyond-schedule hours over 80 as overtime (1.5×). Existing entries are unchanged.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 1)
            }

            // Week 1 / Week 2 indicator. The weeks themselves are a swipe
            // carousel now (no segmented control) — these dots show position and
            // are tappable to jump, mirroring the PWA's floating page dots.
            VStack(spacing: 4) {
                Text("Week \(model.weekPage + 1)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { i in
                        Circle()
                            .fill(model.weekPage == i ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                            // Pad out to a comfortable tap target; swipe is primary,
                            // dot taps are the secondary jump affordance.
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) { model.weekPage = i }
                            }
                            .accessibilityLabel("Week \(i + 1)")
                            .accessibilityAddTraits(model.weekPage == i ? [.isSelected] : [])
                    }
                }
            }
            .padding(.top, 4)
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
        // The today / validation marker is now the curve-following left accent on
        // the card itself (GlassRowBackground.leadingAccent), not an inline bar.
        dayCardBody(model, row)
    }

    @ViewBuilder
    private func dayCardBody(_ model: PeriodViewModel, _ row: PeriodViewModel.DayRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            dayHeader(row, expandable: true, expanded: expandedDate == row.date,
                      leaveGranular: model.leaveGranular,
                      adjustLeave: { model.adjustLeave(on: row.date, deltaMinutes: $0) })
                .contentShape(Rectangle())
                // Tapping a day (header OR its timeline strip) expands it in place
                // and surfaces explicit actions — leave +/−, Open day editor, Add
                // event — instead of silently jumping into the full editor. The
                // strip's drag handles still edit entries directly (separate
                // gestures). Applies in both modes now.
                .onTapGesture { toggleExpand(row.date) }

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
                    onTap: { toggleExpand(row.date) }
                )
            }

            if expandedDate == row.date {
                DayActionsPanel(
                    date: row.date,
                    leaveMinutes: Int((row.leave * 60).rounded()),
                    leaveGranular: model.leaveGranular,
                    events: row.events,
                    calendarMode: calendarMode,
                    onAdjustLeave: { model.adjustLeave(on: row.date, deltaMinutes: $0) },
                    onOpenEditor: { openDate = row.date },
                    onAddEvent: { eventDraft = EventDraft(onDate: row.date) },
                    onTapEvent: { eventDraft = EventDraft(from: $0) }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Toggle the in-place expand panel for a day (one open at a time).
    private func toggleExpand(_ date: String) {
        // Snappier than the default (~0.5s) — roughly twice as fast.
        withAnimation(.snappy(duration: 0.25)) {
            expandedDate = (expandedDate == date) ? nil : date
        }
    }

    private func dayHeader(_ row: PeriodViewModel.DayRow,
                           expandable: Bool, expanded: Bool,
                           leaveGranular: Bool,
                           adjustLeave: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(row.dayLabel)
                .font(.subheadline.weight(row.isToday ? .bold : .regular))
                .foregroundStyle(row.isWeekend ? Color.secondary : Color.primary)
            if expandable {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
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
            // Inline leave +/− right on the collapsed row (the expand panel has
            // the full-size stepper, so hide this one while expanded).
            if !expanded {
                LeaveStepper(minutes: Int((row.leave * 60).rounded()),
                             granular: leaveGranular, compact: true, onAdjust: adjustLeave)
            }
            if row.ot > 0 {
                badge(formatHours(row.ot) + " OT", .orange)
            }
            // Day total = worked + leave (leave counts toward the 80).
            Text(row.countedHours > 0 ? formatHours(row.countedHours) + "h" : "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(row.countedHours > 0 ? .primary : .secondary)
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
