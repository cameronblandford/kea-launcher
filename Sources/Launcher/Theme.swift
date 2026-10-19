import AppKit
import LauncherCore

/// Visual presets for the panel. `accent` colors the selection; `background` tints the blur.
struct Theme {
    var name: String
    var appearance: NSAppearance.Name?     // nil follows the system
    var material: NSVisualEffectView.Material
    var background: NSColor?               // solid tint over the blur
    var tintAlpha: CGFloat
    var accent: NSColor?                   // nil uses the system accent
    var skin: OpalView.Style?              // gradient skin drawn by OpalView; these themes also animate open

    static let presets: [Theme] = [
        Theme(name: "System", appearance: nil, material: .popover, background: nil, tintAlpha: 0, accent: nil),
        Theme(name: "Light", appearance: .aqua, material: .popover, background: nil, tintAlpha: 0, accent: nil),
        Theme(name: "Dark", appearance: .darkAqua, material: .hudWindow, background: nil, tintAlpha: 0, accent: nil),
        Theme(name: "Midnight", appearance: .darkAqua, material: .hudWindow, background: NSColor(hex: "0f1729"), tintAlpha: 0.92, accent: NSColor(hex: "7aa2f7")),
        Theme(name: "Graphite", appearance: .darkAqua, material: .hudWindow, background: NSColor(hex: "1c1c1e"), tintAlpha: 0.94, accent: NSColor(hex: "8e8e93")),
        Theme(name: "Paper", appearance: .aqua, material: .popover, background: NSColor(hex: "f6f1e7"), tintAlpha: 0.96, accent: NSColor(hex: "b7791f")),
        Theme(name: "Rose", appearance: .darkAqua, material: .hudWindow, background: NSColor(hex: "2a1620"), tintAlpha: 0.93, accent: NSColor(hex: "f7768e")),
        Theme(name: "Forest", appearance: .darkAqua, material: .hudWindow, background: NSColor(hex: "14201a"), tintAlpha: 0.93, accent: NSColor(hex: "7fd1a0")),
        Theme(name: "Opal", appearance: nil, material: .popover, background: nil, tintAlpha: 0, accent: NSColor(hex: "b69cf0"), skin: .opal),
        Theme(name: "Opal Light", appearance: .aqua, material: .popover, background: nil, tintAlpha: 0, accent: NSColor(hex: "b69cf0"), skin: .opal),
        Theme(name: "Opal Dark", appearance: .darkAqua, material: .hudWindow, background: nil, tintAlpha: 0, accent: NSColor(hex: "b69cf0"), skin: .opal),
        Theme(name: "Dusk", appearance: nil, material: .popover, background: nil, tintAlpha: 0, accent: NSColor(hex: "9b6cf0"), skin: .dusk),
        Theme(name: "Dusk Light", appearance: .aqua, material: .popover, background: nil, tintAlpha: 0, accent: NSColor(hex: "9b6cf0"), skin: .dusk),
        Theme(name: "Dusk Dark", appearance: .darkAqua, material: .hudWindow, background: nil, tintAlpha: 0, accent: NSColor(hex: "c58cff"), skin: .dusk),
        Theme(name: "Glass", appearance: nil, material: .fullScreenUI, background: nil, tintAlpha: 0, accent: NSColor(hex: "8fb8ff"), skin: .glass),
        Theme(name: "Glass Light", appearance: .aqua, material: .fullScreenUI, background: nil, tintAlpha: 0, accent: NSColor(hex: "8fb8ff"), skin: .glass),
        Theme(name: "Glass Dark", appearance: .darkAqua, material: .fullScreenUI, background: nil, tintAlpha: 0, accent: NSColor(hex: "8fb8ff"), skin: .glass),
    ]

    static func named(_ name: String) -> Theme {
        presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? presets[0]
    }

    /// Preset plus the user's overrides from config.
    static func resolve(_ a: Config.Appearance) -> Theme {
        var t = named(a.theme)
        if let c = NSColor(hex: a.accent) { t.accent = c }
        if let c = NSColor(hex: a.background) { t.background = c; if t.tintAlpha == 0 { t.tintAlpha = 0.92 } }
        if a.opacity > 0, a.opacity < 1, t.background != nil { t.tintAlpha = CGFloat(a.opacity) }
        return t
    }

