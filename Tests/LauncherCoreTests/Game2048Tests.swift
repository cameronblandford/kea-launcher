import XCTest
@testable import LauncherCore

final class Game2048Tests: XCTestCase {
    func testSlideMergesEachTileOnce() {
        XCTAssertEqual(Game2048.slide([2, 2, 2, 2]).line, [4, 4, 0, 0])
        XCTAssertEqual(Game2048.slide([2, 2, 2, 2]).gained, 8)
        XCTAssertEqual(Game2048.slide([4, 0, 4, 8]).line, [8, 8, 0, 0])
        XCTAssertEqual(Game2048.slide([2, 0, 0, 2]).line, [4, 0, 0, 0])
        XCTAssertEqual(Game2048.slide([2, 4, 8, 16]).line, [2, 4, 8, 16])
        XCTAssertEqual(Game2048.slide([0, 0, 0, 2]).line, [2, 0, 0, 0])
    }

    func testDirections() {
        let start = [[2, 0, 0, 2],
                     [0, 4, 0, 4],
                     [0, 0, 0, 0],
                     [2, 0, 0, 0]]
        var g = Game2048(cells: start)
        XCTAssertTrue(g.shift(.right))
        XCTAssertEqual(g.cells, [[0, 0, 0, 4], [0, 0, 0, 8], [0, 0, 0, 0], [0, 0, 0, 2]])
        XCTAssertEqual(g.score, 12)

        g = Game2048(cells: start)
        g.shift(.down)
        XCTAssertEqual(g.cells, [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 2], [4, 4, 0, 4]])

        g = Game2048(cells: start)
        g.shift(.up)
        XCTAssertEqual(g.cells, [[4, 4, 0, 2], [0, 0, 0, 4], [0, 0, 0, 0], [0, 0, 0, 0]])
    }

    func testNoChangeMeansNoMove() {
        var g = Game2048(cells: [[2, 4], [8, 16]])
        XCTAssertFalse(g.move(.left))
        XCTAssertEqual(g.cells, [[2, 4], [8, 16]])
    }

    func testSpawnAndNewGame() {
        var g = Game2048(cells: [[0, 2], [2, 2]])
        g.spawn(random: { _ in 0 })   // first empty cell, and random(10) == 0 gives a 4
        XCTAssertEqual(g.cells, [[4, 2], [2, 2]])
        let fresh = Game2048.new(random: { _ in 1 })
        XCTAssertEqual(fresh.cells.joined().filter { $0 != 0 }.count, 2)
    }

    func testOverAndWon() {
        XCTAssertTrue(Game2048(cells: [[2, 4], [4, 2]]).isOver)
        XCTAssertFalse(Game2048(cells: [[2, 2], [4, 8]]).isOver)
        XCTAssertFalse(Game2048(cells: [[2, 4], [2, 8]]).isOver)
        XCTAssertTrue(Game2048(cells: [[2048, 0], [0, 0]]).won)
    }

    func testMovesAreTrackedForAnimation() {
        var g = Game2048(cells: [[2, 0, 2, 4],
                                 [0, 0, 0, 0],
                                 [0, 0, 0, 0],
                                 [0, 0, 0, 0]])
        g.shift(.right)
        XCTAssertEqual(g.cells[0], [0, 0, 4, 4])
        let moves = Set(g.lastMoves.map { "\($0.from.col)->\($0.to.col):\($0.value)" })
        XCTAssertEqual(moves, ["3->3:4", "2->2:2", "0->2:2"])
        XCTAssertEqual(g.lastMerged, [Game2048.Cell(0, 2)])
        XCTAssertNil(g.lastSpawn)
        g.spawn(random: { _ in 1 })
        XCTAssertNotNil(g.lastSpawn)
    }

    func testDownMovesTrackRows() {
        var g = Game2048(cells: [[2, 0], [0, 0]])
        g.shift(.down)
        XCTAssertEqual(g.lastMoves, [Game2048.TileMove(from: .init(0, 0), to: .init(1, 0), value: 2)])
    }
}

final class Game2048HistoryTests: XCTestCase {
    func testUndoIsLastInFirstOutAndBounded() {
        var h = Game2048History(limit: 2)
        XCTAssertFalse(h.canUndo)
        for v in [2, 4, 8] { h.push(Game2048(cells: [[v]])) }
        XCTAssertEqual(h.pop()?.cells, [[8]])
        XCTAssertEqual(h.pop()?.cells, [[4]])
        XCTAssertNil(h.pop())   // the oldest fell off
    }

    func testMotionCurvesStartAndEndInPlace() {
        for f in [Motion.easeOutQuart, { Motion.easeOutBack($0) }] {
            XCTAssertEqual(f(0), 0, accuracy: 1e-9)
            XCTAssertEqual(f(1), 1, accuracy: 1e-9)
            XCTAssertEqual(f(2), 1, accuracy: 1e-9)
        }
        XCTAssertEqual(Motion.pop(0), 1, accuracy: 1e-9)
        XCTAssertEqual(Motion.pop(1), 1, accuracy: 1e-9)
        let peak = stride(from: 0.0, to: 1, by: 0.001).map { Motion.pop($0) }.max()!
        XCTAssertEqual(peak, 1.18, accuracy: 0.002)
        XCTAssertGreaterThan(Motion.easeOutBack(0.6), 1)   // it overshoots
        XCTAssertEqual(Motion.nudge(0), 1, accuracy: 1e-9)
        XCTAssertEqual(Motion.nudge(1), 0, accuracy: 1e-9)
    }
}
