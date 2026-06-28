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
    // Everyday — bold & transformative
    case daylight, aurora, mono, sunrise
    // The original
    case classic
    // Muted — calm, low-stimulation
    case pacific, sunset, clarity, sage, midnight
    // Moments — temporary / event modes
    case independenceDay, halloween, pride, worldCup
    var id: String { rawValue }

    /// Picker groupings.
    enum Category: String, CaseIterable, Identifiable {
        case everyday, classic, muted, moments
        var id: String { rawValue }
        var title: String {
            switch self {
            case .everyday: return "Everyday"
            case .classic: return "Classic"
            case .muted: return "Muted"
            case .moments: return "Moments"
            }
        }
    }

    var category: Category {
        switch self {
        case .daylight, .aurora, .mono, .sunrise: return .everyday
        case .classic: return .classic
        case .pacific, .sunset, .clarity, .sage, .midnight: return .muted
        case .independenceDay, .halloween, .pride, .worldCup: return .moments
        }
    }

    /// Emoji badge for Moments themes (nil for the everyday ones).
    var emoji: String? {
        switch self {
        case .independenceDay: return "🎆"
        case .halloween: return "🎃"
        case .pride: return "🏳️‍🌈"
        case .worldCup: return "⚽️"
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .daylight: return "Daylight"
        case .aurora: return "Aurora"
        case .mono: return "Mono"
        case .sunrise: return "Sunrise"
        case .classic: return "Classic"
        case .pacific: return "Pacific"
        case .sunset: return "Sunset"
        case .clarity: return "Clarity"
        case .sage: return "Sage"
        case .midnight: return "Midnight"
        case .independenceDay: return "Independence Day"
        case .halloween: return "Halloween"
        case .pride: return "Pride"
        case .worldCup: return "World Cup"
        }
    }

    var mood: String {
        switch self {
        case .daylight: return "Bright, airy true light mode"
        case .aurora: return "Vivid neon — cyan · magenta · violet"
        case .mono: return "Max-contrast, sharp, minimal"
        case .sunrise: return "Warm light — coral & amber"
        case .classic: return "The original iOS look"
        case .pacific: return "Calm, trustworthy, focused"
        case .sunset: return "Warm, energetic, optimistic"
        case .clarity: return "High-contrast, accessible-first"
        case .sage: return "Muted, earthy, low-stimulation"
        case .midnight: return "Deep, premium, refined"
        case .independenceDay: return "Red · white · blue"
        case .halloween: return "Pumpkin & purple, spooky"
        case .pride: return "Rainbow accents"
        case .worldCup: return "Festive emerald & gold"
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

        // ---- Everyday (bold) ------------------------------------------------
        case .daylight:
            return Palette(
                work: dyn("#1A73E8", "#5B9BFF"), personal: dyn("#5E5CE6", "#8B8DF6"),
                ritza: dyn("#0072B2", "#56B4E9"), amelia: dyn("#E0552B", "#FF7A4D"),
                leave: dyn("#00B8A9", "#2FD3C4"), ot: dyn("#FF8A00", "#FFA733"),
                otDeep: dyn("#C56A00", "#C97E22"), holiday: dyn("#E5398B", "#F472B6"),
                credit: dyn("#7C4DFF", "#B49BF0"), accent: dyn("#1A73E8", "#5B9BFF"),
                success: dyn("#1E9E5A", "#34D27B"), warning: dyn("#C9700A", "#F4A52A"),
                danger: dyn("#DC2626", "#F26D6D"),
                background: dyn("#F4F8FF", "#0E1422"),
                backgroundElevated: dyn("#E3ECFB", "#18222E"), themed: true)
        case .aurora:
            return Palette(
                work: dyn("#1AA9C0", "#4DD0E1"), personal: dyn("#7C4DFF", "#9B7BFF"),
                ritza: dyn("#0091B5", "#3FC2E0"), amelia: dyn("#FF7A4D", "#FF9466"),
                leave: dyn("#00B89E", "#34E0C8"), ot: dyn("#E6318C", "#FF6FB3"),
                otDeep: dyn("#B81F6E", "#D9558F"), holiday: dyn("#C13AE6", "#E06BFF"),
                credit: dyn("#7C4DFF", "#B49BF0"), accent: dyn("#9B59FF", "#B07BFF"),
                success: dyn("#12B886", "#3FD9A6"), warning: dyn("#E8950A", "#FFC04D"),
                danger: dyn("#FA5252", "#FF7A7A"),
                background: dyn("#F0ECFA", "#0E0B1E"),
                backgroundElevated: dyn("#E2D8F5", "#241652"), themed: true)
        case .mono:
            return Palette(
                work: dyn("#111111", "#FFFFFF"), personal: dyn("#5A5A5A", "#BBBBBB"),
                ritza: dyn("#0066CC", "#5AC8FF"), amelia: dyn("#CC5500", "#FF9E4D"),
                leave: dyn("#0091A8", "#00E5FF"), ot: dyn("#B98A00", "#FFD400"),
                otDeep: dyn("#8A6A00", "#C9A800"), holiday: dyn("#C0007A", "#FF4DC4"),
                credit: dyn("#6A35D6", "#B388FF"), accent: dyn("#111111", "#FFFFFF"),
                success: dyn("#1A7F37", "#3FE06B"), warning: dyn("#B98A00", "#FFD400"),
                danger: dyn("#D11A2A", "#FF5A5A"),
                background: dyn("#FFFFFF", "#000000"),
                backgroundElevated: dyn("#ECECEC", "#141414"), themed: true)
        case .sunrise:
            return Palette(
                work: dyn("#E0552B", "#FF7A4D"), personal: dyn("#9B5DE5", "#B98BF0"),
                ritza: dyn("#1F8FB2", "#56B4E9"), amelia: dyn("#C77A3A", "#E0A05E"),
                leave: dyn("#0E9AA7", "#2FD3C4"), ot: dyn("#E8920C", "#FFB454"),
                otDeep: dyn("#B5710A", "#C97E22"), holiday: dyn("#D6336C", "#FF6FA3"),
                credit: dyn("#7C4DD0", "#B49BF0"), accent: dyn("#E0552B", "#FF7A4D"),
                success: dyn("#2F9E44", "#48C46A"), warning: dyn("#C2410C", "#F08A3C"),
                danger: dyn("#C01F1F", "#F0625C"),
                background: dyn("#FFF6EE", "#1A1009"),
                backgroundElevated: dyn("#FFE7D6", "#2A1B10"), themed: true)

        // ---- Moments (temporary / event) ------------------------------------
        case .independenceDay:
            return Palette(
                work: dyn("#0A3161", "#3C6FE0"), personal: dyn("#5E5CE6", "#8B8DF6"),
                ritza: dyn("#1F6FB2", "#56B4E9"), amelia: dyn("#B31942", "#E23B5A"),
                leave: dyn("#5B7FB5", "#AFC4E8"), ot: dyn("#B31942", "#E23B5A"),
                otDeep: dyn("#8A1233", "#B5274A"), holiday: dyn("#B31942", "#E23B5A"),
                credit: dyn("#6A4FB0", "#B49BF0"), accent: dyn("#B31942", "#E23B5A"),
                success: dyn("#1E7A46", "#3FD27B"), warning: dyn("#C9700A", "#F4A52A"),
                danger: dyn("#B31942", "#E23B5A"),
                background: dyn("#EEF2FB", "#0A1733"),
                backgroundElevated: dyn("#DCE6F5", "#0A3161"), themed: true)
        case .halloween:
            return Palette(
                work: dyn("#FF7518", "#FF9347"), personal: dyn("#7B2FBF", "#A56BE0"),
                ritza: dyn("#3FB57A", "#5FD699"), amelia: dyn("#D6336C", "#FF6FA3"),
                leave: dyn("#5FA8A0", "#7FD0C8"), ot: dyn("#FFB300", "#FFC54A"),
                otDeep: dyn("#C98A00", "#D9A82E"), holiday: dyn("#9B2FBF", "#C46BE0"),
                credit: dyn("#7B2FBF", "#A56BE0"), accent: dyn("#FF7518", "#FF9347"),
                success: dyn("#3FB57A", "#5FD699"), warning: dyn("#FFB300", "#FFC54A"),
                danger: dyn("#E0392B", "#FF6B5E"),
                background: dyn("#F3EEF7", "#0B0A0F"),
                backgroundElevated: dyn("#E7DCF0", "#1A0F22"), themed: true)
        case .pride:
            return Palette(
                work: dyn("#004DFF", "#5A8CFF"), personal: dyn("#750787", "#A65BC4"),
                ritza: dyn("#008026", "#3FD27B"), amelia: dyn("#FF8C00", "#FFA94D"),
                leave: dyn("#0FA3B1", "#3FD0D9"), ot: dyn("#E40303", "#FF5A5A"),
                otDeep: dyn("#B00202", "#D93B3B"), holiday: dyn("#FF0098", "#FF5AC4"),
                credit: dyn("#750787", "#A65BC4"), accent: dyn("#9C27B0", "#C45BD6"),
                success: dyn("#008026", "#3FD27B"), warning: dyn("#FF8C00", "#FFA94D"),
                danger: dyn("#E40303", "#FF5A5A"),
                background: dyn("#F6F3F8", "#15121A"),
                backgroundElevated: dyn("#ECE4F2", "#221830"), themed: true)
        case .worldCup:
            return Palette(
                work: dyn("#1FB573", "#3FD694"), personal: dyn("#1F6FB2", "#56B4E9"),
                ritza: dyn("#C026A3", "#E879C9"), amelia: dyn("#E0552B", "#FF7A4D"),
                leave: dyn("#0E9AA7", "#34C7CA"), ot: dyn("#E0A21C", "#FFD873"),
                otDeep: dyn("#B07E14", "#D9B84E"), holiday: dyn("#D6336C", "#FF6FA3"),
                credit: dyn("#7E4FD0", "#B292EE"), accent: dyn("#1FB573", "#3FD694"),
                success: dyn("#1FB573", "#3FD694"), warning: dyn("#E0A21C", "#FFD873"),
                danger: dyn("#E0392B", "#FF6B5E"),
                background: dyn("#EAF6F0", "#06281C"),
                backgroundElevated: dyn("#D6EBE0", "#0B3B29"), themed: true)
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
                Text((theme.emoji.map { $0 + "  " } ?? "") + theme.displayName)
                Text(theme.mood).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The theme picker screen — themes grouped by category (Everyday · Classic ·
/// Muted · Moments), each row a tappable `ThemeRow` with a check on the active one.
struct ThemePickerView: View {
    @AppStorage("appTheme") private var themeId = AppTheme.classic.rawValue
    var body: some View {
        List {
            ForEach(AppTheme.Category.allCases) { cat in
                Section(cat.title) {
                    ForEach(AppTheme.allCases.filter { $0.category == cat }) { t in
                        Button {
                            themeId = t.rawValue
                        } label: {
                            HStack {
                                ThemeRow(theme: t)
                                Spacer()
                                if t.rawValue == themeId {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}
