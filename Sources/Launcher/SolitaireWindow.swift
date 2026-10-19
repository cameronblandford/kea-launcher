import AppKit
import LauncherCore
import QuartzCore

/// `sol` opens Sawayama Solitaire: Klondike with every card face up, one pass through
/// the stock three cards at a time, and a free cell where the stock was. Drag a card or a
/// run, or click it to send it to the best place. Space deals, Z or Cmd+Z undoes, N deals
/// a new game, Escape closes. Cards that can never be needed again go to the foundations
/// by themselves. The game and the win count are saved, so `sol` resumes.
final class SolitaireWindow: NSObject, NSWindowDelegate {
    /// `solitaire` is not a keyword: it must still find a solitaire app. It finds this row in normal search.
    static let keywords: Set<String> = ["sol", "sawayama"]
    private static var shared: SolitaireWindow?

    private let window: NSWindow
    private let table = SolitaireView(save: SolitaireView.load())

    static func show() {
        let w = shared ?? SolitaireWindow()
        shared = w
        NSApp.activate(ignoringOtherApps: true)
        w.window.makeKeyAndOrderFront(nil)
        w.window.makeFirstResponder(w.table)
    }

    static func results() -> [Result] {
        var subtitle = "Klondike with all cards face up, one pass through the stock, and a free cell · drag or click a card"
        let stats = SolitaireView.loadStats()
        if let save = SolitaireView.load(), save.started, !save.game.isWon {
            let home = save.game.foundations.reduce(0) { $0 + $1.count }
            subtitle = "Resume: \(save.game.moves) moves, \(home) of 52 cards home · N deals a new game"
        } else if stats.played > 0 {
            subtitle = "Won \(stats.won) of \(stats.played) · drag or click a card, Space deals, Z undoes"
        }
        return [Result(id: "game:sawayama", title: "Play Sawayama Solitaire", subtitle: subtitle,
                       icon: NSImage(systemSymbolName: "suit.spade.fill", accessibilityDescription: nil),
                       action: .custom { show() }, keyword: "solitaire cards")]
    }

    static var command: KeaCommand {
        KeaCommand(id: "solitaire", name: "Solitaire", keywords: keywords,
                   help: [.init(keyword: "sol", summary: "Play Sawayama Solitaire in a small window; the game is saved", example: "sol")],
                   search: { term, _ in "solitaire".hasPrefix(term.lowercased()) && term.count >= 4 ? results() : [] },
                   results: { _ in results() })
    }

    /// Renders sample tables to PNGs with no window (`Kea --sol-snapshot out.png`): out.png
    /// (a game in progress with a run lifted, light), out-dark.png (the stock empty and a
    /// card in the cell) and out-won.png. It does not read or write the saved game.
    static func snapshot(to url: URL) {
        let base = url.deletingPathExtension().path
        func write(_ v: SolitaireView, _ path: String, dark: Bool = false) {
            v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        var game = Sawayama(seed: 42)
        _ = game.tapStock()
        _ = game.tapStock()
        while game.autoStep() {}
        let mid = SolitaireView(sample: game)
        mid.sampleLift(column: 6)
        write(mid, url.path)

        var late = Sawayama(seed: 42)
        while late.tapStock() {}
        _ = late.move(from: .waste, at: late.waste.count - 1, to: .stock)
        write(SolitaireView(sample: late), "\(base)-dark.png", dark: true)

        var won = Sawayama(seed: 42)
        won.tableau = Array(repeating: [], count: 7)
        won.stock = []
        won.foundations = Suit.allCases.map { suit in (1 ... 13).map { Card(suit, $0) } }
        won.moves = 96
        write(SolitaireView(sample: won), "\(base)-won.png")
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: SolitaireView.size),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Sawayama Solitaire"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = SolitaireView.Colors.felt
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = table
        window.center()
        window.setFrameAutosaveName("Solitaire")
    }

    func windowWillClose(_ notification: Notification) { table.save() }
}

struct SolitaireSave: Codable {
    var game: Sawayama
    /// The tables before each of the person's moves, the oldest first.
    var history: [Sawayama] = []
    /// The person made a move in this game.
    var started = false
}

struct SolitaireStats: Codable {
    var played = 0
    var won = 0
}

