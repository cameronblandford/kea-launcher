import AppKit
import LauncherCore

/// `conv` converts the files that are selected in Finder: an image to JPEG, PNG or HEIC,
/// or to a smaller size, and a video to MP4 or GIF. `conv` lists what is possible for the
/// selection; `conv jpg`, `conv gif` or `conv 1600` names it. The new file goes next to
/// the original, which is not changed.
final class ConvertCommand {
    static let shared = ConvertCommand()

    private var selection: [String] = []
    private var fetchedAt: Date?
    private var fetching = false
    private(set) var busy: String?

    private static func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    /// The POSIX paths of the Finder selection. Finder is asked through `osascript`,
    /// which takes too long for a keystroke, so this runs off the main thread.
    private static func finderSelection() -> [String] {
        // `KEA_CONV_FILES=a:b` stands in for Finder in a check from the shell.
        if let fixed = ProcessInfo.processInfo.environment["KEA_CONV_FILES"] { return fixed.split(separator: ":").map(String.init) }
        guard Bundle.main.bundleIdentifier != nil else { return [] }
        let script = """
        tell application "Finder"
            set out to ""
            repeat with f in (get selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """
        let result = Proc.run("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else {
            Log.write("conv: could not read the Finder selection: \(result.output.prefix(200))")
            return []
        }
        return result.output.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }
    }

    private func loadSelection(then refresh: @escaping () -> Void) {
        if fetching { return }
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < 2 { return }
        fetching = true
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = Self.finderSelection()
            DispatchQueue.main.async {
                self.selection = paths
                self.fetchedAt = Date()
                self.fetching = false
                refresh()
            }
        }
    }

    private static func describe(_ paths: [String], _ target: Convert.Target) -> String {
        let noun = target.kind == .image ? "image" : "video"
        let what = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) \(noun)s"
        if case .resize(let side) = target { return "Make \(what) at Most \(side) px Wide or High" }
        return "Convert \(what) to \(target.label)"
    }

    func results(_ context: CommandContext) -> [Result] {
        if let busy { return [Result(id: "conv:busy", title: "\(busy)…", subtitle: "The new files go next to the originals", icon: Self.icon("arrow.triangle.2.circlepath"), action: .none)] }
        loadSelection(then: context.refresh)
        let example = "Images: jpg, png, heic, or a size such as 1600 · videos: mp4, gif"
        let typed = context.argument.trimmingCharacters(in: .whitespaces)
        var targets: [Convert.Target]
        if typed.isEmpty {
            targets = Convert.targets(forPaths: selection)
        } else if let target = Convert.target(from: typed) {
            targets = [target]
        } else {
            return [Result(id: "conv:error", title: "Could not read \(typed)", subtitle: example, icon: Self.icon("arrow.triangle.2.circlepath"), action: .none)]
        }
        guard !selection.isEmpty else {
            return [Result(id: "conv:none", title: fetchedAt == nil ? "Reading the Finder selection…" : "Select images or videos in Finder first",
                           subtitle: example, icon: Self.icon("arrow.triangle.2.circlepath"), action: .none)]
        }
        targets = targets.filter { !Convert.applicable(selection, to: $0).isEmpty }
        guard !targets.isEmpty else {
            return [Result(id: "conv:nothing", title: typed.isEmpty ? "The selected files are not images or videos" : "No selected file can become \(Convert.target(from: typed)?.label ?? typed)",
                           subtitle: example, icon: Self.icon("arrow.triangle.2.circlepath"), action: .none)]
        }
        return targets.map { target in
            let files = Convert.applicable(selection, to: target)
            let names = files.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + (files.count > 3 ? ", …" : "")
            return Result(id: "conv:\(target.label)", title: Self.describe(files, target),
                          subtitle: "\(names) · the new file goes next to the original",
                          icon: Self.icon(target.kind == .image ? "photo" : "film"),
                          action: .custom { [weak self] in self?.start(target, files) })
        }
    }

    /// Converts each file and returns the new paths. Blocks; call it off the main thread.
    static func convert(_ files: [String], to target: Convert.Target) -> [String] {
        files.compactMap { path in
            let output = Convert.outputPath(for: path, target: target) { FileManager.default.fileExists(atPath: $0) }
            return MediaConvert.run(URL(fileURLWithPath: path), to: URL(fileURLWithPath: output), target: target) ? output : nil
        }
    }

    private func start(_ target: Convert.Target, _ files: [String]) {
        guard busy == nil else { return }
        busy = Self.describe(files, target).replacingOccurrences(of: "Convert", with: "Converting").replacingOccurrences(of: "Make", with: "Making")
        DispatchQueue.global(qos: .userInitiated).async {
            let made = Self.convert(files, to: target)
            DispatchQueue.main.async {
                self.busy = nil
                self.fetchedAt = nil
                Log.write("conv: \(made.count) of \(files.count) files to \(target.label)")
                if made.isEmpty {
                    Notify.post(title: "Could not convert", body: "See ~/.launcher/launcher.log")
                } else {
                    Notify.post(title: made.count == files.count ? "Converted to \(target.label)" : "Converted \(made.count) of \(files.count) files",
                                body: made.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    NSWorkspace.shared.activateFileViewerSelecting(made.map { URL(fileURLWithPath: $0) })
                }
            }
        }
    }

    var command: KeaCommand {
        KeaCommand(id: "conv", name: "Convert Files", keywords: ["conv"],
                   help: [.init(keyword: "conv", summary: "Convert the files selected in Finder: images to jpg, png, heic or a size; videos to mp4 or gif", example: "conv jpg · conv 1600 · conv gif")],
                   live: (0.5, { [unowned self] in busy != nil }),
                   results: { [unowned self] in results($0) })
    }
}
