import AppKit
import LauncherCore

/// Turns search-box text into a ranked result list, merging sync providers
/// (apps, commands) with async ones (files, list scripts).
final class SearchCoordinator {
    let apps: AppIndex
    let files: FileSearch?
    let scripts: ScriptCommands
    var frecency: Frecency
    let maxResults: Int
    let webSearches: [String: String]
    let defineKeywords: Set<String>
    let clipboard: ClipboardHistory
    let clipboardKeyword: String
    let rates: RatesStore
    let timers = TimerManager()
    let caffeinate = Caffeinate()
    let zones: ZoneManager
    let keyboardLock = KeyboardLock()
    let autoClicker: AutoClicker
    let hyperKey: HyperKeyManager
    let tidy = TidyCommand()
    let weather: WeatherCommand
    let boot = BootCommand()
    let stats = SystemStats()
    let emoji: EmojiCommand
    let imageEdit: ImageEditCommand
    let snippets = SnippetExpander()
    let menuSearch = MenuSearchCommand()
    /// The personal features (see PersonalStub.swift).
    let personal: Personal
    let config: Config
    private var liveTimer: Timer?
    let folders: [String]
    let calendarStore: CalendarStore
    let calendarKeyword: String
    let meetingAlerts: MeetingAlerter
    var onResults: (([Result]) -> Void)?

    /// The coordinator in use, for code that needs the command list (the Settings window).
    private(set) static weak var current: SearchCoordinator?

    private var debounce: DispatchWorkItem?
    private var generation = 0
    private var recentCache: [Result] = []

    init(apps: AppIndex, files: FileSearch?, scripts: ScriptCommands, frecency: Frecency, config: Config,
         clipboard: ClipboardHistory, rates: RatesStore) {
        self.apps = apps
        self.files = files
        self.scripts = scripts
        self.frecency = frecency
        self.config = config
        zones = ZoneManager(config: config.zones)
        autoClicker = AutoClicker(settings: config.autoclick)
        hyperKey = HyperKeyManager(settings: config.hyperKey)
        self.maxResults = config.maxResults
        self.webSearches = config.webSearches
        self.defineKeywords = Set(config.defineKeywords)
        self.clipboard = clipboard
        self.clipboardKeyword = config.clipboard.keyword
        personal = Personal(config: config, timers: timers, zones: zones)
        self.weather = WeatherCommand(config: config.weather)
        self.rates = rates
        self.folders = config.folders.map(Paths.expand).filter { FileManager.default.fileExists(atPath: $0) }
        self.calendarStore = CalendarStore(preferredCalendar: config.calendar.calendar)
        self.calendarKeyword = config.calendar.keyword
        meetingAlerts = MeetingAlerter(calendar: calendarStore, settings: config.alerts, appearance: config.appearance)
        emoji = EmojiCommand(assistant: personal.emojiAssistant)
        imageEdit = ImageEditCommand(assistant: personal.imageAssistant)
        MarkupRenderer.fontName = config.imageEditor.font
        Self.current = self
    }

    /// A coordinator with nothing started (no indexing, no polling), for checks that only
    /// need the command list or a query.
    static func standalone(config: Config) -> SearchCoordinator {
        let files = config.fileSearch.enabled ? FileSearch(scopes: config.fileSearch.scopes, maxResults: config.fileSearch.maxResults) : nil
        let frecency = (try? Data(contentsOf: Paths.frecency)).flatMap { try? Frecency(data: $0) } ?? Frecency()
        return SearchCoordinator(apps: AppIndex(folders: config.appFolders), files: files, scripts: ScriptCommands(), frecency: frecency,
                                 config: config, clipboard: ClipboardHistory(limit: config.clipboard.limit), rates: RatesStore())
    }

    /// Whether the command with this id is on.
    func isEnabled(_ id: String) -> Bool { commands.contains { $0.id == id } }

    /// Loads today's weather in the background, at most once a day.
    func preloadWeather() {
        if isEnabled("weather") { weather.preloadIfNewDay() }
    }

    private func folderResults(_ term: String) -> [Result] {
        let rankables = folders.map { Rankable(id: "folder:\($0)", text: URL(fileURLWithPath: $0).lastPathComponent) }
        return Ranker.rank(rankables, query: term, frecency: frecency).filter { $0.score > 250 }.prefix(3).map { r in
            let path = String(r.id.dropFirst(7))
            return Result(id: r.id, title: URL(fileURLWithPath: path).lastPathComponent,
                          subtitle: path.replacingOccurrences(of: Paths.home.path, with: "~"),
                          icon: IconLoader.shared.icon(forPath: path), action: .openPath(path), revealPath: path)
        }
    }