/// The card table. It asks the game only the questions of `SolitaireGame`; what is
/// specific to Sawayama here is where its piles are.
final class SolitaireView: NSView {
    static let card = NSSize(width: 88, height: 124)
    private static let gap: CGFloat = 14
    private static let margin: CGFloat = 24
    private static let top: CGFloat = 36
    /// Seven columns, and an eighth at the right for the four foundations.
    static let size = NSSize(width: 2 * margin + 8 * card.width + 7 * gap, height: 740)
    private static let key = "solitaire.sawayama"
    private static let statsKey = "solitaire.sawayama.stats"
    private static let historyLimit = 300

    enum Colors {
        private static func dynamic(_ light: Int, _ dark: Int) -> NSColor {
            NSColor(name: nil) { a in
                let hex = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                               blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
        }
        static let felt = dynamic(0x2F7D5D, 0x1D4A39)
        static let face = dynamic(0xFCFBF7, 0xE9E6DF)
        static let back = dynamic(0x3D5FAE, 0x34508F)
        static let red = dynamic(0xC8342B, 0xB52E26)
        static let black = dynamic(0x1E1E22, 0x1E1E22)
    }

    private var game: Sawayama
    private var history: [Sawayama]
    private var started: Bool
    private var stats: SolitaireStats
    private let sample: Bool

    /// Where each card was when the last change began; cards glide from there.
    private var glideFrom: [UInt8: NSPoint] = [:]
    private var glideStart: CFTimeInterval = 0
    private static let glide: CFTimeInterval = 0.16
    private var frameTimer: Timer?
    private var autoTimer: Timer?

    private struct Drag {
        var pile: PileID
        var index: Int
        var run: [Card]
        /// From the pointer to the corner of the first card.
        var grab: NSSize
        var point: NSPoint
        var start: NSPoint
        var moved = false
    }
    private var drag: Drag?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Saved game

