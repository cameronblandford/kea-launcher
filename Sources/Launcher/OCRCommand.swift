import AppKit
import LauncherCore
import Vision

/// `ocr`: drag over any part of the screen and its text goes to the clipboard.
enum OCRCommand {
    private static func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    static var command: KeaCommand {
        KeaCommand(id: "ocr", name: "Copy Text from Screen", keywords: ["ocr"],
                   help: [.init(keyword: "ocr", summary: "Drag over a part of the screen; its text goes to the clipboard", example: "ocr")],
                   search: { term, _ in
                       "copy text from screen".hasPrefix(term.lowercased()) && term.count >= 4 ? [row] : []
                   },
                   results: { _ in
                       var rows = [row]
                       if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage {
                           rows.append(Result(id: "ocr:clipboard", title: "Copy text from the image on the clipboard",
                                              subtitle: "\(Int(image.size.width)) × \(Int(image.size.height))", icon: icon("doc.on.clipboard"),
                                              action: .custom { if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { recognize(cg) } }))
                       }
                       return rows
                   })
    }

    private static var row: Result {
        Result(id: "ocr:region", title: "Copy text from screen", subtitle: "Drag over the text · Esc cancels",
               icon: icon("text.viewfinder"), action: .custom { capture() })
    }

    private static func capture() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kea-ocr-\(UUID().uuidString).png")
        // After the panel is gone, so it is not in the picture.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
            _ = Proc.run("/usr/sbin/screencapture", ["-i", "-x", file.path])
            defer { try? FileManager.default.removeItem(at: file) }
            guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }   // cancelled
            recognize(cg)
        }
    }

    /// The text in an image, lines top to bottom.
    static func text(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func recognize(_ image: CGImage) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = text(in: image)
            DispatchQueue.main.async {
                guard !found.isEmpty else { Notify.post(title: "No text found", body: "The clipboard is not changed."); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(found, forType: .string)
                let lines = found.split(separator: "\n").count
                Notify.post(title: "Copied \(lines) line\(lines == 1 ? "" : "s") of text", body: String(found.prefix(120)))
            }
        }
    }
}
