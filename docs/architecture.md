# Architecture

This file describes how Kea is built. For why, see [decisions.md](decisions.md).
For the user view of each feature, see the [README](../README.md).

## Package layout

```
Package.swift            Swift 5.9, macOS 14, two targets and the tests
Sources/LauncherCore/    Pure logic. Foundation (and CoreGraphics types) only. Unit tested.
Sources/Launcher/        The app: AppKit, Carbon hotkeys, EventKit, Accessibility.
Tests/LauncherCoreTests/ XCTest for everything in LauncherCore.
Resources/               AppIcon.icns, emoji.tsv.
Info.plist.template      App Info.plist; the Makefile fills in name and bundle id.
Makefile                 build, test, run, bundle, install, reload, install-commands, uninstall, clean.
scripts/make-icon.swift  Renders Resources/AppIcon.icns.
examples/commands/       Sample script commands; `make install-commands` copies them.
```

The installed bundle:

```
/Applications/Kea.app/Contents/
  MacOS/Kea                                   the app (built from the Launcher target)
  Resources/AppIcon.icns
  Info.plist                                  LSUIElement = true (no Dock tile of its own)
```

## Processes and startup

| Process | Started by | Runs as | Job |
|---|---|---|---|
| `Kea` | LaunchAgent `~/Library/LaunchAgents/directory.kea.launcher.agent.plist` at login (`RunAtLoad`, restarts after a crash, stays quit after Quit) | the user | Everything except root work |

`main.swift` handles command-line flags first (see AGENTS.md). With no
flags it exits if another Kea runs (single instance), refreshes the
LaunchAgent path, and starts `NSApplication` with the accessory policy.

`AppDelegate.applicationDidFinishLaunching`, in order:

1. Load `~/.launcher/config.json` (`Config.load`; bad or missing keys get defaults).
2. Start the providers that index in the background: `AppIndex`,
   `ScriptCommands`, `ClipboardHistory`, `RatesStore`.
   `FileSearch` is only built; it runs a Spotlight query when a search needs it.
3. Load frecency, build `SearchCoordinator` (which builds the timer,
   caffeinate, zones, keyboard lock, stats, and calendar store) and `PanelController`.
4. Register the main hotkey (Carbon). Start zones (their four hotkeys).
5. Build the menu bar item, the Edit/View menus (needed for Cmd+C/V/A/Z and
   Cmd+Y), and the USR1/USR2 signal handlers.
6. Warm up: order the panel at alpha 0 (0.3 s), build the recent list
   (1.5 s), run every provider once to fill caches (2.5 s).

## The panel

`PanelController.swift`. An `NSPanel` subclass (`LauncherPanel`) with
`.nonactivatingPanel`: it becomes key without activating Kea, so the app
behind keeps focus. It stays on screen at alpha 0 between uses; `show()`
only sets alpha 1, `makeKey`, and the first responder (3–7 ms, logged as
"panel shown: …"). It hides on Escape with an empty field, when another app
activates, or on a click outside. On hide it reactivates the app that was
in front when it opened.

Parts: a wrapping text field that grows the panel downward, and an
`NSTableView` of results. Rows have a fixed height, except "expanded" rows
(definitions, help keys) which are measured.

Keys (`control(_:textView:doCommandBy:)`):

| Key | Action |
|---|---|
| Up / Down | Move the selection |
| Return | Perform the row's action (`Actions.perform`); `.fill` puts text in the field. On a list script command's row, Return fills its keyword. |
| Cmd+Return | Reveal `revealPath` in Finder |
| Escape | Clear the field, or hide when empty |
| fn+Delete, Cmd+Delete | Run the row's `onDelete`, then refresh |
| Tab | Complete a list command's keyword |
| Cmd+Y | Quick Look `revealPath` (Up/Down/Return work inside Quick Look) |
| Cmd+A/C/V/X/Z, Cmd+, | Sent to the main menu by `performKeyEquivalent`, because the app is never active |

## The result model

`Result.swift`:

```swift
struct Result {
    var id: String            // stable; the prefix names the source: "app:", "file:", "cmd:", "zones:3", ...
    var title: String
    var subtitle: String?
    var icon: NSImage?
    var action: ResultAction  // .openPath, .item(open/shell/copy), .runScript, .custom(closure), .openWith, .fill, .none
    var revealPath: String?   // Cmd+Return and Quick Look
    var keyword: String?      // extra text that matches with less weight
    var onDelete: (() -> Void)?
    var expanded = false      // subtitle wraps over several lines
}
```

