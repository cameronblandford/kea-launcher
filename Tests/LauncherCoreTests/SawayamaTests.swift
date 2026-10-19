import XCTest
@testable import LauncherCore

final class SawayamaTests: XCTestCase {
    private func c(_ suit: Suit, _ rank: Int) -> Card { Card(suit, rank) }

    /// An empty table to set up by hand.
    private func empty() -> Sawayama {
        var g = Sawayama(seed: 1)
        g.tableau = Array(repeating: [], count: 7)
        g.stock = []
        g.waste = []
        return g
    }

    func testCards() {
        XCTAssertEqual(Set(Card.deck).count, 52)
        XCTAssertEqual(c(.hearts, 12).name, "Q♥")
        XCTAssertEqual(c(.clubs, 1).rank, 1)
        XCTAssertEqual(c(.clubs, 13).suit, .clubs)
        XCTAssertEqual(Card(.spades, 5, deck: 1).rank, 5)
        XCTAssertNotEqual(Card(.spades, 5, deck: 1), c(.spades, 5))
        XCTAssertTrue(c(.hearts, 6).stacks(on: c(.clubs, 7)))
        XCTAssertFalse(c(.hearts, 6).stacks(on: c(.diamonds, 7)), "same color")
        XCTAssertFalse(c(.hearts, 6).stacks(on: c(.clubs, 8)))
        XCTAssertEqual(Card.shuffled(seed: 7), Card.shuffled(seed: 7))
        XCTAssertNotEqual(Card.shuffled(seed: 7), Card.shuffled(seed: 8))
        XCTAssertEqual(Set(Card.shuffled(seed: 7)).count, 52)
    }

