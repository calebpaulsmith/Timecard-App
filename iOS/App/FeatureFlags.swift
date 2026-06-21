import Foundation

/// Build-edition switch for the two "faces" of the Timecard iOS app.
///
/// - **Production (App Store / pay):** the sellable timecard core + Pro. The
///   personal/calendar/life/tax exploration is **compiled out** so no dormant
///   code ships in the reviewable build (App Store compliance — see
///   `../PLATFORM-STRATEGY.md` and the legal notes in `research/`).
/// - **Personal (you):** everything on, including calendar mode and future
///   life-timecard / tax-from-LES experiments.
///
/// The `PERSONAL` compilation condition is defined ONLY for the `Personal` build
/// configuration (see `project.yml`), which the **"Maxiflex Personal"** scheme
/// runs. The default **"Maxiflex"** scheme (Debug run, Release archive → App
/// Store) leaves it undefined, so production is the safe default.
///
/// Rule for new features: anything outside the sellable timecard core is gated
/// here and defaults OFF in production. Never let a gated feature change core
/// timecard/pay math.
enum FeatureFlags {
    /// True only in the Personal edition.
    static let personalEnabled: Bool = {
        #if PERSONAL
        return true
        #else
        return false
        #endif
    }()

    /// Calendar mode (events, EventKit sync, the "life timecard"). Personal-only.
    static var calendarMode: Bool { personalEnabled }

    /// Tax-from-LES companion and other exploratory tracks. Personal-only.
    static var experiments: Bool { personalEnabled }
}