The `id` is also the frecency key, so keep it stable across launches for
anything a user opens repeatedly.

## Search flow

`SearchCoordinator.update(text:)` runs on every keystroke. `Query.parse`
splits the text:

- **Keyword command**: the first word is a known keyword and a space follows
  (or the text is only the keyword). The coordinator finds the first enabled
  `KeaCommand` with that keyword and shows its rows (`run`). A command can
  refresh its rows itself (`context.refresh`, for answers from the network or
  a model) or declare `live` to be asked again on a timer. Keywords that no
  command claims go to list script commands (async, 120 ms debounce).
- **Plain search**:
  1. Calculator or unit/currency conversion row, if the text is one.
  2. Instant providers: apps, action script commands, System Settings panes,
     quick folders, the Kea settings row, and the `search` rows of every enabled
     command (settings panes, Shortcuts, Finder toggles, keep awake). They are merged
     and ranked (`rankMerged`: fuzzy score × source weight, app 1.3, file 0.6,
     plus frecency).
  3. The list is shown at once.
  4. After 180 ms (debounce), Spotlight file results arrive and are appended
     below. Instant rows never move.
  5. If everything is empty, a Google row is the fallback.
- **Empty text**: the precomputed recent list (most-used by frecency).

A `generation` counter drops late async answers from an older query.
Live lists (`stats`) refresh on a timer that `cancelLive()` stops on hide.
A slow reading (the sensors of `stats`, `lsof` and `ps` for `port` and `kill`) goes through
`Cached`: it is read off the main thread, the rows come from the last answer, and the
command's `refresh` runs when a new answer is in.

Ranking lives in `LauncherCore`: `FuzzyMatcher` (exact 1000, prefix 500+,
word-prefix 450+, subsequence with bonuses), `Frecency` (`1 + ln(1 + count)`
plus a recency bonus, saved in `~/.launcher/frecency.json`), and `Ranker`.

## Commands

`KeaCommand.swift` defines what a command is: `id`, `name`, `keywords`, `help`
lines, `results` (rows for a keyword and argument), and optionally `live`
(refresh on a timer while busy) and `search` (rows for plain search). Each
feature builds its `KeaCommand` in its own file (`WeatherCommand.command`,
`TidyCommand.command`, `FinderToggles.command`, …). `Commands.swift` holds
`SearchCoordinator.buildCommands()`, the one list of them. Everything else
reads that list:

- dispatch (`SearchCoordinator.update` → `run`)
- the set of keywords `Query.parse` knows
- `help` (`HelpProvider.entries`)
- Settings › Commands (one checkbox each)
- `commands.disabled` in config: ids or keywords; `SearchCoordinator.commands`
  is the enabled list, `allCommands` is all of them. A disabled command's
  background work is also skipped (`AppDelegate` checks `isEnabled("clipboard")`
  and `isEnabled("zones")`).

A keyword claimed by two commands logs a warning at launch; the first in the
list wins. Web searches are one command (`web`) whose keywords come from
`webSearches`; it is last, so built-in keywords win.

## Features

Each row: keyword, main files, what it keeps on disk, what permission it needs.

