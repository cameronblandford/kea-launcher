import AppKit
import LauncherCore

let args = CommandLine.arguments
// The personal flags come first, because one of them is a longer form of a flag below.
if Personal.handleArguments(args) {
    exit(0)
} else if args.count >= 3, args[1] == "--query" {
    // `Launcher --query "text"` prints results and exits. Used for smoke tests.
    HeadlessQuery.run(args[2...].joined(separator: " "))
} else if args.count >= 3, args[1] == "--login" {
    // `Launcher --login on|off|status` manages the launch-at-login item from the shell.
    if args[2] == "on", !LoginItem.isEnabled { LoginItem.toggle() }
    if args[2] == "off", LoginItem.isEnabled { LoginItem.toggle() }
    print("launch at login: \(LoginItem.isEnabled ? "enabled" : "disabled")")
    exit(0)
} else if args.count >= 3, args[1] == "--2048-snapshot" {
    _ = NSApplication.shared
    Game2048Window.snapshot(to: URL(fileURLWithPath: args[2]))
    exit(0)
} else if args.count >= 4, args[1] == "--diskmap-snapshot" {
    // Scans a folder and writes the disk map of it to a PNG; prints the counts and the time.
    _ = NSApplication.shared
    DiskMapWindow.snapshot(path: args[2], to: URL(fileURLWithPath: args[3]))
    exit(0)
} else if args.count >= 3, args[1] == "--paint-snapshot" {
    _ = NSApplication.shared
    PaintWindow.snapshot(to: URL(fileURLWithPath: args[2]))
    exit(0)
} else if args.count >= 2, args[1] == "--tidy-scan" {
    TidyCommand.printScan()
    exit(0)
} else if args.count >= 3, args[1] == "--uninstall-plan" {
    // Prints what `uninstall` would move to the Trash for an app. It moves nothing.
    let term = args[2...].joined(separator: " ").lowercased()
    let folders = ["/Applications", Paths.home.appendingPathComponent("Applications").path]
    let apps = folders.flatMap { dir in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }
        .map { AppEntry(name: String($0.dropLast(4)), path: "\(dir)/\($0)") } }
    if let app = apps.first(where: { $0.name.lowercased() == term }) ?? apps.first(where: { $0.name.lowercased().contains(term) }) {
        let plan = UninstallCommand.plan(for: app)
        print("\(plan.app.name): \(plan.items.count) items, \(Tidy.size(plan.total))\n\(UninstallCommand.describe(plan))")
    } else {
        print("no app found for \(term)")
    }
    exit(0)
} else if args.count >= 3, args[1] == "--press-plan" {
    // Prints what `press` would change in a folder. It changes nothing.
    exit(PressCommand.printPlan(args[2...].joined(separator: " ")))
} else if args.count >= 3, args[1] == "--press-apply" {
    // Reads a folder and presses it, with no question: files are compressed in place and duplicates share their data.
    exit(PressCommand.runFromShell(args[2...].joined(separator: " ")))
} else if args.count >= 4, args[1] == "--convert" {
    // `Kea --convert gif clip.mov`: the same conversion as `conv`, from the shell.
    if let target = Convert.target(from: args[2]) {
        ConvertCommand.convert(Array(args[3...]), to: target).forEach { print($0) }
    } else {
        print("could not read \(args[2])")
    }
    exit(0)
} else if args.count >= 4, args[1] == "--qr" {
    // `Kea --qr out.png some text` writes a QR code; `Kea --qr-read file.png` prints what one says.
    if let image = QRCommand.image(for: args[3...].joined(separator: " ")) {
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
    }
    exit(0)
} else if args.count >= 3, args[1] == "--qr-read" {
    if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
        QRCommand.read(image).forEach { print($0) }
    }
    exit(0)
} else if args.count >= 3, args[1] == "--sol-snapshot" {
    _ = NSApplication.shared
    SolitaireWindow.snapshot(to: URL(fileURLWithPath: args[2]))
    exit(0)
} else if args.count >= 3, args[1] == "--zonedrop-snapshot" {
    _ = NSApplication.shared
    ZoneDropController.snapshot(manager: ZoneManager(config: Config.load(from: Paths.config).zones), to: URL(fileURLWithPath: args[2]))
    exit(0)
} else if args.count >= 3, args[1] == "--alerts-snapshot" {
    _ = NSApplication.shared
    MeetingAlertOverlay.snapshot(to: URL(fileURLWithPath: args[2]), themeName: args.count >= 4 ? args[3...].joined(separator: " ") : nil)
    exit(0)
} else if args.count >= 3, args[1] == "--alerts" {
    // `Kea --alerts test` shows the preview alert in the running app.
    DistributedNotificationCenter.default().postNotificationName(.init("directory.kea.launcher.alerts"), object: args[2], userInfo: nil, deliverImmediately: true)
    exit(0)
} else if args.count >= 3, args[1] == "--panel-snapshot" {
    _ = NSApplication.shared
    PanelSnapshot.render(to: URL(fileURLWithPath: args[2]), theme: args.count >= 4 ? args[3...].joined(separator: " ") : nil)
    exit(0)
} else if args.count >= 3, args[1] == "--ocr" {
    // Prints the text Kea reads in an image file.
    if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        print(OCRCommand.text(in: cg))
    } else {
        print("could not read \(args[2])")
    }
} else if args.count >= 2, args[1] == "--ie-selftest" {
    _ = NSApplication.shared
    EditorCanvas.selfTest()
    exit(0)
} else if args.count >= 4, args[1] == "--ie-snapshot" {
    _ = NSApplication.shared
    ImageEditCommand.snapshot(input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
                              instructions: args.count >= 5 ? args[4...].joined(separator: " ") : "")
    exit(0)
} else if args.count >= 3, args[1] == "--theme-snapshot" {
    _ = NSApplication.shared
    ThemeSnapshot.render(to: URL(fileURLWithPath: args[2]))
    exit(0)
} else if args.count >= 3, args[1] == "--settings-snapshot" {
    _ = NSApplication.shared
    // The Commands section lists the registry, so a coordinator must exist.
    let coordinator = SearchCoordinator.standalone(config: Config.load(from: Paths.config))
    SettingsWindowController.shared.snapshot(to: URL(fileURLWithPath: args[2]))
    _ = coordinator
    exit(0)
} else if args.count >= 3, args[1] == "--kblock" {
    DistributedNotificationCenter.default().postNotificationName(.init("directory.kea.launcher.kblock"), object: args[2], userInfo: nil, deliverImmediately: true)
    exit(0)
} else if args.count >= 3, args[1] == "--zone" {
    DistributedNotificationCenter.default().postNotificationName(.init("directory.kea.launcher.zone"), object: args[2], userInfo: nil, deliverImmediately: true)
    exit(0)
} else if args.count >= 3, args[1] == "--open" {
    // Exercises the open action (including scheme-link launch waiting) from the shell.
    Actions.perform(.item(.open(args[2])), scripts: ScriptCommands())
    RunLoop.main.run(until: Date().addingTimeInterval(25))
    exit(0)
} else if args.count >= 2, args[1].hasPrefix("--") {
    // A flag that this build does not have (a wrong name, too few arguments, or a personal flag
    // in a build without Personal) must not start a second copy of the app.
    FileHandle.standardError.write(Data("Kea: unknown or incomplete flag \(args[1])\n".utf8))
    exit(2)
} else {
    // launchd and `open` can both start the app at login; the first copy wins.
    if let id = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
        exit(0)
    }
    LoginItem.refreshIfNeeded()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
