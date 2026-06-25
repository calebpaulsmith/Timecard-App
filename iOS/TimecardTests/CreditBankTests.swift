import XCTest
@testable import Timecard

final class CreditBankTests: XCTestCase {

    func testEmptyFoldIsEmpty() {
        XCTAssertTrue(creditBankFold(earnedByPeriod: []).isEmpty)
    }

    func testAccumulatesUnderCap() {
        let f = creditBankFold(earnedByPeriod: [("2026-01-04", 5), ("2026-01-18", 6)], cap: 24)
        XCTAssertEqual(f[0].carryOut, 5, accuracy: 1e-9)
        XCTAssertEqual(f[1].carryIn, 5, accuracy: 1e-9)
        XCTAssertEqual(f[1].balance, 11, accuracy: 1e-9)
        XCTAssertEqual(f[1].carryOut, 11, accuracy: 1e-9)
        XCTAssertEqual(f[1].lost, 0, accuracy: 1e-9)
    }

    func testForfeitsOverCap() {
        // 20 carried in + 10 earned = 30 → cap 24, lose 6.
        let f = creditBankFold(earnedByPeriod: [("2026-01-04", 20), ("2026-01-18", 10)], cap: 24)
        XCTAssertEqual(f[1].balance, 30, accuracy: 1e-9)
        XCTAssertEqual(f[1].carryOut, 24, accuracy: 1e-9)
        XCTAssertEqual(f[1].lost, 6, accuracy: 1e-9)
        // Next period starts from the capped 24, not 30.
        let g = creditBankFold(earnedByPeriod: [("2026-01-04", 20), ("2026-01-18", 10), ("2026-02-01", 1)], cap: 24)
        XCTAssertEqual(g[2].carryIn, 24, accuracy: 1e-9)
        XCTAssertEqual(g[2].balance, 25, accuracy: 1e-9)
        XCTAssertEqual(g[2].carryOut, 24, accuracy: 1e-9)
        XCTAssertEqual(g[2].lost, 1, accuracy: 1e-9)
    }

    func testDefaultCapIs24() {
        let f = creditBankFold(earnedByPeriod: [("2026-01-04", 30)])
        XCTAssertEqual(f[0].carryOut, 24, accuracy: 1e-9)
        XCTAssertEqual(f[0].lost, 6, accuracy: 1e-9)
    }

    func testSlotLookupSynthesizesZeroEarnedPeriod() {
        // A 0-earned period after an earning one carries the prior balance through.
        let folded = creditBankFold(earnedByPeriod: [("2026-01-04", 10)])
        let slot = creditBankSlot(forPeriodStart: "2026-02-15", in: folded)
        XCTAssertEqual(slot.carryIn, 10, accuracy: 1e-9)
        XCTAssertEqual(slot.earned, 0, accuracy: 1e-9)
        XCTAssertEqual(slot.carryOut, 10, accuracy: 1e-9)
        XCTAssertEqual(slot.lost, 0, accuracy: 1e-9)
    }

    func testSlotLookupBeforeAnyEarningIsZero() {
        let folded = creditBankFold(earnedByPeriod: [("2026-03-01", 10)])
        let slot = creditBankSlot(forPeriodStart: "2026-01-04", in: folded)
        XCTAssertEqual(slot.carryIn, 0, accuracy: 1e-9)
        XCTAssertEqual(slot.carryOut, 0, accuracy: 1e-9)
    }
}
