import SwiftUI
import Observation

/// Edits the 14-slot default schedule. A slot's start/end set that day-of-period
/// index's SCHEDULED hours, which drive overtime (8h-mode OT = worked − scheduled;
/// maxiflex auto-OT = work beyond scheduled past 80h). `leaveHours` is recurring
/// leave. Changes persist immediately via `TimecardStore.setDefaultSchedule`.
///
/// Note: this edits the schedule definition. Auto-*seeding* work entries from it
/// into upcoming periods (the PWA's `applyDefaultSchedule`) is a later increment.
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

    private func commit(_ i: Int, _ s: ScheduleSlot) {
        slots[i] = s
        store.setDefaultSchedule(slots)
    }
}

struct ScheduleEditorView: View {
    @State private var model: ScheduleViewModel

    init(model: ScheduleViewModel) { _model = State(initialValue: model) }

    private static let weekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        List {
            week(title: "Week 1", range: 0..<7)
            week(title: "Week 2", range: 7..<14)
        }
        .navigationTitle("Default Schedule")
        .navigationBarTitleDisplayMode(.inline)
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
