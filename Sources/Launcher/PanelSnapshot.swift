import AppKit
import LauncherCore

/// `Kea --panel-snapshot out.png` draws the panel in the configured theme, light and dark
/// side by side, with sample rows, without opening a window. The blur behind the panel
/// is not drawn; a flat gray stands in for the desktop.
enum PanelSnapshot {
    static func render(to url: URL, theme name: String? = nil) {
        var config = Config.load(from: Paths.config)
        if let name { config.appearance.theme = name }
        let theme = Theme.resolve(config.appearance)
        let placeholder = config.placeholder.components(separatedBy: " | ").first ?? "Search"
        let rows: [Result] = [
            ("🎉", "Party popper", "celebrate party tada"), ("🥳", "Partying face", "birthday celebrate"),
            ("🌧️☕📖", "🌧️☕📖", "Haiku · sequence for \"cozy rainy day\""),
        ].map { Result(id: $0.0, title: $0.1, subtitle: $0.2, icon: $0.0.count > 1 ? IconLoader.shared.icon(forSpec: "sf:sparkles") : EmojiImage.image($0.0), action: .none) }
            + [Result(id: "keys", title: "New Private Window", subtitle: "Safari · File", icon: IconLoader.shared.icon(forSpec: "sf:filemenu.and.selection"), action: .none, keys: ["⇧", "⌘", "N"])]

        let w: CGFloat = 680, rowH: CGFloat = 46, fieldH: CGFloat = 56
        let h = fieldH + rowH * CGFloat(rows.count) + 8
        let pad: CGFloat = 24
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: w * 2 + pad * 3, height: (h + pad * 2) * 2 - pad))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(white: 0.55, alpha: 1).cgColor

        for (i, dark) in [false, true].enumerated() {
            for (j, query) in ["", "e party"].enumerated() {
                let panel = NSView(frame: NSRect(x: pad + CGFloat(i) * (w + pad), y: pad + CGFloat(1 - j) * (h + pad), width: w, height: h))
                panel.appearance = NSAppearance(named: theme.appearance ?? (dark ? .darkAqua : .aqua))
                panel.wantsLayer = true
                panel.layer?.cornerRadius = 14
                panel.layer?.masksToBounds = true
                panel.layer?.backgroundColor = (panel.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
                canvas.addSubview(panel)
                if let skin = theme.skin {
                    let opal = OpalView(frame: panel.bounds, style: skin)
                    opal.autoresizingMask = [.width, .height]
                    panel.addSubview(opal)
                } else if let bg = theme.background {
                    panel.layer?.backgroundColor = bg.withAlphaComponent(max(theme.tintAlpha, 0.9)).cgColor
                }
                let field = NSTextField(labelWithString: query.isEmpty ? placeholder : query)
                field.font = .systemFont(ofSize: CGFloat(config.appearance.fontSize), weight: .light)
                field.textColor = query.isEmpty ? .placeholderTextColor : .labelColor
                field.frame = NSRect(x: 18, y: h - fieldH + 10, width: w - 36, height: fieldH - 20)
                panel.addSubview(field)
                RowBackground.selectionColor = theme.selectionColor
                for (k, r) in rows.enumerated() {
                    let bgRow = RowBackground(frame: NSRect(x: 0, y: h - fieldH - rowH * CGFloat(k + 1), width: w, height: rowH))
                    bgRow.isSelected = k == 0
                    let cell = ResultRowView(identifier: .init("row"))
                    cell.frame = bgRow.bounds
                    cell.configure(r)
                    bgRow.addSubview(cell)
                    panel.addSubview(bgRow)
                }
            }
        }
        // Subview layers only exist inside a window; this one is never shown.
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        canvas.displayIfNeeded()
        CATransaction.flush()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width * scale), pixelsHigh: Int(canvas.bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        ctx.cgContext.scaleBy(x: scale, y: scale)
        canvas.layer?.render(in: ctx.cgContext)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// `Kea --theme-snapshot out.png` draws every theme's menu swatch and Settings preview.
enum ThemeSnapshot {
    static func render(to url: URL) {
        let rowH: CGFloat = 84
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: rowH * CGFloat(Theme.presets.count) + 16))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        for (i, t) in Theme.presets.enumerated() {
            let y = canvas.bounds.height - 8 - rowH * CGFloat(i + 1) + 6
            let name = NSTextField(labelWithString: t.name)
            name.textColor = .black
            name.frame = NSRect(x: 16, y: y + 46, width: 110, height: 18)
            let sw = NSImageView(image: t.swatch())
            sw.frame = NSRect(x: 16, y: y + 22, width: 46, height: 16)
            let p = ThemePreview(frame: NSRect(x: 180, y: y, width: 400, height: 72))
            p.show(t, placeholder: "ᕕ( ᐛ )ᕗ")
            [name, sw, p].forEach(canvas.addSubview)
        }
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        canvas.displayIfNeeded()
        CATransaction.flush()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width * 2), pixelsHigh: Int(canvas.bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        ctx.cgContext.scaleBy(x: 2, y: 2)
        canvas.layer?.render(in: ctx.cgContext)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
