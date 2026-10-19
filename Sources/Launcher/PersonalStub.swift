import AppKit
import LauncherCore

/// The seam to the personal features, which are not in the public repository. Kea's own
/// build has `Personal/Personal.swift` instead of this file (see Package.swift), with the
/// same functions. The public code calls nothing else of the personal code.
final class Personal {
    /// Called when `statusTitle` changed, so the menu bar can follow.
    var onChange: (() -> Void)?

    init(config: Config, timers: TimerManager, zones: ZoneManager) {}

    /// More commands for the list in Commands.swift. Each one goes in before the command
    /// with the id `before`.
    func commands(for coordinator: SearchCoordinator) -> [(before: String, command: KeaCommand)] { [] }

    /// More rows for `e`, and what `ie <words>` does. Nil means the plain command.
    var emojiAssistant: EmojiAssistant? { nil }
    var imageAssistant: ImageEditAssistant? { nil }

    /// A title for the menu bar item while something waits for the user. A running timer shows before it.
    var statusTitle: String? { nil }

    /// The menu item that goes with `statusTitle`. It is at the top of the menu while the title shows.
    var statusMenuItem: NSMenuItem? { nil }

    /// Starts the indexes that search reads. The app and `--query` call it once.
    func startIndexing() {}

    /// Reads again what can change between two uses of the panel; part of `SearchCoordinator.refreshRecent`.
    func refresh() {}

    /// Fills caches before the first keystroke; part of `SearchCoordinator.warmUp`.
    func warmUp(frecency: Frecency) {}

    /// Starts background work and hooks, once, when the app launches. Not for `--query`.
    func start() {}

    /// Rows for the "Keywords" section of the Settings form. `place` says where they go:
    /// after the rows of "clipboard" or of "define". The three functions make the form's
    /// usual label, hint, and multi-line box.
    static func settingsRows(after place: String, label: (String) -> NSView, hint: (String) -> NSView,
                             scroll: (NSTextView, CGFloat) -> NSView) -> [[NSView]] { [] }

    /// Puts the config's values into those rows.
    static func loadSettings(from config: Config) {}

    /// Reads those rows into the config. Returns the text of the first problem, or nil.
    static func saveSettings(to config: inout Config) -> String? { nil }

    /// The multi-line boxes in those rows (`--settings-snapshot` lays them out).
    static var settingsTextViews: [NSTextView] { [] }

    /// More command-line flags for main.swift. True means the flag was one of these and is done.
    static func handleArguments(_ args: [String]) -> Bool { false }
}
