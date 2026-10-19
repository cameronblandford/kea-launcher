import AppKit
import LauncherCore

enum ResultAction {
    case openPath(String)
    case item(ItemAction)
    case runScript(URL, argument: String)
    case custom(() -> Void)
    /// Open a URL with a specific app (used for sites whose desktop app handles https links).
    case openWith(URL, appPath: String)
    /// Replace the search text (used by help to jump to a keyword).
    case fill(String)
    case none
}

struct Result {
    var id: String
    var title: String
    var subtitle: String?
    var icon: NSImage?
    var action: ResultAction
    /// Path used by "reveal in Finder" (Cmd+Return), when it makes sense.
    var revealPath: String?
    /// Extra text that should match with lower weight, like a command keyword.
    var keyword: String?
    /// Cmd+Delete on the row runs this, then the list refreshes.
    var onDelete: (() -> Void)?
    /// Let the subtitle wrap over several lines (definitions, etymologies).
    var expanded = false
    /// A shortcut drawn as key caps at the right edge of the row, one string for each key.
    var keys: [String] = []
}
