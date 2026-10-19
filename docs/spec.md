# Kea: a specification to build it again

Kea is a small native launcher for macOS. A hotkey opens a search box. The box finds apps
and files, does math, and holds about fifty keyword tools: clipboard history, timers, a
calendar, window zones, a disk map, screen capture, and more. It has no accounts, no
extension store, no web view, and no network service of its own.

This document describes Kea well enough that a coding agent can build an equal launcher
from nothing. It says what to build and how each part must behave. It does not give the
code. The source of the original is in this repository.

To use it: give this file to your agent and say "Build this for me, part by part, in the
order of section 12. Ask me before each permission prompt." Change what you do not like.
The rules in section 1 are the part to keep.

---

## 1. Rules that make Kea good

These rules are more important than any feature. A launcher that breaks them feels slow or
rude, however many features it has.

1. **Speed is the main feature.** The panel shows about 10 ms after the hotkey (the original: median 9 ms, 90% under 16 ms). No
   slow work runs on a keystroke or when the panel opens. Indexes, icons, caches and the
   list of recent items are made before they are needed. Slow answers (Spotlight, the
   network, other processes) come later and never block typing.
2. **Keyboard first, and never steal focus.** The panel is a non-activating panel. The app
   behind it keeps focus, as with Spotlight. When the panel closes, the app that was in
   front is in front again.
3. **One keyword, one feature.** Each tool starts with a short word: `cb` for the
   clipboard, `timer`, `du`, `qr`. The keyword alone shows the state or the choices. The
   keyword with text shows a preview. Return does it.
4. **Preview before action.** The title of a row says exactly what Return does: "Start a
   25m timer", "Move Ollama and 3 items to the Trash". Nothing destructive happens without
   a Return on a row that says so. Deletion goes to the Trash when possible, and a
   permanent action asks one more time.
5. **Stable results.** Rows that are ready at once (apps, the calculator, commands) never
   move when slow rows (files from Spotlight) arrive. Slow rows go below them.
6. **Config is one JSON file, and the Settings window edits the same file.** Every key is
   optional and has a default. A key with a wrong type gets its default and does not break
   the rest of the file. Nothing is kept only in the user interface.
7. **Local data is plain files** (JSON and CSV in `~/.launcher/`), so the person and other
   tools can read them.
8. **Pure logic is separate and tested.** Parsing, math, ranking, layouts and file formats
   are in a library with no user interface, with unit tests. The app is a thin layer over it.
9. **Ask before power.** Root access, control of the keyboard, firewall rules and other
   strong permissions come only when the person asks for the feature that needs them.

---

## 2. Technology and layout

- Swift with AppKit. No SwiftUI is necessary, and no Electron or web view.
- macOS 14 or later, Apple silicon. One Swift package with two targets:
  - `LauncherCore`: a library. Foundation and CoreGraphics types only. Everything that
    can be tested without a screen: the query parser, fuzzy matching, frecency, the
    calculator, unit conversion, duration and date parsing, the zone layout language,
    the treemap, solitaire rules, config decoding, script command manifests.
  - `Launcher`: the executable. AppKit, Carbon hotkeys, EventKit, the Accessibility API,
    Vision, AVFoundation.
  - A test target for `LauncherCore` (XCTest).
- A `Makefile` with `build`, `test`, `bundle` (makes `Kea.app` with an `Info.plist` that
  sets `LSUIElement` to true, so there is no Dock icon), `install` (copies to
  `/Applications`), and `reload` (restarts the installed app).
- Sign the app with a stable identity (an Apple Development certificate, or a self-signed
  code-signing certificate in the keychain). Ad hoc signing makes macOS forget each
  privacy permission after every build.
- One instance only: at start, exit if another process with the same bundle id runs.
- Data folder: `~/.launcher/` (config, frecency, clipboard images, logs, saved games).
- A log file, `~/.launcher/launcher.log`, with one line for each important event: hotkey
  registration, panel show time in milliseconds, script failures, permission states.

---

## 3. The panel

- An `NSPanel` subclass with `.nonactivatingPanel`, a large rounded rectangle with a
  blurred background (`NSVisualEffectView`), centered in the upper third of the screen
  that has the mouse pointer.
