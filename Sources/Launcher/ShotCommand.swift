import AppKit
import LauncherCore

/// A picture of a part of the screen, chosen by the person.
enum ScreenGrab {
    /// Lets the person drag over a region (or click a window) and gives the picture to
    /// `completion` on the main thread. Nil when they press Escape.
    static func region(window: Bool = false, completion: @escaping (CGImage?) -> Void) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kea-grab-\(UUID().uuidString).png")
        // After the panel is gone, so it is not in the picture.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
            _ = Proc.run("/usr/sbin/screencapture", (window ? ["-i", "-W"] : ["-i"]) + ["-x", file.path])
            defer { try? FileManager.default.removeItem(at: file) }
            let image = CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            DispatchQueue.main.async { completion(image) }
        }
    }
}

/// `shot`: take a picture of a part of the screen and open it at once in the image
/// editor (`ie`) or in Paint, without the clipboard in between.
enum ShotCommand {
    private static func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    private static func edit(_ image: CGImage) {
        ImageEditor.show(image: NSImage(cgImage: image, size: .zero), pixelSize: CGSize(width: image.width, height: image.height))
    }

    static var rows: [Result] {
        [Result(id: "shot:region", title: "Screenshot a Region and Mark It Up", subtitle: "Drag over the region; it opens in the image editor · Esc cancels",
                icon: icon("camera.viewfinder"), action: .custom { ScreenGrab.region { $0.map(edit) } }),
         Result(id: "shot:window", title: "Screenshot a Window and Mark It Up", subtitle: "Click the window; it opens in the image editor · Esc cancels",
                icon: icon("macwindow"), action: .custom { ScreenGrab.region(window: true) { $0.map(edit) } }),
         Result(id: "shot:paint", title: "Screenshot a Region and Paint on It", subtitle: "Drag over the region; it goes on the Paint canvas · Esc cancels",
                icon: icon("paintpalette"), action: .custom { ScreenGrab.region { $0.map { PaintWindow.show(image: $0) } } })]
    }

    static var command: KeaCommand {
        KeaCommand(id: "shot", name: "Screenshot to Editor", keywords: ["shot"],
                   help: [.init(keyword: "shot", summary: "Screenshot a region or a window and open it in the image editor or Paint", example: "shot")],
                   results: { _ in rows })
    }
}
