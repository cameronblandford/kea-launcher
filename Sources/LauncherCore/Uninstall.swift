import Foundation

/// The rules of `uninstall`: which files in the Library folders belong to an app.
public enum Uninstall {
    /// The folders in `~/Library` where apps keep their files, in the order they are shown.
    public static let libraryFolders = ["Application Support", "Caches", "Preferences", "Saved Application State", "Logs", "WebKit",
                                        "HTTPStorages", "Cookies", "Containers", "Application Scripts", "LaunchAgents"]

    /// Endings that a file of an app has after the app's name or bundle id.
    private static let suffixes = [".plist", ".savedState", ".binarycookies"]

    /// True when a file or folder name in a Library folder belongs to the app. It
    /// belongs when the name is the bundle id, starts with the bundle id and a dot
    /// (`com.x.app.helper`), or is the app's name (with or without its spaces). Case
    /// does not matter. A name or id shorter than 3 characters matches nothing: a wrong
    /// match here would put another app's data in the Trash.
    public static func belongs(_ item: String, appName: String, bundleId: String?) -> Bool {
        var name = item.lowercased()
        for suffix in suffixes where name.hasSuffix(suffix.lowercased()) {
            name = String(name.dropLast(suffix.count))
            break
        }
        if let id = bundleId?.lowercased(), id.count >= 3, id.contains(".") {
            if name == id || name.hasPrefix(id + ".") { return true }
        }
        let app = appName.lowercased()
        guard app.count >= 3 else { return false }
        return name == app || name == app.replacingOccurrences(of: " ", with: "")
    }

    /// The name of the folder an app may keep directly in the home folder: `.ollama` for
    /// "Ollama", `.docker` for "Docker". Nil for a name that is short or has other characters.
    public static func homeFolder(appName: String) -> String? {
        let name = appName.lowercased().replacingOccurrences(of: " ", with: "")
        guard name.count >= 4, name.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "." + name
    }

    /// True for an app that `uninstall` must not offer: a part of macOS, or Kea.
    public static func isProtected(path: String, bundleId: String?) -> Bool {
        if path.hasPrefix("/System/") { return true }
        guard let id = bundleId?.lowercased() else { return false }
        return id.hasPrefix("com.apple.") || id == "directory.kea.launcher"
    }
}
