import AppKit
import LauncherCore

/// What a command gets when the search box holds one of its keywords.
struct CommandContext {
    /// The keyword as typed (a command can have several).
    let keyword: String
    /// The text after the keyword.
    let argument: String
    let frecency: Frecency
    /// Call when the rows changed on their own (an answer arrived from the network or a
    /// model). The coordinator asks for the rows again if this query is still on screen.
    let refresh: () -> Void
}

/// One keyword feature of Kea: `weather`, `rate`, `tidy`, …
///
/// Each feature describes itself with one of these, next to its own code, and
/// `SearchCoordinator.buildCommands()` lists them. The coordinator, `help`, and the
/// Settings checkboxes all read that list, so a new command is one file plus one line.
/// A command whose `id` or keyword is in `commands.disabled` in config is left out
/// everywhere: its keyword becomes normal search text again.
struct KeaCommand {
    /// Stable name for config (`commands.disabled`) and Settings. Never rename one.
    let id: String
    /// For people: "Weather", "Disk Map".
    let name: String
    let keywords: Set<String>
    /// Lines for `help`. Empty for a command that should not be listed there.
    var help: [HelpProvider.Entry] = []
    /// Refresh the rows every `interval` seconds while `isLive()` is true (and once more
    /// after it turns false, to show the final state).
    var live: (interval: TimeInterval, isLive: () -> Bool)? = nil
    /// Rows for plain search (no keyword), ranked with apps and files by the coordinator.
    var search: ((_ term: String, _ frecency: Frecency) -> [Result])? = nil
    /// One answer row for plain search that is pinned above everything, like the
    /// calculator's: return it only when the whole text is clearly meant for this command
    /// (`3pm pst in nyc`). The first command that answers wins.
    var instant: ((_ term: String) -> Result?)? = nil
    /// Rows when the keyword is typed.
    let results: (CommandContext) -> [Result]

    /// A command is off when its id or any of its keywords is listed.
    func isDisabled(by list: [String]) -> Bool {
        let off = Set(list.map { $0.lowercased() })
        return off.contains(id.lowercased()) || !keywords.isDisjoint(with: off)
    }
}
