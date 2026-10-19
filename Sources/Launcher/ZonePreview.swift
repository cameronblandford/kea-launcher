import AppKit
import LauncherCore

/// Draws each display's zone layout as a small numbered diagram, updated while typing.
final class ZonePreview: NSView {
    struct Item {
        let match: String
        let layout: Swift.Result<ZoneLayout, Error>
    }

    var items: [Item] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    private let height: CGFloat = 110

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: items.isEmpty ? 20 : height + 22)
    }

    /// A rough shape for each kind of match, so the diagram looks like the real display.
    private func aspect(_ match: String) -> CGFloat {
        switch match.lowercased() {
        case "portrait", "vertical": return 9.0 / 16.0
        case "builtin", "laptop": return 16.0 / 10.4
        default: return 16.0 / 9.0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        // Shrink the diagrams together so every display fits on one row.
        let spacing: CGFloat = 14
        let natural = items.reduce(0) { $0 + height * aspect($1.match) } + spacing * CGFloat(max(0, items.count - 1))
        let scale = min(1, bounds.width / max(natural, 1))
        let h = height * scale
        let captionAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        for item in items {
            let w = h * aspect(item.match)
            let screen = CGRect(x: x, y: height - h, width: w, height: h)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: screen, xRadius: 6, yRadius: 6).fill()
            switch item.layout {
            case .success(let layout):
                // Same order and gaps as the real zones, at diagram scale.
                let rects = ZoneNavigator.globalZones(displays: [(screen, layout)], gap: 6)
                for (i, r) in rects.enumerated() {
                    NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
                    let n = NSAttributedString(string: "\(i + 1)", attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
                    let s = n.size()
                    n.draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
                }
            case .failure:
                let t = NSAttributedString(string: "Can't read layout", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemRed])
                let s = t.size()
                t.draw(at: CGPoint(x: screen.midX - s.width / 2, y: screen.midY - s.height / 2))
            }
            NSAttributedString(string: item.match, attributes: captionAttrs).draw(at: CGPoint(x: x, y: height + 4))
            x += w + spacing * scale
        }
    }
}
