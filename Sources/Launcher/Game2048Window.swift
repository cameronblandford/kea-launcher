import AppKit
import LauncherCore
import QuartzCore

/// `2048` opens a small game window. Arrow keys, WASD, HJKL or a two-finger swipe
/// move, Cmd+Z undoes (many moves), R starts over, Escape closes. The game and the
/// best score are saved, so closing the window and typing `2048` again resumes it.
final class Game2048Window: NSObject, NSWindowDelegate {
    static let keywords: Set<String> = ["2048"]
    private static var shared: Game2048Window?

    private let window: NSWindow
    private let board = BoardView()

    static func show() {
        let w = shared ?? Game2048Window()
        shared = w
        NSApp.activate(ignoringOtherApps: true)
        w.window.makeKeyAndOrderFront(nil)
        w.window.makeFirstResponder(w.board)
    }

    static func results() -> [Result] {
        let saved = BoardView.loadState()
        let subtitle = saved.map { "Resume: score \($0.game.score), best tile \($0.game.best) · arrows, WASD or swipe, Cmd+Z undo, R new game" }
            ?? "Arrows, WASD or swipe to slide, Cmd+Z undo, R new game"
        return [Result(id: "game:2048", title: "Play 2048", subtitle: subtitle,
                       icon: NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil),
                       action: .custom { show() })]
    }

    /// Renders sample boards to PNGs with no window (`Kea --2048-snapshot out.png`):
    /// out.png (light), out-dark.png, out-<theme>[-dark].png for every theme, out-over.png,
    /// out-won.png, and out-1.png … out-6.png,
    /// frames of one animated move to the right.
    static func snapshot(to url: URL) {
        let base = url.deletingPathExtension().path
        func write(_ v: BoardView, _ path: String, dark: Bool = false) {
            v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        let sample = Game2048(cells: [[2, 4, 8, 16], [32, 64, 128, 256], [512, 1024, 2048, 4096], [8192, 16384, 0, 131072]], score: 20480)
        write(BoardView(sample: sample), url.path)
        write(BoardView(sample: sample), "\(base)-dark.png", dark: true)
        for theme in Theme2048.all {
            for dark in [false, true] {
                let v = BoardView(sample: sample)
                v.themeOverride = theme
                write(v, "\(base)-\(theme.name.lowercased())\(dark ? "-dark" : "").png", dark: dark)
            }
        }
        write(BoardView(sample: Game2048(cells: [[2, 4, 2, 4], [4, 2, 4, 2], [2, 4, 2, 4], [4, 2, 4, 2]], score: 1234), endState: true), "\(base)-over.png")
        write(BoardView(sample: Game2048(cells: [[2048, 4, 0, 0], [8, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 2]], score: 20000), endState: true), "\(base)-won.png", dark: true)

        var g = Game2048(cells: [[2, 0, 2, 4], [0, 8, 0, 0], [64, 64, 0, 0], [16, 0, 0, 16]])
        let before = g
        g.move(.right, random: { _ in 1 })
        for (i, t) in [0.0, 0.04, 0.09, 0.15, 0.2, 0.3].enumerated() {
            let v = BoardView(sample: g)
            v.showMove(from: before, frozenAt: t)
            write(v, "\(base)-\(i + 1).png")
        }
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: BoardView.size),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "2048"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(name: nil) { Palette(dark: $0.isDark).background }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = board
        window.center()
    }

    func windowWillClose(_ notification: Notification) { board.save() }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

