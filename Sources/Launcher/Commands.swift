import AppKit
import LauncherCore

/// The list of Kea's keyword commands.
///
/// To add a command: write its code in its own file with a `command` that describes it
/// (see KeaCommand.swift, and WeatherCommand.swift or Caffeinate.swift for examples),
/// then add one line here. The order here is the order in `help` and in Settings. The
/// web searches come last, so a built-in keyword wins over a web search with the same one.
extension SearchCoordinator {
    func buildCommands() -> [KeaCommand] {
        var list = [
            clipboard.command(keyword: config.clipboard.keyword),
            calendarStore.command(keyword: config.calendar.keyword),
            meetingAlerts.command,
            weather.command,
            AudioDevices.command,
            BluetoothDevices.command,
            DefaultApps.command,
            FinderToggles.command,
            boot.command,
            Game2048Window.command,
            SolitaireWindow.command,
            tidy.command,
            DiskMapWindow.command,
            PaintWindow.command,
            UninstallCommand.command(apps: apps),
            PressCommand.shared.command,
            ShotCommand.command,
            ScreenRecorder.shared.command,
            ConvertCommand.shared.command,
            QRCommand.command,
            TerminalCommand.command(settings: config.terminal),
            keyboardLock.command,
            autoClicker.command,
            hyperKey.command,
            timers.command,
            caffeinate.command,
            zones.command(moveKey: config.zones.keys["right"]),
            stats.command,
            DictionaryLookup.defineCommand(keywords: config.defineKeywords),
            DictionaryLookup.etymologyCommand,
            emoji.command,
            imageEdit.command,
            ZalgoCommand.command,
            LoremCommand.command,
            ZoneTimeCommand.command(favorites: config.tz.favorites),
            OCRCommand.command,
            snippets.command,
            menuSearch.command,
            zones.layoutCommand,
        ] + DevToolCommands.commands + PortKillCommands.commands + [
            SettingsPanes.command,
            webCommand,
            helpCommand,
        ]
        // The personal commands name their place, so that the order stays the same with them.
        for extra in personal.commands(for: self) {
            list.insert(extra.command, at: list.firstIndex { $0.id == extra.before } ?? list.endIndex)
        }
        return list
    }

    /// Every `webSearches` entry in config: `g`, `c`, `gpt`, and the user's own.
    private var webCommand: KeaCommand {
        let help = webSearches.sorted { $0.key < $1.key }.map { k, url -> HelpProvider.Entry in
            let host = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
            return .init(keyword: k, summary: "Search or ask \(host)", example: "\(k) something")
        }
        return KeaCommand(id: "web", name: "Web Searches", keywords: Set(webSearches.keys), help: help,
                          results: { [unowned self] ctx in
                              webSearches[ctx.keyword].map { [webResult(keyword: ctx.keyword, template: $0, query: ctx.argument)] } ?? []
                          })
    }

    private var helpCommand: KeaCommand {
        KeaCommand(id: "help", name: "Help", keywords: HelpProvider.keywords,
                   help: [.init(keyword: "help", summary: "This list", example: "help cal")],
                   results: { [unowned self] ctx in
                       HelpProvider.results(filter: ctx.argument, commands: commands, config: config, scripts: scripts)
                   })
    }
}
