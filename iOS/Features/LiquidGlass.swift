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
    @Environment(\.palette) private var palette
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
        // A whisper of the theme accent so cards read as faintly tinted glass over
        // the themed backdrop (Classic stays untinted → native).
        let glassTint = palette.themed ? palette.accent.opacity(0.07) : Color.clear
        ZStack(alignment: .leading) {
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(glassTint), in: shape)
            } else {
                shape.fill(.ultraThinMaterial).overlay(shape.fill(glassTint))
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

/// Format leave minutes as DECIMAL hours: a whole number of hours → integer
/// ("1"), otherwise two decimals ("1.25"). No clock format. `compact` drops the
/// trailing " h".
func leaveLabel(minutes: Int, compact: Bool = false) -> String {
    let num = minutes % 60 == 0 ? "\(minutes / 60)" : String(format: "%.2f", Double(minutes) / 60)
    return compact ? num : num + " h"
}

/// A leave stepper rendered as ONE glass pill — `−  N  +`. The center number is a
/// **button**: tap it to switch THAT day between **whole hours** (integer, ±1 h)
/// and **quarter hours** (two decimals like 1.25, ±0.25 h). Switching back to
/// whole rounds that day to the nearest hour. `compact` is the smaller inline form
/// on the collapsed day row; the full form sits in the expand panel. Clamped
/// 0…24 h by disabling the ends. `.borderless`/`.plain` segments stay
/// independently tappable inside a List row.
struct LeaveStepper: View {
    @Environment(\.palette) private var palette
    let minutes: Int
    var compact: Bool
    var onAdjust: (Int) -> Void   // delta in MINUTES (± step, or a rounding snap)
    /// Per-day precision. Starts fine when the value isn't on a whole hour, so a
    /// fractional value always shows its decimals.
    @State private var fine: Bool

    init(minutes: Int, compact: Bool = false, onAdjust: @escaping (Int) -> Void) {
        self.minutes = minutes
        self.compact = compact
        self.onAdjust = onAdjust
        _fine = State(initialValue: minutes % 60 != 0)
    }

    private var step: Int { fine ? 15 : 60 }
    private var display: String {
        fine ? String(format: "%.2f", Double(minutes) / 60) : "\(minutes / 60)"
    }

    var body: some View {
        HStack(spacing: 0) {
            seg("minus", delta: -step, enabled: minutes > 0)
            numberButton
            seg("plus", delta: step, enabled: minutes < 24 * 60)
        }
        .padding(.vertical, compact ? 1 : 3)
        .modifier(LeavePillBackground())
        .sensoryFeedback(.selection, trigger: fine)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Leave hours")
        .accessibilityValue(leaveLabel(minutes: minutes))
        .accessibilityHint("Double-tap the number to switch between whole and quarter hours")
    }

    /// The "tap to refine" button (affordance D): the number sits in a subtle
    /// raised glass capsule so it reads as pressable, distinct from −/+.
    private var numberButton: some View {
        Button { toggleFine() } label: {
            Text(display)
                .font((compact ? Font.subheadline : Font.callout).weight(.semibold).monospacedDigit())
                .foregroundStyle(minutes > 0 ? palette.leave : Color.secondary)
                .frame(minWidth: compact ? (fine ? 38 : 16) : (fine ? 50 : 28))
                .contentTransition(.numericText())
                .padding(.horizontal, compact ? 7 : 10)
                .padding(.vertical, compact ? 2 : 4)
                .modifier(LeaveNumberGlass())
        }
        .buttonStyle(.plain)
    }

    private func toggleFine() {
        if fine {
            // Leaving fine → round THIS day to the nearest whole hour.
            let rounded = Int((Double(minutes) / 60).rounded()) * 60
            let delta = rounded - minutes
            if delta != 0 { onAdjust(delta) }
        }
        withAnimation(.snappy(duration: 0.2)) { fine.toggle() }
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

/// Subtle raised glass capsule behind the leave number — the "this is a button"
/// cue, kept quiet (a faint glass tint + hairline teal edge, not a second heavy
/// blur).
private struct LeaveNumberGlass: ViewModifier {
    @Environment(\.palette) private var palette
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(palette.leave.opacity(0.12)), in: Capsule())
        } else {
            content
                .background(.white.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(palette.leave.opacity(0.30), lineWidth: 0.75))
        }
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
