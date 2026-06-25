import SwiftUI
import Observation

/// Edits the 14-slot default schedule. A slot's start/end set that day-of-period
/// index's SCHEDULED hours, which drive overtime (8h-mode OT = worked − scheduled;
/// maxiflex auto-OT = work beyond scheduled past 80h). `leaveHours` is recurring
/// leave. Edits persist immediately via `TimecardStore.setDefaultSchedule`; the
/// **Apply** button then seeds work entries + leave into upcoming periods
/// (`TimecardStore.applyDefaultSchedule`, the PWA's "Save & apply").
@MainActor
@Observable
final class ScheduleViewModel {
    private let store: TimecardStore
    private(set) var slots: [ScheduleSlot?]
    /// Shared horizontal scale across all 14 strips, fit to every slot's work bar
    /// + leave so the bars stay comparable. Expanded (never contracted) live
    /// during a drag via `expandScale`; re-settled on every edit (`commit`).
    private(set) var timelineScale: TimelineScale = .default

    var use24h: Bool { store.use24h }

    /// Local recurring **series** (biweekly schedule events) — the "set up my
    /// repeating events alongside my work schedule" list. Calendar-mode only.
    private(set) var recurringEvents: [CalEvent] = []

    init(store: TimecardStore) {
        self.store = store
        self.slots = store.defaultSchedule()
        refitScale()
        reloadEvents()
    }

    /// A working copy of a slot — a disabled 8:00–16:30 default when never set.
    private func slot(_ i: Int) -> ScheduleSlot {
        slots[i] ?? ScheduleSlot(enabled: false, startMin: 8 * 60, endMin: 16 * 60 + 30, leaveHours: 0)
    }

    func isEnabled(_ i: Int) -> Bool { slots[i]?.enabled ?? false }
    func startMin(_ i: Int) -> Int { slots[i]?.startMin ?? 8 * 60 }
    func endMin(_ i: Int) -> Int { slots[i]?.endMin ?? 16 * 60 + 30 }
    func leave(_ i: Int) -> Int { slots[i]?.leaveHours ?? 0 }

    func setEnabled(_ i: Int, _ on: Bool) { var s = slot(i); s.enabled = on; commit(i, s) }
    func setStart(_ i: Int, _ m: Int) { var s = slot(i); s.startMin = m; commit(i, s) }
    func setEnd(_ i: Int, _ m: Int) { var s = slot(i); s.endMin = m; commit(i, s) }
    /// Set both edges at once (the strip drag commits a start+end pair).
    func setTimes(_ i: Int, _ start: Int, _ end: Int) {
        var s = slot(i); s.startMin = start; s.endMin = end; commit(i, s)
    }
    func setLeave(_ i: Int, _ h: Int) { var s = slot(i); s.leaveHours = max(0, h); commit(i, s) }

    var hasAnchor: Bool { store.anchorDate != nil }

    /// Seed the saved schedule into upcoming periods (the PWA's "Save & apply").
    /// `includeCurrent` starts at the current period, else the next one. Returns
    /// nil when no anchor is set (the caller surfaces that).
    func apply(includeCurrent: Bool, calendar: Calendar = DomainCalendar.shared) -> (written: Int, leaveDays: Int)? {
        guard let anchor = store.anchorDate else { return nil }
        let today = Date()
        let start = includeCurrent
            ? payPeriodFor(today: today, anchor: anchor, calendar: calendar).start
            : payPeriodOffset(today: today, anchor: anchor, offset: 1, calendar: calendar).start
        return store.applyDefaultSchedule(startPeriodStart: start, anchor: anchor,
                                          holidays: store.holidaySet(), calendar: calendar)
    }

    private func commit(_ i: Int, _ s: ScheduleSlot) {
        slots[i] = s
        store.setDefaultSchedule(slots)
        refitScale()
    }

    // MARK: - Recurring schedule events (calendar mode)
    //
    // A recurring event here is a **biweekly series** (FREQ=WEEKLY;INTERVAL=2)
    // anchored to a day-of-period in the current pay period — the natural cadence
    // for the 14-day schedule. Reuses the event store + recurrence engine; the
    // Domain layer is untouched.

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// The current pay period's 14 dates, for the day-of-period picker. Empty when
    /// no anchor is set (the caller gates the add affordance on `hasAnchor`).
    var currentPeriodDays: [String] {
        guard let anchor = store.anchorDate else { return [] }
        return payPeriodFor(today: Date(), anchor: anchor, calendar: DomainCalendar.shared).days
    }