    var selectionColor: NSColor { (accent ?? .controlAccentColor).withAlphaComponent(0.28) }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "" }
        return String(format: "%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

extension Theme {
    private static func swatchColors(_ t: Theme, dark: Bool) -> [NSColor] {
        switch t.skin {
        case .opal?: return dark ? [NSColor(hex: "26232e")!, NSColor(hex: "302a3a")!] : [NSColor(hex: "ffe3ef")!, NSColor(hex: "e6ecff")!, NSColor(hex: "dcf7ec")!]
        case .dusk?: return dark ? [NSColor(hex: "6b3a78")!, NSColor(hex: "34507a")!] : [NSColor(hex: "f7b5e8")!, NSColor(hex: "c6b8f7")!, NSColor(hex: "a9d3f2")!]
        case .glass?: return dark ? [NSColor(white: 0.32, alpha: 0.9), NSColor(white: 0.22, alpha: 0.9)] : [NSColor(white: 0.97, alpha: 0.9), NSColor(white: 0.88, alpha: 0.9)]
        case nil:
            if let bg = t.background { return [bg] }
            return dark ? [NSColor(hex: "2b2b2e")!] : [NSColor(hex: "ececee")!]
        }
    }

    /// Whether this theme shows a light and a dark face (it follows the system).
    var followsSystem: Bool { appearance == nil }
    var isDark: Bool { appearance == .darkAqua }

    /// A small pill for the theme menu: its colors (light and dark halves when it follows
    /// the system) and a dot in its selection color.
    func swatch(size: NSSize = NSSize(width: 46, height: 16)) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
            NSGraphicsContext.saveGraphicsState()
            pill.addClip()
            let faces: [Bool] = self.followsSystem ? [false, true] : [self.isDark]
            let w = rect.width / CGFloat(faces.count)
            for (i, dark) in faces.enumerated() {
                let r = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: rect.height)
                let colors = Theme.swatchColors(self, dark: dark)
                if colors.count > 1 { NSGradient(colors: colors)?.draw(in: r, angle: 0) } else { colors[0].setFill(); r.fill() }
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 0.5, alpha: 0.35).setStroke()
            pill.lineWidth = 0.5
            pill.stroke()
            let d = rect.height - 8
            (self.accent ?? .controlAccentColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - d - 4, y: 4, width: d, height: d)).fill()
            return true
        }
    }
}

/// A live preview of a theme in Settings: a small panel with a placeholder and a
/// selected row, light and dark side by side when the theme follows the system.
final class ThemePreview: NSView {
    private var faces: [NSView] = []

    override var intrinsicContentSize: NSSize { NSSize(width: 400, height: 72) }

    func show(_ theme: Theme, placeholder: String) {
        faces.forEach { $0.removeFromSuperview() }
        faces = []
        let looks: [NSAppearance.Name] = theme.appearance.map { [$0] } ?? [.aqua, .darkAqua]
        let gap: CGFloat = 8
        let w = (400 - gap * CGFloat(looks.count - 1)) / CGFloat(looks.count)
        for (i, look) in looks.enumerated() {
            let face = NSView(frame: NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: 72))
            face.appearance = NSAppearance(named: look)
            face.wantsLayer = true
            face.layer?.cornerRadius = 10
            face.layer?.masksToBounds = true
            let dark = look == .darkAqua
            face.layer?.backgroundColor = (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
            if let skin = theme.skin {
                let v = OpalView(frame: face.bounds, style: skin)
                face.addSubview(v)
            } else if let bg = theme.background {
                face.layer?.backgroundColor = bg.withAlphaComponent(max(theme.tintAlpha, 0.9)).cgColor
            }
            let text = NSTextField(labelWithString: placeholder)
            text.font = .systemFont(ofSize: 15, weight: .light)
            text.textColor = .placeholderTextColor
            text.frame = NSRect(x: 12, y: 42, width: w - 24, height: 20)
            face.addSubview(text)
            let row = NSView(frame: NSRect(x: 6, y: 8, width: w - 12, height: 26))
            row.wantsLayer = true
            row.layer?.cornerRadius = 6
            row.layer?.backgroundColor = theme.selectionColor.cgColor
            let title = NSTextField(labelWithString: "🎉  Party popper")
            title.font = .systemFont(ofSize: 12)
            title.frame = NSRect(x: 8, y: 4, width: w - 28, height: 17)
            row.addSubview(title)
            face.addSubview(row)
            addSubview(face)
            faces.append(face)
        }
    }
}
