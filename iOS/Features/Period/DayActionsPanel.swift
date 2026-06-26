import SwiftUI

/// The expand-in-place actions revealed when a day card is tapped open on the
/// Period view (both timecard and calendar mode). It replaces the old behavior
/// where tapping the day's timeline strip silently opened the full day editor —
/// now a tap *expands* the day and surfaces explicit, labeled actions:
///
///   • quick **leave +/−** (whole hours — the inward mirror of the PWA's per-day
///     leave steppers on the cards),
///   • an **Open day editor** badge (a real button, not an invisible tap area),
///   • in calendar mode, **Add event** + the read-only event mini-timeline.
///
/// Renders as inline content with a leading divider — the surrounding day-card
/// `List` row already provides the Liquid-Glass surface (see `GlassRowBackground`
/// in `PeriodView`), so the panel doesn't draw its own background (no glass-on-
/// glass). Its chips are glass (`glassChip`), grouped via `GlassGroup`.
struct DayActionsPanel: View {
    let date: String
    let leaveMinutes: Int
    let events: [CalEvent]
    let calendarMode: Bool
    var onAdjustLeave: (Int) -> Void   // delta in minutes
    var onOpenEditor: () -> Void
    var onAddEvent: () -> Void
    var onTapEvent: (CalEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().opacity(0.4)
            leaveRow
            actionRow
            if calendarMode && !events.isEmpty {
                DayEventStrip(date: date, events: events, onTapEvent: onTapEvent)
            }
        }
        .padding(.top, 6)
    }

    // Leave label + stepper read as ONE centered control rather than a label
    // stranded at the far left with the stepper pinned to the right edge.
    private var leaveRow: some View {
        HStack(spacing: 12) {
            Text("Leave")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LeaveStepper(minutes: leaveMinutes, onAdjust: onAdjustLeave)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var actionRow: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button { onOpenEditor() } label: {
                    Label("Open day editor", systemImage: "square.and.pencil")
                }
                .glassChip()

                if calendarMode {
                    Button { onAddEvent() } label: {
                        Label("Add event", systemImage: "calendar.badge.plus")
                    }
                    .glassChip(tint: .accentColor)
                }
            }
            .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
