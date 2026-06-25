import XCTest
@testable import Timecard

final class CreditBankTests: XCTestCase {

    func testEmptyFoldIsEmpty() {
        XCTAssertTrue(creditBankFold(byPeriod: []).isEmpty)
    }

    func testAccumulatesUnderCap() {
        let f = creditBankFold(byPeriod: [("2026-01-04", 5, 0), ("2026-01-18", 6, 0)], cap: 24)
        XCTAssertEqual(f[0].carryOut, 5, accuracy: 1e-9)
        XCTAssertEqual(f[1].carryIn, 5, accuracy: 1e-9)
        XCTAssertEqual(f[1].balance, 11, accuracy: 1e-9)
        XCTAssertEqual(f[1].carryOut, 11, accuracy: 1e-9)
        XCTAssertEqual(f[1].lost, 0, accuracy: 1e-9)
    }

    func testForfeitsOverCap() {
        // 20 carried in + 10 earned = 30 → cap 24, lose 6.
        let f = creditBankFold(byPeriod: [("2026-01-04", 20, 0), ("2026-01-18", 10, 0)], cap: 24)
        XCTAssertEqual(f[1].balance, 30, accuracy: 1e-9)
        XCTAssertEqual(f[1].carryOut, 24, accuracy: 1e-9)
        XCTAssertEqual(f[1].lost, 6, accuracy: 1e-9)
        // Next period starts from the capped 24, not 30.
        let g = creditBankFold(byPeriod: [("2026-01-04", 20, 0), ("2026-01-18", 10, 0), ("2026-02-01", 1, 0)], cap: 24)
        XCTAssertEqual(g[2].carryIn, 24, accuracy: 1e-9)
        XCTAssertEqual(g[2].balance, 25, accuracy: 1e-9)
        XCTAssertEqual(g[2].carryOut, 24, accuracy: 1e-9)
        XCTAssertEqual(g[2].lost, 1, accuracy: 1e-9)
    }

    func testSpendingDrawsBalanceDown() {
        // Earn 10, then spend 4 next period: balance 10 → 6.
        let f = creditBankFold(byPeriod: [("2026-01-04", 10, 0), ("2026-01-18", 0, 4)], cap: 24)
        XCTAssertEqual(f[1].carryIn, 10, accuracy: 1e-9)
        XCTAssertEqual(f[1].used, 4, accuracy: 1e-9)
        XCTAssertEqual(f[1].balance, 6, accuracy: 1e-9)
        XCTAssertEqual(f[1].carryOut, 6, accuracy: 1e-9)
    }

    func testSpendingAvoidsForfeiture() {
        // 20 in + 10 earned would lose 6, but spending 6 keeps it at exactly 24.
        let f = creditBankFold(byPeriod: [("2026-01-04", 20, 0), ("2026-01-18", 10, 6)], cap: 24)
        XCTAssertEqual(f[1].balance, 24, accuracy: 1e-9)
        XCTAssertEqual(f[1].lost, 0, accuracy: 1e-9, "spending down to the cap avoids forfeiture")
        XCTAssertEqual(f[1].carryOut, 24, accuracy: 1e-9)
    }

    func testOverspendClampsToZero() {
        // Spend more than available → carryOut floors at 0, never negative.
        let f = creditBankFold(byPeriod: [("2026-01-04", 5, 0), ("2026-01-18", 0, 8)], cap: 24)
        XCTAssertEqual(f[1].balance, -3, accuracy: 1e-9)
        XCTAssertEqual(f[1].carryOut, 0, accuracy: 1e-9)
    }

    func testDefaultCapIs24() {
        let f = creditBankFold(byPeriod: [("2026-01-04", 30, 0)])
        XCTAssertEqual(f[0].carryOut, 24, accuracy: 1e-9)
        XCTAssertEqual(f[0].lost, 6, accuracy: 1e-9)
    }

    func testSlotLookupSynthesizesInertPeriod() {
        // An inert period after an active one carries the prior balance through.
        let folded = creditBankFold(byPeriod: [("2026-01-04", 10, 0)])
        let slot = creditBankSlot(forPeriodStart: "2026-02-15", in: folded)
        XCTAssertEqual(slot.carryIn, 10, accuracy: 1e-9)
        XCTAssertEqual(slot.earned, 0, accuracy: 1e-9)
        XCTAssertEqual(slot.carryOut, 10, accuracy: 1e-9)
        XCTAssertEqual(slot.lost, 0, accuracy: 1e-9)
    }

    func testSlotLookupBeforeAnyActivityIsZero() {
        let folded = creditBankFold(byPeriod: [("2026-03-01", 10, 0)])
        let slot = creditBankSlot(forPeriodStart: "2026-01-04", in: folded)
        XCTAssertEqual(slot.carryIn, 0, accuracy: 1e-9)
        XCTAssertEqual(slot.carryOut, 0, accuracy: 1e-9)
    }
}