- Parts: one text field with a large font (24 pt), and a table of result rows under it.
  The panel grows down with the rows. Each row has an icon (32 pt), a title, and a
  smaller gray subtitle. Some rows can wrap their subtitle over several lines (a
  definition, the help list). A row can show key caps at its right edge (for a menu item
  shortcut).
- Fast open: keep the panel on screen at alpha 0 between uses. To show it, set alpha 1,
  make it key, and put the cursor in the field. Log the time it takes.
- It hides on Escape with an empty field, when another app comes to the front, or on a
  click outside it.
- A global hotkey shows and hides it (default Option+Space; Command+Space works after the
  person turns off the Spotlight shortcut). Use the Carbon `RegisterEventHotKey` API.

Keys in the panel:

| Key | Action |
|---|---|
| Up, Down | Move the selection |
| Return | Do the action of the selected row |
| Command+Return | Show the item in Finder |
| Command+Y | Quick Look the item (Up and Down still move through the rows) |
| fn+Delete or Command+Delete | Delete the selected item: files go to the Trash, clipboard entries are removed |
| Tab | Complete the keyword of a list command |
| Escape | Clear the text, then hide |
| Command+A, C, V, X, Z | Normal text editing (the app needs an Edit menu for these, even with no Dock icon) |
| Command+, | Settings |

An empty field shows the most-used items.

---

## 4. Search

### 4.1 The query

On each keystroke, parse the text:

- **A keyword command**: the first word is a known keyword, and a space follows it or the
  text is only the keyword. Show only that command's rows.
- **Plain search**: everything else.
- **Empty**: the recent list.

### 4.2 Plain search, in this order

1. A calculator row, if the text is math: `12*4.5`, `2^10`, `sqrt(2)`, `15% * 80`. Return
   copies the answer.
2. A conversion row, if the text is a conversion: `10 mi in km`, `72f to c`,
   `1 gib in mib`, `100 usd in eur`. Currency uses the daily rates of the European Central
   Bank, fetched one time a day and kept in a file.
3. A time zone row, if the text is a time with zones: `3pm pst in nyc`.
4. The instant sources, merged and ranked together: apps, System Settings panes, quick
   folders (Downloads, Desktop), action script commands, and the plain-search rows that
   commands give ("Keep Awake", "Disk Map", "Show Hidden Files").
5. Show these rows at once.
6. After a short pause (about 180 ms after the last keystroke), ask Spotlight
   (`NSMetadataQuery`) for files by name, and add them below. Do not move the rows above.
7. If nothing matched, one row searches the web.

Drop a late answer that belongs to an older query (use a counter that each keystroke
increases).

### 4.3 Ranking

- Fuzzy match: an exact match scores highest, then a prefix, then the start of a word
  ("vsc" finds "Visual Studio Code"), then letters in order with bonuses for runs.
- Weight by source: apps a little higher than settings and commands, files lower.
- Frecency: each time the person opens a row, add to its count. The score is
  `1 + ln(1 + count)` plus a bonus for recent use. Keep it in `~/.launcher/frecency.json`,
  keyed by a stable row id such as `app:/Applications/Safari.app`.

### 4.4 Apps

Index `.app` bundles in `/Applications`, `~/Applications`, `/System/Applications` and its
Utilities, at start and when those folders change. Also ask Spotlight for applications in
other places. Load icons in the background and cache them.

---

## 5. Commands

### 5.1 One list of commands

Each keyword tool is a value with:

- `id`: a stable name, used in config to turn it off.
- `name`: for people ("Disk Map").
- `keywords`: every word that starts it (`du`).
- `help`: one or more lines with an example.
- `results(keyword, argument, context)`: the rows. The context has a `refresh()` function
  that the command calls when a slow answer arrives.
- Optional `live`: an interval and a condition. While the condition is true, ask the command
  for its rows again on that interval (a scan in progress, a running timer).
- Optional `search(term)`: rows for plain search, when the feature is also useful without
  its keyword.

Each feature defines its command next to its own code. One list in one file holds all of
them, in order. Everything reads that list: the dispatch, the set of known keywords, the
`help` command, the checkboxes in Settings, and the `commands.disabled` key in config.

