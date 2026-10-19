import Foundation

/// The rules of 2048 on a square board. 0 is an empty cell.
public struct Game2048: Equatable {
    public enum Direction: CaseIterable { case left, right, up, down }

    public private(set) var cells: [[Int]]
    public private(set) var score = 0
    public let size: Int

    /// Where one tile went in the last move, for animation. `value` is its value before merging.
    public struct TileMove: Equatable {
        public var from: Cell
        public var to: Cell
        public var value: Int
    }

    public struct Cell: Hashable {
        public var row: Int
        public var col: Int
        public init(_ row: Int, _ col: Int) { self.row = row; self.col = col }
    }

    /// Every tile of the last move (moved or not), the cells where two tiles merged,
    /// and the cell of the new tile.
    public private(set) var lastMoves: [TileMove] = []
    public private(set) var lastMerged: Set<Cell> = []
    public private(set) var lastSpawn: Cell?

    public static func == (a: Game2048, b: Game2048) -> Bool { a.cells == b.cells && a.score == b.score }

    public init(size: Int = 4) {
        self.size = size
        cells = Array(repeating: Array(repeating: 0, count: size), count: size)
    }

    /// A board with fixed cells, for tests.
    public init(cells: [[Int]], score: Int = 0) {
        self.cells = cells
        self.size = cells.count
        self.score = score
    }

    public var won: Bool { cells.joined().contains { $0 >= 2048 } }
    public var best: Int { cells.joined().max() ?? 0 }

    /// No empty cell and no two equal neighbours.
    public var isOver: Bool {
        for r in 0..<size {
            for c in 0..<size {
                let v = cells[r][c]
                if v == 0 { return false }
                if c + 1 < size, cells[r][c + 1] == v { return false }
                if r + 1 < size, cells[r + 1][c] == v { return false }
            }
        }
        return true
    }

