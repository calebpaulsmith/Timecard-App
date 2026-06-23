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

    init(store: TimecardStore) {
        self.store = store
        self.slots = store.defaultSchedule()
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
                                          holidays: Set(store.holidays().keys), calendar: calendar)
    }

    private func commit(_ i: Int, _ s: ScheduleSlot) {
        slots[i] = s
        store.setDefaultSchedule(slots)
    }
}

struct ScheduleEditorView: View {
    @State private var model: ScheduleViewModel
    @State private var includeCurrent = false
    @State private var status: String?
    @State private var confirming = false
    @State private var showNoAnchor = false

    init(model: ScheduleViewModel) { _model = State(initialValue: model) }

    private static let weekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        List {
            week(title: "Week 1", range: 0..<7)
            week(title: "Week 2", range: 7..<14)
            applySection
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
            Toggle(isOn: Binding(get: { model.isEnabled(i) }, set: { model.setEnabled(i, $0) })) {
                Text("\(Self.weekdayShort[i % 7]) — work").font(.body)
            }
            if model.isEnabled(i) {
                HStack {
                    QuarterHourPicker(minutes: Binding(get: { model.startMin(i) }, set: { model.setStart(i, $0) }))
                    Text("–").foregroundStyle(.secondary)
                    QuarterHourPicker(minutes: Binding(get: { model.endMin(i) }, set: { model.setEnd(i, $0) }))
                }
                .font(.footnote)
            }
            Stepper(value: Binding(get: { model.leave(i) }, set: { model.setLeave(i, $0) }), in: 0...24) {
                Text("Leave: \(model.leave(i)) h").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
