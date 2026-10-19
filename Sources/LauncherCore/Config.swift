import Foundation

/// `~/.launcher/config.json`. Every key is optional. A missing key, or a value of the
/// wrong type, gets its default; the other keys still load.
public struct Config: Codable, Equatable {
    public struct FileSearch: Codable, Equatable {
        public var enabled: Bool = true
        public var scopes: [String] = ["~"]
        public var maxResults: Int = 20

        public init() {}

        enum CodingKeys: String, CodingKey { case enabled, scopes, maxResults }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
            scopes = (try? c.decodeIfPresent([String].self, forKey: .scopes)) ?? ["~"]
            maxResults = (try? c.decodeIfPresent(Int.self, forKey: .maxResults)) ?? 20
        }
    }

    public var hotkey: String = "option+space"
    public var appFolders: [String] = Config.defaultAppFolders
    public var fileSearch: FileSearch = FileSearch()
    public var maxResults: Int = 12
    /// Text shown in the empty search field.
    public var placeholder: String = "Search"
    /// Keyword to URL template. `{query}` is replaced with the encoded search text.
    public var webSearches: [String: String] = Config.defaultWebSearches
    /// Keywords that trigger the dictionary lookup.
    public var defineKeywords: [String] = ["define", "def"]
    public var clipboard: Clipboard = Clipboard()
    /// Folders offered by name in search; Return opens them in Finder.
    public var folders: [String] = Config.defaultFolders
    public var calendar: CalendarSettings = CalendarSettings()
    public var appearance: Appearance = Appearance()
    public var zones: Zones = Zones()
    public var weather: WeatherSettings = WeatherSettings()
    public var terminal: TerminalSettings = TerminalSettings()
    public var commands: CommandSettings = CommandSettings()
    public var tz: TimeZoneSettings = TimeZoneSettings()
    public var alerts: Alerts = Alerts()
    public var autoclick: AutoClick = AutoClick()
    public var hyperKey: HyperKey = HyperKey()
    /// The sections of the personal features (empty in the public build). Their keys are
    /// at the top level of the file, like the ones above.
    public var personal: PersonalConfig = PersonalConfig()

    /// `tz` alone lists the time now in these places (city names or abbreviations).
    public struct TimeZoneSettings: Codable, Equatable {
        public var favorites: [String] = ["sf", "nyc", "london", "tokyo"]
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            favorites = (try? c.decodeIfPresent([String].self, forKey: .favorites)) ?? ["sf", "nyc", "london", "tokyo"]
        }
    }

    /// Meeting alerts: a full-screen alert before each calendar event (`alerts`).
    public struct Alerts: Codable, Equatable {
        public var enabled = true
        /// Minutes before the start. 0 alerts at the start only.
        public var leadMinutes: Double = 1
        /// A second alert at the start time.
        public var alertAtStart = false
        public var snoozeMinutes: Double = 1
        /// A system sound name (Glass, Ping, Submarine, …); empty for none.
        public var sound = "Glass"
        public var skipAllDay = true
        public var skipDeclined = true
        /// Alert only for events with at least one other attendee.
        public var requireAttendees = false
        /// Calendar titles that never alert.
        public var ignoreCalendars: [String] = []
        public init() {}
        enum CodingKeys: String, CodingKey { case enabled, leadMinutes, alertAtStart, snoozeMinutes, sound, skipAllDay, skipDeclined, requireAttendees, ignoreCalendars }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
            leadMinutes = max(0, (try? c.decodeIfPresent(Double.self, forKey: .leadMinutes)) ?? 1)
            alertAtStart = (try? c.decodeIfPresent(Bool.self, forKey: .alertAtStart)) ?? false
            snoozeMinutes = max(0.25, (try? c.decodeIfPresent(Double.self, forKey: .snoozeMinutes)) ?? 1)
            sound = (try? c.decodeIfPresent(String.self, forKey: .sound)) ?? "Glass"
            skipAllDay = (try? c.decodeIfPresent(Bool.self, forKey: .skipAllDay)) ?? true
            skipDeclined = (try? c.decodeIfPresent(Bool.self, forKey: .skipDeclined)) ?? true
            requireAttendees = (try? c.decodeIfPresent(Bool.self, forKey: .requireAttendees)) ?? false
            ignoreCalendars = (try? c.decodeIfPresent([String].self, forKey: .ignoreCalendars)) ?? []
        }

        public var rules: MeetingAlertRules {
            var r = MeetingAlertRules()
            r.leadMinutes = leadMinutes
            r.alertAtStart = alertAtStart
            r.skipAllDay = skipAllDay
            r.skipDeclined = skipDeclined
            r.requireAttendees = requireAttendees
            r.ignoreCalendars = ignoreCalendars
            return r
        }
    }

    /// Which keyword commands are off. Each entry is a command id (`weather`, `2048`,
    /// `tidy`; the list is in Settings and in Commands.swift) or one of its keywords.
    public struct CommandSettings: Codable, Equatable {
        public var disabled: [String] = []
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            disabled = (try? c.decodeIfPresent([String].self, forKey: .disabled)) ?? []
        }
    }

    public var imageEditor: ImageEditorSettings = ImageEditorSettings()

    /// `ie`: the font for text labels. Empty uses SF Rounded.
    public struct ImageEditorSettings: Codable, Equatable {
        public var font = ""
        public init() {}
        enum CodingKeys: String, CodingKey { case font }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            font = (try? c.decodeIfPresent(String.self, forKey: .font)) ?? ""
        }
    }

    /// `weather`. An empty `location` means Location Services; `units` is auto, metric or imperial.
    public struct WeatherSettings: Codable, Equatable {
        public var keyword: String = "weather"
        public var location: String = ""
        public var units: String = "auto"
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keyword = (try? c.decodeIfPresent(String.self, forKey: .keyword)) ?? "weather"
            location = (try? c.decodeIfPresent(String.self, forKey: .location)) ?? ""
            units = (try? c.decodeIfPresent(String.self, forKey: .units)) ?? "auto"
        }
    }

    /// `t <command>` runs the command in a new window of `app` (a bundle id): Ghostty or Terminal.
    public struct TerminalSettings: Codable, Equatable {
        public var keyword: String = "t"
        public var app: String = TerminalLaunch.ghostty
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keyword = (try? c.decodeIfPresent(String.self, forKey: .keyword)) ?? "t"
            app = (try? c.decodeIfPresent(String.self, forKey: .app)) ?? TerminalLaunch.ghostty
        }
    }

    /// Window zones. Each display gets the layout of the first entry whose `match`
    /// fits it: `builtin`, `portrait`, `landscape`, `main`, or part of the display name.
    public struct Zones: Codable, Equatable {
        public struct Display: Codable, Equatable {
            public var match: String
            public var layout: String
            public init(match: String, layout: String) { self.match = match; self.layout = layout }
        }
        public var enabled: Bool = true
        public var gap: Double = 8
        /// Focus view size, as a share of the display.
        public var focusWidth: Double = 0.6
        public var focusHeight: Double = 0.85
        public var keys: [String: String] = Zones.defaultKeys
        public var displays: [Display] = Zones.defaultDisplays
        /// Hold Shift while dragging a window to show the zones and drop the window in one.
        public var dropZones: Bool = true

        public static let defaultKeys = [
            "left": "command+shift+left", "right": "command+shift+right",
            "up": "command+shift+up", "down": "command+shift+down",
        ]
        public static let defaultDisplays = [
            Display(match: "builtin", layout: "cols 2"),
            Display(match: "portrait", layout: "rows 3"),
            Display(match: "landscape", layout: "cols(zone, rows 2)"),
        ]

        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
            gap = (try? c.decodeIfPresent(Double.self, forKey: .gap)) ?? 8
            focusWidth = (try? c.decodeIfPresent(Double.self, forKey: .focusWidth)) ?? 0.6
            focusHeight = (try? c.decodeIfPresent(Double.self, forKey: .focusHeight)) ?? 0.85
            keys = (try? c.decodeIfPresent([String: String].self, forKey: .keys)) ?? Zones.defaultKeys
            displays = (try? c.decodeIfPresent([Display].self, forKey: .displays)) ?? Zones.defaultDisplays
            dropZones = (try? c.decodeIfPresent(Bool.self, forKey: .dropZones)) ?? true
        }
    }

    public struct Appearance: Codable, Equatable {
        public var theme: String = "System"
        public var accent: String = ""        // hex, overrides the preset
        public var background: String = ""    // hex, overrides the preset
        public var opacity: Double = 0        // 0 keeps the preset's tint strength
        public var fontSize: Double = 24
        /// Open animation. Unset means on for the Opal themes and off for the rest.
        public var animate: Bool?
        public init() {}
        enum CodingKeys: String, CodingKey { case theme, accent, background, opacity, fontSize, animate }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            theme = (try? c.decodeIfPresent(String.self, forKey: .theme)) ?? "System"
            accent = (try? c.decodeIfPresent(String.self, forKey: .accent)) ?? ""
            background = (try? c.decodeIfPresent(String.self, forKey: .background)) ?? ""
            opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? 0
            fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? 24
            animate = try? c.decodeIfPresent(Bool.self, forKey: .animate)
        }
    }

    public struct CalendarSettings: Codable, Equatable {
        public var keyword: String = "cal"
        /// Calendar name for new events; empty means the system default.
        public var calendar: String = ""
        public init() {}
        enum CodingKeys: String, CodingKey { case keyword, calendar }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keyword = (try? c.decodeIfPresent(String.self, forKey: .keyword)) ?? "cal"
            calendar = (try? c.decodeIfPresent(String.self, forKey: .calendar)) ?? ""
        }
    }

    public static let defaultFolders = ["/Applications", "~/Applications", "~/Downloads", "~/Desktop", "~/Documents"]

    public struct Clipboard: Codable, Equatable {
        public var keyword: String = "cb"
        public var limit: Int = 100
        public init() {}
        enum CodingKeys: String, CodingKey { case keyword, limit }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keyword = (try? c.decodeIfPresent(String.self, forKey: .keyword)) ?? "cb"
            limit = (try? c.decodeIfPresent(Int.self, forKey: .limit)) ?? 100
        }
    }

    public static let defaultWebSearches = [
        "g": "https://www.google.com/search?q={query}",
        "c": "https://claude.ai/new?q={query}",
        "gpt": "https://chatgpt.com/?q={query}",
    ]

    public static let defaultAppFolders = [
        "/Applications",
        "~/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications",
    ]

    public init() {}

    enum CodingKeys: String, CodingKey, CaseIterable { case hotkey, appFolders, fileSearch, maxResults, webSearches, defineKeywords, clipboard, placeholder, folders, calendar, appearance, zones, weather, terminal, imageEditor, commands, tz, alerts, autoclick, hyperKey }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = (try? c.decodeIfPresent(String.self, forKey: .hotkey)) ?? "option+space"
        appFolders = (try? c.decodeIfPresent([String].self, forKey: .appFolders)) ?? Config.defaultAppFolders
        fileSearch = (try? c.decodeIfPresent(FileSearch.self, forKey: .fileSearch)) ?? FileSearch()
        maxResults = (try? c.decodeIfPresent(Int.self, forKey: .maxResults)) ?? 12
        placeholder = (try? c.decodeIfPresent(String.self, forKey: .placeholder)) ?? "Search"
        webSearches = (try? c.decodeIfPresent([String: String].self, forKey: .webSearches)) ?? Config.defaultWebSearches
        defineKeywords = (try? c.decodeIfPresent([String].self, forKey: .defineKeywords)) ?? ["define", "def"]
        clipboard = (try? c.decodeIfPresent(Clipboard.self, forKey: .clipboard)) ?? Clipboard()
        folders = (try? c.decodeIfPresent([String].self, forKey: .folders)) ?? Config.defaultFolders
        calendar = (try? c.decodeIfPresent(CalendarSettings.self, forKey: .calendar)) ?? CalendarSettings()
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? Appearance()
        zones = (try? c.decodeIfPresent(Zones.self, forKey: .zones)) ?? Zones()
        weather = (try? c.decodeIfPresent(WeatherSettings.self, forKey: .weather)) ?? WeatherSettings()
        terminal = (try? c.decodeIfPresent(TerminalSettings.self, forKey: .terminal)) ?? TerminalSettings()
        commands = (try? c.decodeIfPresent(CommandSettings.self, forKey: .commands)) ?? CommandSettings()
        tz = (try? c.decodeIfPresent(TimeZoneSettings.self, forKey: .tz)) ?? TimeZoneSettings()
        alerts = (try? c.decodeIfPresent(Alerts.self, forKey: .alerts)) ?? Alerts()
        autoclick = (try? c.decodeIfPresent(AutoClick.self, forKey: .autoclick)) ?? AutoClick()
        hyperKey = (try? c.decodeIfPresent(HyperKey.self, forKey: .hyperKey)) ?? HyperKey()
        imageEditor = (try? c.decodeIfPresent(ImageEditorSettings.self, forKey: .imageEditor)) ?? ImageEditorSettings()
        personal = (try? PersonalConfig(from: decoder)) ?? PersonalConfig()
    }

    /// Written by hand so that the personal sections go into the same object as the rest.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hotkey, forKey: .hotkey)
        try c.encode(appFolders, forKey: .appFolders)
        try c.encode(fileSearch, forKey: .fileSearch)
        try c.encode(maxResults, forKey: .maxResults)
        try c.encode(placeholder, forKey: .placeholder)
        try c.encode(webSearches, forKey: .webSearches)
        try c.encode(defineKeywords, forKey: .defineKeywords)
        try c.encode(clipboard, forKey: .clipboard)
        try c.encode(folders, forKey: .folders)
        try c.encode(calendar, forKey: .calendar)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(zones, forKey: .zones)
        try c.encode(weather, forKey: .weather)
        try c.encode(terminal, forKey: .terminal)
        try c.encode(commands, forKey: .commands)
        try c.encode(tz, forKey: .tz)
        try c.encode(alerts, forKey: .alerts)
        try c.encode(autoclick, forKey: .autoclick)
        try c.encode(hyperKey, forKey: .hyperKey)
        try c.encode(imageEditor, forKey: .imageEditor)
        try personal.encode(to: encoder)
    }

    public static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }
}
