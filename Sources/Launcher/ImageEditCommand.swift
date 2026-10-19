import AppKit
import LauncherCore

/// Marks the clipboard image up from the words after `ie`. Kea's own build has one, which
/// asks a vision model; the public build has none, and the words do nothing.
protocol ImageEditAssistant: AnyObject {
    /// The `help` line of `ie` while this is in use.
    var help: HelpProvider.Entry { get }
    /// Added to the subtitle of the "Edit Clipboard Image" row.
    var hint: String { get }
    /// The row for `ie <words>`. `size` is the image's size as text, for the subtitle.
    func row(for words: String, image: NSImage, pixelSize: CGSize, size: String, icon: NSImage?) -> Result
}

/// `ie` opens the clipboard image in the editor.
final class ImageEditCommand {
    static let keywords: Set<String> = ["ie"]
    private let assistant: ImageEditAssistant?

    init(assistant: ImageEditAssistant?) { self.assistant = assistant }

    func results(argument: String) -> [Result] {
        let text = argument.trimmingCharacters(in: .whitespaces)
        guard let (img, px) = ImageEditor.clipboardImage() else {
            return [Result(id: "ie:none", title: "No image on the clipboard",
                           subtitle: "Copy an image or take a screenshot to the clipboard (Ctrl+Cmd+Shift+4), then ie",
                           icon: IconLoader.shared.icon(forSpec: "sf:photo.badge.exclamationmark"), action: .none)]
        }
        let thumb = img.copy() as? NSImage
        thumb?.size = NSSize(width: 30, height: 30 * px.height / max(px.width, 1))
        let size = "\(Int(px.width))×\(Int(px.height))"
        if !text.isEmpty, let assistant { return [assistant.row(for: text, image: img, pixelSize: px, size: size, icon: thumb)] }
        return [Result(id: "ie:edit", title: "⟡ Edit Clipboard Image", subtitle: "\(size) ⋆ arrows, boxes, text, pen, highlight, redact, mosaic\(assistant?.hint ?? "")",
                       icon: thumb, action: .custom { ImageEditor.show(image: img, pixelSize: px) })]
    }
}

extension ImageEditCommand {
    /// `Kea --ie-snapshot in.png out.png`: draws a sample of every mark on the image and
    /// writes the exported PNG. No window. With `--window` after the paths it renders the
    /// editor window itself.
    static func snapshot(input: URL, output: URL, instructions: String) {
        let config = Config.load(from: Paths.config)
        MarkupRenderer.fontName = config.imageEditor.font
        guard let img = NSImage(contentsOf: input), let rep = img.representations.first else { print("cannot read \(input.path)"); return }
        let px = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        func write(_ marks: [Markup]) {
            if let data = MarkupRenderer.export(img, pixelSize: px, marks: marks) { try? data.write(to: output) }
        }
        if instructions == "--window" {
            // The editor window itself, laid out offscreen, with a few marks.
            let e = ImageEditor.show(image: img, pixelSize: px, onScreen: false)
            e.addMarks([Markup(kind: .arrow, points: [.init(0.6, 0.2), .init(0.4, 0.4)], color: .lilac),
                        Markup(kind: .text, points: [.init(0.62, 0.1)], color: .butter, text: "hello ✧")], note: "")
            guard let v = e.window.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output)
            return
        }
        write([
            Markup(kind: .box, points: [.init(0.06, 0.08), .init(0.4, 0.4)], color: .pink),
            Markup(kind: .arrow, points: [.init(0.55, 0.15), .init(0.42, 0.3)], color: .lilac),
            Markup(kind: .text, points: [.init(0.56, 0.08)], color: .butter, text: "look here ✧"),
            Markup(kind: .highlight, points: [.init(0.06, 0.5), .init(0.5, 0.6)], color: .mint),
            Markup(kind: .redact, points: [.init(0.6, 0.5), .init(0.92, 0.62)], color: .ink),
            Markup(kind: .mosaic, points: [.init(0.6, 0.66), .init(0.92, 0.8)], color: .ink),
            Markup(kind: .pen, points: (0..<30).map { i in .init(0.1 + Double(i) * 0.027, 0.82 + 0.05 * sin(Double(i) / 3)) }, color: .sky),
        ])
    }
}

extension ImageEditCommand {
    var command: KeaCommand {
        KeaCommand(id: "ie", name: "Image Editor", keywords: Self.keywords,
                   help: [assistant?.help ?? .init(keyword: "ie", summary: "Edit the clipboard image: arrows, boxes, text, pen, highlight, redact, mosaic", example: "ie")],
                   results: { [unowned self] in results(argument: $0.argument) })
    }
}