    /// Starts a new game with two tiles.
    public static func new(size: Int = 4, random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Game2048 {
        var g = Game2048(size: size)
        g.spawn(random: random)
        g.spawn(random: random)
        return g
    }

    /// Slides and merges one line toward its start. Each tile merges at most once per move.
    /// `moves` maps each tile's index to its new index; `merged` lists indices that merged.
    static func slide(_ line: [Int]) -> (line: [Int], gained: Int, moves: [(from: Int, to: Int)], merged: [Int]) {
        let tiles = line.enumerated().filter { $0.element != 0 }
        var out: [Int] = []
        var gained = 0
        var moves: [(from: Int, to: Int)] = []
        var merged: [Int] = []
        var i = 0
        while i < tiles.count {
            if i + 1 < tiles.count, tiles[i].element == tiles[i + 1].element {
                moves.append((tiles[i].offset, out.count))
                moves.append((tiles[i + 1].offset, out.count))
                merged.append(out.count)
                out.append(tiles[i].element * 2)
                gained += tiles[i].element * 2
                i += 2
            } else {
                moves.append((tiles[i].offset, out.count))
                out.append(tiles[i].element)
                i += 1
            }
        }
        return (out + Array(repeating: 0, count: line.count - out.count), gained, moves, merged)
    }

    /// Moves without adding a tile. Returns false when nothing changed.
    @discardableResult
    public mutating func shift(_ d: Direction) -> Bool {
        let before = cells
        lastMoves = []
        lastMerged = []
        lastSpawn = nil
        for i in 0..<size {
            // Read each row or column so that index 0 is the side tiles move toward.
            var line: [Int]
            switch d {
            case .left: line = cells[i]
            case .right: line = cells[i].reversed()
            case .up: line = (0..<size).map { cells[$0][i] }
            case .down: line = (0..<size).reversed().map { cells[$0][i] }
            }
            let original = line
            let (moved, gained, tileMoves, merged) = Self.slide(line)
            score += gained
            line = moved
            // Index k along this line, as a board cell.
            func cell(_ k: Int) -> Cell {
                switch d {
                case .left: return Cell(i, k)
                case .right: return Cell(i, size - 1 - k)
                case .up: return Cell(k, i)
                case .down: return Cell(size - 1 - k, i)
                }
            }
            lastMoves += tileMoves.map { TileMove(from: cell($0.from), to: cell($0.to), value: original[$0.from]) }
            lastMerged.formUnion(merged.map(cell))
            switch d {
            case .left: cells[i] = line
            case .right: cells[i] = line.reversed()
            case .up: for r in 0..<size { cells[r][i] = line[r] }
            case .down: for r in 0..<size { cells[size - 1 - r][i] = line[r] }
            }
        }
        return cells != before
    }

    /// A move as the player makes it: shift, then add a tile if anything moved.
    @discardableResult
    public mutating func move(_ d: Direction, random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Bool {
        guard shift(d) else { return false }
        spawn(random: random)
        return true
    }

    /// A 2 (90%) or a 4 (10%) in a random empty cell.
    public mutating func spawn(random: (Int) -> Int = { Int.random(in: 0..<$0) }) {
        let empty = (0..<size).flatMap { r in (0..<size).compactMap { c in cells[r][c] == 0 ? (r, c) : nil } }
        guard !empty.isEmpty else { return }
        let (r, c) = empty[random(empty.count)]
        cells[r][c] = random(10) == 0 ? 4 : 2
        lastSpawn = Cell(r, c)
    }
}

/// Past boards for undo, newest last. Bounded so a long game does not grow without limit.
public struct Game2048History: Equatable {
    public private(set) var boards: [Game2048] = []
    public let limit: Int

    public init(limit: Int = 50) { self.limit = limit }

    public var canUndo: Bool { !boards.isEmpty }

    public mutating func push(_ g: Game2048) {
        boards.append(g)
        if boards.count > limit { boards.removeFirst(boards.count - limit) }
    }

    public mutating func pop() -> Game2048? { boards.popLast() }
    public mutating func clear() { boards = [] }
}

/// Timing curves for the 2048 animations. Each takes progress 0...1 (clamped) and
/// returns 0 at the start and 1 at the end, except `pop`, which returns a scale.
public enum Motion {
    static func clamp(_ t: Double) -> Double { min(1, max(0, t)) }

    /// Fast start, soft landing: tiles sliding into place.
    public static func easeOutQuart(_ t: Double) -> Double { 1 - pow(1 - clamp(t), 4) }

    /// Overshoots a little and settles: tiles that appear.
    public static func easeOutBack(_ t: Double, overshoot s: Double = 1.7) -> Double {
        let x = clamp(t) - 1
        return 1 + (s + 1) * x * x * x + s * x * x
    }

    /// Fast out of the blocks and still moving on arrival, so `settle` can carry the
    /// tile a little past its cell and spring it back: tiles sliding.
    public static func slide(_ t: Double) -> Double {
        let x = clamp(t)
        return 1.6 * x - 0.6 * x * x
    }

    /// After a slide arrives: how far past its cell the tile is, as a fraction of `amount`
    /// (positive is further along the slide). Starts and ends at 0, with one small rebound.
    public static func settle(_ t: Double, amount: Double) -> Double { pop(t, amount: amount) - 1 }

    /// A damped spring around 1: swells to about `1 + amount`, dips below 1 once, and rests at 1.
    public static func pop(_ t: Double, amount: Double = 0.18) -> Double {
        let x = clamp(t)
        guard x < 1 else { return 1 }
        // The first peak of exp(-4.5x)·sin(2πx) is 0.412 (at x≈0.15); divide to make it `amount`.
        return 1 + amount / 0.412 * exp(-4.5 * x) * sin(2 * .pi * x)
    }

    /// A shake that starts at full offset and dies away: the board's "can't move that way".
    public static func nudge(_ t: Double) -> Double {
        let x = clamp(t)
        guard x < 1 else { return 0 }
        return exp(-5 * x) * cos(3 * .pi * x) * (1 - x)
    }
}
