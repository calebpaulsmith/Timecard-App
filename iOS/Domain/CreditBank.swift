import Foundation

/// One pay period's slot in the running credit-hour bank (LOGIC-FREEZE §4.6).
/// Phase 2 of the credit-hours feature: credit earned in a period adds to a
/// balance carried forward (credit spent as time off subtracts), but a
/// flexible-schedule employee may carry at most `creditCarryoverCap` (24h) into
/// the next period — anything above that at period end is **forfeited**.
struct CreditBankSlot: Equatable, Sendable {
    var periodStart: String   // "YYYY-MM-DD" anchor-aligned period start
    var carryIn: Double       // balance carried in from the prior period (≤ cap)
    var earned: Double        // credit hours earned this period
    var used: Double          // credit hours spent this period (time off, like leave)
    var balance: Double       // carryIn + earned − used, before the cap
    var carryOut: Double      // clamp(balance, 0, cap) — carried into the next period
    var lost: Double          // max(0, balance − cap) — forfeited over the cap
}

/// Fold per-period credit into a running balance, applying the carryover cap at
/// every period boundary. Each period contributes `earned` (credit accrued) and
/// `used` (credit spent as time off); `balance = carryIn + earned − used`.
/// `byPeriod` MUST be in chronological order (oldest first). Pure — no DB/UI.
///
/// A period with no earn and no spend just passes its (already ≤ cap) carry-in
/// straight through, so callers can fold over **only the credit-relevant
/// periods** and get the identical balance sequence — the inert periods in
/// between are no-ops. That keeps the input small without changing the result.
func creditBankFold(byPeriod: [(start: String, earned: Double, used: Double)],
                    cap: Double = TimeConstants.creditCarryoverCap) -> [CreditBankSlot] {
    var carryIn = 0.0
    var out: [CreditBankSlot] = []
    for p in byPeriod {
        let balance = carryIn + p.earned - p.used
        let carryOut = min(cap, max(0, balance))   // can't carry negative or over the cap
        let lost = max(0, balance - cap)
        out.append(CreditBankSlot(periodStart: p.start, carryIn: carryIn, earned: p.earned,
                                  used: p.used, balance: balance, carryOut: carryOut, lost: lost))
        carryIn = carryOut
    }
    return out
}

/// The bank state as of a given period: the slot whose `periodStart` matches, or
/// a synthesized carry-in-only slot when that period is credit-inert and isn't in
/// the folded list. `folded` is the output of `creditBankFold`.
func creditBankSlot(forPeriodStart start: String, in folded: [CreditBankSlot],
                    cap: Double = TimeConstants.creditCarryoverCap) -> CreditBankSlot {
    if let exact = folded.first(where: { $0.periodStart == start }) { return exact }
    // Inert period → its balance is the carryOut of the most recent credit-active
    // period strictly before it (0 if none).
    let carryIn = folded.last(where: { $0.periodStart < start })?.carryOut ?? 0
    return CreditBankSlot(periodStart: start, carryIn: carryIn, earned: 0, used: 0,
                          balance: carryIn, carryOut: min(cap, carryIn), lost: 0)
}
