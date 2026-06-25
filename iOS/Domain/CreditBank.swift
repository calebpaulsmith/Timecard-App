import Foundation

/// One pay period's slot in the running credit-hour bank (LOGIC-FREEZE §4.6).
/// Phase 2 of the credit-hours feature: credit earned in a period adds to a
/// balance carried forward, but a flexible-schedule employee may carry at most
/// `creditCarryoverCap` (24h) into the next period — anything above that at
/// period end is **forfeited**.
struct CreditBankSlot: Equatable, Sendable {
    var periodStart: String   // "YYYY-MM-DD" anchor-aligned period start
    var carryIn: Double       // balance carried in from the prior period (≤ cap)
    var earned: Double        // credit hours earned this period
    var balance: Double       // carryIn + earned, before the cap
    var carryOut: Double      // min(cap, balance) — carried into the next period
    var lost: Double          // max(0, balance − cap) — forfeited over the cap
}

/// Fold per-period earned credit into a running balance, applying the carryover
/// cap at every period boundary. `earnedByPeriod` MUST be in chronological order
/// (oldest first). Pure — no DB/UI.
///
/// Because a period that earns 0 credit just passes its (already ≤ cap) carry-in
/// straight through, callers can fold over **only the credit-earning periods**
/// and get the identical balance sequence — the 0-earned periods in between are
/// no-ops. That keeps the input small without changing the result.
func creditBankFold(earnedByPeriod: [(start: String, earned: Double)],
                    cap: Double = TimeConstants.creditCarryoverCap) -> [CreditBankSlot] {
    var carryIn = 0.0
    var out: [CreditBankSlot] = []
    for p in earnedByPeriod {
        let balance = carryIn + p.earned
        let carryOut = min(cap, balance)
        let lost = max(0, balance - carryOut)
        out.append(CreditBankSlot(periodStart: p.start, carryIn: carryIn, earned: p.earned,
                                  balance: balance, carryOut: carryOut, lost: lost))
        carryIn = carryOut
    }
    return out
}

/// The bank state as of a given period: the slot whose `periodStart` matches, or
/// a synthesized carry-in-only slot (earned 0) when that period earned no credit
/// and isn't in the folded list. `folded` is the output of `creditBankFold`.
func creditBankSlot(forPeriodStart start: String, in folded: [CreditBankSlot],
                    cap: Double = TimeConstants.creditCarryoverCap) -> CreditBankSlot {
    if let exact = folded.first(where: { $0.periodStart == start }) { return exact }
    // Not a credit-earning period → its balance is the carryOut of the most
    // recent earning period strictly before it (0 if none).
    let carryIn = folded.last(where: { $0.periodStart < start })?.carryOut ?? 0
    return CreditBankSlot(periodStart: start, carryIn: carryIn, earned: 0,
                          balance: carryIn, carryOut: min(cap, carryIn), lost: 0)
}
