import AppKit
import LauncherCore

/// `rec` records a part of the screen as a GIF or an MP4. Drag over the region, then stop
/// with the Stop button below it or with `rec` again. The file goes to `~/Movies/Kea` and
/// to the clipboard. macOS's `screencapture` makes the recording, so Kea needs the Screen
/// Recording permission.
final class ScreenRecorder {
    static let shared = ScreenRecorder()
    enum Format: String, CaseIterable { case gif, mp4 }
    /// A recording stops by itself after this many seconds.
    static let limit = 300
    static let folder = Paths.home.appendingPathComponent("Movies/Kea", isDirectory: true)

    private var process: Process?
    private var input: Pipe?
    private var started: Date?
    private var format = Format.gif
    private var movie: URL?
    private var hud: RecordingHUD?
    private(set) var converting = false
    var isRecording: Bool { process != nil }

    private static func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    var elapsed: String {
        let seconds = Int(Date().timeIntervalSince(started ?? Date()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func results(argument: String) -> [Result] {
        if converting {
            return [Result(id: "rec:converting", title: "Making the \(format.rawValue.uppercased())…", subtitle: "It goes to the clipboard when it is ready",
                           icon: Self.icon("film"), action: .none)]
        }
        if isRecording {
            return [Result(id: "rec:stop", title: "Stop Recording · \(elapsed)", subtitle: "The \(format.rawValue.uppercased()) goes to the clipboard and to ~/Movies/Kea",
                           icon: Self.icon("stop.circle.fill"), action: .custom { [weak self] in self?.stop() })]
        }
        var rows: [Result] = []
        if !CGPreflightScreenCaptureAccess() {
            rows.append(Result(id: "rec:grant", title: "Allow Kea to Record the Screen",
                               subtitle: "Opens System Settings › Privacy › Screen Recording: turn Kea on, then restart Kea",
                               icon: Self.icon("lock.open"), action: .custom {
                                   CGRequestScreenCaptureAccess()
                                   NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                               }))
        }
        let typed = argument.trimmingCharacters(in: .whitespaces).lowercased()
        let formats = Format.allCases.filter { typed.isEmpty || $0.rawValue.hasPrefix(typed) }
        if formats.isEmpty {
            return [Result(id: "rec:error", title: "Could not read \(typed)", subtitle: "rec, rec gif, or rec mp4", icon: Self.icon("record.circle"), action: .none)]
        }
        rows += formats.map { f in
            Result(id: "rec:\(f.rawValue)", title: "Record a Region as \(f == .gif ? "a GIF" : "an MP4")",
                   subtitle: "Drag over the region · stop with the Stop button or with rec · the file goes to the clipboard",
                   icon: Self.icon("record.circle"), action: .custom { [weak self] in self?.start(f) })
        }
        return rows
    }

    private func start(_ format: Format) {
        guard !isRecording, !converting else { return }
        self.format = format
        // After the panel is gone, so it is not under the picker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            RegionPicker.pick { [weak self] region in
                guard let self, let region else { return }
                self.begin(region)
            }
        }
    }

    /// `region` is in Cocoa screen coordinates (y goes up from the bottom of the main screen).
    private func begin(_ region: NSRect) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kea-rec-\(UUID().uuidString).mov")
        // screencapture counts y down from the top of the main screen.
        let top = (NSScreen.screens.first?.frame.height ?? region.maxY) - region.maxY
        let rect = [region.minX, top, region.width, region.height].map { String(Int($0.rounded())) }.joined(separator: ",")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-v", "-x", "-V", String(Self.limit), "-R", rect, file.path]
        // It reads its input for "any key stops"; an open pipe with nothing in it keeps it recording.
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.finish() } }
        do { try p.run() } catch {
            Log.write("rec: could not start screencapture: \(error.localizedDescription)")
            return
        }
        process = p
        input = pipe
        movie = file
        started = Date()
        hud = RecordingHUD(region: region, recorder: self)
        Log.write("rec: recording \(rect) as \(format.rawValue)")
    }

    func stop() { process?.interrupt() }

    private func finish() {
        hud?.close()
        hud = nil
        process = nil
        input = nil
        guard let movie else { return }
        self.movie = nil
        converting = true
        let format = format
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let output = Self.folder.appendingPathComponent("Recording \(stamp.string(from: Date())).\(format.rawValue)")
            let made = format == .gif ? MediaConvert.gif(from: movie, to: output) : MediaConvert.mp4(from: movie, to: output, passthrough: true)
            try? FileManager.default.removeItem(at: movie)
            DispatchQueue.main.async {
                self.converting = false
                guard made else {
                    Log.write("rec: no \(format.rawValue) was made")
                    Notify.post(title: "The recording could not be saved", body: "See ~/.launcher/launcher.log")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([output as NSURL])
                Log.write("rec: saved \(output.lastPathComponent)")
                Notify.post(title: "The recording is on the clipboard", body: "\(output.lastPathComponent) in ~/Movies/Kea")
            }
        }
    }

    var command: KeaCommand {
        KeaCommand(id: "rec", name: "Record the Screen", keywords: ["rec"],
                   help: [.init(keyword: "rec", summary: "Record a part of the screen as a GIF or an MP4; it goes to the clipboard", example: "rec · rec mp4")],
                   live: (1, { [unowned self] in isRecording || converting }),
                   results: { [unowned self] in results(argument: $0.argument) })
    }
}

