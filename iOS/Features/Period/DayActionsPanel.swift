import SwiftUI

/// The expand-in-place panel revealed when a day card is tapped open on the
/// Period view (both timecard and calendar mode). It replaces the old behavior
/// where tapping the day's timeline strip silently opened the full day editor —
/// now a tap *expands* the day and surfaces explicit, labeled actions:
///
///   • quick **leave +/−** (whole hours, the inward mirror of the PWA's per-day
///     leave steppers on the cards),
///   • an **Open day editor** badge (a real button, not an invisible tap area),
///   • in calendar mode, **Add event** + the read-only event mini-timeline.
///
/// Styled with Apple's **Liquid Glass** (iOS 26 `.buttonStyle(.glass)` /
/// `.glassEffect`) and a `.ultraThinMaterial` fallback below iOS 26, so it reads
/// as a distinct floating surface over the day card without a hard-edged box.
struct DayActionsPanel: View {
    let date: String
    let leaveHours: Int
    let events: [CalEvent]
    let calendarMode: Bool
    var onAdjustLeave: (Int) -> Void
    var onOpenEditor: () -> Void
    var onAddEvent: () -> Void
    var onTapEvent: (CalEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            leaveRow
            actionRow
            if calendarMode && !events.isEmpty {
                Divider().opacity(0.4)
                DayEventStrip(date: date, events: events, onTapEvent: onTapEvent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassPanelBackground())
        .padding(.top, 6)
    }

    // MARK: - Leave quick-adjust

    private var leaveRow: some View {
        HStack(spacing: 12) {
            Label("Leave", systemImage: "cup.and.saucer")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            glassGroup {
                HStack(spacing: 12) {
                    Button { onAdjustLeave(-1) } label: {
                        Image(systemName: "minus").frame(width: 20, height: 20)
                    }
                    .modifier(GlassChipButton())
                    .disabled(leaveHours <= 0)

                    Text("\(leaveHours) h")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 36)
                        .contentTransition(.numericText())

                    Button { onAdjustLeave(1) } label: {
                        Image(systemName: "plus").frame(width: 20, height: 20)
                    }
                    .modifier(GlassChipButton(tint: .teal))
                    .disabled(leaveHours >= 24)
                }
            }
            .font(.headline)
        }
    }

    // MARK: - Action badges

    private var actionRow: some View {
        glassGroup {
            HStack(spacing: 10) {
                Button { onOpenEditor() } label: {
                    Label("Open day editor", systemImage: "square.and.pencil")
                }
                .modifier(GlassChipButton())

                if calendarMode {
                    Button { onAddEvent() } label: {
                        Label("Add event", systemImage: "calendar.badge.plus")
                    }
                    .modifier(GlassChipButton(tint: .accentColor))
                }
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.semibold))
        }
    }

    /// Group adjacent glass elements so they blend + animate coherently (iOS 26).
    /// A no-op container below iOS 26.
    @ViewBuilder
    private func glassGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Liquid Glass styling (with pre-iOS-26 fallbacks)

/// Glass button chrome for the panel's chips. `.buttonStyle(.glass)` on iOS 26;
/// a bordered capsule on earlier systems.
private struct GlassChipButton: ViewModifier {
    var tint: Color? = nil

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            applyTint(content.buttonStyle(.glass))
        } else {
            content
                .buttonStyle(.bordered)
                .tint(tint ?? .accentColor)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func applyTint<V: View>(_ view: V) -> some View {
        if let tint { view.tint(tint) } else { view }
    }
}

/// The floating-glass surface behind the whole panel. `.glassEffect` on iOS 26;
/// an ultra-thin material below.
private struct GlassPanelBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}
