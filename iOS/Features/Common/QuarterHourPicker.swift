import SwiftUI

/// Three discrete menus (hour · quarter-minute · AM/PM) editing a
/// minutes-since-midnight value. Deliberately NOT a `DatePicker` wheel, which on
/// iOS only offers 1-minute granularity and lets users save sub-quarter times
/// that then round on display (PWA gotcha #5).
struct QuarterHourPicker: View {
    @Binding var minutes: Int

    private static let quarters = [0, 15, 30, 45]

    var body: some View {
        let p = clockFromMinutes(minutes)
        HStack(spacing: 6) {
            Picker("Hour", selection: hourBinding(p)) {
                ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
            }
            Text(":").foregroundStyle(.secondary)
            Picker("Minute", selection: minuteBinding(p)) {
                ForEach(Self.quarters, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            Picker("AM/PM", selection: meridiemBinding(p)) {
                Text("AM").tag(false)
                Text("PM").tag(true)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private func hourBinding(_ p: (hour12: Int, minute: Int, isPM: Bool)) -> Binding<Int> {
        Binding(get: { p.hour12 },
                set: { minutes = minutesFromClock(hour12: $0, minute: p.minute, isPM: p.isPM) })
    }
    private func minuteBinding(_ p: (hour12: Int, minute: Int, isPM: Bool)) -> Binding<Int> {
        Binding(get: { p.minute },
                set: { minutes = minutesFromClock(hour12: p.hour12, minute: $0, isPM: p.isPM) })
    }
    private func meridiemBinding(_ p: (hour12: Int, minute: Int, isPM: Bool)) -> Binding<Bool> {
        Binding(get: { p.isPM },
                set: { minutes = minutesFromClock(hour12: p.hour12, minute: p.minute, isPM: $0) })
    }
}