    func testDeal() {
        let g = Sawayama(seed: 3)
        XCTAssertEqual(g.tableau.map(\.count), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(g.stock.count, 24)
        XCTAssertTrue(g.waste.isEmpty)
        XCTAssertEqual(Set(g.tableau.flatMap { $0 } + g.stock).count, 52)
        XCTAssertFalse(g.isWon)
        XCTAssertEqual(g, Sawayama(seed: 3))
    }

    func testStockDealsThreeOneTimeThenBecomesACell() {
        var g = Sawayama(seed: 3)
        let top = g.stock.last!
        XCTAssertNil(g.run(from: .stock, at: 23), "the stock is dealt, not moved")
        for dealt in 1 ... 8 {
            XCTAssertTrue(g.tapStock())
            XCTAssertEqual(g.waste.count, dealt * 3)
        }
        XCTAssertEqual(g.waste.first, top, "the first card dealt is at the bottom of the waste")
        XCTAssertFalse(g.tapStock(), "no second pass")
        XCTAssertTrue(g.stockIsCell)
        XCTAssertTrue(g.cards(in: .stock).isEmpty)

        // Only the top card of the waste moves, and one card fits in the cell.
        XCTAssertNil(g.run(from: .waste, at: 22))
        let card = g.waste.last!
        XCTAssertTrue(g.move(from: .waste, at: 23, to: .stock))
        XCTAssertEqual(g.cell, card)
        XCTAssertEqual(g.cards(in: .stock), [card])
        XCTAssertFalse(g.move(from: .waste, at: 22, to: .stock), "the cell is full")
        XCTAssertEqual(g.run(from: .stock, at: 0), [card])
    }

    func testCellIsClosedWhileTheStockHasCards() {
        var g = Sawayama(seed: 3)
        XCTAssertTrue(g.tapStock())
        XCTAssertFalse(g.canDrop([g.waste.last!], from: .waste, on: .stock))
    }

    func testRunsAndColumns() {
        var g = empty()
        g.tableau[0] = [c(.spades, 9), c(.hearts, 8), c(.clubs, 7)]
        g.tableau[1] = [c(.diamonds, 10)]
        g.tableau[2] = [c(.clubs, 5), c(.clubs, 4)]
        XCTAssertEqual(g.run(from: .tableau(0), at: 1)?.map(\.name), ["8♥", "7♣"])
        XCTAssertNil(g.run(from: .tableau(2), at: 0), "not a run: same color")
        XCTAssertEqual(g.run(from: .tableau(2), at: 1)?.count, 1)
        XCTAssertFalse(g.move(from: .tableau(0), at: 1, to: .tableau(1)), "8 does not go on 10")
        XCTAssertTrue(g.move(from: .tableau(0), at: 0, to: .tableau(1)))
        XCTAssertEqual(g.tableau[1].map(\.name), ["10♦", "9♠", "8♥", "7♣"])
        XCTAssertTrue(g.tableau[0].isEmpty)
        // Any card may go to an empty column, not only a king.
        XCTAssertTrue(g.move(from: .tableau(2), at: 1, to: .tableau(0)))
        XCTAssertEqual(g.moves, 2)
        XCTAssertFalse(g.move(from: .tableau(0), at: 0, to: .tableau(0)))
    }

    func testFoundations() {
        var g = empty()
        g.tableau[0] = [c(.hearts, 2), c(.hearts, 1)]
        g.tableau[1] = [c(.spades, 1), c(.spades, 2)]
        XCTAssertFalse(g.move(from: .tableau(0), at: 1, to: .foundation(Suit.spades.rawValue)), "each suit has its own pile")
        XCTAssertTrue(g.move(from: .tableau(0), at: 1, to: .foundation(Suit.hearts.rawValue)))
        XCTAssertTrue(g.move(from: .tableau(0), at: 0, to: .foundation(Suit.hearts.rawValue)))
        XCTAssertFalse(g.move(from: .tableau(1), at: 1, to: .foundation(Suit.spades.rawValue)), "the ace is not there yet")
        XCTAssertFalse(g.move(from: .tableau(1), at: 0, to: .foundation(Suit.spades.rawValue)), "two cards do not go at one time")
        XCTAssertNil(g.run(from: .foundation(Suit.hearts.rawValue), at: 1), "a card does not come back")
    }

    func testAutoTarget() {
        var g = empty()
        g.tableau[0] = [c(.hearts, 1)]
        g.tableau[1] = [c(.clubs, 7), c(.hearts, 6)]
        g.tableau[2] = [c(.spades, 7)]
        g.tableau[3] = [c(.diamonds, 9)]
        XCTAssertEqual(g.autoTarget(from: .tableau(0), at: 0), .foundation(Suit.hearts.rawValue))
        XCTAssertEqual(g.autoTarget(from: .tableau(1), at: 1), .tableau(2), "onto another card before an empty column")
        g.tableau[5] = [c(.diamonds, 2), c(.spades, 12), c(.hearts, 11)]
        XCTAssertEqual(g.autoTarget(from: .tableau(5), at: 1), .tableau(4), "a run that leaves a card behind may take an empty column")
        XCTAssertNil(g.autoTarget(from: .tableau(1), at: 0), "a whole column to an empty column changes nothing")
        XCTAssertNil(g.autoTarget(from: .tableau(3), at: 0), "a lone card does not go to the cell or to another empty column by a click")
        // With no column free, a single card goes to the cell.
        g.tableau[4] = [c(.clubs, 9)]
        g.tableau[6] = [c(.clubs, 13)]
        g.tableau[0] = [c(.diamonds, 13)]
        g.waste = [c(.spades, 3)]
        XCTAssertEqual(g.autoTarget(from: .waste, at: 0), .stock)
    }

    func testAutoStepOnlyMakesSafeMoves() {
        var g = empty()
        g.tableau[0] = [c(.hearts, 3)]
        g.tableau[1] = [c(.spades, 1)]
        g.tableau[2] = [c(.hearts, 2)]
        g.foundations[Suit.hearts.rawValue] = [c(.hearts, 1)]
        XCTAssertTrue(g.autoStep())
        XCTAssertTrue(g.autoStep())
        XCTAssertEqual(g.foundations[Suit.spades.rawValue].count, 1)
        XCTAssertEqual(g.foundations[Suit.hearts.rawValue].count, 2)
        // The 3♥ stays: a black 2 may still need it in a column.
        XCTAssertFalse(g.autoStep())
        XCTAssertEqual(g.tableau[0].count, 1)
        g.foundations[Suit.spades.rawValue] = [c(.spades, 1), c(.spades, 2)]
        g.foundations[Suit.clubs.rawValue] = [c(.clubs, 1), c(.clubs, 2)]
        XCTAssertTrue(g.autoStep())
        XCTAssertEqual(g.moves, 0, "automatic moves are not counted")
    }

    func testWinAndCoding() throws {
        var g = empty()
        g.foundations = Suit.allCases.map { suit in (1 ... 13).map { Card(suit, $0) } }
        g.foundations[0].removeLast()
        g.tableau[0] = [c(.spades, 13)]
        XCTAssertFalse(g.isWon)
        XCTAssertTrue(g.move(from: .tableau(0), at: 0, to: .foundation(0)))
        XCTAssertTrue(g.isWon)
        let copy = try JSONDecoder().decode(Sawayama.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(copy, g)
    }

    /// A simple player that only makes legal moves must never break the table.
    func testRandomPlayKeepsAllCards() {
        for seed in 1 ... 30 as ClosedRange<UInt64> {
            var g = Sawayama(seed: seed)
            var rng = Lorem.SplitMix(seed: seed)
            for _ in 0 ..< 300 {
                let piles: [PileID] = [.waste, .stock] + (0 ..< 7).map(PileID.tableau)
                let pile = piles[Int(rng.next() % UInt64(piles.count))]
                let count = g.cards(in: pile).count
                if count > 0, let target = g.autoTarget(from: pile, at: Int(rng.next() % UInt64(count))) {
                    _ = g.move(from: pile, at: Int(rng.next() % UInt64(count)), to: target)
                } else {
                    _ = g.tapStock()
                }
                while g.autoStep() {}
            }
            let all = g.tableau.flatMap { $0 } + g.foundations.flatMap { $0 } + g.stock + g.waste + (g.cell.map { [$0] } ?? [])
            XCTAssertEqual(Set(all).count, 52, "seed \(seed)")
            XCTAssertEqual(all.count, 52, "seed \(seed)")
            for (i, pile) in g.foundations.enumerated() {
                XCTAssertEqual(pile.map(\.rank), Array(1 ... max(pile.count, 1)).prefix(pile.count).map { $0 })
                XCTAssertTrue(pile.allSatisfy { $0.suit.rawValue == i })
            }
        }
    }
}