    /// Every command, in registry order (see Commands.swift), including disabled ones.
    private(set) lazy var allCommands: [KeaCommand] = {
        let all = buildCommands()
        // Two commands with one keyword: the first in the list wins. Say so in the log.
        var owner: [String: String] = [:]
        for c in all {
            for k in c.keywords {
                if let first = owner[k], first != c.id { Log.write("commands: keyword \"\(k)\" is claimed by \(first) and \(c.id); \(first) wins") }
                else { owner[k] = c.id }
            }
        }
        return all
    }()
    /// The commands that are on: everything not listed in `commands.disabled`.
    private(set) lazy var commands: [KeaCommand] = allCommands.filter { !$0.isDisabled(by: config.commands.disabled) }

    private lazy var allKeywords: Set<String> = commands.reduce(into: Set<String>()) { $0.formUnion($1.keywords) }

    /// Stops any live-refreshing list (stats). Called when the panel hides.
    func cancelLive() {
        generation += 1
        liveTimer?.invalidate(); liveTimer = nil
    }

    func update(text: String) {
        generation += 1
        let gen = generation
        debounce?.cancel()
        files?.cancel()
        liveTimer?.invalidate(); liveTimer = nil

        switch Query.parse(text, listKeywords: allKeywords.union(scripts.listKeywords)) {
        case .command(let keyword, let argument):
            if let command = commands.first(where: { $0.keywords.contains(keyword) }) {
                run(command, keyword: keyword, argument: argument, generation: gen)
                return
            }
            // A list script command: its `run` answers a moment later.
            guard let cmd = scripts.command(forKeyword: keyword) else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.scripts.run(cmd, argument: argument) { results in
                    guard gen == self.generation else { return }
                    self.onResults?(Array(results.prefix(50)))
                }
            }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)

        case .search(let term):
            if term.isEmpty {
                onResults?(cachedRecent())
                return
            }
            let calc = (calculatorResult(term) ?? conversionResult(term) ?? commands.lazy.compactMap { $0.instant?(term) }.first).map { [$0] } ?? []
            let sync = (apps.results(for: term, frecency: frecency, limit: maxResults)
                        + scripts.results(for: term, frecency: frecency)
                        + commands.flatMap { $0.search?(term, frecency) ?? [] }
                        + folderResults(term)
                        + launcherSettingsResult(term))
            let ranked = rankMerged(sync, term: term)
            emit(calc + ranked, term: term, final: !(term.count >= 2 && files != nil))

