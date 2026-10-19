import AppKit
import LauncherCore

/// Draws `ie` marks in a cute sticker style: pastel strokes with a white rim and a soft
/// drop shadow. The same code draws the editor canvas and the exported PNG, so what you
/// see is what gets copied. Sizes scale with the image, not the window.
enum MarkupRenderer {
    static var fontName = ""

    static func color(_ c: PastelColor) -> NSColor {
        NSColor(srgbRed: CGFloat((c.hex >> 16) & 0xff) / 255, green: CGFloat((c.hex >> 8) & 0xff) / 255,
                blue: CGFloat(c.hex & 0xff) / 255, alpha: 1)
    }

    /// The configured font (for example Fredoka) at a weight, else SF Rounded.
    static func font(size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        if !fontName.isEmpty {
            let d = NSFontDescriptor(fontAttributes: [.family: fontName, .traits: [NSFontDescriptor.TraitKey.weight: weight]])
            if let f = NSFont(descriptor: d, size: size), f.familyName == fontName { return f }
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    /// Style unit for an image drawn in `rect`: about 1 at 900 px across.
    static func unit(for rect: CGRect) -> CGFloat { max(max(rect.width, rect.height) / 900, 0.45) }

    static func point(_ p: Markup.Point, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }

    /// Draws into the current context, which must be flipped (y grows downward).
    /// `image` is the picture under the marks; the mosaic mark samples it.
    static func draw(_ marks: [Markup], in rect: CGRect, image: NSImage? = nil) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let u = unit(for: rect)
        let source = marks.contains { $0.kind == .mosaic } ? image?.cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
        for m in marks {
            if m.kind == .mosaic { mosaic(box(m, in: rect), in: rect, source: source, unit: u, ctx: ctx) }
            else { draw(m, in: rect, unit: u, ctx: ctx) }
        }
    }

    /// Pixelates the part of the picture under `r`: the region is averaged down to a few
    /// coarse blocks and drawn back without smoothing. It samples the original picture, so
    /// it hides what is in the image itself (not marks drawn earlier).
    private static func mosaic(_ r: CGRect, in rect: CGRect, source: CGImage?, unit u: CGFloat, ctx: CGContext) {
        guard r.width > 2, r.height > 2 else { return }
        let clip = CGPath(roundedRect: r, cornerWidth: min(8 * u, r.width / 2), cornerHeight: min(8 * u, r.height / 2), transform: nil)
        var blocks: CGImage?
        if let source {
            // The region in the image's own pixels (top-left origin, like CGImage cropping).
            let sx = CGFloat(source.width) / rect.width, sy = CGFloat(source.height) / rect.height
            let crop = CGRect(x: (r.minX - rect.minX) * sx, y: (r.minY - rect.minY) * sy, width: r.width * sx, height: r.height * sy).integral
                .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
            let grid = Markup.mosaicGrid(width: r.width, height: r.height, unit: u)
            if !crop.isEmpty, let part = source.cropping(to: crop),
               let small = CGContext(data: nil, width: grid.cols, height: grid.rows, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                small.interpolationQuality = .high
                small.draw(part, in: CGRect(x: 0, y: 0, width: grid.cols, height: grid.rows))
                blocks = small.makeImage()
            }
        }
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        if let blocks {
            // CGContext draws images bottom-up; flip inside the region so the blocks stay upright.
            ctx.translateBy(x: r.minX, y: r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(blocks, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        } else {
            ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
            ctx.fill(r)
        }
        ctx.restoreGState()
        // The same white rim as the other marks, so it reads as placed on purpose.
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(3 * u)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func withShadow(_ ctx: CGContext, _ u: CGFloat, alpha: CGFloat = 0.24, _ body: () -> Void) {
        ctx.saveGState()
        // Shadow offsets ignore the flip, so a negative height falls downward on screen.
        ctx.setShadow(offset: CGSize(width: 0, height: -3 * u), blur: 9 * u, color: NSColor(white: 0, alpha: alpha).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The drawn size of a text mark's pill, for hit-testing.
    static func textPillSize(_ m: Markup, in rect: CGRect) -> CGSize {
        let u = unit(for: rect)
        let size = NSAttributedString(string: m.text, attributes: [.font: font(size: 22 * u)]).size()
        return CGSize(width: size.width + 26 * u, height: size.height + 12 * u)
    }

    static func box(_ m: Markup, in rect: CGRect) -> CGRect {
        let a = point(m.points[0], in: rect), b = point(m.points[m.points.count - 1], in: rect)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private static func draw(_ m: Markup, in rect: CGRect, unit u: CGFloat, ctx: CGContext) {
        let c = color(m.color)
        switch m.kind {
        case .box:
            let r = box(m, in: rect)
            withShadow(ctx, u) {
                let p = NSBezierPath(roundedRect: r, xRadius: 12 * u, yRadius: 12 * u)
                p.lineWidth = 9 * u; NSColor.white.setStroke(); p.stroke()
                p.lineWidth = 5.5 * u; c.setStroke(); p.stroke()
            }
        case .highlight:
            let r = box(m, in: rect)
            c.withAlphaComponent(0.38).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6 * u, yRadius: 6 * u).fill()
        case .redact:
            let r = box(m, in: rect)
            withShadow(ctx, u, alpha: 0.18) {
                let p = NSBezierPath(roundedRect: r, xRadius: 8 * u, yRadius: 8 * u)
                c.setFill(); p.fill()
                // Soft diagonal stripes, so it reads as "hidden on purpose".
                NSGraphicsContext.saveGraphicsState()
                p.addClip()
                NSColor(white: 1, alpha: 0.08).setStroke()
                let stripes = NSBezierPath(); stripes.lineWidth = 6 * u
                var x = r.minX - r.height
                while x < r.maxX { stripes.move(to: CGPoint(x: x, y: r.maxY)); stripes.line(to: CGPoint(x: x + r.height, y: r.minY)); x += 16 * u }
                stripes.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
        case .arrow:
            let a = point(m.points[0], in: rect), b = point(m.points[m.points.count - 1], in: rect)
            let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 1)
            // A gentle bow makes it look hand-placed rather than ruled.
            let bow: CGFloat = 0.12 * len
            let ctrl = CGPoint(x: (a.x + b.x) / 2 - dy / len * bow, y: (a.y + b.y) / 2 + dx / len * bow)
            let head = min(max(16 * u, len * 0.2), 26 * u)
            let tx = b.x - ctrl.x, ty = b.y - ctrl.y, tl = max(hypot(tx, ty), 1)
            let ux = tx / tl, uy = ty / tl
            let base = CGPoint(x: b.x - ux * head * 0.8, y: b.y - uy * head * 0.8)
            let shaft = NSBezierPath()
            shaft.move(to: a); shaft.curve(to: base, controlPoint1: ctrl, controlPoint2: ctrl)
            shaft.lineCapStyle = .round
            let tip = NSBezierPath()
            let wing = head * 0.62
            tip.move(to: b)
            tip.line(to: CGPoint(x: b.x - ux * head - uy * wing, y: b.y - uy * head + ux * wing))
            tip.line(to: CGPoint(x: b.x - ux * head + uy * wing, y: b.y - uy * head - ux * wing))
            tip.close()
            tip.lineJoinStyle = .round
            withShadow(ctx, u) {
                NSColor.white.setStroke()
                shaft.lineWidth = 12 * u; shaft.stroke()
                tip.lineWidth = 7 * u; tip.stroke()
                c.setStroke(); c.setFill()
                shaft.lineWidth = 7 * u; shaft.stroke()
                tip.lineWidth = 2 * u; tip.stroke(); tip.fill()
            }
        case .pen:
            let pts = m.points.map { point($0, in: rect) }
            guard pts.count > 1 else { return }
            let p = NSBezierPath()
            p.move(to: pts[0])
            // Midpoint smoothing: each point becomes a control point, so strokes look inked, not jagged.
            for i in 1..<pts.count {
                let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                p.curve(to: mid, controlPoint1: pts[i - 1], controlPoint2: pts[i - 1])
            }
            p.line(to: pts[pts.count - 1])
            p.lineCapStyle = .round; p.lineJoinStyle = .round
            withShadow(ctx, u) {
                p.lineWidth = 10 * u; NSColor.white.setStroke(); p.stroke()
                p.lineWidth = 6 * u; c.setStroke(); p.stroke()
            }
        case .mosaic:
            break   // drawn by mosaic(_:in:source:unit:ctx:), which needs the picture
        case .text:
            let origin = point(m.points[0], in: rect)
            let f = font(size: 22 * u)
            let ink = m.color == .ink ? NSColor.white : color(.ink)
            let s = NSAttributedString(string: m.text, attributes: [.font: f, .foregroundColor: ink])
            let size = s.size()
            let pill = CGRect(x: origin.x, y: origin.y, width: size.width + 26 * u, height: size.height + 12 * u)
            withShadow(ctx, u) {
                let p = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
                c.setFill(); p.fill()
                p.lineWidth = 3 * u; NSColor.white.setStroke(); p.stroke()
            }
            s.draw(at: CGPoint(x: pill.minX + 13 * u, y: pill.minY + 6 * u))
        }
    }

    /// The image with its marks at full pixel size, as PNG data.
    static func export(_ image: NSImage, pixelSize: CGSize, marks: [Markup]) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = pixelSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let rect = CGRect(origin: .zero, size: pixelSize)
        image.draw(in: rect)
        // Flip so marks use the same top-left space as the editor.
        let flipped = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
        NSGraphicsContext.current = flipped
        ctx.cgContext.translateBy(x: 0, y: pixelSize.height)
        ctx.cgContext.scaleBy(x: 1, y: -1)
        draw(marks, in: rect, image: image)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