A command that is turned off does not react to its keyword (the word becomes normal search
text), leaves `help`, adds nothing to plain search, and stops its background work. When two
commands claim one keyword, log a warning; the first in the list wins.

### 5.2 Row rules for every command

- The keyword alone: show the current state and the choices.
- With text: show a preview row whose title says exactly what Return does.
- Text that cannot be read: one row "Could not read …" with an example in the subtitle.
- A slow reading (a process list, sensors, a scan) runs off the main thread. The rows show
  the last answer, and `refresh()` runs when a new answer arrives.

### 5.3 Script commands

People add their own commands without code in the app. Each one is a folder in
`~/.launcher/commands/` with a `command.json` and an executable file `run`:

```json
{ "title": "Projects", "keyword": "p", "subtitle": "Open a folder", "icon": "sf:folder", "mode": "list" }
```

- `icon`: an absolute path, a `~` path, or `sf:` and an SF Symbol name.
- `mode: action`: the command is one row when its title or keyword matches. Return runs
  `run` with the query as the first argument.
- `mode: list`: typing the keyword and a space gives the rest of the text to `run` as the
  first argument. `run` prints JSON: `{"items": [{"title", "subtitle", "icon", "action":
  {"type": "open"|"shell"|"copy", "target": "…"}}]}`. Wait 120 ms after the last keystroke
  before a run.
- A script that exits with an error, prints bad JSON, or runs for more than 8 seconds
  shows one "failed" row with the first line of its error output.

---

## 6. Config and settings

- `~/.launcher/config.json`. Decode each key with a default; a key with a wrong type gets
  its default, and the rest of the file still loads. An old file must always load.