| Feature | Keyword | Files | Data | Permission |
|---|---|---|---|---|
| Apps | (search) | AppIndex | — | — |
| Files | (search) | FileSearch (`NSMetadataQuery`) | — | Files access per folder |
| Script commands | own keyword | ScriptCommands, core Command.swift | `~/.launcher/commands/<name>/` | Automation, if scripts use AppleScript |
| System Settings panes | `settings` | SettingsPanes | — | — |
| Quick folders | (search) | SearchCoordinator.folderResults | — | — |
| Calculator, units, currency | (search) | core Calculator, UnitConverter; RatesStore | `rates.json` (daily ECB rates) | Network, once a day |
| Dictionary, etymology | `def`, `ety` | Dictionary.swift (DictionaryServices) | — | — |
| Web search, Claude, ChatGPT | `g`, `c`, `gpt`, config | SearchCoordinator.webResult, core WebSearch | — | — |
| Clipboard history | `cb` | ClipboardHistory (polls every 0.5 s) | `clipboard.json`, PNGs in `~/.launcher/clipboard/` | — |
| Timers | `timer` | TimerManager, core DurationParser | — | Notifications |
| Calendar events | `cal` | CalendarStore, core EventParser | — | Calendar (full access) |
| Meeting alerts | `alerts`, `inyourface`, `iyf`; background | MeetingAlerts.swift (`MeetingAlerter`, `MeetingAlertOverlay`, `MeetingAlertView`), CalendarStore.meetingEvents, core MeetingAlerts.swift (`MeetingAlertPlanner`, `MeetingAlertState`, `MeetingLink`) | — (shown and snoozed alerts are in memory) | Calendar (full access) |
| Lorem ipsum | `lorem` | core Lorem | — | — |
| Developer tools | `uuid`, `b64`, `url`, `hash`, `json`, `color` | DevToolCommands, core DevTools.swift | — | — |
| Time zones | `tz`, `time`, inline (`instant`) | DevToolCommands (ZoneTimeCommand), core ZoneTimes.swift | — | — |
| Ports and processes | `port`, `kill`, `quit` | PortKillCommands, core Processes.swift (`lsof`, `ps`) | — | — |
| OCR | `ocr` | OCRCommand (`screencapture -i`, Vision) | — | Screen Recording |
| Snippets | `snip`; expansion in every app | SnippetExpander (key event tap), core Snippets.swift | `snippets.json` | Accessibility |
| Menu search | `menu` | MenuSearchCommand (AX menu bar of the front app, 20 s cache) | — | Accessibility |
| Saved layouts | `layout` | ZoneManager extension, core Snippets.swift (WindowLayouts) | `layouts.json` | Accessibility |
| Emoji picker | `e`, `emoji` | EmojiCommand, core Emoji (EmojiIndex) | `Resources/emoji.tsv` (from `scripts/make-emoji.sh`), picks in `frecency.json` as `emoji:<char>` | Accessibility to paste |
| Image editor | `ie` | ImageEditCommand, ImageEditor, MarkupRenderer, core Markup | — | — |
| Zalgo text | `zalgo` | ZalgoCommand, core FancyText (Zalgo) | — | — |
| Keep awake | `caff` | Caffeinate (`/usr/bin/caffeinate`, `pmset` for lid) | — | Admin prompt for lid modes |
| System stats | `stats` | SystemStats (host stats, IOKit, private HID temperature API) | — | — |
| Help | `help`, `?` | HelpProvider | — | — |
| Window zones | `zones`, hotkeys | ZoneManager, core Zones.swift, ZonePreview | — | Accessibility |
| Keyboard lock | `clean` | KeyboardLock (CGEvent tap) | — | Accessibility |
| Autoclicker | `autoclicker`, hotkey | AutoClicker (Carbon hotkey, `CGEvent` mouse events), core AutoClick.swift (`Config.AutoClick`, `AutoClickPlan`, `AutoClickState`) | — | Accessibility |
| Hyper key | `hyper`, Caps Lock | HyperKeyManager (`hidutil` Caps Lock to F18, HID-level `CGEvent` tap, IOKit keyboard notice), core HyperKey.swift (`Config.HyperKey`, `HyperMapping`, `HyperState`) | `UserKeyMapping` of hidutil, while Kea runs | Accessibility |
| Audio devices | `audio` | AudioDevices (CoreAudio) | — | — |
| Bluetooth | `bt` | BluetoothDevices (IOBluetooth) | — | Bluetooth |
| Default apps | `default` | DefaultApps (`NSWorkspace.setDefaultApplication`) | — | — |
| Finder toggles | `finder` + search | FinderToggles (`defaults write`, restarts Finder) | Finder preferences | — |
| Login and background items | `boot` | BootCommand, core BootItems.swift (`sfltool dumpbtm`) | — | System Events automation (removing login apps) |
| Weather | `weather` | WeatherCommand, core Weather.swift | — (10-minute cache in memory; the default place preloads once a day) | Location (optional; falls back to the time zone's city); network |
| 2048 | `2048` | Game2048Window, core Game2048.swift | game state in UserDefaults (`game2048.state`) | — |
| Tidy | `tidy` | TidyCommand, core Tidy.swift | — (reads sizes; clears only on Return) | Downloads and iCloud Drive access; Finder automation to empty the Trash |
| Disk map | `du` | DiskMapWindow, core DiskScan.swift (`DiskScanner`, `DiskTree`) and Treemap.swift | — (the tree is in memory while the window is open) | Full Disk Access for a correct map of the whole disk |
| Paint | `paint`, `doodle` | PaintWindow (`PaintCanvas`), core PaintFill.swift | `~/.launcher/paint.png` (the drawing) | — |
| Uninstall | `uninstall` | UninstallCommand, core Uninstall.swift | — | — (everything goes to the Trash) |
| Press | `press` | PressCommand, core Press.swift | `~/.launcher/press-log.csv` (one row for each file that a press looked at) | Full Disk Access for folders that macOS protects |
| Screenshot | `shot` | ShotCommand (`ScreenGrab`) | — | Screen Recording |
| Record | `rec` | RecCommand (`ScreenRecorder`, `RegionPicker`), MediaConvert | recordings in `~/Movies/Kea` | Screen Recording |
| Convert | `conv` | ConvertCommand, MediaConvert, core Convert.swift | — | Finder automation (to read the selection) |
| Terminal command | `t` (config) | TerminalCommand, core Terminal.swift (`TerminalLaunch`) | — | Automation (Ghostty or Terminal) |
| QR | `qr` | QRCommand (`QRWindow`) | — | Screen Recording (to read a code from the screen) |
| Settings window | plain search "kea settings", Cmd+, | SettingsWindow, Theme | writes `config.json` | — |

### Meeting alerts

`MeetingAlerter` starts 2 s after launch when the `alerts` command is on and `alerts.enabled`
is true. It reads the events of the next 36 hours from EventKit (all calendars, cancelled
events left out) and asks the core planner for the alerts that are due and the next one. One
`Timer` waits for the next alert, or 10 minutes at most; at the 10-minute mark it reads the
calendar again. `EKEventStoreChanged`, wake from sleep, screen wake, session activation, and
clock or time zone changes read it again too (one reload per second at most). A timer does
not fire during sleep, so the wake reload shows an alert that came due while the Mac slept.

The planner (`MeetingAlertPlanner`) is pure. An alert is keyed by the event id, its start
time, and the kind (`before`, `atStart`, `snoozed`), so a moved event alerts again. When
several alerts of one event are due (a late wake), only the latest shows. A missed alert is
dropped 10 minutes after the start; a snoozed one shows until the event ends. The state
(`MeetingAlertState`) is in memory only: after a relaunch, an alert that is still due shows again.

`MeetingAlertOverlay` opens one borderless non-activating `NSPanel` per display at
`.screenSaver` level with `.canJoinAllSpaces` and `.fullScreenAuxiliary`. The panel on the
display with the pointer takes the keys, so the app in front does not lose its place. Alerts
that arrive while one is on screen wait in a queue. The alert closes itself when the event ends.
`Kea --alerts-snapshot out.png [theme]` renders it with sample events, and `Kea --alerts test`
shows the preview in the running app.

### Window zones

- `LauncherCore/Zones.swift` is all the geometry, with tests:
  - `ZoneLayout.parse` reads the layout language: `zone`, `cols N`, `rows N`,
    `cols(a, b)`, `rows(a, b)`, weights `2*zone`. `rects(in:)` gives rectangles in reading order.
  - `ZoneNavigator.globalZones` orders all zones: displays left to right
    (then top to bottom), and reading order inside each display. Frames use
    a top-left origin, the same as the Accessibility API.
  - `locate` finds the zone a window is in (IoU ≥ 0.85 means snapped).
  - `target` moves left/right through the global loop with wrap.
  - `entry` picks the first zone for a window that is not in a zone: Left
    takes the first zone (reading order) on the display's left edge, Right
    the first zone on its right edge.
- `ZoneManager.swift` does the Accessibility work: it finds the focused
  window of the frontmost app, sets size, position, then size again (so a
  window can cross to a smaller display), and turns `AXEnhancedUserInterface`
  off during the move (Chrome animates otherwise). It remembers where it put
  each window, so a terminal that rounds its size to its character grid still counts as snapped.
- Up and Down are not spatial. Up: restore the last minimized window if the
  app has none up, else maximize, else switch between maximized and focus
  view. Down: minimize, or restore when all the app's windows are minimized.
  See decisions.md.
- Displays match config entries by `builtin` (or `laptop`), `portrait`
  (`vertical`), `landscape` (`horizontal`), `main` (`primary`), `*` (`any`),
  or part of the display name. The first match wins. Layout words: `zone`
  (or `z`, `full`), `cols` (or `columns`), `rows`.

Drop zones (`ZoneDrop.swift`): `ZoneDropController` always has a monitor for
the modifier keys only. The monitors for the left mouse button (down, dragged,
up) are added when Shift goes down and removed when it goes up, so a drag
without Shift does not wake Kea. They only watch; macOS moves the window. With Shift down in a drag, the controller reads
the standard window under the pointer and its frame (the front window from
`CGWindowListCopyWindowInfo`, then the same window in that app's Accessibility
list; an Accessibility hit test finds Kea's own panel, which stays on screen
at zero opacity) (on its own queue, because
this calls another app), and reads the frame again after the pointer went 10
points: `ZoneDrop.isWindowDrag` in core says whether the window went where the
pointer went. When a look is not conclusive it looks again, up to four times.
A drag that selects text, drags a file, or resizes does not pass, the log says
why (`zones: drop: …`), and nothing more happens until the next mouse down. When it passes,
`ZoneDropOverlay` puts one clear window that takes no clicks over each display
and draws the zones; `ZoneDrop.targets` gives the zone, or the zones near a
shared border, under the pointer. On mouse up with Shift down, `place` runs
60 ms later, after macOS has let go of the window.
`Kea --zonedrop-snapshot out.png` draws the overlay of the main display.

### Keyboard lock

`KeyboardLock.swift`. A session-level `CGEvent` tap drops key down, key up,
modifier changes, and system-defined events (media and brightness keys)
until the time ends. The mouse still works: a floating panel shows the
countdown and an Unlock button. The lock is at most 15 minutes. If macOS
turns the tap off (timeout or secure input), the callback turns it back on.

### Autoclicker

`AutoClicker.swift`. `start()` registers the `autoclick.hotkey` Carbon hotkey (default
Ctrl+Option+Cmd+C). A failure logs "autoclick hotkey taken" or the error, and the keyword
still works. `AutoClickState` in core decides what each event does: the hotkey toggles,
and Esc, sleep, screen lock, quit, and the stop row stop it. It does not start without
Accessibility (`ZoneManager.trusted`). While it is on, a repeating timer in the common run
loop modes reads the pointer with `CGEvent(source: nil)?.location` and posts a left mouse
down and up there with `.cgSessionEventTap`, with no modifier flags. A global and a local
key monitor watch for Esc, and observers watch `willSleep`, `screensDidSleep`,
`sessionDidResignActive`, and `com.apple.screenIsLocked`. They exist only while it is on.
There is no `--click` hook: any process of the user could post it and make Kea click.

### Hyper key

`HyperKeyManager.swift`. Off unless `hyperKey.enabled` is true (or `hyper on` for one
session). `start()` needs Accessibility (`ZoneManager.trusted`). It creates a key event tap at
`.cghidEventTap` (the session tap if that fails), then, on a serial queue, reads
`hidutil property --get UserKeyMapping`, merges Caps Lock to F18 into the list with
`HyperMapping.applied(to:)`, and writes it with `hidutil property --set`. The Caps Lock entry
that was there before is kept in memory and put back by `stop()` (`HyperMapping.removed`).
`applicationWillTerminate` and the SIGTERM handler call `stop(sync: true)`, which waits for
hidutil. `HyperMapping.parse` returns nil for output it cannot read, and then nothing is written.

The tap sees key down, key up, and mouse downs. F18 (key code 79) goes to `HyperState` and is
dropped. While `HyperState.isHeld`, every other key down and key up gets the Control, Option,
Command, and Shift flags; a key down or a click sets `used`, so the release is not a tap. A
release that is a tap, with `hyperKey.tapEscape` on, posts Esc (marked with
`eventSourceUserData`, which the tap lets through). Events with any `eventSourceUserData`
(Kea's snippet typing) pass unchanged. Hyper resets when macOS turns the tap off, at sleep and
a session switch, and when `CGEventSource.keyState(.hidSystemState)` says F18 is up.

Wake, screen wake, a session that becomes active, and an IOKit first-match notice for
`IOHIDDevice` with usage page 1 and usage 6 (a keyboard) schedule a re-apply 1.5 s later: the
tap is turned on again and the mapping is written again. The `hyper` rows show the state,
whether the mapping is active (read from hidutil at most every 2 s, off the main thread), and
Accessibility. `HotKeySpec.parse` reads `hyper` as all four modifiers.

### Disk map

`DiskMapWindow.swift`, with the scan and the layout in core.

`DiskScanner` walks one volume with `getattrlistbulk` on a pool of threads
(one for each active processor). A worker reads one folder without the lock,
then takes the lock to add the entries to the `DiskTree` and to queue the
subfolders. The tree is flat arrays indexed by node id; the children of a
folder have consecutive ids and a child has a larger id than its parent, so
one pass from the end sums the folders. Size is allocated bytes. A file with
more than one link is counted at its first sighting. A folder on another
device, and an iCloud folder that is not downloaded, is not entered. `du`
scans `/System/Volumes/Data` (`/` is the sealed system volume; the user's
files are only linked into it) and the window removes that prefix from paths.
Measured on a folder of projects: 720,000 files in 3 s, with about 200 MB in use at the peak.

`Treemap.layout` is a squarified treemap in pixels. Children are sorted by
size for each folder that is drawn; a child that would be smaller than 2
pixels square joins one "small" block of its folder, and a folder narrower
than 4 pixels is one block. Each block carries the cushion surface (van
Wijk), and `Treemap.render` lights it into RGBA bytes on all cores. With
`free` bytes, the layout first divides the area between the tree and one
`.free` block (node -1), which the renderer draws flat with diagonal lines.

The view scans on a global queue, and lays out and draws on its own serial
queue; a generation number drops a picture that is out of date. The only
change to a tree after the scan is `remove` (after a move to the Trash),
which runs on that same queue. Hit-testing is a linear search of the blocks.
The L key lists the largest files below the zoomed folder (100 MB or more)
whose access date is older than six months; only the 400 largest are checked.
A `.Trash` folder at the top of the scan, or in a user's folder on a whole
disk, is drawn in its own color.
`Kea --diskmap-snapshot <folder> out.png` scans, prints counts and times,
and writes `out.png`, `out-old.png` (with the list), and `out-zoom.png` with
no window.

### Paint

`PaintWindow.swift`. `PaintCanvas` owns one bitmap `CGContext` of 1920 × 1280
pixels (2 for each point); every tool draws into it, and `draw(_:)` shows an
image of it. A line, rectangle, or ellipse that is still dragged is drawn over
the view with the same width and color, and goes into the bitmap on mouse up.
A freehand stroke is smoothed a little: the pen moves 60% of the way to the
pointer on each event, and the stroke is drawn as curves between the middles
of the pen positions, so pieces join without corners. Undo keeps up to 20 images of the bitmap, taken before each change; the window
object is dropped on close to free them. The fill is `PaintFill.fill` in core:
a run-by-run flood fill with a color tolerance, which then mixes the one-pixel
ring around the filled area half and half with the new color, so that the
smooth edge of a line leaves no pale outline. The drawing is written to
`~/.launcher/paint.png` 1.5 s after the last change and on close.
`Kea --paint-snapshot out.png` draws a sample with every tool with no window
and without touching the saved drawing.

### Uninstall, screenshot, record, convert, QR

`UninstallCommand.plan(for:)` lists the app, the items in the `~/Library`
folders of `Uninstall.libraryFolders` for which `Uninstall.belongs` is true
(the bundle id, the bundle id plus a dot, or the app's name), the app's dot
folder in the home folder, and the links in `/usr/local/bin` and
`/opt/homebrew/bin` that point into the app. Sizes come from `du`. An alert
shows the list; only then `FileManager.trashItem` runs for each item.
`Kea --uninstall-plan <name>` prints the list and moves nothing.

`press <folder>` frees disk space and deletes nothing (core `Press`). `Press.scan`
walks the folder and reads only metadata, plus the content of files that have the
same size as a different file. `Press.skip` gives the reason that a file is left
alone; `Press.refusal` gives the reason that a folder is not pressed at all. Two
changes exist:

- **Compress** (`Press.compress`): `/usr/bin/ditto --hfsCompression` writes a
  compressed copy next to the file, with the same dates, mode, attributes, and
  access list. Kea checks that the copy is compressed, is smaller on the disk,
  and has the same bytes, and that the file did not change in the meantime. Then
  `rename` puts the copy in the place of the file. `ditto` keeps the compression
  only when it gains about a fifth, so `Press.estimate` measures each large file
  at 32 or 128 places and leaves out the ones that do not reach that.
- **Share** (`Press.share`): for files with the same content, one is the keeper.
  `clonefile` makes a clone of the keeper next to each copy, `Press.copyMetadata`
  gives the clone the mode, hidden flag, attributes, access list, and dates of the
  copy, and `rename` puts it in the place of the copy. Files that already are
  clones of one another have the same `fileContentIdentifier` and are not counted.

A copy is not compressed: it gets the data of its keeper, and the keeper is
compressed first. `Press.openFiles` lists the files that a process has open
(libproc); a press asks for the list again every 5 seconds and leaves those files.
A replaced file has a new inode. That is why files with hard links, databases,
disk images, and files that changed in the last day are left alone: a program
that holds the old file open would write to a file that no path names.
`Kea --press-plan <folder>` prints the plan and changes nothing.
`Kea --press-apply <folder>` presses with no question; use it only on a test folder.

`ScreenGrab.region` runs `screencapture -i` (the same as `ocr`) and gives a
`CGImage`. `shot` hands it to `ImageEditor` or `PaintWindow`; `qr` hands it to
Vision (`VNDetectBarcodesRequest`). `QRCommand.image` draws a
`CIQRCodeGenerator` code with whole pixels for each module.

`ScreenRecorder` (RecCommand.swift) asks for a rectangle with `RegionPicker`
(one dim window on each screen), then runs `screencapture -v -R x,y,w,h` with
an open, empty pipe as its input, and stops it with an interrupt signal.
`RecordingHUD` is the red frame and the Stop button; their windows have
`sharingType = .none`, so they are not recorded. When the tool exits,
`MediaConvert` makes the GIF (frames from `AVAssetImageGenerator` into a
`CGImageDestination`) or the MP4 (a passthrough export), and the file goes on
the pasteboard as a file URL.

`ConvertCommand` reads the Finder selection with `osascript` off the main
thread and keeps it for 2 s; the rows come from `Convert` in core (what a file
can become, and the name of the new file). Images go through `sips`, videos
through `MediaConvert`. `Kea --convert <target> <file>…` runs the same
conversion from the shell, and `KEA_CONV_FILES=a:b` stands in for the Finder
selection in `--query "conv"`.

### Solitaire

Core `Solitaire.swift` has what every card game shares: `Card` (one number;
suit and rank come from it, and a second deck has ids from 52), `PileID`, and
the protocol `SolitaireGame`: the cards of a pile, the run a person may lift,
whether a run may drop on a pile, the move, the stock, the best place for a
click (`autoTarget`), and one safe move to a foundation (`autoStep`).
`Sawayama.swift` is the first game. FreeCell and Spider are planned: each is a
new struct that answers the same questions, and `PileID.cell` and the deck
number in `Card` are there for them.

`SolitaireView` draws the table and knows only the protocol, plus where
Sawayama's piles are (`slot`, `position`): the stock at the top left, the
waste spread over the rest of the top row (it closes up to fit all 24 cards, and
a covered card has its suit below its rank), the foundations down the right. It holds no positions of its own:
`placements()` lists every card with its place from the game, and a move
glides each card from where it was drawn to its new place for 0.16 s. After
each move a timer calls `autoStep` every 0.11 s until nothing is safe, so the
cards go home one at a time. Undo restores the table from before the person's
move, which is always a settled table. `Kea --sol-snapshot out.png` renders
three sample tables with no window and does not touch the saved game.

### Tidy

`TidyCommand.swift`. A scan runs on a utility queue at most every 10
minutes (the coordinator refreshes the rows every 0.75 s while a scan or a
clear runs). Sizes come from `du -sk`; values are stored on the main thread,
which is the only reader. The places it knows are listed in `scan()`; it
touches nothing else. Safe rows clear by moving folder contents to the Trash
(DerivedData, SwiftPM cache, old DeviceSupport) or by the owning tool (`npm
cache clean --force`, `pnpm store prune`, `pip3 cache purge`, `brew cleanup
--prune=all -s`, `xcrun simctl delete unavailable`). Review rows: iCloud
eviction (`FileManager.evictUbiquitousItem` on uploaded files not opened in 30
days), `docker system prune -f` (only when Docker runs), and the Downloads,
projects (`Tidy.buildFolders` in `~/Developer/*` and `~/Projects/*`, idle by last git commit), and caches
sub-lists, simulator runtimes not used for 90 days (`Tidy.unusedRuntimes`, from
`simctl runtime list -j`; the newest stays), mounted disk images (`hdiutil
info -plist`; `Tidy.isEjectable` leaves the simulator images alone), and large
AI model files (a `DiskScanner` walk of the project roots, `~/.cache`,
Application Support and Downloads). `Kea --tidy-scan` prints one scan and
clears nothing. "Empty Trash" asks with an alert, then tells Finder to empty it.
`Tidy.swift` (core) holds the size format, the DeviceSupport keep rule, and the
staleness rule. Headless checks need `KEA_QUERY_WAIT=150` because the scan is slow.

### Menu bar item

`AppDelegate.updateStatusTitle()`. The icon is a bird (a cursor while
the autoclicker runs, a cup while caffeinate is on). `updateStatusIcon()` picks it. The
title starts with "Clicking 50/s" while the autoclicker runs. Then it shows the soonest timer with its badge. The menu also has Show, Settings, Reload Commands, Open Commands
Folder, Launch at Login, and Quit. A Dock click (reopen) shows the panel.

### Keyword aliases

Every keyword and alias in `allKeywords`, grouped by feature:

| Feature | Keywords |
|---|---|
| Dictionary | `define`, `def` (config `defineKeywords`) |
| Etymology | `ety`, `etym`, `etymology`, `origin` |
| Clipboard | `cb` (config) |
| Calendar | `cal` (config) |
| Web searches | `g`, `c`, `gpt` (config `webSearches`) |
| Lorem, timer, settings panes, stats | `lorem`, `timer`, `settings`, `stats` |
| Developer tools, time zones | `uuid`, `b64`, `url`, `hash`, `json`, `color`, `tz`, `time` |
| Ports and processes | `port`, `ports`, `kill`, `quit` |
| OCR, snippets, menu search, layouts | `ocr`, `snip`, `snippet`, `snippets`, `menu`, `layout`, `layouts` |
| Emoji, zalgo, image editor | `e`, `emoji`, `zalgo`, `ie` |
| Help | `help`, `?` |
| Keep awake | `caff`, `caffeinate`, `awake`, `caffeine` |
| Meeting alerts | `alerts`, `inyourface`, `iyf` |
| Zones | `zones`, `zone`, `win` |
| Keyboard lock | `clean`, `kblock`, `keylock` |
| Autoclicker | `autoclicker`, `click`, `clicker` |
| Hyper key | `hyper`, `capslock` |
| Audio | `audio`, `sound`, `output`, `speaker`, `speakers`, `mic` |
| Bluetooth | `bt`, `bluetooth` |
| Default apps | `default`, `defaults`, `openwith` |
| Terminal command | `t` (config `terminal.keyword`) |
| Finder | `finder` |
| Boot | `boot`, `startup`, `login` |
| Weather | `weather` (config) |
| 2048 | `2048` |
| Tidy | `tidy`; `tidy downloads`, `tidy projects`, `tidy caches` |
| Disk map | `du`; `du <folder>` |
| Paint | `paint`, `doodle` |
| Script commands | each list command's `keyword` |

### Script commands

`ScriptCommands.swift` and core `Command.swift`. Each folder in
`~/.launcher/commands/` has `command.json` (`title`, `keyword`, `subtitle`,
`icon`, `mode`; `mode` defaults to `action`) and an executable `run`.
Scripts run with the working directory `~` and with `/opt/homebrew/bin` and
`/usr/local/bin` added to the front of `PATH`. A list item whose action
`type` is not `open`, `shell`, or `copy` gets no action.

### Currency rates

`RatesStore.swift` fetches `https://api.frankfurter.app/latest?from=USD`
(ECB data) at most once a day and caches it in `rates.json`.

### Settings window notes

`SettingsWindow.swift` builds an `NSGridView` form in a scroll view. The
multi-line boxes come from `scroll(_:height:)`, a local function inside
`buildForm()`. `snapshot(to:)` (for `--settings-snapshot`) lays out a fixed
list of text views; add new ones to that list.

## Data on disk

| Path | Owner | Contents |
|---|---|---|
| `~/.launcher/config.json` | the user, Settings window | All settings. Every key optional. |
| `~/.launcher/frecency.json` | Kea | Use counts and last use per result id |
| `~/.launcher/clipboard.json`, `~/.launcher/clipboard/*.png` | Kea | Clipboard history |
| `~/.launcher/rates.json` | Kea | Exchange rates, refreshed daily |
| `~/.launcher/commands/` | the user | Script commands |
| `~/.launcher/launcher.log` | Kea | Debug log |
| `~/Library/LaunchAgents/directory.kea.launcher.agent.plist` | Kea (`--login on`) | Starts Kea at login |

## Config

`LauncherCore/Config.swift` is the schema. Top-level keys: `hotkey`,
`appFolders`, `fileSearch`, `maxResults`, `placeholder`, `webSearches`,
`defineKeywords`, `clipboard`, `folders`, `calendar`,
`appearance`, `zones`, `weather`, `imageEditor`, `commands`. Each struct has a custom
`init(from:)` that uses `decodeIfPresent` with a default for every key, so
an old or partial config always loads. The README "Config" section and
each feature section show examples.
