import AppKit
import LauncherCore

/// Deep links into System Settings. Matched by name in the normal search, or listed by the `settings` keyword.
enum SettingsPanes {
    struct Pane {
        var name: String
        var id: String
        var aliases: String = ""
        var url: String { "x-apple.systempreferences:\(id)" }
    }

    static let panes: [Pane] = [
        Pane(name: "Wi-Fi", id: "com.apple.wifi-settings-extension", aliases: "wifi wireless network"),
        Pane(name: "Bluetooth", id: "com.apple.BluetoothSettings"),
        Pane(name: "Network", id: "com.apple.Network-Settings.extension", aliases: "vpn dns ethernet"),
        Pane(name: "Displays", id: "com.apple.Displays-Settings.extension", aliases: "display monitor resolution brightness"),
        Pane(name: "Sound", id: "com.apple.Sound-Settings.extension", aliases: "audio output input volume"),
        Pane(name: "Privacy & Security", id: "com.apple.settings.PrivacySecurity.extension", aliases: "privacy security permissions"),
        Pane(name: "Full Disk Access", id: "com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles", aliases: "privacy files"),
        Pane(name: "Accessibility Access", id: "com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility", aliases: "privacy permissions"),
        Pane(name: "Screen Recording Access", id: "com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture", aliases: "privacy permissions"),
        Pane(name: "General", id: "com.apple.settings.General"),
        Pane(name: "Software Update", id: "com.apple.Software-Update-Settings.extension", aliases: "update upgrade macos"),
        Pane(name: "Login Items", id: "com.apple.LoginItems-Settings.extension", aliases: "startup launch at login"),
        Pane(name: "Appearance", id: "com.apple.Appearance-Settings.extension", aliases: "dark mode accent color theme"),
        Pane(name: "Desktop & Dock", id: "com.apple.Desktop-Settings.extension", aliases: "dock stage manager hot corners"),
        Pane(name: "Wallpaper", id: "com.apple.Wallpaper-Settings.extension", aliases: "background"),
        Pane(name: "Screen Saver", id: "com.apple.ScreenSaver-Settings.extension"),
        Pane(name: "Lock Screen", id: "com.apple.Lock-Screen-Settings.extension", aliases: "password sleep"),
        Pane(name: "Notifications", id: "com.apple.Notifications-Settings.extension", aliases: "alerts"),
        Pane(name: "Focus", id: "com.apple.Focus-Settings.extension", aliases: "do not disturb dnd"),
        Pane(name: "Keyboard", id: "com.apple.Keyboard-Settings.extension", aliases: "shortcuts input sources text replacement"),
        Pane(name: "Trackpad", id: "com.apple.Trackpad-Settings.extension", aliases: "gestures"),
        Pane(name: "Mouse", id: "com.apple.Mouse-Settings.extension"),
        Pane(name: "Battery", id: "com.apple.Battery-Settings.extension", aliases: "energy power"),
        Pane(name: "Accessibility", id: "com.apple.Accessibility-Settings.extension", aliases: "zoom voiceover"),
        Pane(name: "Users & Groups", id: "com.apple.Users-Groups-Settings.extension", aliases: "accounts"),
        Pane(name: "Date & Time", id: "com.apple.Date-Time-Settings.extension", aliases: "clock timezone"),
        Pane(name: "Storage", id: "com.apple.settings.Storage", aliases: "disk space"),
        Pane(name: "Printers & Scanners", id: "com.apple.Print-Scan-Settings.extension", aliases: "printer"),
        Pane(name: "Control Center", id: "com.apple.ControlCenter-Settings.extension", aliases: "menu bar"),
        Pane(name: "Siri", id: "com.apple.Siri-Settings.extension", aliases: "apple intelligence"),
        Pane(name: "Time Machine", id: "com.apple.Time-Machine-Settings.extension", aliases: "backup"),
        Pane(name: "Game Controllers", id: "com.apple.Game-Controller-Settings.extension"),
    ]

    static let keyword = "settings"

    private static var icon: NSImage {
        IconLoader.shared.icon(forPath: "/System/Applications/System Settings.app")
    }

    private static func result(_ p: Pane) -> Result {
        Result(id: "settings:\(p.id)", title: "\(p.name) Settings", subtitle: "System Settings › \(p.name)",
               icon: icon, action: .item(.open(p.url)), keyword: p.aliases)
    }

    /// Panes that match a free-text query. The name must match well; aliases match at lower weight.
    static func results(for query: String, frecency: Frecency) -> [Result] {
        let rankables = panes.map { Rankable(id: "settings:\($0.id)", text: $0.name, secondary: $0.aliases) }
        let byID = Dictionary(uniqueKeysWithValues: panes.map { ("settings:\($0.id)", $0) })
        return Ranker.rank(rankables, query: query, frecency: frecency)
            .filter { $0.score > 250 }   // only prefix/word-prefix quality matches in the general list
            .prefix(4)
            .compactMap { byID[$0.id].map(result) }
    }

    /// Every pane, filtered, for the `settings` keyword.
    static func list(filter: String, frecency: Frecency) -> [Result] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        if f.isEmpty { return panes.map(result) }
        let rankables = panes.map { Rankable(id: "settings:\($0.id)", text: $0.name, secondary: $0.aliases) }
        let byID = Dictionary(uniqueKeysWithValues: panes.map { ("settings:\($0.id)", $0) })
        return Ranker.rank(rankables, query: f, frecency: frecency).compactMap { byID[$0.id].map(result) }
    }
}

extension SettingsPanes {
    static var command: KeaCommand {
        KeaCommand(id: "settings", name: "System Settings Panes", keywords: [keyword],
                   help: [.init(keyword: "settings", summary: "System Settings panes", example: "settings wifi")],
                   search: { results(for: $0, frecency: $1) },
                   results: { list(filter: $0.argument, frecency: $0.frecency) })
    }
}