- A Settings window (from the menu bar item, Command+, in the panel, or a search for "kea
  settings") edits the same file and restarts the app on Save. Sections: General (hotkey,
  launch at login, folders), Appearance (theme, accent, font size), Window Zones (with a
  live preview of each display's layout), Commands (one checkbox for each command).
- Hotkey syntax: modifiers from `command`, `option`, `control`, `shift`, joined with `+`,
  then a key (a letter, a digit, `space`, `return`, `escape`, `tab`, arrows, `f1`–`f12`).
- Launch at login with a user LaunchAgent (`RunAtLoad`, restart after a crash, stay
  quit after Quit).
- A menu bar item with: Show, Settings, Reload Commands, Open Commands Folder, Launch at
  Login, Quit. It can show a short title (the countdown of the nearest timer).
- Themes: System, Light, Dark, and a few colored ones. A theme sets the panel tint, the
  text colors and the selection color. The panel must not grow or shrink as it opens.

---

## 7. Features

Each feature below is a keyword command unless the text says otherwise. Build the ones you
want. The behavior in each entry is the behavior of the original.

### 7.1 Text and knowledge

- **Calculator and conversion** (plain search, section 4.2). Return copies the result.
- **Dictionary**: `def word`. The definition from the system dictionary (the Dictionary
  Services API). Return opens Dictionary.app. `ety word` shows the ORIGIN section only.
- **Web searches**: a map in config from a keyword to a URL with `{query}`, for example
  `g` for Google. The `g` entry is also the fallback of plain search.
- **Clipboard history**: `cb`. The last 100 copies, text and images. Watch the general
  pasteboard on a short timer. Skip entries that password managers mark as confidential
  (`org.nspasteboard.ConcealedType`). Images are saved as PNG files. Return puts an entry
  back on the clipboard; fn+Delete removes it; `cb clear` clears all.
- **Snippets**: type a trigger such as `;sig` in any app and it becomes its text.
  Placeholders `{date}`, `{date+1}`, `{time}`, `{clipboard}`. Needs an event tap and
  Accessibility. The list is a JSON file; `snip new ;sig Best, Sam` adds one.
- **Emoji**: `e party`. Search emoji names and keywords; the ones used most come first.
  Return types the emoji into the app that was in front (or copies it without
  Accessibility).
- **Text styles**: `zalgo hello` in three strengths. The row shows exactly what Return copies.
- **Placeholder text**: `lorem`, `lorem 3`, `lorem 3 md` (a Markdown document with every
  element type, to test a renderer).
- **Developer tools**: `uuid`, `b64 text`, `url text`, `hash text` (MD5, SHA-1, SHA-256,
  SHA-512), `json {…}` (pretty and compact, and where it is not valid), `color #ff8800`
  (hex, RGB, HSL; `color` alone picks a color from the screen with `NSColorSampler`).
- **Time zones**: `tz` shows favorite zones; `tz 3pm pst in nyc` converts.

### 7.2 Time and the calendar

- **Timers**: `timer 25m`, `timer 2h5m`, `timer 10` (a bare number is minutes), with an
  optional label. A notification with sound at the end. The menu bar shows the countdown.
  `timer` alone lists them; fn+Delete cancels one.
- **Calendar events**: `cal dentist fri 2-3:30pm`, `cal deep work mon 9am for 2h`. Parse a
  title, a day, a time or range, or a duration. The row previews the parsed event. Return
  saves it with EventKit. No time means all day. `cal` alone lists the next 7 days.
- **Meeting alerts**: one minute before each event, cover every display with a full-screen
  alert above full-screen apps: title, time, a countdown, the place, and a large Join
  button when the event has a video call link (Zoom, Meet, Teams, Webex, FaceTime). Return
  joins, S snoozes, Escape dismisses. Skip all-day and declined events.
- **Weather**: `weather`, `weather tokyo`. Now, the next 12 hours, 7 days, and "what to
  wear" (from the coldest "feels like" for the rest of the day, rain chance, wind, UV).
  Use a free API that needs no key (Open-Meteo). Load the default place in the background
  one time each day, so the rows are there when the person types.

### 7.3 The Mac

- **System Settings panes**: `settings wifi`. Open each pane by its URL
  (`x-apple.systempreferences:` and the pane id). Common panes also show in plain search.
- **Keep awake**: `caff`, `caff 45m`, `caff off`, with the system `caffeinate` tool. The
  menu bar icon changes while it is on.
- **Audio devices**: `audio` lists outputs and inputs and marks the current ones; Return
  switches (Core Audio).
- **Bluetooth**: `bt` lists paired devices; Return connects or disconnects.
- **Default apps**: `default md`, `default browser` lists the apps that can open a type or
  a link scheme; Return makes one the default.
- **Finder toggles**: hidden files, desktop icons, file extensions.
- **Login items**: `boot` lists what starts at login or runs in the background; Return
  removes or disables a person's own item.
- **System stats**: `stats` shows CPU, GPU, memory, disk, temperature and battery, live,
  every 2 seconds, with the readings done off the main thread.
- **Ports and processes**: `port 3000` shows what listens on a port; `kill chrome` quits an
  app or stops a process. Everything except a normal Quit asks first.
- **Menu search**: `menu export` searches the menu bar of the front app through
  Accessibility. Return chooses the item. The row shows the menu path and the shortcut.
- **Keyboard lock**: `clean 30s` ignores every key so the person can wipe the keyboard. The
  mouse still works, and a panel shows the countdown and an Unlock button.
- **Hyper key**: Caps Lock acts as Control+Option+Command+Shift in every app. Remap it with
  `hidutil` while the app runs, keep the other mappings, and put Caps Lock back when the app
  quits, also on SIGTERM.
- **Autoclicker**: a left click at the pointer every 0.02 s until a hotkey, Escape, sleep or
  a screen lock stops it.
- **Terminal**: `t ls -la` opens a new terminal window and runs the command there.

### 7.4 Windows

- **Zones**: each display is split into zones by a small layout language:
  - `zone` is one zone; `cols 3` and `rows 2` split evenly;
  - `cols(a, b, …)` and `rows(a, b, …)` nest; `2*zone` takes twice the space.
  - Example: `cols(2*zone, rows 2)` is a wide left zone and two stacked on the right.
  - Config: a list of `{ "match": …, "layout": … }`. `match` is `builtin`, `portrait`,
    `landscape`, `main`, `*`, or part of the display name. The first match wins.
  - A gap (default 8 pt) between zones and at the edges of the usable area.
- **Moving with keys**: Command+Shift+Right moves the front window to the next zone, across
  all displays from left to right, and wraps. Left goes back. Up fills the display, and on
  a full window it toggles a centered "focus" size (60% × 85%). Down minimizes; Up brings
  back the last minimized window of the app. Remember where each window was put, because
  some windows cannot take an exact size (terminals round to their cell grid).
- **Drop zones**: while the person drags a window by its title bar and holds Shift, show
  every zone as a gray rectangle on every display. The zone under the pointer lights up;
  on release the window fills it. Near the border of two zones, the window spans both.
  Releasing Shift first cancels. Build it this way:
  - Watch only the modifier keys all the time; add the mouse monitors only while Shift is
    down.
  - To know that a drag moves a window, read the window under the pointer from the window
    server (`CGWindowListCopyWindowInfo`) two times, and check that it moved as the
    pointer moved. Do not use the Accessibility position for this: many apps report a
    stale position during a drag.
  - Set the frame with Accessibility only after the drop.
- **Saved layouts**: `layout save work` records where the front window of each app is, as
  shares of its display; `layout work` puts them back.
- All window work uses the Accessibility API (`AXUIElement` position and size).

### 7.5 Disk space

- **Disk map**: `du` or `du ~/Downloads`. A cushion treemap, like WinDirStat:
  - Each file is a block whose area is its size on disk; the color is its file type (the
    12 types that use the most space); the shading shows the folders.
  - Scan with `getattrlistbulk` on a pool of threads. Count allocated bytes, count each
    hard-linked file one time, do not follow symbolic links, stay on one volume, and never
    open an iCloud folder that is not downloaded.
  - Keep the tree in flat arrays (about 40 bytes for each file).
  - Free space is one block with diagonal lines.
  - Click selects, Return zooms in, Delete zooms out, Space previews, Command+Delete moves
    to the Trash.
  - L lists large files that were not opened for six months.
- **Tidy**: `tidy` finds space to free:
  - Safe rows that rebuild by themselves: build output, package manager caches, old iOS
    device support files, unavailable simulators.
  - Rows that need a decision: old downloads, build folders of old projects, app caches,
    unused Docker data, unused simulator runtimes, mounted disk images, large AI model files.
  - Nothing goes without a Return. Folders go to the Trash; tool caches are cleaned by
    their own tool.
- **Uninstall**: `uninstall <app>` lists the app and its leftovers with sizes, then moves
  them to the Trash after a confirmation:
  - Leftovers are the items in the `~/Library` folders that carry the app's bundle id or its
    exact name, and its dot folder in the home folder.
  - Keep the match strict, because a loose match puts another app's data in the Trash.
  - Never offer an app that is part of macOS.
- **Press**: `press <folder>` frees space and deletes nothing:
  - Apply APFS transparent compression in place.
  - Make files with the same content share their data as APFS clones.
  - Compare each new file with the old one, byte for byte, before it takes its place.

### 7.6 Screen and media

- **Screenshot to editor**: `shot` captures a region or a window (`screencapture -i`) and
  opens it at once in the image editor or in the paint window.
- **Image editor**: `ie` opens the clipboard image with tools for arrows, boxes, text,
  pen, highlight, redaction and pixelation. Marks stay movable. Return copies the result
  and closes.
- **Paint**: `paint` opens a small drawing window like MS Paint:
  - Tools: pencil, eraser, fill, line, rectangle, ellipse, and a color picker, in four
    sizes, with the 20 classic Paint colors.
  - Freehand strokes are smoothed a little: the pen moves part of the way to the pointer on
    each event, and the stroke is drawn as curves between the middles of the pen positions.
  - Return copies the drawing and closes the window. The drawing is kept between uses.
- **Screen recording**: `rec`, `rec gif`, `rec mp4`. Drag over a region; a red frame and a
  Stop button show while it records, and both are left out of the recording
  (`sharingType = .none`). The file goes to the clipboard as a file.
- **Convert**: `conv jpg`, `conv 1600`, `conv gif` converts the files selected in Finder:
  images with `sips`, videos with AVFoundation. The new file goes next to the original.
- **Text from the screen**: `ocr` reads the text in a dragged region (Vision) and copies it.
- **QR codes**: `qr <text>` shows a QR code (Core Image) in a small window; `qr` also reads
  one from the screen or the clipboard image.

### 7.7 Games, for a short wait

Each game is a small window. It saves its state, so its keyword resumes it.

- **2048**: tiles glide and merge with short, springy motion. A key press never waits for an
  animation. Undo has no limit.
- **Sawayama Solitaire**:
  - Klondike with every card face up.
  - The stock is dealt three at a time and one time only; when it is empty, its place is a
    free cell for one card.
  - Any card can go to an empty column.
  - Drag a card or a run, or click it to send it to the best place.
  - A card that no other card can still need goes to its foundation by itself.
  - Keep the rules in the core library behind a small protocol (cards, piles, "can this run
    drop here", "the best place for a click", "one safe move home"), so FreeCell and Spider
    can use the same window.

---

## 8. Permissions

Ask for each permission only when the person first uses a feature that needs it, and show a
row that opens the right System Settings pane when it is missing.

| Permission | Features |
|---|---|
| Accessibility | Window zones and drop zones, menu search, snippets, the keyboard lock, typing an emoji, the Hyper key, the autoclicker |
| Screen Recording | `shot`, `rec`, `ocr`, reading a QR code from the screen |
| Calendars | `cal`, meeting alerts |
| Full Disk Access | A correct `du` map of the whole disk (without it, protected folders count as empty) |
| Automation (per app) | Script commands that drive Finder or System Events, reading the Finder selection for `conv`, the terminal command |
| Location (optional) | The default place for `weather` |
| Bluetooth | `bt` |

---

## 9. Speed budget

| Moment | Budget |
|---|---|
| Hotkey to a visible panel | about 10 ms; never more than one frame or two |
| Keystroke to instant rows | under 16 ms (one frame) |
| Keystroke to file rows | about 200 ms (debounce and Spotlight) |
| App start to a warm panel | about 3 s, in the background |

To keep these: build the recent list, app icons and command caches after start; keep the
panel alive at alpha 0; do every reading of another process (`ps`, `lsof`, sensors,
Accessibility, Spotlight) off the main thread; and drop late answers.

---

## 10. Data on disk

| File | Holds |
|---|---|
| `~/.launcher/config.json` | All settings |
| `~/.launcher/frecency.json` | Use counts and times for each row id |
| `~/.launcher/clipboard/` | Clipboard history and its images |
| `~/.launcher/snippets.json` | Snippets |
| `~/.launcher/layouts.json` | Saved window layouts |
| `~/.launcher/rates.json` | Daily currency rates |
| `~/.launcher/commands/` | Script commands |
| `~/.launcher/launcher.log` | The log |

---

## 11. How to check the work

- Unit tests for everything in the core library. Write the test first for each parser,
  layout, rule and file format.
- A headless mode: `Kea --query "text"` runs the full search without a window and prints
  the ranked rows. Use it for every change to rows, and keep a fixed list of queries whose
  output you compare before and after a change to search or dispatch.
- Snapshot flags that draw a window into a PNG with no window on screen (`--paint-snapshot
  out.png`, `--sol-snapshot out.png`, `--zonedrop-snapshot out.png`), so an agent can look
  at a feature without disturbing the person.
- A log line for each decision that can go wrong in the field (for example why a drag did
  not count as a window drag). Then a report of "it did not work" can be read from the log.

---

## 12. Build order

Build in this order. Each step gives something that works.

1. The package, the Makefile, signing, the app bundle with no Dock icon, one instance only,
   the log.
2. The panel and the hotkey, with a fixed list of rows. Measure the open time.
3. App search with fuzzy ranking, then frecency, then the recent list.
4. Spotlight file search below the instant rows. Quick Look, reveal, Trash.
5. The calculator and the conversions.
6. The command list (section 5.1) and `help`. Then add commands one at a time, each with
   its tests: clipboard, timers, settings panes, dictionary, web searches.
7. Config with defaults and the Settings window. Launch at login. The menu bar item.
8. Script commands.
9. Window zones, then drop zones.
10. The rest of section 7, in the order the person wants.

---

## 13. What Kea leaves out on purpose

- Accounts, sync, telemetry, and an extension store.
- Background work that the person did not ask for.
- Animations that change the size of the panel as it opens.
- A permanent delete without a second confirmation.
- Features that take control of keys or the network without the person's explicit choice.
