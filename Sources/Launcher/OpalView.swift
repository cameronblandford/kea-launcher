import AppKit
import QuartzCore

/// Gradient skins drawn over the panel's blur, with tints that drift slowly while the
/// panel is open and a band of light that crosses it as it opens. Colors follow the
/// panel's effective appearance.
/// - opal: pearl white with pastel pink, lilac, mint and sky.
/// - dusk: a magenta to blue gradient.
/// - glass: almost clear, a bright rim and a specular highlight, like liquid glass.
final class OpalView: NSView {
    enum Style { case opal, dusk, glass }

    let style: Style
    private let base = CALayer()
    private let tints = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private let sweep = CAGradientLayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }

    /// Each band ends on its first color so the drift loops without a seam.
    private var band: [NSColor] {
        switch style {
        case .opal: return [0xFFD6E8, 0xE3D6FF, 0xD1F5E8, 0xCFE6FF, 0xFFE6D4, 0xFFD6E8].map { Self.rgb($0) }
        case .dusk: return [0xF06BD0, 0xC98AF5, 0x8D9FF3, 0x4FABE4, 0xA98CF6, 0xF06BD0].map { Self.rgb($0) }
        case .glass: return [0xFFC8F0, 0xC8E0FF, 0xC8FFF0, 0xFFF0C8, 0xFFC8F0].map { Self.rgb($0) }
        }
    }

    init(frame: NSRect = .zero, style: Style = .opal) {
        self.style = style
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        tints.startPoint = CGPoint(x: 0, y: 0.2)
        tints.endPoint = CGPoint(x: 1, y: 0.8)
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.45)
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.opacity = 0
        // The rim is a gradient seen through a stroked outline: bright on top, faint below.
        rim.startPoint = CGPoint(x: 0.5, y: 1)
        rim.endPoint = CGPoint(x: 0.5, y: 0)
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.white.cgColor
        rim.mask = rimMask
        for l in [base, tints, glow, sheen, sweep, rim] { layer?.addSublayer(l) }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the rows

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dark = isDark
        let white = { (a: CGFloat) in NSColor(white: 1, alpha: a).cgColor }
        let tintAlpha: CGFloat, glowColor: NSColor, sheenTop: CGFloat, rimTop: CGFloat, rimBottom: CGFloat
        switch style {
        case .opal:
            base.backgroundColor = dark ? Self.rgb(0x17171C, 0.86).cgColor : white(0.74)
            tintAlpha = dark ? 0.22 : 0.7
            glowColor = Self.rgb(0xEDE0FF, dark ? 0.2 : 0.6)
            sheenTop = dark ? 0.07 : 0.6
            rimTop = dark ? 0.16 : 0.95; rimBottom = dark ? 0.06 : 0.6
        case .dusk:
            base.backgroundColor = dark ? Self.rgb(0x17151E, 0.62).cgColor : white(0.38)
            tintAlpha = dark ? 0.5 : 0.62
            glowColor = Self.rgb(0xFF9BE6, dark ? 0.28 : 0.45)
            sheenTop = dark ? 0.08 : 0.45
            rimTop = dark ? 0.22 : 0.85; rimBottom = dark ? 0.08 : 0.35
        case .glass:
            // Nearly clear: the blur does the work, the rim and highlight sell it as glass.
            base.backgroundColor = dark ? NSColor(white: 0, alpha: 0.12).cgColor : white(0.12)
            tintAlpha = dark ? 0.05 : 0.1
            glowColor = NSColor(white: 1, alpha: dark ? 0.12 : 0.35)
            sheenTop = dark ? 0.1 : 0.28
            rimTop = dark ? 0.5 : 0.95; rimBottom = dark ? 0.12 : 0.3
        }
        tints.colors = band.map { $0.withAlphaComponent(tintAlpha).cgColor }
        glow.colors = [glowColor.cgColor, glowColor.withAlphaComponent(0).cgColor]
        sheen.colors = [white(sheenTop), white(0)]
        let s = NSColor(white: 1, alpha: dark ? 0.14 : 0.75)
        sweep.colors = [s.withAlphaComponent(0).cgColor, s.cgColor, s.withAlphaComponent(0).cgColor]
        sweep.locations = [0.35, 0.5, 0.65]
        rim.colors = [white(rimTop), white(rimBottom)]
        rimMask.lineWidth = style == .glass ? 1.5 : 1
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        base.frame = b
        sheen.frame = b
        rim.frame = b
        rimMask.frame = b
        rimMask.path = CGPath(roundedRect: b.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 13.5, cornerHeight: 13.5, transform: nil)
        // Wider than the panel so the band can drift without showing an edge.
        tints.frame = CGRect(x: -b.width, y: 0, width: b.width * 3, height: b.height)
        let glowSize = style == .glass ? CGSize(width: 360, height: 200) : CGSize(width: 520, height: 320)
        glow.frame = CGRect(x: style == .glass ? -60 : b.width * 0.15, y: b.height - glowSize.height * 0.7,
                            width: glowSize.width, height: glowSize.height)
        sweep.frame = CGRect(x: -b.width, y: 0, width: b.width * 0.9, height: b.height)
        CATransaction.commit()
    }

    /// Starts the slow drift. Stopped while hidden so an idle panel costs nothing.
    func startDrift() {
        guard tints.animation(forKey: "drift") == nil else { return }
        let w = bounds.width
        let drift = CABasicAnimation(keyPath: "position.x")
        drift.fromValue = tints.position.x
        drift.toValue = tints.position.x + w
        drift.duration = style == .dusk ? 12 : 16
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        tints.add(drift, forKey: "drift")

        let wander = CABasicAnimation(keyPath: "position")
        wander.fromValue = glow.position
        wander.toValue = CGPoint(x: glow.position.x + w * (style == .glass ? 0.25 : 0.45), y: glow.position.y + 30)
        wander.duration = 11
        wander.autoreverses = true
        wander.repeatCount = .infinity
        wander.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(wander, forKey: "drift")
    }

    func stopDrift() {
        tints.removeAnimation(forKey: "drift")
        glow.removeAnimation(forKey: "drift")
    }

    /// A band of light crosses the panel once as it opens.
    func playSweep() {
        let w = bounds.width
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -w * 0.45
        move.toValue = w * 1.45
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.2, 0.7, 1]
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.7
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        sweep.add(group, forKey: "sweep")
    }
}