/// While a recording runs: a red frame around the region and a Stop button with the time.
/// Both are left out of screen captures, so they are not in the recording.
private final class RecordingHUD: NSObject {
    private let frameWindow: NSWindow
    private let panel: NSPanel
    private let button = NSButton(title: "", target: nil, action: nil)
    private var timer: Timer?
    private weak var recorder: ScreenRecorder?

    init(region: NSRect, recorder: ScreenRecorder) {
        self.recorder = recorder
        frameWindow = NSWindow(contentRect: region.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 150, height: 32), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        for w in [frameWindow, panel] as [NSWindow] {
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .statusBar
            w.sharingType = .none
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.isReleasedWhenClosed = false
        }
        frameWindow.ignoresMouseEvents = true
        let border = NSView(frame: NSRect(origin: .zero, size: frameWindow.frame.size))
        border.wantsLayer = true
        border.layer?.borderWidth = 2
        border.layer?.borderColor = NSColor.systemRed.cgColor
        frameWindow.contentView = border

        button.target = self
        button.action = #selector(stop)
        button.bezelStyle = .rounded
        button.bezelColor = .systemRed
        button.frame = NSRect(x: 0, y: 0, width: 150, height: 32)
        panel.contentView = button
        // Below the region; above it when there is no room; else inside its top right corner.
        let screen = NSScreen.screens.first { $0.frame.intersects(region) }?.visibleFrame ?? region
        var origin = NSPoint(x: region.midX - 75, y: region.minY - 42)
        if origin.y < screen.minY { origin.y = region.maxY + 10 }
        if origin.y + 32 > screen.maxY { origin = NSPoint(x: region.maxX - 160, y: region.maxY - 42) }
        panel.setFrameOrigin(origin)

        frameWindow.orderFrontRegardless()
        panel.orderFrontRegardless()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() { button.title = "■ Stop · \(recorder?.elapsed ?? "")" }

    @objc private func stop() { recorder?.stop() }

    func close() {
        timer?.invalidate()
        frameWindow.close()
        panel.close()
    }
}

/// Lets the person drag a rectangle on any screen. The screens go dim, the rectangle
/// stays clear, and Escape cancels.
final class RegionPicker {
    private static var current: RegionPicker?
    private var windows: [NSWindow] = []
    private let completion: (NSRect?) -> Void

    /// `completion` gets the rectangle in Cocoa screen coordinates, or nil when cancelled
    /// or when the rectangle is too small to be meant.
    static func pick(_ completion: @escaping (NSRect?) -> Void) {
        current?.end(nil)
        current = RegionPicker(completion)
    }

    private init(_ completion: @escaping (NSRect?) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            let window = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onDone = { [weak self] rect in self?.end(rect) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func end(_ rect: NSRect?) {
        windows.forEach { $0.close() }
        windows = []
        if Self.current === self { Self.current = nil }
        completion(rect.flatMap { $0.width >= 16 && $0.height >= 16 ? $0 : nil })
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class PickerView: NSView {
    var onDone: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var selection: NSRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        guard let selection else {
            let hint = "Drag over the region to record · Esc cancels" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attributes)
            hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
            return
        }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1
        path.stroke()
        let label = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
        label.draw(at: NSPoint(x: selection.minX, y: selection.maxY + 4),
                   withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection, let window else { return onDone?(nil) ?? () }
        onDone?(window.convertToScreen(convert(selection, to: nil)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?(nil) } else { super.keyDown(with: event) }
    }
}
