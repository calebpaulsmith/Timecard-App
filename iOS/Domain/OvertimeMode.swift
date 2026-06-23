import Foundation

/// Resolve the OT mode for a pay period: a per-period override wins over the
/// global default. Mirrors the PWA's `otModeForPeriod` (and `db.js`'s
/// `getOvertimeModeForPeriodStart`). `periodStart` is the anchor-aligned period
/// start as "YYYY-MM-DD". `true` = 8-hour OT, `false` = Maxiflex.
func resolveOtMode(default def: Bool, overrides: [String: Bool], periodStart: String) -> Bool {
    overrides[periodStart] ?? def
}