            guard term.count >= 2, let files else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                files.search(term, frecency: self.frecency) { fileResults in
                    guard gen == self.generation else { return }
                    // Instant rows never move: files are appended below them, ranked among themselves.
                    let shown = Set(ranked.map(\.id))
                    let shownPaths = Set(ranked.compactMap(\.revealPath))
                    let extra = self.rankMerged(fileResults.filter { !shown.contains($0.id) && !shownPaths.contains($0.revealPath ?? "") }, term: term)
                    self.emit(calc + ranked + extra, term: term, final: true)
                }
            }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }

    /// Shows a command's rows, and keeps them fresh: on the command's own `refresh` call,
    /// and on a timer while it says it is live.
    private func run(_ command: KeaCommand, keyword: String, argument: String, generation gen: Int) {
        let quiet = CommandContext(keyword: keyword, argument: argument, frecency: frecency, refresh: {})
        let context = CommandContext(keyword: keyword, argument: argument, frecency: frecency, refresh: { [weak self] in
            guard let self, gen == self.generation else { return }
            self.onResults?(command.results(quiet))
        })
        onResults?(command.results(context))
        guard let live = command.live else { return }
        liveTimer = Timer.scheduledTimer(withTimeInterval: live.interval, repeats: true) { [weak self] t in
            guard let self, gen == self.generation else { t.invalidate(); return }
            // One more refresh after it stops being live, to show the final state.
            let wasLive = live.isLive()
            self.onResults?(command.results(quiet))
            if !wasLive { t.invalidate() }
        }
    }

    /// Caps the list and, once every provider has answered with nothing, offers a web search.
    private func emit(_ results: [Result], term: String, final: Bool) {
        var out = Array(results.prefix(maxResults))
        if out.isEmpty, final, let template = webSearches["g"] ?? webSearches.values.first {
            out = [webResult(keyword: "g", template: template, query: term)]
        }
        onResults?(out)
    }

    private func calculatorResult(_ term: String) -> Result? {
        guard let value = Calculator.evaluate(term) else { return nil }
        let text = Calculator.format(value)
        return Result(id: "calc", title: "= \(text)", subtitle: "Return copies the result",
                      icon: IconLoader.shared.icon(forSpec: "sf:equal.circle"), action: .item(.copy(text)))
    }

    private func launcherSettingsResult(_ term: String) -> [Result] {
        // The app was called Launcher first; both names find it.
        let score = max(FuzzyMatcher.score(query: term, candidate: "Kea Settings") ?? 0,
                        FuzzyMatcher.score(query: term, candidate: "Launcher Settings") ?? 0)
        guard score > 250 else { return [] }
        return [Result(id: "launcher:settings", title: "Kea Settings", subtitle: "Hotkey, keywords, folders, web searches",
                       icon: IconLoader.shared.icon(forSpec: "sf:gearshape"),
                       action: .custom { (NSApp.delegate as? AppDelegate)?.openSettings() }, keyword: "launcher settings preferences config")]
    }

    private func conversionResult(_ term: String) -> Result? {
        guard let c = UnitConverter.convert(term, rates: rates.rates) else { return nil }
        let rounded = (c.value * 10000).rounded() / 10000
        let text = "\(Calculator.format(rounded)) \(c.unit)"
        var subtitle = "Return copies the result"
        if let r = rates.rates, UnitConverter.isCurrency(c.unit.lowercased()), r.rates[c.unit] != nil || c.unit == r.base {
            subtitle += " · ECB rates \(r.date)"
        }
        return Result(id: "convert", title: "= \(text)", subtitle: subtitle,
                      icon: IconLoader.shared.icon(forSpec: "sf:arrow.left.arrow.right"), action: .item(.copy(text)))
    }

    /// Sites that also ship a desktop app. A bare keyword opens the app; a prompt goes to the app
    /// through its own URL scheme when it has one, or by handing it the https link.
    private struct DesktopApp { var name: String; var promptScheme: String? }
    private static let desktopApps: [String: DesktopApp] = [
        "claude.ai": DesktopApp(name: "Claude", promptScheme: "claude://claude.ai/new?q={query}"),
        "chatgpt.com": DesktopApp(name: "ChatGPT", promptScheme: nil),
        "chat.openai.com": DesktopApp(name: "ChatGPT", promptScheme: nil),
        "github.com": DesktopApp(name: "GitHub Desktop", promptScheme: nil),
        "notion.so": DesktopApp(name: "Notion", promptScheme: nil),
        "linear.app": DesktopApp(name: "Linear", promptScheme: nil),
        "slack.com": DesktopApp(name: "Slack", promptScheme: nil),
    ]

    func webResult(keyword: String, template: String, query: String) -> Result {
        let host = URL(string: template)?.host?.replacingOccurrences(of: "www.", with: "") ?? keyword
        let q = query.trimmingCharacters(in: .whitespaces)
        let isAI = host.contains("claude") || host.contains("chatgpt") || host.contains("openai")
        let icon = IconLoader.shared.icon(forSpec: isAI ? "sf:sparkles" : "sf:magnifyingglass")
        if q.isEmpty {
            let origin = URL(string: template).flatMap { u -> String? in
                guard let scheme = u.scheme, let h = u.host else { return nil }
                return "\(scheme)://\(h)"
            } ?? template
            if let d = Self.desktopApps[host], let app = apps.apps.first(where: { $0.name == d.name }) {
                return Result(id: "app:\(app.path)", title: d.name, subtitle: "Open \(d.name) · type text to send a prompt",
                              icon: IconLoader.shared.icon(forPath: app.path), action: .openPath(app.path), revealPath: app.path)
            }
            return Result(id: "web:\(keyword)", title: "Open \(host)", subtitle: isAI ? "Type text to send a prompt" : "Type what to search for",
                          icon: icon, action: .item(.open(origin)))
        }
        guard let webURL = WebSearch.url(template: template, query: q) else {
            return Result(id: "web:\(keyword)", title: "Bad URL template for \(keyword)", subtitle: template, icon: icon, action: .none)
        }
        // Prefer the desktop app when it is installed.
        if let d = Self.desktopApps[host], let app = apps.apps.first(where: { $0.name == d.name }) {
            let action: ResultAction
            if let scheme = d.promptScheme, let u = WebSearch.url(template: scheme, query: q) { action = .item(.open(u.absoluteString)) }
            else { action = .openWith(webURL, appPath: app.path) }
            return Result(id: "web:\(keyword)", title: isAI ? "Ask \(d.name): \"\(q)\"" : "Search \(d.name) for \"\(q)\"",
                          subtitle: "\(d.name) app", icon: IconLoader.shared.icon(forPath: app.path), action: action)
        }
        return Result(id: "web:\(keyword)", title: isAI ? "Ask \(host): \"\(q)\"" : "Search \(host) for \"\(q)\"",
                      subtitle: host, icon: icon, action: .item(.open(webURL.absoluteString)))
    }

    /// Re-scores a mixed set. Apps are what people launch most, so they get a boost;
    /// files only win when they match clearly better. Frecency then orders within each group.
    func rankMerged(_ results: [Result], term: String) -> [Result] {
        let byID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rankables = results.map { Rankable(id: $0.id, text: $0.title, secondary: $0.keyword) }
        let ranked = Ranker.rank(rankables, query: term, frecency: frecency)
        let weighted = ranked.map { r -> Ranked in
            let factor: Double
            if r.id.hasPrefix("app:") { factor = 1.3 }
            else if r.id.hasPrefix("file:") { factor = 0.6 }
            else { factor = 1.0 }
            return Ranked(id: r.id, score: r.score * factor)
        }.sorted { $0.score > $1.score }
        return weighted.compactMap { byID[$0.id] }
    }

    /// Rebuilt after every hide and launch, so opening the panel does no work.
    func refreshRecent() {
        personal.refresh()
        recentCache = recent()
        for r in recentCache { _ = r.icon }
    }

    /// Runs each provider once so icons, symbol images, thumbnails, and the dictionary
    /// service are cached before the first real keystroke.
    func warmUp() {
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = clipboard.results(filter: "")
        personal.warmUp(frecency: frecency)
        _ = DictionaryLookup.result(for: "warm")
        _ = DictionaryLookup.etymologyResults(for: "warm")
        _ = calculatorResult("1+1")
        _ = conversionResult("1 m in cm")
        _ = LoremCommand.results(filter: "")
        _ = timers.results(argument: "")
        _ = calendarStore.results(argument: "warm tomorrow at 5pm")
        _ = SettingsPanes.list(filter: "", frecency: frecency)
        _ = launcherSettingsResult("launcher settings")
        _ = webResult(keyword: "g", template: webSearches["g"] ?? "", query: "warm")
        _ = apps.results(for: "a", frecency: frecency, limit: 30)
        _ = scripts.results(for: "a", frecency: frecency)
        _ = folderResults("a")
        Log.write("providers warmed in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms")
    }

    func cachedRecent() -> [Result] {
        if recentCache.isEmpty { refreshRecent() }
        return recentCache
    }

    /// Most-used apps and commands, shown for an empty query.
    private func recent() -> [Result] {
        // Emoji picks have their own list under `e`.
        let top = frecency.entries.filter { !$0.key.hasPrefix("emoji") }.sorted { a, b in
            frecency.multiplier(for: a.key) > frecency.multiplier(for: b.key)
        }.prefix(8)
        return top.compactMap { id, _ in
            if let a = apps.entry(forID: id) {
                return Result(id: id, title: a.name, subtitle: a.path.replacingOccurrences(of: Paths.home.path, with: "~"),
                              icon: IconLoader.shared.icon(forPath: a.path), action: .openPath(a.path), revealPath: a.path)
            }
            if let c = scripts.command(forID: id) {
                let action: ResultAction = c.manifest.mode == .action ? .runScript(c.runURL, argument: "") : .none
                return Result(id: id, title: c.manifest.title, subtitle: c.manifest.subtitle ?? c.manifest.keyword, icon: c.icon, action: action)
            }
            if id.hasPrefix("file:") {
                let path = String(id.dropFirst(5))
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return Result(id: id, title: URL(fileURLWithPath: path).lastPathComponent,
                              subtitle: path.replacingOccurrences(of: Paths.home.path, with: "~"),
                              icon: IconLoader.shared.icon(forPath: path), action: .openPath(path), revealPath: path,
                              onDelete: { Actions.trash(path) })
            }
            return nil
        }
    }

    func recordUse(_ id: String) {
        frecency.record(id)
        recentCache = []
        if let data = try? frecency.encoded() {
            try? data.write(to: Paths.frecency, options: .atomic)
        }
    }
}
