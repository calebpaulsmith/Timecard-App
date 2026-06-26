import SwiftUI

// Shared Apple **Liquid Glass** building blocks (iOS 26) with graceful fallbacks
// for the iOS 17 deployment floor. Centralized so the Period page — header,
// day-card rows, the expand panel — share one consistent glass language.
//
// Restraint per Apple's HIG: glass is for floating/interactive chrome (chips,
// nav buttons, card surfaces), not every pixel. Everything here is gated behind
// `#available(iOS 26.0, *)` and degrades to `.ultraThinMaterial` / `.bordered`.

/// Groups adjacent glass elements so they blend + morph coherently
/// (`GlassEffectContainer` on iOS 26); a transparent passthrough below.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A floating Liquid-Glass surface for a `List` row / card. `.glassEffect` on
/// iOS 26, `.ultraThinMaterial` below. Insets itself slightly so adjacent rows
/// read as separate cards once the List's own background is hidden.
struct GlassRowBackground: View {
    var cornerRadius: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// Glass chrome for a small label/icon button: `.buttonStyle(.glass)` on iOS 26,
/// a bordered capsule below. Optional tint.
struct GlassChipButton: ViewModifier {
    var tint: Color? = nil

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint { content.buttonStyle(.glass).tint(tint) }
            else { content.buttonStyle(.glass) }
        } else {
            content.buttonStyle(.bordered)
                .tint(tint ?? .accentColor)
                .clipShape(Capsule())
        }
    }
}

extension View {
    /// Apply the shared glass chip chrome to a button (with pre-iOS-26 fallback).
    func glassChip(tint: Color? = nil) -> some View { modifier(GlassChipButton(tint: tint)) }
}

/// A whole-hours leave +/− stepper, teal-tinted. `compact` is the tiny inline
/// form on the collapsed day row; the full form (glass chips) lives in the
/// expand panel. Clamped 0…24 by disabling the ends.
struct LeaveStepper: View {
    let hours: Int
    var compact: Bool = false
    var onAdjust: (Int) -> Void

    var body: some View {
        HStack(spacing: compact ? 4 : 12) {
            button("minus", delta: -1, enabled: hours > 0)
            Text(compact ? "\(hours)" : "\(hours) h")
                .font((compact ? Font.caption : Font.callout).weight(.semibold).monospacedDigit())
                .foregroundStyle(hours > 0 ? Color.teal : Color.secondary)
                .frame(minWidth: compact ? 14 : 34)
                .contentTransition(.numericText())
            button("plus", delta: 1, enabled: hours < 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Leave hours")
        .accessibilityValue("\(hours)")
    }

    @ViewBuilder
    private func button(_ symbol: String, delta: Int, enabled: Bool) -> some View {
        let b = Button { onAdjust(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: compact ? 10 : 15, weight: .bold))
                .frame(width: compact ? 22 : 30, height: compact ? 22 : 30)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)

        if compact {
            // Tiny, self-contained teal circle — keeps the collapsed row quiet.
            // `.borderless` keeps each button independently tappable inside a List
            // row (so a tap adjusts leave instead of expanding the day).
            b.buttonStyle(.borderless)
                .foregroundStyle(enabled ? Color.teal : Color.secondary)
                .background(Color.teal.opacity(enabled ? 0.14 : 0.06), in: Circle())
        } else {
            b.glassChip(tint: .teal)
        }
    }
}
