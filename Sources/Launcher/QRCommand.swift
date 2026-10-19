import AppKit
import CoreImage
import LauncherCore
import Vision

/// `qr` makes a QR code from the clipboard text (or `qr <text>`) and shows it in a small
/// window; `qr` also reads a QR code from a part of the screen or from the clipboard image
/// and copies what it says.
enum QRCommand {
    private static func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    /// A QR code for the text, black on white with a quiet margin, at least `side` pixels wide.
    static func image(for text: String, side: Int = 720) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage, code.extent.width > 0 else { return nil }
        // Each module becomes a whole number of pixels, so the edges stay sharp.
        let modules = Int(code.extent.width), margin = 4
        let scale = max(1, side / (modules + 2 * margin))
        let size = (modules + 2 * margin) * scale
        guard let raw = CIContext().createCGImage(code, from: code.extent),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.interpolationQuality = .none
        context.draw(raw, in: CGRect(x: margin * scale, y: margin * scale, width: modules * scale, height: modules * scale))
        return context.makeImage()
    }

    /// What the QR codes in a picture say.
    static func read(_ image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    private static func copyText(in image: CGImage?) {
        guard let image else { return }                       // cancelled
        DispatchQueue.global(qos: .userInitiated).async {
            let found = read(image)
            DispatchQueue.main.async {
                guard let first = found.first else { Notify.post(title: "No QR code found", body: "The clipboard is not changed."); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(first, forType: .string)
                Notify.post(title: "Copied what the QR code says", body: String(first.prefix(160)))
                Log.write("qr: read a code of \(first.count) characters")
            }
        }
    }

    static func results(argument: String) -> [Result] {
        let typed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        func make(_ text: String, title: String) -> Result {
            Result(id: "qr:make", title: title, subtitle: "\(text.prefix(80)) · Return shows the code",
                   icon: icon("qrcode"), action: .custom { QRWindow.show(text: text) })
        }
        if !typed.isEmpty { return [make(typed, title: "QR Code for This Text")] }
        var rows: [Result] = []
        if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.utf8.count <= 2000 {
            rows.append(make(text, title: "QR Code for the Clipboard Text"))
        }
        rows.append(Result(id: "qr:screen", title: "Read a QR Code from the Screen", subtitle: "Drag over the code; what it says goes to the clipboard · Esc cancels",
                           icon: icon("qrcode.viewfinder"), action: .custom { ScreenGrab.region(completion: copyText) }))
        if let image = ImageEditor.clipboardImage()?.0 {
            rows.append(Result(id: "qr:clipboard", title: "Read the QR Code in the Clipboard Image", subtitle: "What it says goes to the clipboard",
                               icon: icon("doc.on.clipboard"), action: .custom { copyText(in: image.cgImage(forProposedRect: nil, context: nil, hints: nil)) }))
        }
        if rows.count == 1 {
            rows.insert(Result(id: "qr:hint", title: "Type the text for a QR code", subtitle: "For example: qr https://kea.directory · or copy text first",
                               icon: icon("qrcode"), action: .none), at: 0)
        }
        return rows
    }

    static var command: KeaCommand {
        KeaCommand(id: "qr", name: "QR Codes", keywords: ["qr"],
                   help: [.init(keyword: "qr", summary: "Make a QR code from text or the clipboard; read one from the screen", example: "qr https://kea.directory")],
                   results: { results(argument: $0.argument) })
    }
}

/// The window that shows one QR code. Return copies the picture and closes, Cmd+C copies,
/// Cmd+S saves a PNG, Escape closes.
final class QRWindow: NSObject, NSWindowDelegate {
    private static var open: [QRWindow] = []
    private let window: NSWindow
    private let image: CGImage

    static func show(text: String) {
        guard let image = QRCommand.image(for: text) else { return NSSound.beep() }
        let w = QRWindow(text: text, image: image)
        open.append(w)
        NSApp.activate(ignoringOtherApps: true)
        w.window.makeKeyAndOrderFront(nil)
    }

    private init(text: String, image: CGImage) {
        self.image = image
        let view = QRView(image: image, text: text)
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "QR Code"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = view
        view.onKey = { [weak self] key in self?.handle(key) }
        window.makeFirstResponder(view)
        window.center()
    }

    private func png() -> Data? { NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) }

    private func copyPicture() {
        guard let data = png() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation { NSPasteboard.general.setData(tiff, forType: .tiff) }
    }

    private func handle(_ key: QRView.Key) {
        switch key {
        case .done:
            copyPicture()
            window.close()
        case .copy: copyPicture()
        case .close: window.close()
        case .save:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "QR Code.png"
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url { try? self?.png()?.write(to: url) }
            }
        }
    }

    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }
}

private final class QRView: NSView {
    enum Key { case done, copy, save, close }
    var onKey: ((Key) -> Void)?
    private let image: CGImage
    private let text: String

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage, text: String) {
        self.image = image
        self.text = text
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 430))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: image, size: .zero).draw(in: NSRect(x: 20, y: 20, width: 320, height: 320))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        (text as NSString).draw(in: NSRect(x: 20, y: 352, width: 320, height: 20),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        ("Return copies the picture and closes · Cmd+S saves" as NSString)
            .draw(in: NSRect(x: 20, y: 384, width: 320, height: 18),
                  withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36, 76: onKey?(.done)
        case 53: onKey?(.close)
        case 8 where command: onKey?(.copy)
        case 1 where command: onKey?(.save)
        case 13 where command: onKey?(.close)
        default: super.keyDown(with: event)
        }
    }
}
