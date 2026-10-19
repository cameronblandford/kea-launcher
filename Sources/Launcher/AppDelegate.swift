import AppKit
import LauncherCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?
    private var panel: PanelController?
    private var coordinator: SearchCoordinator?
    private var statusItem: NSStatusItem?
    private let scripts = ScriptCommands()
    private var clipboard: ClipboardHistory?
    private var rates: RatesStore?
    private var loginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureRoot()
        let config = Config.load(from: Paths.config)

        let apps = AppIndex(folders: config.appFolders)
        apps.start()

        let files: FileSearch? = config.fileSearch.enabled
            ? FileSearch(scopes: config.fileSearch.scopes, maxResults: config.fileSearch.maxResults) : nil

        scripts.reload()

        let clipboard = ClipboardHistory(limit: config.clipboard.limit)
        self.clipboard = clipboard
        let rates = RatesStore()
        rates.refreshIfStale()
        self.rates = rates

        let frecency = (try? Data(contentsOf: Paths.frecency)).flatMap { try? Frecency(data: $0) } ?? Frecency()
        let coordinator = SearchCoordinator(apps: apps, files: files, scripts: scripts, frecency: frecency, config: config,
                                            clipboard: clipboard, rates: rates)
        self.coordinator = coordinator
        coordinator.personal.startIndexing()
        // A disabled command also stops its background work.
        if coordinator.isEnabled("clipboard") { clipboard.start() }
        let panel = PanelController(coordinator: coordinator, scripts: scripts, placeholder: config.placeholder, appearance: config.appearance)
        self.panel = panel

        do {
            let spec = try HotKeySpec.parse(config.hotkey)
            hotKey = try HotKey(spec: spec) { [weak panel] in panel?.toggle() }
            Log.write("hotkey registered: \(config.hotkey)")
        } catch {
            Log.write("hotkey error: \(error). Falling back to option+space")
            hotKey = try? HotKey(spec: HotKeySpec(modifiers: [.option], key: .space)) { [weak panel] in panel?.toggle() }
        }

        if coordinator.isEnabled("zones") { coordinator.zones.start() }
        if coordinator.isEnabled("snippets") { coordinator.snippets.start() }
        if coordinator.isEnabled("autoclicker") { coordinator.autoClicker.start() }
        if coordinator.isEnabled("hyper") { coordinator.hyperKey.startIfConfigured() }
        if coordinator.isEnabled("alerts") {
            coordinator.meetingAlerts.installHook()
            // The calendar prompt may still be open at the first launch; start after it.
            if config.alerts.enabled { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { coordinator.meetingAlerts.start() } }
        }
        restoreOnTermination()
        setupStatusItem(hotkey: config.hotkey)
        coordinator.timers.onChange = { [weak self] _ in self?.updateStatusTitle() }
        coordinator.personal.onChange = { [weak self] in self?.updateStatusTitle() }
        updateStatusTitle()
        coordinator.caffeinate.onChange = { [weak self] _, _ in self?.updateStatusIcon() }
        coordinator.autoClicker.onChange = { [weak self] _ in
            self?.updateStatusIcon()
            self?.updateStatusTitle()
        }
        coordinator.personal.start()
        installEditMenu()
        installToggleSignal()

        // Warm the recent list and its icons once the app index has had a moment to load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { coordinator.refreshRecent() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { coordinator.warmUp() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { panel.warmUp() }
        // At login the network may not be up yet; a failed load is tried again at a panel open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { coordinator.preloadWeather() }
    }

    /// Standard edit shortcuts (Cmd+A, C, V, X, Z) only work when an Edit menu exists.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        appItem.submenu?.addItem(prefs)
        appItem.submenu?.addItem(withTitle: "Quit Kea", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Quick Look", action: #selector(LauncherPanel.quickLook(_:)), keyEquivalent: "y")
        viewItem.submenu = view
        main.addItem(viewItem)
        NSApp.mainMenu = main
    }

    private var signalSource: DispatchSourceSignal?
    private var settingsSignal: DispatchSourceSignal?

    /// `kill -USR1 <pid>` toggles the panel. Handy for scripts and screenshots.
    private func installToggleSignal() {
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.panel?.toggle() }
        src.resume()
        signalSource = src
        // `kill -USR2 <pid>` opens the settings window.
        signal(SIGUSR2, SIG_IGN)
        let s2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        s2.setEventHandler { [weak self] in self?.openSettings() }
        s2.resume()
        settingsSignal = s2
    }

    /// The soonest timer's countdown, or the title of a personal feature that waits for the user.
    /// A running autoclicker always shows first: a clicker left on by mistake is easy to miss.
    private func updateStatusTitle() {
        guard let button = statusItem?.button, let coordinator else { return }
        let waiting = coordinator.personal.statusTitle
        var title: String
        if let next = coordinator.timers.timers.first {
            title = " " + next.badge + DurationParser.format(next.remaining)
        } else {
            title = waiting ?? ""
        }
        if coordinator.autoClicker.isOn {
            title = " Clicking \(coordinator.autoClicker.rate)" + (title.isEmpty ? "" : " ·" + title)
        }
        button.title = title
        button.imagePosition = .imageLeading
        waitingItem?.isHidden = waiting == nil
        waitingSeparator?.isHidden = waiting == nil
    }

    /// The bird, a cursor while the autoclicker runs, or a cup while caffeinate is on.
    private func updateStatusIcon() {
        guard let button = statusItem?.button, let coordinator else { return }
        let caff = coordinator.caffeinate
        let symbol: String
        if coordinator.autoClicker.isOn { symbol = "cursorarrow.click.2" }
        else if caff.isActive { symbol = "cup.and.saucer.fill" }
        else { symbol = "bird" }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Kea")
        var tips: [String] = []
        if coordinator.autoClicker.isOn { tips.append("Autoclicker on (\(coordinator.autoClicker.rate)); Esc stops") }
        if caff.isActive { tips.append(caff.statusText) }
        button.toolTip = tips.isEmpty ? nil : tips.joined(separator: "\n")
    }

    /// The menu item that goes with `Personal.statusTitle`, and the line below it.
    private var waitingItem: NSMenuItem?
    private var waitingSeparator: NSMenuItem?

    private func setupStatusItem(hotkey: String) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Kea")
        // Remembers where you Cmd-drag it, and never lets a stray Cmd-drag remove it.
        item.autosaveName = "directory.kea.launcher.status"
        item.behavior = []
        item.isVisible = true
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Kea (\(hotkey))", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Reload Commands", action: #selector(reloadCommands), keyEquivalent: "")
        menu.addItem(withTitle: "Open Commands Folder", action: #selector(openCommandsFolder), keyEquivalent: "")
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        loginItem = login
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kea", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for m in menu.items where m.action != #selector(NSApplication.terminate(_:)) { m.target = self }
        if let waiting = coordinator?.personal.statusMenuItem {
            let sep = NSMenuItem.separator()
            waiting.isHidden = true
            sep.isHidden = true
            menu.insertItem(waiting, at: 0)
            menu.insertItem(sep, at: 1)
            waitingItem = waiting
            waitingSeparator = sep
        }
        item.menu = menu
        statusItem = item
    }

    /// Clicking Kea in the Dock (or opening it again) shows the search panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show()
        return false
    }

    private var termSources: [DispatchSourceSignal] = []

    /// `kill`, `pkill` and launchd stop Kea with SIGTERM, which skips
    /// applicationWillTerminate. Give Caps Lock back to macOS first, then exit the usual way.
    private func restoreOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.coordinator?.caffeinate.stop(notify: false)
                self?.coordinator?.autoClicker.handle(.quit)
                self?.coordinator?.hyperKey.stop(sync: true)
                signal(sig, SIG_DFL)
                kill(getpid(), sig)
            }
            src.resume()
            termSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.caffeinate.stop(notify: false)
        coordinator?.autoClicker.handle(.quit)
        // Caps Lock gets its old mapping back before Kea exits.
        coordinator?.hyperKey.stop(sync: true)
    }

    @objc private func showPanel() { panel?.show() }
    @objc private func reloadCommands() { scripts.reload() }
    @objc func openSettings() { panel?.hide(); SettingsWindowController.shared.show() }
    @objc private func openCommandsFolder() { NSWorkspace.shared.open(Paths.commands) }
    @objc private func toggleLoginItem() {
        LoginItem.toggle()
        loginItem?.state = LoginItem.isEnabled ? .on : .off
    }
}