    static func load() -> SolitaireSave? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(SolitaireSave.self, from: $0) }
    }

    static func loadStats() -> SolitaireStats {
        UserDefaults.standard.data(forKey: statsKey).flatMap { try? JSONDecoder().decode(SolitaireStats.self, from: $0) } ?? SolitaireStats()
    }

    func save() {
        guard !sample else { return }
        if let data = try? JSONEncoder().encode(SolitaireSave(game: game, history: history, started: started)) { UserDefaults.standard.set(data, forKey: Self.key) }
        if let data = try? JSONEncoder().encode(stats) { UserDefaults.standard.set(data, forKey: Self.statsKey) }
    }

    init(save: SolitaireSave?) {
        game = save?.game ?? Sawayama(seed: UInt64.random(in: 0 ... UInt64.max))
        history = save?.history ?? []
        started = save?.started ?? false
        stats = Self.loadStats()
        sample = false
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        settle()
    }

    /// A table for a snapshot: nothing is loaded or saved.
    init(sample game: Sawayama) {
        self.game = game
        history = []
        started = game.moves > 0
        stats = SolitaireStats(played: 8, won: 3)
        sample = true
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// For a snapshot: the run on a column shown as it is while dragged.
    func sampleLift(column: Int) {
        let cards = game.cards(in: .tableau(column))
        guard let index = cards.indices.first(where: { game.run(from: .tableau(column), at: $0) != nil }), let run = game.run(from: .tableau(column), at: index) else { return }
        let origin = position(.tableau(column), index, of: cards.count)
        let point = NSPoint(x: origin.x - 70, y: origin.y + 60)
        drag = Drag(pile: .tableau(column), index: index, run: run, grab: NSSize(width: 30, height: 20),
                    point: NSPoint(x: point.x + 30, y: point.y + 20), start: origin, moved: true)
    }

    // MARK: - Where things are

    private func slot(_ pile: PileID) -> NSRect {
        func column(_ i: Int, _ y: CGFloat) -> NSRect {
            NSRect(x: Self.margin + CGFloat(i) * (Self.card.width + Self.gap), y: y, width: Self.card.width, height: Self.card.height)
        }
        switch pile {
        case .stock: return column(0, Self.top)
        case .waste: return column(1, Self.top)
        // Down the right side, so the whole top row is free for the dealt cards.
        case .foundation(let i): return column(7, Self.top + CGFloat(i) * (Self.card.height + Self.gap))
        case .tableau(let i): return column(i, Self.top + Self.card.height + 24)
        case .cell(let i): return column(i, Self.top)
        }
    }

    /// How far each card of a column is below the one under it. A long column closes up
    /// so that it stays on the table.
    private func fan(_ count: Int) -> CGFloat {
        let room = bounds.height - 40 - slot(.tableau(0)).minY - Self.card.height
        return count > 1 ? min(30, room / CGFloat(count - 1)) : 30
    }

    private func position(_ pile: PileID, _ index: Int, of count: Int) -> NSPoint {
        let origin = slot(pile).origin
        switch pile {
        case .tableau: return NSPoint(x: origin.x, y: origin.y + CGFloat(index) * fan(count))
        case .waste:
            // Every dealt card shows, spread over the top row above columns 2 to 7; only
            // the last one can be taken. With many cards they close up to fit.
            let room = slot(.tableau(6)).maxX - origin.x - Self.card.width
            let step = count > 1 ? min(30, room / CGFloat(count - 1)) : 30
            return NSPoint(x: origin.x + CGFloat(index) * step, y: origin.y)
        default: return origin
        }
    }

    private var piles: [PileID] { (0 ..< 4).map(PileID.foundation) + [.stock, .waste] + (0 ..< 7).map(PileID.tableau) }

    private struct Placed {
        var card: Card
        var pile: PileID
        var index: Int
        var point: NSPoint
        var faceUp: Bool
    }

    /// Every card on the table with its place, in drawing order.
    private func placements() -> [Placed] {
        var out: [Placed] = []
        for pile in piles {
            let cards = game.cards(in: pile)
            let faceDown = pile == .stock && !game.stockIsCell
            for (i, card) in cards.enumerated() {
                out.append(Placed(card: card, pile: pile, index: i, point: position(pile, i, of: cards.count), faceUp: !faceDown))
            }
        }
        return out
    }

    private var progress: CGFloat {
        guard !glideFrom.isEmpty else { return 1 }
        let t = min(1, (CACurrentMediaTime() - glideStart) / Self.glide)
        return CGFloat(1 - pow(1 - t, 3))
    }

    private func shownPoint(_ p: Placed, _ t: CGFloat) -> NSPoint {
        guard let from = glideFrom[p.card.id] else { return p.point }
        return NSPoint(x: from.x + (p.point.x - from.x) * t, y: from.y + (p.point.y - from.y) * t)
    }

    /// Starts a glide from where every card is now to where the game now has it. Call it
    /// with the positions from before the change.
    private func glide(from before: [UInt8: NSPoint]) {
        glideFrom = before
        glideStart = CACurrentMediaTime()
        needsDisplay = true
        guard frameTimer == nil, !sample else { return }
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            if CACurrentMediaTime() - self.glideStart >= Self.glide {
                self.glideFrom = [:]
                self.frameTimer?.invalidate()
                self.frameTimer = nil
            }
            self.needsDisplay = true
        }
    }

    private func currentPoints() -> [UInt8: NSPoint] {
        let t = progress
        var out: [UInt8: NSPoint] = [:]
        for p in placements() { out[p.card.id] = shownPoint(p, t) }
        if let drag {
            for (k, card) in drag.run.enumerated() { out[card.id] = dragPoint(drag, k) }
        }
        return out
    }

    private func dragPoint(_ drag: Drag, _ k: Int) -> NSPoint {
        NSPoint(x: drag.point.x - drag.grab.width, y: drag.point.y - drag.grab.height + CGFloat(k) * 30)
    }

    // MARK: - Drawing

    /// `narrow` puts the suit below the rank, for a card of which only a strip at the left shows.
    private func draw(_ card: Card, at point: NSPoint, faceUp: Bool, lifted: Bool = false, narrow: Bool = false) {
        let rect = NSRect(origin: point, size: Self.card)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(lifted ? 0.4 : 0.18)
        shadow.shadowBlurRadius = lifted ? 12 : 2
        shadow.shadowOffset = NSSize(width: 0, height: lifted ? -5 : -1)
        shadow.set()
        (faceUp ? Colors.face : Colors.back).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.28).setStroke()
        path.lineWidth = 1
        path.stroke()
        guard faceUp else {
            NSColor.white.withAlphaComponent(0.5).setStroke()
            let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 7, dy: 7), xRadius: 4, yRadius: 4)
            inner.lineWidth = 1.5
            inner.stroke()
            return
        }
        let color = card.isRed ? Colors.red : Colors.black
        let corner = NSFont.systemFont(ofSize: 19, weight: .bold)
        if narrow {
            // Only a strip at the left shows: the suit goes below the rank, and "10",
            // which is wider than the strip, is set smaller and tighter.
            let ten = card.rank == 10
            (card.rankName as NSString).draw(at: NSPoint(x: rect.minX + (ten ? 3 : 6), y: rect.minY + (ten ? 5 : 3)),
                                             withAttributes: [.font: ten ? NSFont.systemFont(ofSize: 16, weight: .bold) : corner, .foregroundColor: color, .kern: ten ? -1.5 : 0])
            (card.suit.symbol as NSString).draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + 24),
                                                withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: color])
        } else {
            // Rank and suit on one line, so both show on a card that is mostly covered from below.
            (card.rankName as NSString).draw(at: NSPoint(x: rect.minX + 7, y: rect.minY + 3), withAttributes: [.font: corner, .foregroundColor: color])
            let rankWidth = (card.rankName as NSString).size(withAttributes: [.font: corner]).width
            (card.suit.symbol as NSString).draw(at: NSPoint(x: rect.minX + 9 + rankWidth, y: rect.minY + 3),
                                                withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: color])
        }
        let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 46), .foregroundColor: color]
        let size = (card.suit.symbol as NSString).size(withAttributes: big)
        (card.suit.symbol as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 12), withAttributes: big)
    }

    private func drawSlot(_ pile: PileID, label: String?) {
        let rect = slot(pile)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        path.lineWidth = 1
        path.stroke()
        guard let label else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: label.count == 1 ? 40 : 13, weight: .medium),
                                                         .foregroundColor: NSColor.white.withAlphaComponent(0.3)]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    override func draw(_ dirtyRect: NSRect) {
        Colors.felt.setFill()
        bounds.fill()
        for i in 0 ..< 4 { drawSlot(.foundation(i), label: Suit(rawValue: i)?.symbol) }
        drawSlot(.stock, label: game.stockIsCell ? "free cell" : nil)
        drawSlot(.waste, label: nil)
        for i in 0 ..< 7 { drawSlot(.tableau(i), label: nil) }

        let lifted = Set(drag.map { $0.moved ? $0.run.map(\.id) : [] } ?? [])
        let t = progress
        var moving: [(Placed, NSPoint)] = []
        for p in placements() where !lifted.contains(p.card.id) {
            // Of a face-down stock only the top card shows.
            if !p.faceUp, p.index < game.stock.count - 1 { continue }
            let point = shownPoint(p, t)
            // In the waste every card but the top one shows only a strip.
            let narrow = p.pile == .waste && p.index < game.waste.count - 1
            if point != p.point { moving.append((p, point)) } else { draw(p.card, at: point, faceUp: p.faceUp, narrow: narrow) }
        }
        if !game.stockIsCell {
            let rect = slot(.stock)
            let count = "\(game.stock.count)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
            let size = count.size(withAttributes: attributes)
            count.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
        if let target = dropTarget() {
            // Where the lifted cards will land.
            let cards = game.cards(in: target)
            let origin = cards.isEmpty ? slot(target).origin : position(target, cards.count - 1, of: cards.count)
            let ring = NSBezierPath(roundedRect: NSRect(origin: origin, size: Self.card).insetBy(dx: -2, dy: -2), xRadius: 10, yRadius: 10)
            ring.lineWidth = 3
            NSColor.white.withAlphaComponent(0.9).setStroke()
            ring.stroke()
        }
        for (p, point) in moving { draw(p.card, at: point, faceUp: true, narrow: p.pile == .waste && p.index < game.waste.count - 1) }
        if let drag, drag.moved {
            for (k, card) in drag.run.enumerated() { draw(card, at: dragPoint(drag, k), faceUp: true, lifted: true) }
        }
        drawStatus()
        if game.isWon { drawWin() }
    }

    private func drawStatus() {
        let y = bounds.height - 28
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.75)]
        let home = game.foundations.reduce(0) { $0 + $1.count }
        ("\(game.moves) moves · \(home) of 52 home · won \(stats.won) of \(stats.played)" as NSString).draw(at: NSPoint(x: Self.margin, y: y), withAttributes: small)
        let keys = "Click sends a card to the best place · Space deals · Z undo · N new game" as NSString
        keys.draw(at: NSPoint(x: bounds.width - Self.margin - keys.size(withAttributes: small).width, y: y), withAttributes: small)
    }

    private func drawWin() {
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.white]
        let detail: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        let first = "Solved in \(game.moves) moves" as NSString, second = "N deals a new game" as NSString
        let y = slot(.tableau(0)).minY + 120
        first.draw(at: NSPoint(x: bounds.midX - first.size(withAttributes: title).width / 2, y: y), withAttributes: title)
        second.draw(at: NSPoint(x: bounds.midX - second.size(withAttributes: detail).width / 2, y: y + 50), withAttributes: detail)
    }

    // MARK: - Playing

    /// The card under a point, the top one first.
    private func hit(_ point: NSPoint) -> (pile: PileID, index: Int)? {
        for p in placements().reversed() where NSRect(origin: p.point, size: Self.card).contains(point) { return (p.pile, p.index) }
        return nil
    }

    /// The pile the lifted cards are over, when they may go there.
    private func dropTarget() -> PileID? {
        guard let drag, drag.moved else { return nil }
        let held = NSRect(origin: dragPoint(drag, 0), size: Self.card)
        var best: (PileID, CGFloat)?
        for pile in piles where game.canDrop(drag.run, from: drag.pile, on: pile) {
            let cards = game.cards(in: pile)
            var area = slot(pile)
            if !cards.isEmpty { area = area.union(NSRect(origin: position(pile, cards.count - 1, of: cards.count), size: Self.card)) }
            let overlap = area.intersection(held)
            let size = overlap.isNull ? 0 : overlap.width * overlap.height
            if size > 0, size > (best?.1 ?? 0) { best = (pile, size) }
        }
        return best?.0
    }

    /// Applies a change that the person made, and remembers the table from before it.
    private func play(_ change: (inout Sawayama) -> Bool) {
        let before = game, points = currentPoints()
        guard change(&game) else { return }
        history.append(before)
        if history.count > Self.historyLimit { history.removeFirst() }
        if !started {
            started = true
            stats.played += 1
        }
        glide(from: points)
        settle()
        save()
    }

    /// Sends the safe cards home one at a time, so the eye can follow them.
    private func settle() {
        autoTimer?.invalidate()
        autoTimer = nil
        if sample { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let points = self.currentPoints()
            if self.game.autoStep() {
                self.glide(from: points)
                return
            }
            timer.invalidate()
            self.autoTimer = nil
            if self.game.isWon, self.started {
                self.stats.won += 1
                self.started = false
                self.history = []
            }
            self.save()
            self.needsDisplay = true
        }
    }

    private func undo() {
        guard let previous = history.popLast() else { return NSSound.beep() }
        autoTimer?.invalidate()
        autoTimer = nil
        let points = currentPoints()
        game = previous
        glide(from: points)
        save()
    }

    private func newGame() {
        autoTimer?.invalidate()
        drag = nil
        game = Sawayama(seed: UInt64.random(in: 0 ... UInt64.max))
        history = []
        started = false
        glide(from: [:])
        settle()
        save()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard !game.isWon, let (pile, index) = hit(point) else { return }
        let cards = game.cards(in: pile)
        let origin = position(pile, index, of: cards.count)
        // A stock with cards cannot be lifted, but a click on it deals.
        let run = game.run(from: pile, at: index) ?? []
        drag = Drag(pile: pile, index: index, run: run, grab: NSSize(width: point.x - origin.x, height: point.y - origin.y), point: point, start: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag else { return }
        d.point = convert(event.locationInWindow, from: nil)
        if !d.run.isEmpty, hypot(d.point.x - d.start.x, d.point.y - d.start.y) > 4 { d.moved = true }
        drag = d
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        if d.moved {
            let target = dropTarget()
            let points = currentPoints()
            drag = nil
            if let target {
                play { $0.move(from: d.pile, at: d.index, to: target) }
                // The glide starts where the hand let go, not where the cards were.
                glideFrom = glideFrom.merging(points.filter { id, _ in d.run.contains { $0.id == id } }) { _, held in held }
            } else {
                glide(from: points)
            }
            return
        }
        drag = nil
        if d.pile == .stock, !game.stockIsCell {
            play { $0.tapStock() }
        } else if let target = game.autoTarget(from: d.pile, at: d.index) {
            play { $0.move(from: d.pile, at: d.index, to: target) }
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: window?.performClose(nil)                       // Escape
        case 13 where command: window?.performClose(nil)         // Cmd+W
        case 6, 32: undo()                                       // Z, U (with or without Cmd)
        case 45: newGame()                                       // N
        case 49, 2: play { $0.tapStock() }                       // Space, D
        default: super.keyDown(with: event)
        }
    }
}
