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
    /// Optional accent hugging the left edge. Drawn inside the card and clipped to
    /// its rounded shape, so the bar's top/bottom ends follow the corner curve
    /// rather than reading as a straight line stopping short of the corners
    /// (the today / validation marker).
    var leadingAccent: Color? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack(alignment: .leading) {
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
            if let leadingAccent {
                leadingAccent.frame(width: 5)
            }
        }
        .clipShape(shape)
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

/// A whole-hours leave stepper rendered as ONE glass pill — `−  N  +` — rather
/// than separate floating circles. `compact` is the smaller inline form on the
/// collapsed day row; the full form sits in the expand panel. Teal-tinted,
/// clamped 0…24 by disabling the ends. `.borderless` segments stay independently
/// tappable inside a List row (a tap adjusts leave, it doesn't expand the day).
struct LeaveStepper: View {
    let hours: Int
    var compact: Bool = false
    var onAdjust: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            seg("minus", delta: -1, enabled: hours > 0)
            Text(compact ? "\(hours)" : "\(hours) h")
                .font((compact ? Font.subheadline : Font.callout).weight(.semibold).monospacedDigit())
                .foregroundStyle(hours > 0 ? Color.teal : Color.secondary)
                .frame(minWidth: compact ? 20 : 30)
                .contentTransition(.numericText())
            seg("plus", delta: 1, enabled: hours < 24)
        }
        .padding(.vertical, compact ? 1 : 3)
        .modifier(LeavePillBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Leave hours")
        .accessibilityValue("\(hours)")
    }

    @ViewBuilder
    private func seg(_ symbol: String, delta: Int, enabled: Bool) -> some View {
        Button { onAdjust(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: compact ? 11 : 14, weight: .bold))
                .foregroundStyle(enabled ? Color.teal : Color.secondary.opacity(0.5))
                .frame(width: compact ? 28 : 36, height: compact ? 24 : 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
    }
}

/// One teal-tinted glass capsule behind the whole leave stepper.
private struct LeavePillBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.teal.opacity(0.18)).interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.teal.opacity(0.30), lineWidth: 1))
        }
    }
}