    func dayLabel(_ date: String) -> String {
        formatDateShort(date, calendar: DomainCalendar.shared)
    }

    /// Short weekday for a series' anchor date (e.g. "Mon") — used in the list row.
    func weekday(for ev: CalEvent) -> String {
        guard let d = ev.date else { return "" }
        let w = dow0(parseLocalDate(d, calendar: DomainCalendar.shared), calendar: DomainCalendar.shared)
        return Self.weekdayNames[w]
    }

    /// Day-of-period index (0..13) of a series' anchor within its own pay period —
    /// the picker's initial selection when editing.
    func dayIndex(for ev: CalEvent) -> Int {
        guard let d = ev.date, let anchor = store.anchorDate else { return 0 }
        let pp = payPeriodFor(today: parseLocalDate(d, calendar: DomainCalendar.shared),
                              anchor: anchor, calendar: DomainCalendar.shared)
        let start = pp.start   // PayPeriod.start is already a Date — don't re-parse
        let idx = daysBetween(start, parseLocalDate(d, calendar: DomainCalendar.shared),
                              calendar: DomainCalendar.shared)
        return max(0, min(13, idx))
    }

    func reloadEvents() {
        recurringEvents = store.recurringSeries()
            .filter { $0.isLocal && Self.isBiweeklySchedule($0) }
            .sorted { ($0.date ?? "", $0.startMin) < ($1.date ?? "", $1.startMin) }
    }

    /// This section manages only the **biweekly pay-period schedule** series it
    /// creates (`FREQ=WEEKLY;INTERVAL=2`). Other recurring series — notably
    /// device/Google events synced in via EventKit (all stored `source:"local"`),
    /// e.g. yearly birthdays — must NOT appear here, or they'd be mislabeled
    /// "Every 2 weeks" and be editable as if they were schedule events.
    static func isBiweeklySchedule(_ ev: CalEvent) -> Bool {
        guard let r = parseRRule(ev.rrule) else { return false }
        return r.freq == "WEEKLY" && r.interval == 2
    }

    func saveScheduleEvent(_ ev: CalEvent) {
        var e = ev
        e.updatedAt = Date()
        store.upsertEvent(e)
        reloadEvents()
    }

    func deleteScheduleEvent(_ ev: CalEvent) {
        store.deleteEvent(id: ev.id)
        reloadEvents()
    }

    /// Widen the shared scale to keep a live-dragged span on-screen (expand-only,
    /// so the strip doesn't shift under the finger). Settled back on `commit`.
    func expandScale(toInclude span: TimelineSegment) {
        timelineScale = fitScale(bars: [span], base: timelineScale)
    }

    /// Re-fit the shared scale to the tight window around every slot's work bar
    /// and leave segment.
    private func refitScale() {
        var bars: [TimelineSegment] = []
        for i in 0..<slots.count {
            guard slots[i] != nil else { continue }
            let s = clampToAbsolute(startMin(i)), e = clampToAbsolute(endMin(i))
            if isEnabled(i), e > s { bars.append(TimelineSegment(startMin: s, widthMin: e - s)) }
            let lv = leave(i)
            if lv > 0 {
                let ls = isEnabled(i) ? e : TimelineConstants.absoluteStart
                let le = min(TimelineConstants.absoluteEnd, ls + lv * 60)
                if le > ls { bars.append(TimelineSegment(startMin: ls, widthMin: le - ls)) }
            }
        }
        timelineScale = fitScale(bars: bars)
    }
}

/// A pending recurring-event editor target: nil `existing` = add, else edit.
/// `dayIndex` is resolved here (in a MainActor button action) so the sheet's
/// `init` doesn't have to call the view model.
private struct ScheduleEventTarget: Identifiable {
    let id = UUID()
    var existing: CalEvent?
    var dayIndex: Int
}

struct ScheduleEditorView: View {
    @AppStorage("calendarMode") private var calendarMode = false
    @State private var model: ScheduleViewModel
    @State private var includeCurrent = false
    @State private var status: String?
    @State private var confirming = false
    @State private var showNoAnchor = false
    @State private var eventTarget: ScheduleEventTarget?

    init(model: ScheduleViewModel) { _model = State(initialValue: model) }

