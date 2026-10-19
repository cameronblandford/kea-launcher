import Foundation

/// Sawayama Solitaire (from Zachtronics' Last Call BBS). It is Klondike with three changes:
/// every card is dealt face up, the stock is dealt three at a time and only one time, and
/// when the stock is empty its place becomes a free cell for one card. Any card or run
/// may go to an empty column.
public struct Sawayama: SolitaireGame {
    /// Seven columns, the bottom card first. Column `i` starts with `i + 1` cards.
    public var tableau: [[Card]]
    /// One pile for each suit, in the order of `Suit`.
    public var foundations: [[Card]]
    /// The top card is the last.
    public var stock: [Card]
    public var waste: [Card]
    /// The card in the stock's place, after the stock is empty.
    public var cell: Card?
    public var moves = 0

    public init(seed: UInt64) {
        let deck = Card.shuffled(seed: seed)
        var next = 0
        tableau = (0 ..< 7).map { column in
            defer { next += column + 1 }
            return Array(deck[next ..< next + column + 1])
        }
        foundations = [[], [], [], []]
        stock = Array(deck[next...])
        waste = []
    }

    /// The stock's place holds a card only when the stock is empty.
    public var stockIsCell: Bool { stock.isEmpty }
    public var isWon: Bool { foundations.allSatisfy { $0.count == 13 } }

    public func cards(in pile: PileID) -> [Card] {
        switch pile {
        case .stock: return stock.isEmpty ? (cell.map { [$0] } ?? []) : stock
        case .waste: return waste
        case .foundation(let i): return foundations[i]
        case .tableau(let i): return tableau[i]
        case .cell: return []
        }
    }

    public func run(from pile: PileID, at index: Int) -> [Card]? {
        switch pile {
        case .waste:
            return index == waste.count - 1 ? [waste[index]] : nil
        case .stock:
            // Only the card in the free cell; the stock itself is dealt, not moved.
            guard stock.isEmpty, index == 0, let cell else { return nil }
            return [cell]
        case .tableau(let i):
            let column = tableau[i]
            guard index >= 0, index < column.count else { return nil }
            let run = Array(column[index...])
            for (upper, lower) in zip(run.dropFirst(), run) where !upper.stacks(on: lower) { return nil }
            return run
        case .foundation, .cell:
            return nil
        }
    }

    public func canDrop(_ run: [Card], from source: PileID, on target: PileID) -> Bool {
        guard let first = run.first, source != target else { return false }
        switch target {
        case .foundation(let i):
            return run.count == 1 && first.suit.rawValue == i && first.rank == foundations[i].count + 1
        case .tableau(let i):
            guard let top = tableau[i].last else { return true }
            return first.stacks(on: top)
        case .stock:
            return run.count == 1 && stock.isEmpty && cell == nil
        case .waste, .cell:
            return false
        }
    }

    private mutating func take(from source: PileID, at index: Int) {
        switch source {
        case .waste: waste.removeLast()
        case .stock: cell = nil
        case .tableau(let i): tableau[i].removeSubrange(index...)
        case .foundation, .cell: break
        }
    }

    private mutating func put(_ run: [Card], on target: PileID) {
        switch target {
        case .foundation(let i): foundations[i] += run
        case .tableau(let i): tableau[i] += run
        case .stock: cell = run[0]
        case .waste, .cell: break
        }
    }

    public mutating func move(from source: PileID, at index: Int, to target: PileID) -> Bool {
        guard let run = run(from: source, at: index), canDrop(run, from: source, on: target) else { return false }
        take(from: source, at: index)
        put(run, on: target)
        moves += 1
        return true
    }

    /// Deals three cards (or what is left) to the waste. The last one dealt is on top.
    public mutating func tapStock() -> Bool {
        guard !stock.isEmpty else { return false }
        for _ in 0 ..< min(3, stock.count) { waste.append(stock.removeLast()) }
        moves += 1
        return true
    }

    public func autoTarget(from source: PileID, at index: Int) -> PileID? {
        guard let run = run(from: source, at: index) else { return nil }
        if run.count == 1, canDrop(run, from: source, on: .foundation(run[0].suit.rawValue)) { return .foundation(run[0].suit.rawValue) }
        let columns = (0 ..< 7).map(PileID.tableau).filter { canDrop(run, from: source, on: $0) }
        // On another card first. An empty column only when the move frees something:
        // a whole column that moves to an empty column changes nothing.
        if let onCard = columns.first(where: { !cards(in: $0).isEmpty }) { return onCard }
        let wholeColumn: Bool = { if case .tableau = source { return index == 0 } else { return false } }()
        // The same for the cell: a click does not swap a free column for a full cell.
        if wholeColumn { return nil }
        if let empty = columns.first { return empty }
        if canDrop(run, from: source, on: .stock) { return .stock }
        return nil
    }

    /// A card is safe on its foundation when nothing can still need it in a column: both
    /// cards of the other color and one rank lower are already on their foundations.
    private func isSafe(_ card: Card) -> Bool {
        guard card.rank > 2 else { return true }
        return Suit.allCases.filter { $0.isRed != card.isRed }.allSatisfy { foundations[$0.rawValue].count >= card.rank - 1 }
    }

    public mutating func autoStep() -> Bool {
        var sources: [(PileID, Int)] = (0 ..< 7).compactMap { tableau[$0].isEmpty ? nil : (.tableau($0), tableau[$0].count - 1) }
        if !waste.isEmpty { sources.append((.waste, waste.count - 1)) }
        if stock.isEmpty, cell != nil { sources.append((.stock, 0)) }
        for (pile, index) in sources {
            guard let card = run(from: pile, at: index)?.first, isSafe(card) else { continue }
            let target = PileID.foundation(card.suit.rawValue)
            guard canDrop([card], from: pile, on: target) else { continue }
            take(from: pile, at: index)
            put([card], on: target)
            return true
        }
        return false
    }
}
