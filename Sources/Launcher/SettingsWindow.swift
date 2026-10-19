import AppKit
import LauncherCore

/// Edits ~/.launcher/config.json in a form. Saving writes the file and relaunches the app.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var config = Config.load(from: Paths.config)

    private let hotkey = NSTextField()
    private let placeholder = NSTextField()
    private let maxResults = NSTextField()
    private let fileSearchEnabled = NSButton(checkboxWithTitle: "Search files with Spotlight", target: nil, action: nil)
    private let fileScopes = NSTextField()
    private let fileMax = NSTextField()
    private let appFolders = NSTextView()
    private let folders = NSTextView()
    private let clipboardKeyword = NSTextField()
    private let clipboardLimit = NSTextField()
    private let defineKeywords = NSTextField()
    private let calKeyword = NSTextField()
    private let calPicker = NSPopUpButton()
    private var calendarChoices: [(id: String, title: String, source: String)] = []
    private let webSearches = NSTextView()
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let themePicker = NSPopUpButton()
    private let themePreview = ThemePreview()
    private let accentWell = NSColorWell()
    private let accentOverride = NSButton(checkboxWithTitle: "Custom accent color", target: nil, action: nil)
    private let fontSize = NSTextField()
    private let status = NSTextField(labelWithString: "")
    /// One checkbox per command in the registry (Commands.swift); unchecked means disabled.
    private var commandChecks: [(command: KeaCommand, box: NSButton)] = []
    private let alertsEnabled = NSButton(checkboxWithTitle: "Full-screen alert before each meeting", target: nil, action: nil)
    private let alertsLead = NSTextField()
    private let alertsAtStart = NSButton(checkboxWithTitle: "Alert again at the start time", target: nil, action: nil)
    private let alertsIgnore = NSTextField()
    private let zonesEnabled = NSButton(checkboxWithTitle: "Move windows between zones", target: nil, action: nil)
    private let zoneDisplays = NSTextView()
    private let zonePreview = ZonePreview()
    private let zoneDisplaysNow = NSTextField(wrappingLabelWithString: "")
    private let zoneGap = NSTextField()
    private let zoneFocus = NSTextField()
    private let zoneKeys = NSTextView()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Kea Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildForm()
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        config = Config.load(from: Paths.config)
        load()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildForm() {
        guard let content = window?.contentView else { return }

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            l.textColor = .secondaryLabelColor
            return l
        }
        func hint(_ s: String) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .tertiaryLabelColor
            return l
        }
        func scroll(_ tv: NSTextView, height: CGFloat) -> NSScrollView {
            let sv = NSScrollView()
            sv.documentView = tv
            sv.hasVerticalScroller = true
            sv.borderType = .bezelBorder
            tv.isRichText = false
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            // A text view made with a zero frame never grows tall enough to show its text.
            tv.frame = NSRect(x: 0, y: 0, width: 400, height: height)
            tv.minSize = NSSize(width: 0, height: height)
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.textContainer?.widthTracksTextView = true
            tv.autoresizingMask = [.width]
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.textContainerInset = NSSize(width: 4, height: 4)
            sv.heightAnchor.constraint(equalToConstant: height).isActive = true
            // Grid cells size views to their intrinsic width, and a scroll view has none.
            sv.widthAnchor.constraint(equalToConstant: 400).isActive = true
            return sv
        }
        func section(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .boldSystemFont(ofSize: 13)
            return l
        }


        for t in Theme.presets {
            themePicker.addItem(withTitle: t.name)
            themePicker.lastItem?.image = t.swatch()
        }
        themePicker.target = self
        themePicker.action = #selector(updateThemePreview)
        accentWell.target = self
        accentWell.action = #selector(updateThemePreview)
        accentOverride.target = self
        accentOverride.action = #selector(updateThemePreview)
        accentWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let accentRow = NSStackView(views: [accentOverride, accentWell])
        accentRow.orientation = .horizontal

        var rows: [[NSView]] = [
            [section("General"), NSGridCell.emptyContentView],
            [label("Hotkey"), hotkey],
            [NSGridCell.emptyContentView, hint("Modifiers joined with +, then a key: shift+space, command+shift+k, control+space, option+f1")],
            [label("Placeholder"), placeholder],
            [label("Max results"), maxResults],
            [NSGridCell.emptyContentView, launchAtLogin],

            [section("Appearance"), NSGridCell.emptyContentView],
            [label("Theme"), themePicker],
            [NSGridCell.emptyContentView, themePreview],
            [label("Accent"), accentRow],
            [label("Font size"), fontSize],
            [NSGridCell.emptyContentView, hint("Theme sets light/dark, blur, background and selection color. The accent override applies to any theme.")],

            [section("Commands"), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, hint("Uncheck a command to turn it off: its keyword becomes normal search text, it leaves help, and its background work stops. The word in brackets is its main keyword.")],
            [NSGridCell.emptyContentView, commandGrid()],

            [section("Meeting Alerts"), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, alertsEnabled],
            [label("Minutes before"), alertsLead],
            [NSGridCell.emptyContentView, alertsAtStart],
            [label("Ignore calendars"), alertsIgnore],
            [NSGridCell.emptyContentView, hint("Calendar names separated by commas. All-day and declined events never alert. alerts test shows a preview.")],

            [section("Window Zones"), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, zonesEnabled],
            [label("Displays"), scroll(zoneDisplays, height: 70)],
            [NSGridCell.emptyContentView, hint("One per line: match = layout. The first line that fits a display wins. match is builtin, portrait, landscape, main, *, or part of the display name. Layouts: zone, cols 2, rows 3, cols(zone, rows 2), cols(2*zone, zone).")],
            [NSGridCell.emptyContentView, zonePreview],
            [NSGridCell.emptyContentView, zoneDisplaysNow],
            [label("Gap"), zoneGap],
            [label("Focus size"), zoneFocus],
            [NSGridCell.emptyContentView, hint("Gap in points between zones. Focus size is width x height in percent of the display, for example 60 x 85.")],
            [label("Keys"), scroll(zoneKeys, height: 70)],
            [NSGridCell.emptyContentView, hint("One per line: left, right, up or down = hotkey. Leave a key out to free it.")],

            [section("Apps"), NSGridCell.emptyContentView],
            [label("App folders"), scroll(appFolders, height: 90)],
            [NSGridCell.emptyContentView, hint("One folder per line, scanned two levels deep. Spotlight finds apps elsewhere too.")],

            [section("Folders"), NSGridCell.emptyContentView],
            [label("Quick folders"), scroll(folders, height: 80)],
            [NSGridCell.emptyContentView, hint("One per line. Matched by name in search; Return opens the folder in Finder.")],

            [section("Files"), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, fileSearchEnabled],
            [label("Scopes"), fileScopes],
            [label("Max file results"), fileMax],
            [NSGridCell.emptyContentView, hint("Scopes are folders separated by commas. ~ is your home folder.")],

            [section("Keywords"), NSGridCell.emptyContentView],
            [label("Clipboard"), clipboardKeyword],
            [label("Clipboard limit"), clipboardLimit],
        ]
        rows += Personal.settingsRows(after: "clipboard", label: label, hint: hint, scroll: scroll)
        rows += [
            [label("Define"), defineKeywords],
            [NSGridCell.emptyContentView, hint("Define keywords separated by commas.")],
        ]
        rows += Personal.settingsRows(after: "define", label: label, hint: hint, scroll: scroll)
        rows += [
            [label("Calendar"), calKeyword],
            [label("Add events to"), calPicker],
            [NSGridCell.emptyContentView, hint("cal <event> creates events in this calendar. Only calendars you can write to are listed.")],
            [label("Web searches"), scroll(webSearches, height: 80)],
            [NSGridCell.emptyContentView, hint("One per line: keyword = URL with {query}. The g entry is the no-match fallback.")],
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.column(at: 0).width = 120
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 400
        for i in 0..<grid.numberOfRows {
            let cell = grid.cell(atColumnIndex: 0, rowIndex: i)
            if let l = cell.contentView as? NSTextField, l.font == .boldSystemFont(ofSize: 13) {
                grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: i, length: 1))
                cell.xPlacement = .leading
                if i > 0 { grid.row(at: i).topPadding = 12 }
            }
        }

        zoneDisplays.delegate = self
        zonePreview.translatesAutoresizingMaskIntoConstraints = false
        zonePreview.widthAnchor.constraint(equalToConstant: 400).isActive = true
        zoneDisplaysNow.font = .systemFont(ofSize: 11)
        zoneDisplaysNow.textColor = .secondaryLabelColor

        let save = NSButton(title: "Save and Relaunch", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let openFile = NSButton(title: "Open config.json", target: self, action: #selector(openConfig))
        let openCommands = NSButton(title: "Commands Folder", target: self, action: #selector(openCommands))
        status.textColor = .systemRed
        status.font = .systemFont(ofSize: 11)
        let buttons = NSStackView(views: [openFile, openCommands, status, NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        // The form scrolls; the button row stays fixed at the bottom.
        let form = NSStackView(views: [grid])
        form.orientation = .vertical
        form.alignment = .leading
        form.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        form.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(form)

        let scroller = NSScrollView()
        scroller.documentView = flipped
        scroller.hasVerticalScroller = true
        scroller.drawsBackground = false
        scroller.translatesAutoresizingMaskIntoConstraints = false

        buttons.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 16, right: 20)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroller)
        content.addSubview(divider)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroller.topAnchor.constraint(equalTo: content.topAnchor),
            scroller.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroller.bottomAnchor.constraint(equalTo: divider.topAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: buttons.topAnchor),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            form.topAnchor.constraint(equalTo: flipped.topAnchor),
            form.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroller.contentView.widthAnchor),
        ])

        // Open at the form's natural height when it fits, else at 85% of the screen.
        let formHeight = form.fittingSize.height + buttons.fittingSize.height + 28
        let width = form.fittingSize.width
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        window?.setContentSize(NSSize(width: width, height: min(formHeight, maxHeight)))
        window?.minSize = NSSize(width: width, height: 320)
        window?.maxSize = NSSize(width: width, height: 4000)
    }

    /// Checkboxes for every command, in two columns, in registry order.
    private func commandGrid() -> NSView {
        let all = SearchCoordinator.current?.allCommands ?? []
        commandChecks = all.filter { $0.id != "help" }.map { c in
            let key = c.help.first?.keyword ?? c.keywords.sorted().first ?? c.id
            let title = c.id == "web" ? "\(c.name) (\(c.keywords.sorted().joined(separator: ", ")))"
                : c.name.lowercased() == key ? c.name : "\(c.name) (\(key))"
            return (c, NSButton(checkboxWithTitle: title, target: nil, action: nil))
        }
        let half = (commandChecks.count + 1) / 2
        let rows: [[NSView]] = (0..<half).map { i in
            [commandChecks[i].box, i + half < commandChecks.count ? commandChecks[i + half].box : NSGridCell.emptyContentView]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        grid.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return grid
    }

    // MARK: - Load / save

    private func load() {
        hotkey.stringValue = config.hotkey
        placeholder.stringValue = config.placeholder
        maxResults.stringValue = String(config.maxResults)
        fileSearchEnabled.state = config.fileSearch.enabled ? .on : .off
        fileScopes.stringValue = config.fileSearch.scopes.joined(separator: ", ")
        fileMax.stringValue = String(config.fileSearch.maxResults)
        appFolders.string = config.appFolders.joined(separator: "\n")
        folders.string = config.folders.joined(separator: "\n")
        clipboardKeyword.stringValue = config.clipboard.keyword
        clipboardLimit.stringValue = String(config.clipboard.limit)
        defineKeywords.stringValue = config.defineKeywords.joined(separator: ", ")
        Personal.loadSettings(from: config)
        calKeyword.stringValue = config.calendar.keyword
        calendarChoices = CalendarStore.writableCalendars()
        calPicker.removeAllItems()
        calPicker.addItem(withTitle: "System default")
        for c in calendarChoices { calPicker.addItem(withTitle: "\(c.title)  —  \(c.source)") }
        if let i = calendarChoices.firstIndex(where: { $0.id == config.calendar.calendar || $0.title == config.calendar.calendar }) {
            calPicker.selectItem(at: i + 1)
        } else {
            calPicker.selectItem(at: 0)
        }
        webSearches.string = config.webSearches.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
        launchAtLogin.state = LoginItem.isEnabled ? .on : .off
        themePicker.selectItem(withTitle: Theme.named(config.appearance.theme).name)
        accentOverride.state = NSColor(hex: config.appearance.accent) != nil ? .on : .off
        accentWell.color = NSColor(hex: config.appearance.accent) ?? Theme.named(config.appearance.theme).accent ?? .controlAccentColor
        fontSize.stringValue = String(Int(config.appearance.fontSize))
        for (command, box) in commandChecks { box.state = command.isDisabled(by: config.commands.disabled) ? .off : .on }
        alertsEnabled.state = config.alerts.enabled ? .on : .off
        alertsLead.stringValue = config.alerts.leadMinutes == config.alerts.leadMinutes.rounded() ? String(Int(config.alerts.leadMinutes)) : String(config.alerts.leadMinutes)
        alertsAtStart.state = config.alerts.alertAtStart ? .on : .off
        alertsIgnore.stringValue = config.alerts.ignoreCalendars.joined(separator: ", ")
        zonesEnabled.state = config.zones.enabled ? .on : .off
        zoneDisplays.string = config.zones.displays.map { "\($0.match) = \($0.layout)" }.joined(separator: "\n")
        zoneGap.stringValue = String(Int(config.zones.gap))
        zoneFocus.stringValue = "\(Int((config.zones.focusWidth * 100).rounded())) x \(Int((config.zones.focusHeight * 100).rounded()))"
        zoneKeys.string = ZoneDirection.allCases.compactMap { d in config.zones.keys[d.rawValue].map { "\(d.rawValue) = \($0)" } }.joined(separator: "\n")
        zoneDisplaysNow.stringValue = "Connected now: " + NSScreen.screens.map { s in
            let kind = s.frame.height > s.frame.width ? "portrait" : "landscape"
            return "\(s.localizedName) (\(kind))"
        }.joined(separator: ", ")
        updateZonePreview()
        updateThemePreview()
        status.stringValue = ""
    }

    private func parsedZoneLines() -> [(match: String, layout: String)] {
        zoneDisplays.string.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    /// Redraws the preview for the theme and accent chosen in the form, before saving.
    @objc fileprivate func updateThemePreview() {
        var a = Config.Appearance()
        a.theme = themePicker.titleOfSelectedItem ?? "System"
        a.accent = accentOverride.state == .on ? accentWell.color.hexString : ""
        let first = placeholder.stringValue.components(separatedBy: " | ").first ?? ""
        themePreview.show(Theme.resolve(a), placeholder: first.isEmpty ? "Search" : first)
    }

    fileprivate func updateZonePreview() {
        zonePreview.items = parsedZoneLines().map { l in
            ZonePreview.Item(match: l.match, layout: Swift.Result { try ZoneLayout.parse(l.layout) })
        }
    }

    private func list(_ s: String, sep: Character = ",") -> [String] {
        s.split(separator: sep).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func validate() -> Config? {
        var c = config
        do { _ = try HotKeySpec.parse(hotkey.stringValue) } catch { status.stringValue = "Hotkey: \(error)"; return nil }
        c.hotkey = hotkey.stringValue.trimmingCharacters(in: .whitespaces)
        c.placeholder = placeholder.stringValue
        guard let mr = Int(maxResults.stringValue), mr > 0 else { status.stringValue = "Max results must be a number"; return nil }
        c.maxResults = mr
        c.appearance.theme = themePicker.titleOfSelectedItem ?? "System"
        c.appearance.accent = accentOverride.state == .on ? accentWell.color.hexString : ""
        guard let fs = Double(fontSize.stringValue), fs >= 12, fs <= 48 else { status.stringValue = "Font size must be between 12 and 48"; return nil }
        c.appearance.fontSize = fs
        c.fileSearch.enabled = fileSearchEnabled.state == .on
        c.fileSearch.scopes = list(fileScopes.stringValue)
        guard let fm = Int(fileMax.stringValue), fm >= 0 else { status.stringValue = "Max file results must be a number"; return nil }
        c.fileSearch.maxResults = fm
        c.appFolders = list(appFolders.string, sep: "\n")
        c.folders = list(folders.string, sep: "\n")
        let ck = clipboardKeyword.stringValue.trimmingCharacters(in: .whitespaces)
        guard !ck.isEmpty else { status.stringValue = "Clipboard keyword is empty"; return nil }
        c.clipboard.keyword = ck
        guard let cl = Int(clipboardLimit.stringValue), cl > 0 else { status.stringValue = "Clipboard limit must be a number"; return nil }
        c.clipboard.limit = cl
        c.defineKeywords = list(defineKeywords.stringValue)
        if let problem = Personal.saveSettings(to: &c) { status.stringValue = problem; return nil }
        let ck2 = calKeyword.stringValue.trimmingCharacters(in: .whitespaces)
        guard !ck2.isEmpty else { status.stringValue = "Calendar keyword is empty"; return nil }
        c.calendar.keyword = ck2
        let pick = calPicker.indexOfSelectedItem
        c.calendar.calendar = pick > 0 && pick - 1 < calendarChoices.count ? calendarChoices[pick - 1].id : ""
        var searches: [String: String] = [:]
        for line in webSearches.string.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("{query}") else {
                status.stringValue = "Web search line needs: keyword = url with {query}"; return nil
            }
            searches[parts[0]] = parts[1]
        }
        c.webSearches = searches

        // Keep entries this window does not know (a keyword typed by hand that matches nothing here).
        let known = Set(commandChecks.flatMap { [$0.command.id] + Array($0.command.keywords) }.map { $0.lowercased() })
        c.commands.disabled = c.commands.disabled.filter { !known.contains($0.lowercased()) }
            + commandChecks.filter { $0.box.state == .off }.map(\.command.id)
        c.alerts.enabled = alertsEnabled.state == .on
        guard let lead = Double(alertsLead.stringValue.trimmingCharacters(in: .whitespaces)), lead >= 0, lead <= 60 else {
            status.stringValue = "Minutes before must be 0 to 60"; return nil
        }
        c.alerts.leadMinutes = lead
        c.alerts.alertAtStart = alertsAtStart.state == .on
        c.alerts.ignoreCalendars = list(alertsIgnore.stringValue)
        c.zones.enabled = zonesEnabled.state == .on
        var displays: [Config.Zones.Display] = []
        for line in zoneDisplays.string.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { status.stringValue = "Zone line needs: match = layout"; return nil }
            do { _ = try ZoneLayout.parse(parts[1]) } catch { status.stringValue = "Zones, \(parts[0]): \(error)"; return nil }
            displays.append(.init(match: parts[0], layout: parts[1]))
        }
        c.zones.displays = displays
        guard let gap = Double(zoneGap.stringValue), gap >= 0, gap <= 100 else { status.stringValue = "Zone gap must be 0 to 100"; return nil }
        c.zones.gap = gap
        let focus = zoneFocus.stringValue.lowercased().split(whereSeparator: { "x× ,%".contains($0) }).compactMap { Double($0) }
        guard focus.count == 2, focus.allSatisfy({ $0 >= 20 && $0 <= 100 }) else {
            status.stringValue = "Focus size is width x height in percent, like 60 x 85"; return nil
        }
        c.zones.focusWidth = focus[0] / 100
        c.zones.focusHeight = focus[1] / 100
        var keys: [String: String] = [:]
        for line in zoneKeys.string.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2, ZoneDirection(rawValue: parts[0]) != nil else {
                status.stringValue = "Zone key line needs: left, right, up or down = hotkey"; return nil
            }
            do { _ = try HotKeySpec.parse(parts[1]) } catch { status.stringValue = "Zone key \(parts[0]): \(error)"; return nil }
            keys[parts[0]] = parts[1]
        }
        c.zones.keys = keys
        return c
    }

    @objc private func save() {
        guard let c = validate() else { return }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(c).write(to: Paths.config, options: .atomic)
        } catch {
            status.stringValue = "Could not write config: \(error)"
            return
        }
        if (launchAtLogin.state == .on) != LoginItem.isEnabled { LoginItem.toggle() }
        Log.write("settings saved, relaunching")
        window?.close()
        Relaunch.now()
    }

    /// Renders the whole form to a PNG without showing the window. Used for checks.
    func snapshot(to url: URL) {
        guard let doc = (window?.contentView?.subviews.first as? NSScrollView)?.documentView else { return }
        doc.layoutSubtreeIfNeeded()
        // Text views lay out lazily, only where visible; lay out everything for the image.
        for tv in [zoneDisplays, zoneKeys, appFolders, folders, webSearches] + Personal.settingsTextViews {
            if let lm = tv.layoutManager, let tc = tv.textContainer { lm.ensureLayout(for: tc) }
        }
        guard let rep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) else { return }
        doc.cacheDisplay(in: doc.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @objc private func cancel() { window?.close() }
    @objc private func openConfig() { NSWorkspace.shared.open(Paths.config) }
    @objc private func openCommands() { NSWorkspace.shared.open(Paths.commands) }

}

extension SettingsWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        if (notification.object as? NSTextView) === zoneDisplays { updateZonePreview() }
    }
}

/// Top-anchored document view so the form starts at the top of the scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

enum Relaunch {
    /// Restarts through the LaunchAgent when it is on, so the new copy is still
    /// launchd's (an `open` copy would not be, and a later kickstart could not replace it).
    static func now() {
        let path = Bundle.main.bundlePath
        let agent = "gui/\(getuid())/\(LoginItem.label)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", LoginItem.isEnabled
            ? "sleep 0.4; /bin/launchctl kickstart \(agent) || open \"\(path)\""
            : "sleep 0.4; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
