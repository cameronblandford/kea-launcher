import AppKit
import ServiceManagement

/// Launch at login through a LaunchAgent. launchd starts agents as soon as the login
/// session exists, well before the throttled "Open at Login" items, so the hotkey is
/// ready almost immediately after boot.
enum LoginItem {
    static let label = "directory.kea.launcher.agent"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func toggle() {
        if isEnabled {
            // Takes effect at the next login. A bootout here would kill the running app.
            try? FileManager.default.removeItem(at: plistURL)
        } else {
            write()
        }
        // The old SMAppService login item would start a second, later copy.
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        Log.write("launch at login: \(isEnabled)")
    }

    /// Keeps the agent pointed at the current bundle after the app moves.
    static func refreshIfNeeded() {
        guard isEnabled, let exe = Bundle.main.executablePath,
              let dict = NSDictionary(contentsOf: plistURL),
              (dict["ProgramArguments"] as? [String])?.first != exe else { return }
        write()
    }

    private static func write() {
        guard let exe = Bundle.main.executablePath else { return }
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            // Relaunch after a crash, but stay quit after Quit.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            // Settings > Save relaunches through a helper shell that must outlive the app.
            "AbandonProcessGroup": true,
        ]
        if let id = Bundle.main.bundleIdentifier { plist["AssociatedBundleIdentifiers"] = [id] }
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            Log.write("launch at login failed: \(error)")
        }
    }
}
