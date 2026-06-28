import SwiftUI
import UIKit

/// Selectable color themes — the iOS mirror of the PWA's theme menu (CLAUDE.md
/// "Theme menu — BUILT (v37, PWA)"). A theme is just a remap of the semantic
/// **data** colors (work / overtime / leave / credit / holiday / people / accent):
/// the bars, stats, tags, charts, and tint. System chrome (Form/List backgrounds,
/// label text) stays native and already adapts to light/dark — deeper background
/// theming is a deliberate follow-up.
///
/// Classic = the app's current look (the system `.blue`/`.orange`/`.teal`/… it
/// already uses), so the default is unchanged. The other five themes supply
/// explicit light+dark hexes; `Color(light:dark:)` resolves the right one per
/// trait at render time, so OS dark mode keeps working per theme.

// MARK: - Color helpers

extension Color {
    /// Parse `#RGB` / `#RRGGBB` / `#RRGGBBAA`.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        switch s.count {
        case 3:
            r = Double((v >> 8) & 0xF) / 15; g = Double((v >> 4) & 0xF) / 15
            b = Double(v & 0xF) / 15; a = 1
        case 8:
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        default: // 6 (or anything else falls back to 6-digit parse)
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255; a = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// A dynamic color that resolves to `light` or `dark` per the current
    /// userInterfaceStyle — so a single token adapts to OS dark mode.
    init(light: Color, dark: Color) {
        self = Color(UIColor { trait in
            UIColor(trait.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// Per-trait brightness shift (keeps the dynamic light/dark base intact, then
    /// nudges brightness) — used to derive gradient stops from a base hue.
    func shiftedBrightness(_ delta: CGFloat) -> Color {
        Color(UIColor { trait in
            let base = UIColor(self).resolvedColor(with: trait)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard base.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return base }
            return UIColor(hue: h, saturation: s, brightness: min(1, max(0, b + delta)), alpha: a)
        })
    }
    func lightened(_ d: CGFloat = 0.12) -> Color { shiftedBrightness(d) }
    func darkened(_ d: CGFloat = 0.16) -> Color { shiftedBrightness(-d) }
}

private func dyn(_ light: String, _ dark: String) -> Color {
    Color(light: Color(hex: light), dark: Color(hex: dark))
}

// MARK: - Palette (the semantic data colors a theme remaps)

struct Palette {
    var work: Color
    var personal: Color
    var ritza: Color
    var amelia: Color
    var leave: Color
    var ot: Color
    var otDeep: Color
    var holiday: Color
    var credit: Color
    var accent: Color
    var success: Color
    var warning: Color
    var danger: Color
    /// App background tone + its slightly-elevated step. For Classic these are the
    /// system grouped backgrounds (native look); themed palettes carry their own
    /// hues so each theme has a distinct backdrop the glass refracts.
    var background: Color
    var backgroundElevated: Color
    /// False for Classic → `backgroundView` returns the plain system background
    /// (no tint / glow), keeping the default look native.
    var themed: Bool

    /// The full-screen themed backdrop: a soft diagonal gradient (background →
    /// elevated) with a faint accent glow in the top-trailing corner for depth /
    /// "texture" the glass surfaces refract. Classic → flat system background.
    var backgroundView: AnyView {
        guard themed else { return AnyView(Color(.systemGroupedBackground)) }
        return AnyView(
            ZStack {
                LinearGradient(colors: [background, backgroundElevated],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [accent.opacity(0.16), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 420)
                RadialGradient(colors: [leave.opacity(0.10), .clear],
                               center: .bottomLeading, startRadius: 0, endRadius: 380)
            }
        )
    }

    /// SwiftUI color for a calendar event color token.
    func eventColor(_ token: EventColor) -> Color {
        switch token {
        case .work: return work
        case .personal: return personal
        case .ritza: return ritza
        case .amelia: return amelia
        }
    }

    /// Render color for an event: the owning calendar's configured/device color
    /// (`#RRGGBB`) when set, else the legacy `EventColor` theme swatch. This is the
    /// bridge from the old four-token model to per-calendar colors.
    func eventColor(_ ev: CalEvent, configHex: String?) -> Color {
        if let h = configHex, !h.isEmpty { return Color(hex: h) }
        return eventColor(ev.color)
    }

    // Bar gradients — derived from the base hues so they stay dark-correct.
    var workGradient: LinearGradient {
        LinearGradient(colors: [work.lightened(0.12), work],
                       startPoint: .top, endPoint: .bottom)
    }
    var otGradient: LinearGradient {
        LinearGradient(colors: [ot.lightened(0.20), ot, otDeep],
                       startPoint: .top, endPoint: .bottom)
    }
    var inProgressGradient: LinearGradient {
        LinearGradient(colors: [warning.lightened(0.16), warning],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Themes

enum AppTheme: String, CaseIterable, Identifiable {
    case classic, pacific, sunset, clarity, sage, midnight
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .pacific: return "Pacific"
        case .sunset: return "Sunset"
        case .clarity: return "Clarity"
        case .sage: return "Sage"
        case .midnight: return "Midnight"
        }
    }

    var mood: String {
        switch self {
        case .classic: return "The original iOS look"
        case .pacific: return "Calm, trustworthy, focused"
        case .sunset: return "Warm, energetic, optimistic"
        case .clarity: return "High-contrast, accessible-first"
        case .sage: return "Muted, earthy, low-stimulation"
        case .midnight: return "Deep, premium, refined"
        }
    }

    /// Light-mode preview swatches for the Settings picker (work · OT · leave ·
    /// holiday · credit).
    var swatches: [Color] {
        let p = palette
        return [p.work, p.ot, p.leave, p.holiday, p.credit]
    }

    var palette: Palette {
        switch self {
        case .classic:
            // The app's existing system colors — keeps the default unchanged.
            return Palette(
                work: .blue, personal: .indigo, ritza: .pink, amelia: .green,
                leave: .teal, ot: .orange, otDeep: Color(red: 0.90, green: 0.52, blue: 0.0),
                holiday: .pink, credit: .purple, accent: .accentColor,
                success: .green, warning: .orange, danger: .red,
                background: Color(.systemGroupedBackground),
                backgroundElevated: Color(.secondarySystemGroupedBackground),
                themed: false)
        case .pacific:
            return Palette(
                work: dyn("#0A6CFF", "#4F9BFF"), personal: dyn("#6366F1", "#8B8DF6"),
                ritza: dyn("#0072B2", "#56B4E9"), amelia: dyn("#D55E00", "#F0852E"),
                leave: dyn("#0E9AA7", "#3FC7D2"), ot: dyn("#E8920C", "#F6AE3D"),
                otDeep: dyn("#B5710A", "#C98322"), holiday: dyn("#DB2777", "#F472B6"),
                credit: dyn("#8B5CF6", "#B49BF0"), accent: dyn("#0A6CFF", "#4688E0"),
                success: dyn("#16A34A", "#34D27B"), warning: dyn("#D97706", "#F4A52A"),
                danger: dyn("#DC2626", "#F26D6D"),
                background: dyn("#F7F9FC", "#0B0F16"),
                backgroundElevated: dyn("#EEF2F7", "#1B2433"), themed: true)
        case .sunset:
            return Palette(
                work: dyn("#1F6FB2", "#56A0E0"), personal: dyn("#7C5CC4", "#A98BE8"),
                ritza: dyn("#0072B2", "#56B4E9"), amelia: dyn("#E0552B", "#FF7A4D"),
                leave: dyn("#0C8F94", "#34BEC2"), ot: dyn("#D9760B", "#F6A23A"),
                otDeep: dyn("#A8590A", "#C97E22"), holiday: dyn("#C026A3", "#E879C9"),
                credit: dyn("#7E4FD0", "#B292EE"), accent: dyn("#C2461E", "#D66641"),
                success: dyn("#2F9E44", "#48C46A"), warning: dyn("#C2410C", "#F08A3C"),
                danger: dyn("#C01F1F", "#F0625C"),
                background: dyn("#FBF6F0", "#14100C"),
                backgroundElevated: dyn("#F4E9DD", "#2A211A"), themed: true)
        case .clarity:
            return Palette(
                work: dyn("#0072B2", "#56B4E9"), personal: dyn("#7B3FA0", "#C79AE6"),
                ritza: dyn("#009E73", "#34D9A6"), amelia: dyn("#D55E00", "#FF8A3D"),
                leave: dyn("#1B8A8F", "#4FD0D6"), ot: dyn("#B5710A", "#F0C04A"),
                otDeep: dyn("#8A5608", "#C79A2E"), holiday: dyn("#A21C8E", "#E879C9"),
                credit: dyn("#6A4FB0", "#B6A0E8"), accent: dyn("#0058B0", "#4189D6"),
                success: dyn("#007A4D", "#3DDC97"), warning: dyn("#B45309", "#E8A33D"),
                danger: dyn("#C2261B", "#FF6B5E"),
                background: dyn("#FFFFFF", "#000000"),
                backgroundElevated: dyn("#F0F0F0", "#1C1C1C"), themed: true)
        case .sage:
            return Palette(
                work: dyn("#3F6E8C", "#6FA3C2"), personal: dyn("#7A6CA8", "#A99BD6"),
                ritza: dyn("#2F8F7E", "#4FC3AD"), amelia: dyn("#C77A3A", "#E0A05E"),
                leave: dyn("#1F7E86", "#3FB6BD"), ot: dyn("#C0891F", "#E2B254"),
                otDeep: dyn("#946812", "#B98C34"), holiday: dyn("#B5557E", "#DE8AAC"),
                credit: dyn("#8A5BA6", "#C0A0D8"), accent: dyn("#4E7C5B", "#659070"),
                success: dyn("#3E8E55", "#5FBE7C"), warning: dyn("#B07A1E", "#E0AE4B"),
                danger: dyn("#B4452F", "#E07A63"),
                background: dyn("#F5F6F1", "#101410"),
                backgroundElevated: dyn("#E9ECE2", "#222820"), themed: true)
        case .midnight:
            return Palette(
                work: dyn("#3A47B0", "#7A86FF"), personal: dyn("#7A4FC0", "#B07BF0"),
                ritza: dyn("#0E7C9E", "#3CC2E0"), amelia: dyn("#C56A2A", "#F0945A"),
                leave: dyn("#0D8C8F", "#34C7CA"), ot: dyn("#C2891A", "#F0C24E"),
                otDeep: dyn("#946612", "#C39A2E"), holiday: dyn("#B02E86", "#E866B8"),
                credit: dyn("#8A4FD0", "#C49BF0"), accent: dyn("#4B43C4", "#8B83FF"),
                success: dyn("#1E9E6A", "#3FD292"), warning: dyn("#B7791F", "#E6B23E"),
                danger: dyn("#C92D4B", "#FF5C7A"),
                background: dyn("#F4F5FA", "#0A0B14"),
                backgroundElevated: dyn("#E8EAF3", "#1B1D2E"), themed: true)
        }
    }
}

// MARK: - Environment plumbing

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = AppTheme.classic.palette
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Settings picker row

/// One row in the Settings theme picker: name + mood + a strip of the theme's
/// own preview swatches.
struct ThemeRow: View {
    let theme: AppTheme
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(Array(theme.swatches.enumerated()), id: \.offset) { _, c in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(c)
                        .frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(theme.displayName)
                Text(theme.mood).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