private func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A 2048 colour theme: one tile colour per value from 2 up (bigger values reuse the
/// last), plus the window around the board in light and dark mode. Each ramp is an even
/// walk through OKLCH, so lightness, saturation and hue each move one way only.
private struct Theme2048 {
    struct Chrome { var background, board, slot, text, secondary: Int }
    let name: String
    let tiles: [Int]
    var inkAbove: CGFloat = 0.45 // tiles brighter than this get dark numbers, the rest white
    let light, dark: Chrome

    /// The win card, the Keep Going button and a new best use the theme's 2048 colour.
    var accent: Int { tiles[10] }

    static let all: [Theme2048] = [
        // Pastel magenta through lilac to periwinkle blue at 2048, then on through cyan to green at 16384.
        Theme2048(name: "Cute",
                  tiles: [0xFBF0F6, 0xFDD8EE, 0xF8CDEC, 0xF2C3EB, 0xEAB9EC, 0xE1AFED, 0xD0AAF1, 0xBCA6F4, 0xA6A2F5, 0x8D9FF3,
                          0x719DEF, 0x4FABE4, 0x3DB6CF, 0x6BCF9D, 0x55B581, 0x3F9B65],
                  light: Chrome(background: 0xFAF7FC, board: 0xE4DDEE, slot: 0xF0EBF6, text: 0x3A3150, secondary: 0x8A80A0),
                  dark: Chrome(background: 0x17151E, board: 0x28243A, slot: 0x322D45, text: 0xEEEAF6, secondary: 0xA39CB8)),
        // Pale ice to deep navy.
        Theme2048(name: "Tide",
                  tiles: [0xF3F7FC, 0xD8EAFF, 0xC9E0FB, 0xBAD5F7, 0xACCBF2, 0x9DC1EE, 0x8DB5EB, 0x7DA9E9, 0x6E9DE6, 0x6090E3,
                          0x5283E0, 0x4A74CC, 0x4165B9, 0x3857A6, 0x304993, 0x273C81],
                  light: Chrome(background: 0xF5F7FB, board: 0xD9E1EE, slot: 0xE7ECF5, text: 0x2E3A50, secondary: 0x7A869C),
                  dark: Chrome(background: 0x14171F, board: 0x242A37, slot: 0x2D3443, text: 0xE8EDF6, secondary: 0x98A2B5)),
        // Blush to magenta to plum.
        Theme2048(name: "Bloom",
                  tiles: [0xFCF2F6, 0xFFDBEA, 0xFBCDE2, 0xF7BFDB, 0xF2B1D3, 0xEDA4CC, 0xE995C6, 0xE485C0, 0xDF75BA, 0xD965B5,
                          0xD354B0, 0xBC4AA6, 0xA5419B, 0x90388F, 0x7B2F82, 0x672675],
                  light: Chrome(background: 0xFCF6F9, board: 0xEBDBE4, slot: 0xF5EAF0, text: 0x4A3242, secondary: 0x9A8392),
                  dark: Chrome(background: 0x1C1519, board: 0x2F2429, slot: 0x3A2D34, text: 0xF5E9F0, secondary: 0xB09AA6)),
        // Warm, in one direction: cream, butter, apricot, orange, coral, red, crimson, wine.
        Theme2048(name: "Classic",
                  tiles: [0xF6F3EB, 0xFAE6BB, 0xF8D399, 0xF7BF77, 0xF6AC60, 0xF4974C, 0xF2823B, 0xED7339, 0xE8633A, 0xE2533D,
                          0xDB4241, 0xC73645, 0xB32C46, 0x9F2345, 0x8B1943, 0x78113F],
                  inkAbove: 0.55,
                  light: Chrome(background: 0xF8F6F2, board: 0xDFD8CF, slot: 0xEBE5DD, text: 0x3F3934, secondary: 0x8A8178),
                  dark: Chrome(background: 0x1C1B20, board: 0x2B2931, slot: 0x35333C, text: 0xEFEBE6, secondary: 0xA19C97)),
    ]

    private static let key = "game2048.theme"
    static var current: Theme2048 {
        get { all.first { $0.name == UserDefaults.standard.string(forKey: key) } ?? all[0] }
        set { UserDefaults.standard.set(newValue.name, forKey: key) }
    }
    var next: Theme2048 { Self.all[((Self.all.firstIndex { $0.name == name } ?? 0) + 1) % Self.all.count] }
}

private extension NSColor {
    /// Relative luminance, for picking dark or white text on a tile.
    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
}

/// A theme's colours for one appearance.
private struct Palette {
    let dark: Bool
    let theme: Theme2048
    init(dark: Bool, theme: Theme2048 = .current) { self.dark = dark; self.theme = theme }

    private var chrome: Theme2048.Chrome { dark ? theme.dark : theme.light }
    var background: NSColor { rgb(chrome.background) }
    var board: NSColor { rgb(chrome.board) }
    var slot: NSColor { rgb(chrome.slot) }
    var text: NSColor { rgb(chrome.text) }
    var secondary: NSColor { rgb(chrome.secondary) }
    var pill: NSColor { board.blended(withFraction: dark ? 0 : 0.35, of: background) ?? board }
    var pillPressed: NSColor { board.blended(withFraction: 0.12, of: dark ? .white : .black) ?? board }
    var accent: NSColor { rgb(theme.accent) }
    /// The accent as text: deepened on a light background so it reads.
    var accentText: NSColor { dark ? accent : (accent.blended(withFraction: 0.2, of: .black) ?? accent) }

    func tile(_ v: Int) -> NSColor {
        let i = max(0, Int(log2(Double(max(v, 2)))) - 1)
        let c = rgb(theme.tiles[min(i, theme.tiles.count - 1)])
        // On a dark board the palest tiles sink toward the slot colour so they don't glare.
        guard dark, v <= 4 else { return c }
        return c.blended(withFraction: v == 2 ? 0.8 : 0.62, of: slot) ?? c
    }

    /// Dark text on pale tiles (a deep shade of the tile itself), white on the rest.
    func number(_ v: Int) -> NSColor { ink(on: tile(v)) }

    func ink(on c: NSColor) -> NSColor {
        c.luminance > theme.inkAbove ? (c.blended(withFraction: 0.68, of: .black) ?? .black) : .white
    }

    /// How strongly a tile glows: none below 128, building to 2048, steady above.
    func glow(_ v: Int) -> CGFloat {
        guard v >= 128 else { return 0 }
        return min(1, CGFloat(log2(Double(v)) - 6) / 5)
    }
}

private final class BoardView: NSView {
    struct State: Codable {
        var cells: [[Int]]
        var score: Int
        var best: Int
        var game: Game2048 { Game2048(cells: cells, score: score) }
    }

    static let size = NSSize(width: 420, height: 572)
    private static let key = "game2048.state"

    private var game: Game2048
    private var best: Int
    private var bestAtStart: Int
    private var history = Game2048History()
    private var keepGoing = false

    // MARK: Animation state
    //
    // Every effect is a start time plus what it needs to draw; `draw` derives each
    // frame from the clock, so a new key press simply starts new effects and the
    // old ones snap to their end. The display link runs only while something moves.

    private struct MoveAnim {
        var start: CFTimeInterval
        var moves: [Game2048.TileMove]
        var reverse: Bool                  // an undo: tiles slide back from `to` to `from`
        var merged: Set<Game2048.Cell>
        var spawn: Game2048.Cell?
        var ghost: (cell: Game2048.Cell, value: Int)?   // the undone move's new tile, fading out
    }

    private let slideTime = 0.07
    private let popTime = 0.24
    private let settleTime = 0.18
    private let spawnDelay = 0.04
    private let spawnTime = 0.2
    private let scoreTime = 0.3
    private let nudgeTime = 0.34
    private let overlayDelay = 0.45
    private let overlayTime = 0.35
    private let bestFlashTime = 1.2

    private var move: MoveAnim?
    private var themeChange: CFTimeInterval = -10   // a new theme: a ripple across the tiles
    var themeOverride: Theme2048?                   // snapshots render a given theme
    private var spawnAll: CFTimeInterval?   // a new game: every tile grows in, in a diagonal wave
    private var scoreFrom = 0
    private var scoreStart: CFTimeInterval = -10
    private var bestFlash: CFTimeInterval = -10
    private var nudge: (start: CFTimeInterval, dx: CGFloat, dy: CGFloat)?
    private var overlayStart: CFTimeInterval?
    private var frozenTime: CFTimeInterval?
    private var link: CADisplayLink?

    private var now: CFTimeInterval { frozenTime ?? CACurrentMediaTime() }

    // MARK: Layout (flipped: y grows down)

    private let margin: CGFloat = 24
    private let gap: CGFloat = 12
    private var boardRect: NSRect { NSRect(x: margin, y: 150, width: bounds.width - margin * 2, height: bounds.width - margin * 2) }
    private var cellSide: CGFloat { (boardRect.width - gap * CGFloat(game.size + 1)) / CGFloat(game.size) }
    /// Concentric corners: the board's radius is the tile radius plus the gap.
    private var tileRadius: CGFloat { (cellSide * 0.22).rounded() }
    private var boardRadius: CGFloat { tileRadius + gap }
    private func scoreRect(_ i: Int) -> NSRect {
        let w: CGFloat = 86
        return NSRect(x: bounds.width - margin - w * CGFloat(2 - i) - 8 * CGFloat(1 - i), y: 40, width: w, height: 54)
    }

    private enum Button: Hashable { case theme, undo, newGame, keepGoing, tryAgain }
    private var pressed: Button?

    private func buttons() -> [(Button, NSRect, String)] {
        var list: [(Button, NSRect, String)] = []
        let h: CGFloat = 30, y: CGFloat = 108
        let newW: CGFloat = 96, undoW: CGFloat = 70
        list.append((.newGame, NSRect(x: bounds.width - margin - newW, y: y, width: newW, height: h), "New Game"))
        list.append((.undo, NSRect(x: bounds.width - margin - newW - 8 - undoW, y: y, width: undoW, height: h), "Undo"))
        list.append((.theme, NSRect(x: bounds.width - margin - newW - 8 - undoW - 8 - h, y: y, width: h, height: h), "Theme"))
        if let end = endMessage, overlayStart != nil {
            let r = boardRect, w: CGFloat = 132
            list.append((end.button, NSRect(x: r.midX - w / 2, y: r.midY + 34, width: w, height: 38), end.button == .keepGoing ? "Keep Going" : "Try Again"))
        }
        return list
    }

    // MARK: Setup

    static func loadState() -> State? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    init() {
        if let s = Self.loadState(), !s.game.isOver {
            game = s.game
            best = s.best
            keepGoing = s.game.won
        } else {
            game = .new()
            best = Self.loadState()?.best ?? 0
        }
        bestAtStart = best
        scoreFrom = game.score
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    /// A fixed board for snapshots. `endState` shows the win or game-over card at rest.
    init(sample: Game2048, endState: Bool = false) {
        game = sample
        best = max(sample.score, 24816)
        bestAtStart = best
        keepGoing = !endState
        scoreFrom = sample.score
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        frozenTime = 100
        if endState { overlayStart = 0 } else { history.push(sample) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Freezes the animation of the move from `before` to the current board at `t` seconds.
    func showMove(from before: Game2048, frozenAt t: Double) {
        move = MoveAnim(start: 100 - t, moves: game.lastMoves, reverse: false, merged: game.lastMerged, spawn: game.lastSpawn)
        scoreFrom = before.score
        scoreStart = 100 - t
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        l.isPaused = true
        link = l
    }

    func save() {
        let s = State(cells: game.cells, score: game.score, best: best)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: Actions

    private var endMessage: (title: String, subtitle: String, button: Button)? {
        if game.isOver { return ("Game Over", "You scored \(game.score.formatted())", .tryAgain) }
        if game.won && !keepGoing { return ("You made 2048!", "Score \(game.score.formatted()) · keep going for more", .keepGoing) }
        return nil
    }

    private func play(_ d: Game2048.Direction) {
        guard endMessage == nil else { return }
        let before = game
        guard game.move(d) else {
            let v: (CGFloat, CGFloat) = d == .left ? (-1, 0) : d == .right ? (1, 0) : d == .up ? (0, -1) : (0, 1)
            nudge = (now, v.0, v.1)
            startAnimating()
            return
        }
        history.push(before)
        let t = now
        spawnAll = nil
        move = MoveAnim(start: t, moves: game.lastMoves, reverse: false, merged: game.lastMerged, spawn: game.lastSpawn)
        if game.score > before.score {
            scoreFrom = displayedScore
            scoreStart = t
        }
        if game.score > best {
            if best == bestAtStart && best > 0 { bestFlash = t }   // first time past the old record
            best = game.score
        }
        if endMessage != nil { overlayStart = t + overlayDelay }
        save()
        startAnimating()
    }

    private func undo() {
        guard let previous = history.pop() else {
            nudge = (now, 1, 0)   // nothing to undo: a small "no" shake
            startAnimating()
            return
        }
        let undone = game
        let t = now
        scoreFrom = displayedScore
        scoreStart = t
        game = previous
        keepGoing = keepGoing && game.won
        overlayStart = nil
        spawnAll = nil
        let ghost = undone.lastSpawn.map { (cell: $0, value: undone.cells[$0.row][$0.col]) }
        move = MoveAnim(start: t, moves: undone.lastMoves, reverse: true, merged: [], spawn: nil, ghost: ghost)
        save()
        startAnimating()
    }

    private func newGame() {
        let t = now
        history.clear()
        keepGoing = false
        overlayStart = nil
        scoreFrom = displayedScore
        scoreStart = t
        bestAtStart = best
        game = .new()
        move = nil
        spawnAll = t
        save()
        startAnimating()
    }

    private func perform(_ b: Button) {
        switch b {
        case .undo: undo()
        case .newGame, .tryAgain: newGame()
        case .theme:
            Theme2048.current = Theme2048.current.next
            themeChange = now
            startAnimating()
        case .keepGoing:
            keepGoing = true
            overlayStart = nil
            startAnimating()
        }
    }

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) {
            switch e.charactersIgnoringModifiers {
            case "z": undo()
            case "w": window?.performClose(nil)
            case "n": newGame()
            default: super.keyDown(with: e)
            }
            return
        }
        // Holding an arrow should not slam the board through a dozen moves.
        if e.isARepeat { return }
        switch e.keyCode {
        case 123: play(.left)
        case 124: play(.right)
        case 125: play(.down)
        case 126: play(.up)
        case 53: window?.performClose(nil)
        case 36, 76, 49:   // Return, Enter and Space press the card's button
            if let end = endMessage, overlayStart != nil { perform(end.button) }
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "a", "h": play(.left)
            case "d", "l": play(.right)
            case "s", "j": play(.down)
            case "w", "k": play(.up)
            case "u": undo()
            case "t": perform(.theme)
            case "r", "n": newGame()
            case "c" where game.won && !keepGoing: perform(.keepGoing)
            default: break
            }
        }
    }

    // Two-finger swipes: one move per gesture, once the fingers travel far enough.
    private var swipe = CGPoint.zero
    private var swipeDone = false

    override func scrollWheel(with e: NSEvent) {
        guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return }
        if e.phase.contains(.began) { swipe = .zero; swipeDone = false }
        // With natural scrolling the deltas follow the fingers; otherwise they are inverted.
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        swipe.x += e.scrollingDeltaX * sign
        swipe.y += e.scrollingDeltaY * sign
        if !swipeDone, max(abs(swipe.x), abs(swipe.y)) > 22 {
            swipeDone = true
            if abs(swipe.x) > abs(swipe.y) { play(swipe.x > 0 ? .right : .left) }
            else { play(swipe.y > 0 ? .down : .up) }
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) { swipe = .zero; swipeDone = false }
    }

    private func button(at p: NSPoint) -> Button? {
        buttons().first { $0.1.contains(p) && enabled($0.0) }?.0
    }

    private func enabled(_ b: Button) -> Bool { b == .undo ? history.canUndo : true }

    override func mouseDown(with e: NSEvent) {
        pressed = button(at: convert(e.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { pressed = nil; needsDisplay = true }
        if let p = pressed, button(at: convert(e.locationInWindow, from: nil)) == p { perform(p) }
    }

    override func resetCursorRects() {
        for (b, r, _) in buttons() where enabled(b) { addCursorRect(r, cursor: .pointingHand) }
    }

    // MARK: Clock

    private func startAnimating() {
        link?.isPaused = false
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    @objc private func tick() {
        needsDisplay = true
        if !isAnimating { link?.isPaused = true }
    }

    private var isAnimating: Bool {
        let t = now
        if let m = move, t - m.start < slideTime + max(popTime, settleTime, spawnDelay + spawnTime) { return true }
        if let s = spawnAll, t - s < spawnTime + 0.2 { return true }
        if t - scoreStart < scoreTime || t - bestFlash < bestFlashTime { return true }
        if let n = nudge, t - n.start < nudgeTime { return true }
        if let o = overlayStart, t - o < overlayTime { return true }
        if t - themeChange < 1.6 { return true }
        return false
    }

    private var displayedScore: Int {
        let p = (now - scoreStart) / scoreTime
        guard p < 1 else { return game.score }
        return scoreFrom + Int((Double(game.score - scoreFrom) * Motion.easeOutQuart(p)).rounded())
    }

    // MARK: Drawing

    private static func font(_ size: CGFloat, _ weight: NSFont.Weight, monoDigits: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        var d = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        if monoDigits {
            // kNumberSpacingType / kMonospacedNumbersSelector: score digits do not jiggle as they count.
            d = d.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: 6,
                                                        NSFontDescriptor.FeatureKey.selectorIdentifier: 0]]])
        }
        return NSFont(descriptor: d, size: size) ?? base
    }

    /// Draws `s` centred on the cap height, so digits sit in the optical middle of `rect`.
    private func text(_ s: String, _ font: NSFont, _ color: NSColor, in rect: NSRect, kern: CGFloat = 0, align: NSTextAlignment = .center) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern])
        let w = a.size().width
        let x = align == .center ? rect.midX - w / 2 : align == .left ? rect.minX : rect.maxX - w
        a.draw(at: NSPoint(x: x, y: rect.midY + font.capHeight / 2 - font.ascender))
    }

    private var tileFonts: [Int: NSFont] = [:]

    /// The tile font: big for short numbers, shrunk until long numbers fit with a margin.
    private func tileFont(_ v: Int) -> NSFont {
        if let f = tileFonts[v] { return f }
        let digits = String(v).count
        var size = (cellSide * (digits <= 2 ? 0.48 : digits == 3 ? 0.42 : 0.36)).rounded()
        var f = Self.font(size, .heavy)
        while size > 8, NSAttributedString(string: String(v), attributes: [.font: f, .kern: -0.5]).size().width > cellSide * 0.8 {
            size -= 1
            f = Self.font(size, .heavy)
        }
        tileFonts[v] = f
        return f
    }

    private func origin(_ r: CGFloat, _ c: CGFloat) -> NSPoint {
        NSPoint(x: boardRect.minX + gap + c * (cellSide + gap), y: boardRect.minY + gap + r * (cellSide + gap))
    }

    /// One tile, scaled about its centre. `flash` brightens it (a merge); `ring` is the
    /// progress of an outline that grows away from it (a big merge).
    private func drawTile(_ v: Int, at p: NSPoint, _ pal: Palette, scale: CGFloat = 1, alpha: CGFloat = 1, flash: CGFloat = 0, ring: CGFloat? = nil) {
        guard scale > 0.01, alpha > 0.01, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = NSRect(x: p.x, y: p.y, width: cellSide, height: cellSide)
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
        ctx.setAlpha(alpha)
        if alpha < 1 { ctx.beginTransparencyLayer(auxiliaryInfo: nil) }

        let path = NSBezierPath(roundedRect: rect, xRadius: tileRadius, yRadius: tileRadius)
        let color = pal.tile(v)

        if let ring {
            let grow = cellSide * 0.22 * CGFloat(Motion.easeOutQuart(Double(ring)))
            let rp = NSBezierPath(roundedRect: rect.insetBy(dx: -grow, dy: -grow), xRadius: tileRadius + grow, yRadius: tileRadius + grow)
            rp.lineWidth = 4 * (1 - ring)
            color.withAlphaComponent(0.55 * (1 - ring)).setStroke()
            rp.stroke()
        }

        // A soft drop shadow for every tile, and a coloured glow for big ones.
        let glow = pal.glow(v)
        let shadow = NSShadow()
        if glow > 0 {
            shadow.shadowColor = color.withAlphaComponent((pal.dark ? 0.55 : 0.45) * glow)
            shadow.shadowBlurRadius = 6 + 14 * glow
            shadow.shadowOffset = .zero
        } else {
            shadow.shadowColor = NSColor.black.withAlphaComponent(pal.dark ? 0.35 : (v <= 4 ? 0.06 : 0.12))
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1.5)   // NSShadow ignores flipping: negative is down
        }
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        color.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // A gentle top-lit gradient and a hairline highlight give the tile some body.
        let top = color.blended(withFraction: v <= 4 ? 0.05 : 0.14, of: .white) ?? color
        let bottom = color.blended(withFraction: v <= 4 ? 0.02 : 0.05, of: .black) ?? color
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 90)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let hl = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: tileRadius - 0.5, yRadius: tileRadius - 0.5)
        hl.lineWidth = 1
        NSColor.white.withAlphaComponent(pal.dark && v <= 4 ? 0.06 : 0.18).setStroke()
        hl.stroke()
        if flash > 0 {
            NSColor.white.withAlphaComponent(0.4 * flash).setFill()
            path.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let numberShadow = NSShadow()
        // White on gold needs a firmer shadow to read.
        // Dark ink needs no shadow; white on a bright tile needs a firmer one to read.
        let lum = pal.tile(v).luminance
        numberShadow.shadowColor = NSColor.black.withAlphaComponent(lum > pal.theme.inkAbove ? 0 : lum > 0.35 ? 0.22 : 0.12)
        numberShadow.shadowBlurRadius = 1.5
        numberShadow.shadowOffset = NSSize(width: 0, height: -0.5)
        NSGraphicsContext.saveGraphicsState()
        numberShadow.set()
        text("\(v)", tileFont(v), pal.number(v), in: rect, kern: -0.5)
        NSGraphicsContext.restoreGraphicsState()

        if alpha < 1 { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    private func pill(_ rect: NSRect, _ color: NSColor, radius: CGFloat? = nil) {
        color.setFill()
        let r = radius ?? rect.height / 2
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let pal = Palette(dark: effectiveAppearance.isDark, theme: themeOverride ?? .current)
        let t = now
        pal.background.setFill()
        bounds.fill()

        drawHeader(pal, t)
        drawBoard(pal, t)

        text("←↑↓→  WASD  or swipe  ·  ⌘Z undo  ·  R new game  ·  T theme", Self.font(11.5, .medium), pal.secondary,
             in: NSRect(x: 0, y: boardRect.maxY + 12, width: bounds.width, height: 18))
    }

    private func drawHeader(_ pal: Palette, _ t: CFTimeInterval) {
        text("2048", Self.font(46, .heavy), pal.text, in: NSRect(x: margin, y: 40, width: 200, height: 54), kern: -1.5, align: .left)
        // After a theme change the caption names the theme for a moment.
        let named = t - themeChange < 1.6
        text(named ? "\(pal.theme.name) theme" : "Merge your way to 2048.", Self.font(13, named ? .bold : .medium),
             named ? pal.accentText : pal.secondary, in: NSRect(x: margin + 1, y: 108, width: 190, height: 30), align: .left)

        for (i, (label, value)) in [("SCORE", displayedScore), ("BEST", best)].enumerated() {
            let r = scoreRect(i)
            pill(r, pal.pill, radius: 14)
            if i == 1, t - bestFlash < bestFlashTime {
                // A new record: the pill blooms in the accent and fades back.
                let k = CGFloat(1 - Motion.easeOutQuart((t - bestFlash) / bestFlashTime))
                pill(r, pal.accent.withAlphaComponent(0.45 * k), radius: 14)
            }
            text(label, Self.font(10.5, .bold), pal.secondary, in: NSRect(x: r.minX, y: r.minY + 9, width: r.width, height: 14), kern: 1.2)
            text(value.formatted(), Self.font(value >= 100_000 ? 17 : 21, .bold, monoDigits: true), pal.text,
                 in: NSRect(x: r.minX, y: r.minY + 25, width: r.width, height: 24))
        }

        if let (_, r, _) = buttons().first(where: { $0.0 == .theme }) {
            // The theme button: a swatch running from a small tile to the theme's 2048.
            pill(r, pressed == .theme ? pal.pillPressed : pal.pill)
            let dot = NSBezierPath(ovalIn: r.insetBy(dx: 7, dy: 7))
            NSGradient(starting: pal.tile(8), ending: pal.tile(2048))?.draw(in: dot, angle: 45)
        }
        for (b, r, title) in buttons() where b == .undo || b == .newGame {
            pill(r, pressed == b ? pal.pillPressed : pal.pill)
            text(title, Self.font(13, .semibold), enabled(b) ? pal.text : pal.secondary.withAlphaComponent(0.5), in: r)
        }
    }

    private func drawBoard(_ pal: Palette, _ t: CFTimeInterval) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let n = nudge {
            let k = CGFloat(Motion.nudge((t - n.start) / nudgeTime)) * 7
            ctx.translateBy(x: n.dx * k, y: n.dy * k)
        }

        pal.board.setFill()
        NSBezierPath(roundedRect: boardRect, xRadius: boardRadius, yRadius: boardRadius).fill()
        pal.slot.setFill()
        for r in 0..<game.size {
            for c in 0..<game.size {
                let o = origin(CGFloat(r), CGFloat(c))
                NSBezierPath(roundedRect: NSRect(x: o.x, y: o.y, width: cellSide, height: cellSide), xRadius: tileRadius, yRadius: tileRadius).fill()
            }
        }

        if let m = move, t - m.start < slideTime {
            // Slide: each tile glides from its old cell to its new one, still showing its old value.
            let k = CGFloat(Motion.slide((t - m.start) / slideTime))
            if let g = m.ghost {
                drawTile(g.value, at: origin(CGFloat(g.cell.row), CGFloat(g.cell.col)), pal, scale: 1 - 0.6 * k, alpha: 1 - k)
            }
            // Tiles that stay put first, so moving tiles pass over them.
            for tm in m.moves.sorted(by: { ($0.from == $0.to ? 0 : 1) < ($1.from == $1.to ? 0 : 1) }) {
                let (a, b) = m.reverse ? (tm.to, tm.from) : (tm.from, tm.to)
                let r = CGFloat(a.row) + CGFloat(b.row - a.row) * k
                let c = CGFloat(a.col) + CGFloat(b.col - a.col) * k
                drawTile(tm.value, at: origin(r, c), pal)
            }
        } else {
            let after = move.map { t - $0.start - slideTime }
            // Each moved tile overshoots its cell along the slide and springs back.
            var settle: [Game2048.Cell: CGPoint] = [:]
            if let m = move, let a = after, a < settleTime {
                let pitch = cellSide + gap
                for tm in m.moves where tm.from != tm.to {
                    let (src, dst) = m.reverse ? (tm.to, tm.from) : (tm.from, tm.to)
                    let dist = CGFloat(abs(dst.row - src.row) + abs(dst.col - src.col))
                    let o = CGFloat(Motion.settle(a / settleTime, amount: Double(0.05 + 0.02 * dist))) * pitch
                    settle[dst] = CGPoint(x: CGFloat((dst.col - src.col).signum()) * o, y: CGFloat((dst.row - src.row).signum()) * o)
                }
            }
            for r in 0..<game.size {
                for c in 0..<game.size where game.cells[r][c] > 0 {
                    let v = game.cells[r][c]
                    let here = Game2048.Cell(r, c)
                    var scale: CGFloat = 1, alpha: CGFloat = 1, flash: CGFloat = 0
                    var ring: CGFloat?
                    var grow: Double?
                    if let a = after, let m = move {
                        if here == m.spawn {
                            grow = (a - spawnDelay) / spawnTime
                        } else if m.merged.contains(here), a < popTime {
                            let p = a / popTime
                            scale = CGFloat(Motion.pop(p, amount: v >= 128 ? 0.2 : 0.16))
                            flash = CGFloat(max(0, 1 - p * 1.8))
                            if v >= 64 { ring = CGFloat(p) }
                        }
                    }
                    if let s = spawnAll { grow = (t - s - Double(r + c) * 0.03) / spawnTime }
                    let wave = (t - themeChange - Double(r + c) * 0.04) / popTime
                    if wave >= 0, wave < 1 { scale = CGFloat(Motion.pop(wave, amount: 0.09)); flash = CGFloat(max(0, 0.6 - wave)) }
                    if let p = grow, p < 1 {
                        scale = 0.3 + 0.7 * CGFloat(Motion.easeOutBack(p, overshoot: 1.4))
                        alpha = CGFloat(min(1, max(0, p * 2.5)))
                    }
                    var o = origin(CGFloat(r), CGFloat(c))
                    if let d = settle[here] { o.x += d.x; o.y += d.y }
                    drawTile(v, at: o, pal, scale: scale, alpha: alpha, flash: flash, ring: ring)
                }
            }
        }

        drawEndCard(pal, t)
    }

    private func drawEndCard(_ pal: Palette, _ t: CFTimeInterval) {
        guard let end = endMessage, let start = overlayStart, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = (t - start) / overlayTime
        guard p > 0 else { return }
        let k = CGFloat(Motion.easeOutQuart(p))
        let br = boardRect
        let won = end.button == .keepGoing
        pal.background.withAlphaComponent(0.76 * k).setFill()
        NSBezierPath(roundedRect: br, xRadius: boardRadius, yRadius: boardRadius).fill()

        // The card rises a few points and settles as it fades in.
        ctx.saveGState()
        let s = CGFloat(0.92 + 0.08 * Motion.easeOutBack(p, overshoot: 1.2))
        ctx.translateBy(x: br.midX, y: br.midY + 10 * (1 - k))
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -br.midX, y: -br.midY)
        ctx.setAlpha(k)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        let titleRect = NSRect(x: br.minX, y: br.midY - 62, width: br.width, height: 50)
        if won {
            let glow = NSShadow()
            glow.shadowColor = pal.accent.withAlphaComponent(0.6)
            glow.shadowBlurRadius = 18
            NSGraphicsContext.saveGraphicsState()
            glow.set()
            text(end.title, Self.font(38, .heavy), pal.accentText, in: titleRect, kern: -0.8)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            text(end.title, Self.font(40, .heavy), pal.text, in: titleRect, kern: -0.8)
        }
        let newBest = !won && game.score >= best && game.score > bestAtStart
        text(newBest ? "New best: \(game.score.formatted())" : end.subtitle, Self.font(15, .semibold), newBest ? pal.text : pal.secondary,
             in: NSRect(x: br.minX, y: br.midY - 4, width: br.width, height: 22))

        if let (b, r, label) = buttons().first(where: { $0.0 == end.button }) {
            let fill = won ? pal.accent : pal.text
            pill(r, pressed == b ? (fill.blended(withFraction: 0.2, of: .black) ?? fill) : fill)
            text(label, Self.font(15, .bold), won ? pal.ink(on: pal.accent) : pal.background, in: r)
            let hint = won ? "C or Return · R for a new game" : "R or Return · ⌘Z to undo"
            text(hint, Self.font(11.5, .medium), pal.secondary, in: NSRect(x: br.minX, y: r.maxY + 12, width: br.width, height: 16))
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

extension Game2048Window {
    static var command: KeaCommand {
        KeaCommand(id: "2048", name: "2048", keywords: keywords,
                   help: [.init(keyword: "2048", summary: "Play 2048 in a small window; the game is saved", example: "2048")],
                   results: { _ in results() })
    }
}