    private static let weekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        List {
            week(title: "Week 1", range: 0..<7)
            week(title: "Week 2", range: 7..<14)
            applySection
            if calendarMode { recurringSection }
        }
        .navigationTitle("Default Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Apply schedule?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Save & apply", role: .destructive) { runApply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Fills work days for the next year from this schedule. Existing entries on scheduled days are replaced.")
        }
        .alert("Set an anchor date first", isPresented: $showNoAnchor) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The schedule needs a pay-period anchor (Settings → Pay period) before it can be applied.")
        }
        .sheet(item: $eventTarget) { target in
            ScheduleEventEditView(existing: target.existing,
                                  initialDayIndex: target.dayIndex,
                                  model: model)
        }
    }

    // MARK: - Recurring events

    private var recurringSection: some View {
        Section {
            ForEach(model.recurringEvents) { ev in
                Button { eventTarget = ScheduleEventTarget(existing: ev, dayIndex: model.dayIndex(for: ev)) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(eventColor(ev.color)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ev.title.isEmpty ? "(untitled)" : ev.title)
                                .foregroundStyle(.primary)
                            Text(recurringSubtitle(ev))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) { model.deleteScheduleEvent(ev) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            Button {
                if model.hasAnchor { eventTarget = ScheduleEventTarget(existing: nil, dayIndex: 0) }
                else { showNoAnchor = true }
            } label: {
                Label("Add recurring event", systemImage: "plus")
            }
        } header: {
            Text("Recurring events")
        } footer: {
            Text("Repeating events that ride your pay-period schedule — each repeats every 2 weeks on its day. Edit or delete here; they also show on the Timecard and Calendar tabs.")
        }
    }

    private func recurringSubtitle(_ ev: CalEvent) -> String {
        let when = ev.allDay
            ? "all-day"
            : "\(formatMinutes(ev.startMin, use24h: model.use24h))–\(formatMinutes(ev.endMin, use24h: model.use24h))"
        return "Every 2 weeks · \(model.weekday(for: ev)) · \(when)"
    }

    private var applySection: some View {
        Section {
            Toggle("Include current period", isOn: $includeCurrent)
            Button {
                if model.hasAnchor { confirming = true } else { showNoAnchor = true }
            } label: {
                Label("Save & apply to upcoming periods", systemImage: "calendar.badge.plus")
            }
            if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
        } footer: {
            Text("Edits above save automatically and set your scheduled hours (used for overtime). “Apply” also fills work entries + leave onto your upcoming days.")
        }
    }

    private func runApply() {
        guard let result = model.apply(includeCurrent: includeCurrent) else {
            showNoAnchor = true; return
        }
        let work = "Filled \(result.written) work day\(result.written == 1 ? "" : "s")"
        let leave = result.leaveDays > 0 ? " and seeded leave on \(result.leaveDays) day\(result.leaveDays == 1 ? "" : "s")" : ""
        status = "\(work)\(leave) across the next year."
    }

    private func week(title: String, range: Range<Int>) -> some View {
        Section(title) {
            ForEach(range, id: \.self) { i in slotRow(i) }
        }
    }

    @ViewBuilder
    private func slotRow(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Day name + (when enabled) the exact work hours, all inside the
            // Toggle's label so the switch stays pinned to the trailing edge.
            Toggle(isOn: Binding(get: { model.isEnabled(i) }, set: { model.setEnabled(i, $0) })) {
                HStack(spacing: 8) {
                    Text(Self.weekdayShort[i % 7]).font(.body)
                    if model.isEnabled(i) {
                        Spacer(minLength: 8)
                        Text("\(formatMinutes(model.startMin(i), use24h: model.use24h)) – \(formatMinutes(model.endMin(i), use24h: model.use24h))")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Draggable strip: drag the handles to set the work hours; the teal
            // segment shows this day's recurring leave so it's clear which day it
            // belongs to. Mirrors the PWA's schedule editor.
            ScheduleStripView(
                startMin: model.startMin(i),
                endMin: model.endMin(i),
                leaveHours: model.leave(i),
                enabled: model.isEnabled(i),
                use24h: model.use24h,
                scale: model.timelineScale,
                onExpand: { model.expandScale(toInclude: $0) },
                onCommit: { s, e in model.setTimes(i, s, e) }
            )

            Stepper(value: Binding(get: { model.leave(i) }, set: { model.setLeave(i, $0) }), in: 0...24) {
                Text("Leave: \(model.leave(i)) h").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
