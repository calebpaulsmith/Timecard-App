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
    /// (the timecard-validation reminder marker).
    var leadingAccent: Color? = nil
    /// Optional full-card outline (today gets one to draw the eye, replacing the
    /// "Today" chip).
    var outline: Color? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack(alignment: .leading) {
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
            if let leadingAccent {
                leadingAccent.frame(width: 7)   // slightly larger reminder
            }
        }
        .clipShape(shape)
        .overlay {
            if let outline { shape.strokeBorder(outline, lineWidth: 2) }
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

/// Format leave minutes for a label. Whole-hour mode → "1 h" (or "1" compact);
/// granular mode → "1:15" for quarter-hour values, "1 h"/"1" on the hour.
func leaveLabel(minutes: Int, granular: Bool, compact: Bool = false) -> String {
    let h = minutes / 60, m = minutes % 60
    if granular && m != 0 { return String(format: "%d:%02d", h, m) }
    return compact ? "\(h)" : "\(h) h"
}

/// A leave stepper rendered as ONE glass pill — `−  N  +`. Operates in **minutes**
/// and steps by an hour (`granular == false`) or 15 minutes (`granular == true`).
/// `compact` is the smaller inline form on the collapsed day row; the full form
/// sits in the expand panel. Teal-tinted, clamped 0…24h by disabling the ends.
/// `.borderless` segments stay independently tappable inside a List row (a tap
/// adjusts leave, it doesn't expand the day).
struct LeaveStepper: View {
    @Environment(\.palette) private var palette
    let minutes: Int
    var granular: Bool = false
    var compact: Bool = false
    var onAdjust: (Int) -> Void   // delta in MINUTES (± step)

    private var step: Int { granular ? 15 : 60 }

    var body: some View {
        HStack(spacing: 0) {
            seg("minus", delta: -step, enabled: minutes > 0)
            Text(leaveLabel(minutes: minutes, granular: granular, compact: compact))
                .font((compact ? Font.subheadline : Font.callout).weight(.semibold).monospacedDigit())
                .foregroundStyle(minutes > 0 ? palette.leave : Color.secondary)
                .frame(minWidth: compact ? (granular ? 32 : 20) : 40)
                .contentTransition(.numericText())
            seg("plus", delta: step, enabled: minutes < 24 * 60)
        }
        .padding(.vertical, compact ? 1 : 3)
        .modifier(LeavePillBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Leave")
        .accessibilityValue(leaveLabel(minutes: minutes, granular: granular))
    }

    @ViewBuilder
    private func seg(_ symbol: String, delta: Int, enabled: Bool) -> some View {
        Button { onAdjust(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: compact ? 11 : 14, weight: .bold))
                .foregroundStyle(enabled ? palette.leave : Color.secondary.opacity(0.5))
                .frame(width: compact ? 28 : 36, height: compact ? 24 : 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
    }
}

/// A translucent, **tinted** Liquid-Glass fill — the themed alternative to a flat
/// `.fill(color)` / `.background(color.opacity(…))` for chips, stat pills, and
/// tags. On iOS 26 it's real glass (genuine translucency + specular sheen) tinted
/// by the palette color; below 26 it frosts `.ultraThinMaterial`, lays a tinted
/// top-down gradient over it, and hairline-strokes the edge so it still reads as
/// frosted glass, not a flat swatch. `strength` is the tint opacity.
struct TintedGlass<S: Shape>: ViewModifier {
    let tint: Color
    let shape: S
    var strength: Double = 0.2

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint.opacity(strength)).interactive(), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(
                    LinearGradient(colors: [tint.opacity(strength + 0.14),
                                            tint.opacity(strength * 0.55)],
                                   startPoint: .top, endPoint: .bottom),
                    in: shape)
                .overlay(shape.stroke(tint.opacity(0.32), lineWidth: 0.75))
        }
    }
}

/// A top-down specular highlight — the "wet glass" sheen — layered over a fill so
/// solid color bars read as glossy/translucent rather than flat. Pure overlay,
/// non-interactive.
struct GlassGloss: ViewModifier {
    var cornerRadius: CGFloat = 5
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.1), .clear],
                                     startPoint: .top, endPoint: .center))
                .blendMode(.plusLighter)
                .allowsHitTesting(false))
    }
}

extension View {
    /// Frosted, palette-tinted glass fill behind a chip/tag/stat (see `TintedGlass`).
    func tintedGlass<S: Shape>(_ tint: Color, in shape: S, strength: Double = 0.2) -> some View {
        modifier(TintedGlass(tint: tint, shape: shape, strength: strength))
    }
    /// Glassy specular sheen over a colored bar (see `GlassGloss`).
    func glassGloss(cornerRadius: CGFloat = 5) -> some View {
        modifier(GlassGloss(cornerRadius: cornerRadius))
    }
}

/// One teal-tinted glass capsule behind the whole leave stepper.
private struct LeavePillBackground: ViewModifier {
    @Environment(\.palette) private var palette
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(palette.leave.opacity(0.18)).interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(palette.leave.opacity(0.30), lineWidth: 1))
        }
    }
}
