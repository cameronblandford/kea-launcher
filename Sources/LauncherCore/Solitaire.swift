import Foundation

/// The parts that every solitaire game in Kea shares: cards, piles, and the questions a
/// card table asks of a game. `Sawayama` is the first game; FreeCell and Spider can
/// answer the same questions and use the same window.

public enum Suit: Int, Codable, CaseIterable {
    case spades, hearts, diamonds, clubs

    public var isRed: Bool { self == .hearts || self == .diamonds }
    public var symbol: String { ["♠", "♥", "♦", "♣"][rawValue] }
}

/// One playing card. `id` is unique on the table, also with two decks (Spider): the
/// second deck has ids 52 to 103.
public struct Card: Codable, Hashable {
    public var id: UInt8

    public init(id: UInt8) { self.id = id }
    public init(_ suit: Suit, _ rank: Int, deck: Int = 0) { id = UInt8(deck * 52 + suit.rawValue * 13 + rank - 1) }

    public var suit: Suit { Suit(rawValue: Int(id) % 52 / 13)! }
    /// 1 (ace) to 13 (king).
    public var rank: Int { Int(id) % 13 + 1 }
    public var isRed: Bool { suit.isRed }
    public var rankName: String { ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"][rank - 1] }
    public var name: String { rankName + suit.symbol }

    /// One deck in a fixed order.
    public static let deck: [Card] = (0 ..< 52).map { Card(id: UInt8($0)) }

    /// A shuffled deck. The same seed gives the same order.
    public static func shuffled(seed: UInt64) -> [Card] {
        var rng = Lorem.SplitMix(seed: seed)
        var cards = deck
        for i in stride(from: cards.count - 1, to: 0, by: -1) {
            cards.swapAt(i, Int(rng.next() % UInt64(i + 1)))
        }
        return cards
    }

    /// True when `self` can lie on `other` in a column that goes down by one and
    /// changes color with each card.
    public func stacks(on other: Card) -> Bool { isRed != other.isRed && rank == other.rank - 1 }
}

/// A place on the table where cards lie.
public enum PileID: Hashable, Codable {
    case stock
    case waste
    case cell(Int)
    case foundation(Int)
    case tableau(Int)
}

/// What a card table needs to know to show a game and to let a person play it.
public protocol SolitaireGame: Codable, Equatable {
    /// A new deal. The same seed gives the same deal.
    init(seed: UInt64)
    /// The cards of a pile, the bottom card first.
    func cards(in pile: PileID) -> [Card]
    /// The cards a person picks up when they take the card at `index`: that card and
    /// everything on it. Nil when it cannot be picked up.
    func run(from pile: PileID, at index: Int) -> [Card]?
    /// True when the run from `source` may be put on `target`.
    func canDrop(_ run: [Card], from source: PileID, on target: PileID) -> Bool
    /// Moves the run that starts at `index`. False, and no change, when it is not allowed.
    mutating func move(from source: PileID, at index: Int, to target: PileID) -> Bool
    /// A click on the stock. False when it does nothing.
    mutating func tapStock() -> Bool
    /// Where a click (without a drag) sends the run from `index`: the best legal place.
    func autoTarget(from source: PileID, at index: Int) -> PileID?
    /// Makes one move to a foundation that can never hurt. False when there is none.
    mutating func autoStep() -> Bool
    var isWon: Bool { get }
    /// Moves the person made (the automatic ones do not count).
    var moves: Int { get }
}
