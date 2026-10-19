# Kea

A small native macOS launcher, named after the clever New Zealand parrot. A
hotkey (default Option+Space, set with `hotkey`) opens a search box that
finds apps and files, runs your own script commands, and holds keyword tools:
clipboard history, calendar events, timers, window zones, a disk map, screen
capture, and more. No accounts, no extension store, no Electron.

Working on the code? Read [AGENTS.md](AGENTS.md), then
[docs/architecture.md](docs/architecture.md) and [docs/decisions.md](docs/decisions.md).

## Build and install

```bash
make install
open /Applications/Kea.app
```

After later changes, `make install && make reload` installs and restarts it.

`make run` starts an unbundled copy from the build folder. It shares
`~/.launcher` with the installed app and competes for the same hotkeys, so
quit the installed Kea first. `make test`
runs the unit tests for the core library.

To start it at login, turn on "Launch at login" in Settings, or run:

```bash
/Applications/Kea.app/Contents/MacOS/Kea --login on
```

This writes a LaunchAgent (`~/Library/LaunchAgents/directory.kea.launcher.agent.plist`).
launchd starts it as soon as you log in, before the normal login items, and
starts it again after a crash. The icon comes from `swift scripts/make-icon.swift`.

## Use

| Key | Action |
|---|---|
| The hotkey (default Option+Space) | Show or hide |
| Up / Down | Move selection |
| Return | Open the selected item |
| Cmd+Return | Reveal in Finder |
| fn+Delete | Delete the selected item: files and notes go to the Trash, clipboard and log entries are removed. Calendar events are never deleted. Cmd+Delete does the same. |
| Tab | Complete a list command's keyword |
| Escape | Clear the query, then hide |

An empty query shows your most-used items.

Built-in extras:

| Type | Result |
|---|---|
| `12*4.5`, `2^10`, `sqrt(2)`, `15% * 80` | Calculator row at the top. Return copies the answer. |
| `def word` or `define word` | System dictionary definition. Return opens Dictionary.app. |
| `ety word`, `etym word`, `origin word` | Word origin from the system dictionary's ORIGIN section. Return opens Dictionary.app; a second row opens etymonline.com. |
| `g something` | Google search in the browser. |
| `c prompt`, `gpt prompt` | Opens Claude or ChatGPT with the prompt filled in. Bare `c` or `gpt` opens the desktop app if installed, else the site. |
| `10 mi in km`, `72f to c`, `1 gib in mib`, `100 usd in eur` | Unit and currency conversion. Currency uses daily ECB rates, cached in `~/.launcher/rates.json`. |
| `cb`, `cb text` | Clipboard history, last 100 copies, text and images. Return puts the entry back on the clipboard. fn+Delete removes the selected entry. `cb clear` wipes the history. Images are saved as PNG under `~/.launcher/clipboard/` and preview with Cmd+Y. Entries marked confidential by password managers are skipped. |
| `applications`, `downloads`, `desktop` | Quick folders, opened in Finder. The list is in settings. |
| `settings`, `settings blue` | Every System Settings pane. Common ones like Wi-Fi, Bluetooth, Displays, and Privacy & Security also show up in normal search. |
| `cal go to alex's tomorrow at 5p`, `cal dentist fri 2-3:30pm`, `cal deep work mon 9am for 2h`, `cal mom's birthday next friday` | Creates a calendar event. The row previews the parsed title and time; Return saves it to the calendar chosen in settings under "Add events to" (system default until you pick one). No time means all day. `cal` alone opens Calendar.app, with the next 7 days listed below. |
| `alerts`, `alerts test` (also `inyourface`, `iyf`) | Meeting alerts, like InYourFace. One minute before each calendar event, Kea covers every display with a full-screen alert, above full-screen apps: the title, the time, a countdown, the place, and a large Join button when the event has a Zoom, Google Meet, Teams, Webex, or FaceTime link (in the URL field, the location, or the notes). Return joins (Zoom and Teams links open in their app when it is installed), S snoozes for 1 minute, Esc dismisses. All-day and declined events do not alert. `alerts` shows the next alert time and the next events: Return previews an event's alert, Cmd+Delete skips it. `alerts test` shows a test alert; its Join opens Zoom's test page. Settings › Meeting Alerts sets the minutes before, a second alert at the start, and calendars to ignore. |
| `help`, `help cal` | Every keyword with an example. Return puts the keyword in the search field. |
| `stats` | Live CPU, GPU, memory, disk, temperature, and battery, refreshed every 2 seconds. Return opens Activity Monitor. |
| `caff lid` | Closed-lid options: stay awake with the lid shut, unlocked or locked, and restore normal sleep. Uses `pmset -a disablesleep` through the macOS admin dialog. The locked variant relies on "Require password after sleep" being set to immediately. |
| `caff`, `caff 45m`, `caff off` (also `awake`, `caffeinate`) | Keeps the Mac and display awake with the system `caffeinate` tool, indefinitely or for a duration. The menu bar icon becomes a cup while active. "Keep Awake" also appears in plain search. |
| `timer 5m`, `timer 2h5m`, `timer 2.5h`, `timer 25m focus`, `timer 10` | Countdown timer. A bare number is minutes; trailing words are the label. Fires a notification with sound; the menu bar shows the countdown. `timer` alone lists running timers, fn+Delete cancels one. |
| `weather`, `weather tokyo` | Current weather (temperature, feels like, high and low, wind, humidity, rain chance), what to wear, the next 12 hours, and 7 days. What to wear covers the rest of today until 10pm (from 8pm on, tomorrow 8am–8pm): clothing for the coldest "feels like", a layer when it swings 15°F or more, an umbrella or maybe one (rain 60%+ or 30%+, with the start time), a rain jacket instead when it is windy, boots for snow, sunscreen at UV 6+. Data from Open-Meteo (free, no account; only coordinates are sent). The place is `weather.location` in config if set, else your location from Location Services (macOS asks once), else the city of your time zone. `weather <place>` shows any place. Units follow the Mac's region; set `weather.units` to `metric` or `imperial`. Return opens the Weather app. Answers are kept for 10 minutes. Kea loads your default place in the background once a day, so `weather` opens with rows already there. |
| `audio`, `audio in`, `audio airpods` | Lists sound outputs and microphones, marks the current ones; Return switches. |
| `bt`, `bt airpods` | Lists paired Bluetooth devices, connected first; Return connects or disconnects. macOS asks once for Bluetooth access. |
| `default md`, `default json`, `default browser`, `default mail` | Lists the apps that can open that file type or link, current one first; Return makes another one the default (macOS confirms browser and mail changes). |
| `finder`, or search "hidden files", "desktop icons", "file extensions" | Show or hide hidden files, desktop icons, and file extensions. Restarts Finder so the change applies. |
| `boot`, `boot postgres` | Everything that starts at login or runs in the background (from `sfltool dumpbtm`, about 30 seconds the first time, kept 10 minutes): on or off, and running or not. Return removes an "Open at Login" app from login, or stops and disables one of your own launch agents in `~/Library/LaunchAgents` (`launchctl enable gui/$UID/<label>` undoes it). Other items open Login Items settings. Kea's own row does nothing. |
| `2048` | Plays 2048 in a small window. Tiles glide, merges pop (big ones flash a ring), new tiles spring in, the score counts up, and a new record makes Best glow; a key press never waits for an animation. Arrow keys, WASD, HJKL or a two-finger swipe slide; Cmd+Z or U undoes, as many moves back as you like; R or Cmd+N starts a new game; Escape closes. Undo and New Game are also buttons. T or the swatch button cycles color themes (Cute, pastel magenta to blue, the default; Tide, blues; Bloom, pinks; Classic, cream to wine), and the choice is remembered. Follows light and dark mode. The game and your best score are saved, so typing `2048` again resumes. `2048*2` and other sums still go to the calculator. |
| `sol` (or `sawayama`) | Plays Sawayama Solitaire in a small window. It is Klondike with three changes: every card is dealt face up, the stock is dealt three cards at a time and only one time, and when the stock is empty its place becomes a free cell for one card. Columns go down by one with the colors in turn, any card or run may go to an empty column, and each suit builds up from the ace on its own pile. Drag a card or a run, or click it to send it to the best place (its suit pile first, then another card, then an empty column, then the free cell). A click on the stock, or Space, deals. Every dealt card stays in view in a row along the top (only the last one can be taken), and the four suit piles are down the right side. Z or Cmd+Z undoes any number of moves, N deals a new game, Escape closes. A card that nothing can still need goes to its pile by itself. Not every deal can be solved. The game and the count of wins are saved, so `sol` resumes. "Solitaire" also finds it in normal search. |
| `tidy`, `tidy downloads`, `tidy projects`, `tidy caches` | Finds disk space to free. Scans in the background (about a minute; the list updates as it goes, and results are kept for 10 minutes) and shows free space and one row per place, with its size. **Safe** rows rebuild by themselves: Xcode DerivedData, the npm, pnpm, pip, Swift package and Homebrew caches, old iOS DeviceSupport versions, unavailable simulators. "Clear All Safe" clears all of them. Rows that need a decision each take their own Return: make iCloud Drive files not opened in 30 days cloud-only (they stay in Finder and download when opened), Docker unused images and containers, simulator runtimes that no simulator used for 90 days (the newest always stays; these are deleted for good, and Xcode can download them again), mounted disk images (ejected; an image in use stays, and the image files in temporary folders and Downloads go to the Trash), and four review lists: large AI model files (`tidy models`: safetensors, gguf, ckpt and similar of 500 MB or more, with the day each was last opened), Downloads added more than 30 days ago (largest first; Cmd+Y previews, fn+Delete trashes), build folders in projects under `~/Developer` and `~/Projects` untouched for 60 days, and app caches (an app that is running must be quit first). Folders go to the Trash; tool caches are cleaned by their own tool. Trashed items use space until the Trash is emptied, so the last row empties it after asking. Nothing is cleared without a Return press. |
| `du`, `du ~/Downloads` | Opens a map of what uses the disk, like WinDirStat. Each file is a block: the area is its size on disk, the color is its file type (the 12 types that use the most space; the list is below the map), and the shading shows the folders. `du` maps the whole disk and `du <folder>` maps one folder. On the map of the whole disk, free space is one flat block with diagonal lines. A scan of the whole disk is correct only when Kea has Full Disk Access: without it the first row opens that pane in System Settings, and protected folders count as empty. Click selects a file; another click on the same block selects the folder above it. Return or a double-click zooms into the folder, Delete zooms out, and the folder names at the top are buttons. Space previews, Cmd+R shows in Finder, Cmd+C copies the path, Cmd+Delete moves to the Trash (a folder asks first), R scans again, Escape closes. L lists the largest files (100 MB or more) that were not opened for six months; a click on a row selects the file on the map. What is in the Trash is drawn in its own color, with its total in the list of colors. Sizes are space on this disk, so an iCloud file that is not downloaded counts as nothing and a file with several hard links counts one time. Copies made with APFS cloning count each time, and the bottom line shows how much used space is outside the files (snapshots, purgeable space, the system). "Disk Map" also shows in normal search. |
| `paint` (or `doodle`) | Opens a small drawing window in the style of MS Paint, for a quick sketch. Tools: pencil, eraser, fill, line, rectangle, ellipse, and a color picker, each in four sizes (freehand strokes are smoothed a little), with the 20 classic Paint colors and a color well for any other color. Keys: P, E, F, L, R, O, I pick the tool and 1–4 the size. Shift keeps a line at 45° and a shape square; Option fills a rectangle or ellipse. Cmd+Z undoes (20 steps) and Cmd+Shift+Z redoes. Return copies the drawing and closes the window; Cmd+C copies and keeps it open. Cmd+S saves a PNG, Cmd+V puts the clipboard image on the canvas, Cmd+N starts a new drawing, Escape closes. The canvas is 960 × 640 points and does not change size. The drawing is kept in `~/.launcher/paint.png`, so `paint` shows it again. With an image on the clipboard, a second row opens Paint with that image. |
| `uninstall <app>` | Finds an app in `/Applications` and the files it left behind: its folders and files in `~/Library` (Application Support, Caches, Preferences, saved state, logs, containers, launch agents) that carry its bundle id or its name, and its dot folder in the home folder (`~/.ollama`). Return on the app shows the whole list with sizes and asks; after that everything goes to the Trash, so it can be put back. An app that is running must be quit first, and apps that are part of macOS are not offered. Command-line links that pointed into the app (`/usr/local/bin/…`) need an administrator: Kea names them and puts the `sudo rm` command on the clipboard. |
| `press <folder>` | Frees disk space in a folder and deletes nothing. Files get APFS transparent compression in place, and files with the same content share their data as APFS clones. Each file keeps its name, place, dates, mode, and attributes, and opens as before. The first Return only reads the folder and shows what a press frees (compression is an estimate). The press starts after a list and a confirmation; a second Return on the progress row stops it. Kea compares each new file with the old one, byte for byte, before the new one takes its place. Left alone: files that are open, files that changed in the last day, databases and disk images, files with hard links or special flags, cloud-only files, folders that a cloud service keeps, `.git` folders, and photo and virtual machine libraries. Only folders inside the home folder (not `~/Library`) and `/Applications`, on an APFS disk. There is no undo button: a compressed file stays compressed until a program writes it again. Each change is a row in `~/.launcher/press-log.csv`. |
| `shot` | Takes a screenshot and opens it at once: a region or a window in the image editor (`ie`), or a region on the Paint canvas. |
| `rec`, `rec gif`, `rec mp4` | Records a part of the screen. Drag over the region; a red frame and a Stop button show while it records (neither is in the recording). Stop with the button or with `rec` again; a recording also stops by itself after 5 minutes. The GIF (at most 720 px wide, 12 frames a second) or MP4 is saved in `~/Movies/Kea` and put on the clipboard as a file. Needs the Screen Recording permission; `rec` shows a row to grant it when it is missing. |
| `conv`, `conv jpg`, `conv 1600`, `conv gif` | Converts the files that are selected in Finder. Images: to JPEG, PNG or HEIC, or to a size (`conv 1600` makes the long side at most 1600 px). Videos (mov, mp4, m4v): to MP4 or to a GIF. `conv` by itself lists what is possible for the selection. The new file goes next to the original with a new name; the original is not changed. |
| `t`, `t <command>` | Runs the command in a new Ghostty window, in the home folder. Kea types the command into your normal shell, so aliases work, and the window stays open after the command ends. `t` alone opens a new window. The first time, macOS asks if Kea may control Ghostty. Config: `terminal.app` (`com.mitchellh.ghostty` or `com.apple.Terminal`) and `terminal.keyword`. |
| `qr`, `qr <text>` | Shows a QR code for the text, or for the text on the clipboard, in a small window: Return copies the picture and closes, Cmd+S saves it. `qr` also reads a QR code: drag over one on the screen, or use the image on the clipboard, and what it says goes to the clipboard. |
| `clean`, `clean 30s`, `clean 2m` | Locks the keyboard so you can wipe it: every key, including media and brightness keys, is ignored. The mouse and trackpad still work; a panel shows the countdown and an Unlock button. Default 1 minute, 15 minutes at most. Uses the Accessibility access that zones use. The power button and Touch ID still work. |
| `autoclicker`, `click`, `clicker` | Autoclicker: a left click at the pointer every 0.02 s (50 a second) until you stop it. The pointer can move while it runs; each click goes where the pointer is. Ctrl+Option+Cmd+C starts and stops it in any app; Return on "Start Autoclicker" starts it too. Esc, system or display sleep, a screen lock, and quitting Kea also stop it. While it runs, the menu bar icon is a cursor and the title says "Clicking 50/s". The rows show the hotkey and the interval; set `autoclick.hotkey` (empty for no hotkey) and `autoclick.interval` (0.01 s at least) in config. Needs Accessibility access: without it, the clicker does not start and macOS asks. If another app (for example Hammerspoon) has the same hotkey, the hotkey row says so and the log says "autoclick hotkey taken". |
| `hyper`, `hyper on`, `hyper off` (or `capslock`) | Hyper key: Caps Lock acts as Control+Option+Command+Shift held together, in every app, so you can make shortcuts that clash with nothing. Off until you set `hyperKey.enabled` to `true` in config; `hyper on` turns it on until Kea quits, and "Turn On at Every Start" copies the config line. `hyper` shows whether it is on, whether Caps Lock is remapped, and whether Kea has Accessibility access (it needs it; without it Caps Lock stays Caps Lock). Caps Lock no longer types capitals while it is on. In Kea's hotkey settings, `hyper+k` means `control+option+command+shift+k`; other apps (Hammerspoon, BetterTouchTool, System Settings › Keyboard Shortcuts) see the same four modifiers. With `hyperKey.tapEscape`, a short tap of Caps Lock alone (0.5 s at most) sends Esc. Kea remaps Caps Lock with `hidutil` and keeps your other key mappings; quitting Kea or `hyper off` puts Caps Lock back. If Kea is force-quit, Caps Lock does nothing until Kea runs Hyper again or the Mac restarts. |
| `e party`, `emoji cozy rainy day` (also `e` alone) | Emoji picker. Searches emoji names and keywords; the ones you use most come first, and `e` alone lists them. Return pastes the emoji into the app you were in (copies only, without Accessibility access). |
| `ie` | Image editor for the picture on the clipboard (copy one, or screenshot with Ctrl+Cmd+Shift+4). Tools: arrow (A), box (B), text label (T), pen (P), highlight (H), redact (R), mosaic (M, pixelates the area under it into coarse blocks); colors 1–7 (pastel pink, peach, butter, mint, sky, lilac, and ink). Marks have a white rim and a soft drop shadow. Drag a mark to move it: filled marks and labels anywhere on them, a box by its outline (so you can still draw inside it), arrows and pen strokes near the line; hold Option to draw on top of a mark instead. A move is one undo step. Return or Cmd+C copies the result to the clipboard and closes; Delete or Cmd+Z undoes; Save… writes a PNG; Escape closes. `imageEditor.font` sets the label font (for example `"Fredoka"`); empty uses SF Rounded. |
| `zalgo hello` | Z̴̡a̸l̷g̶o̵ text in mild, medium and max strengths. The row you see is exactly what Return copies. |
| `lorem`, `lorem 3`, `lorem 3 md` | Placeholder text. `lorem` alone offers a phrase (sentence case, good for titles), a sentence, a paragraph, or 5 paragraphs. `lorem 3` gives exactly that many paragraphs (1 to 100), with a second row for the same as Markdown. `lorem 3 md` (or `lorem md` for 5) gives a Markdown document to test a renderer: a title, section headers, bold, italic and a link inside paragraphs, and between paragraphs an image (a placeholder photo from picsum.photos, with a caption), a bullet list, a quote, a numbered list, a code block and a table in turn. Return copies it. |
| `uuid`, `b64 text`, `url text`, `hash text`, `json {...}`, `color` | Developer tools. `uuid` gives new UUIDs. `b64` and `url` show the encoded and the decoded form. `hash` gives MD5, SHA-1, SHA-256 and SHA-512. `json` gives pretty and compact forms (and says where the text is not valid). `color #ff8800` shows hex, RGB and HSL; `color` alone picks a color from the screen. Return copies. |
| `tz`, `tz 3pm pst in nyc`, or only `3pm pst in nyc` | Time zones. `tz` shows the time now in your favorite zones (`tz.favorites` in config). A time with a zone converts to another zone; this also works with no keyword. |
| `port`, `port 3000`, `port node` | What listens on a TCP port. Return stops the process; Kea asks first (Stop, Force Stop, Cancel). |
| `kill chrome` (also `quit`) | Quit an app, force quit it, or stop a process by name. A normal Quit does not ask (the app asks about unsaved work). Everything else asks first. |
| `ocr` | Drag over a part of the screen. The text in it goes to the clipboard. If an image is on the clipboard, a second row reads that image. |
| `snip`, `snip new ;sig Best, Sam`, `snip rm ;sig` | Snippets: type a trigger in any app and it becomes its text. `{date}`, `{date+1}`, `{date-1}`, `{time}`, `{datetime}` and `{clipboard}` are filled in. Kea starts with `;td`, `;tm` and `;yd` (the date today, tomorrow, yesterday). The list is `~/.launcher/snippets.json`. |
| `menu export` | Search the menus of the front app. Return chooses the item. The row shows the menu path, and the shortcut as key caps at the right edge. |
| `layout save work`, `layout work`, `layout rm work` | Saved window layouts. Save records where the front window of each open app is; the name puts them back. Frames are shares of the display, so a layout fits another display size. |
| Cmd+Y | Quick Look the selected file. Up/Down inside the preview move the selection. |
| fn+Delete | Move the selected file or note to the Trash. |
| anything with no matches | A "Search google.com" row as a fallback. |

The menu bar item has a "Launch at Login" toggle.

## Window zones

Each display is split into zones. Cmd+Shift+Right moves the front window
to the next zone, across all displays from left to right, and wraps back
to the first one. Cmd+Shift+Left goes back. A window that is not in a
zone yet (maximized, focus view, anywhere else) starts on the side you
pressed: Right takes the first zone on the right edge, Left zone 1. With `cols(zone, rows 2)`,
Right goes 2, 3 (top right, bottom right) and Left goes 1, 3, 2.
Cmd+Shift+Up fills the display; on a maximized window it switches to focus
view (centred, `focusWidth` × `focusHeight` of the display, default 60% ×
85%), and back. If the app has no window up, Up brings back its most
recently minimized one. Cmd+Shift+Down minimizes the window; when all of
the app's windows are minimized, Down brings the latest one back. `zones` in
the search box lists every zone; Return moves the front window there.

Drop zones: hold Shift while you drag a window by its title bar, and every
zone shows as a gray rectangle on every display. The zone under the pointer
lights up; let go and the window fills it. Near the border of two zones, both
light up and the window spans them (three, where three meet). Release Shift
before the mouse button and the window stays where you dropped it. You can
press Shift at any time in the drag. `"dropZones": false` under `zones` turns
this off.

Edit zones in Settings › Window Zones: one `match = layout` line per
display, with a preview that redraws as you type. Typing `zones` in the
search box also has an "Edit Zone Layouts" row.

Kea needs Accessibility access for this (Privacy & Security ›
Accessibility). The first key press shows the prompt.

These keys replace "select to line start/end" and "select to document
start/end" in text fields. Change them under `zones.keys` if you miss that.

```json
"zones": {
  "enabled": true,
  "gap": 8,
  "focusWidth": 0.6,
  "focusHeight": 0.85,
  "dropZones": true,
  "keys": { "left": "command+shift+left", "right": "command+shift+right",
            "up": "command+shift+up", "down": "command+shift+down" },
  "displays": [
    { "match": "builtin", "layout": "cols 2" },
    { "match": "portrait", "layout": "rows 3" },
    { "match": "landscape", "layout": "cols(zone, rows 2)" }
  ]
}
```

The first `displays` entry that matches a display wins. `match` is
`builtin`, `portrait`, `landscape`, `main`, `*`, or part of the display's
name (for example `"DELL"`). A display with no match is one zone.

Layouts: `zone` is one zone. `cols 3` and `rows 2` split evenly.
`cols(a, b, ...)` and `rows(a, b, ...)` nest, and `2*` gives a part twice
the space: `cols(2*zone, rows 2)` is a wide left zone with two stacked on
the right. Zones are numbered in reading order.

## Appearance

Settings › Appearance has a theme dropdown, where each theme shows a swatch of its colors and
the one you pick is previewed below it, light and dark (System, Light, Dark, Midnight,
Graphite, Paper, Rose, Forest, Opal, Dusk, Glass, each of the last three also as Light and Dark), an optional accent color, and the search
font size. In `config.json` these live under `appearance`; `background`
takes a hex color and `opacity` its strength for a custom look.

Opal is a pearl-white panel with pastel pink, lilac, mint and sky tints that
drift slowly while it is open, a sheen across the top, and a band of light
that crosses it as it opens. "Opal" follows the system's light or dark mode;
"Opal Light" and "Opal Dark" pick one. Dusk is the same idea as a magenta to
blue gradient. Glass is nearly clear over the blur, with a bright rim and a
highlight in the corner, like liquid glass. These themes open with a short fade
(the panel does not change size as it opens); set `appearance.animate` to
`false` to turn that off, or `true` to fade other themes. Reduce Motion keeps
only the fade.

The `placeholder` can hold several choices separated by ` | `, for example
`"ᕕ( ᐛ )ᕗ | (ﾉ◕ヮ◕)ﾉ*:･ﾟ✧"`; Kea picks one each time it opens.

## Config

Open the settings window from the menu bar icon, with Cmd+, while the
panel is open, or by searching "kea settings". Saving writes the file below
and relaunches the app.

`~/.launcher/config.json`, every key optional. A missing key, or a value of
the wrong type, gets its default. These are the defaults for the main keys
(`zones` is shown in its own section):

```json
{
  "hotkey": "option+space",
  "appFolders": ["/Applications", "~/Applications", "/System/Applications",
                 "/System/Applications/Utilities", "/System/Library/CoreServices/Applications"],
  "fileSearch": { "enabled": true, "scopes": ["~"], "maxResults": 20 },
  "maxResults": 12,
  "placeholder": "Search",
  "webSearches": {
    "g": "https://www.google.com/search?q={query}",
    "c": "https://claude.ai/new?q={query}",
    "gpt": "https://chatgpt.com/?q={query}"
  },
  "defineKeywords": ["define", "def"],
  "clipboard": { "keyword": "cb", "limit": 100 },
  "calendar": { "keyword": "cal", "calendar": "" },
  "alerts": { "enabled": true, "leadMinutes": 1, "alertAtStart": false, "snoozeMinutes": 1, "sound": "Glass",
              "skipAllDay": true, "skipDeclined": true, "requireAttendees": false, "ignoreCalendars": [] },
  "appearance": { "theme": "System", "accent": "", "background": "", "opacity": 0, "fontSize": 24 },
  "autoclick": { "hotkey": "control+option+command+c", "interval": 0.02 },
  "hyperKey": { "enabled": false, "tapEscape": false, "arrowSpaces": true }
}
```

`autoclick.interval` is the time in seconds between clicks, from 0.01 to 60. An empty
`autoclick.hotkey` turns the hotkey off.

`hyperKey.enabled` turns Caps Lock into the Hyper key (Control+Option+Command+Shift) at each
start of Kea. `hyperKey.tapEscape` makes a short tap of Caps Lock alone send Esc.
`hyperKey.arrowSpaces` makes Caps+Left and Caps+Right send Control+Left and Control+Right,
the macOS shortcuts that move one Space to the left or right (Keyboard Shortcuts › Mission
Control). Set it to false to use `hyper+left` and `hyper+right` for other shortcuts.

`alerts` sets the meeting alerts. `leadMinutes` 0 alerts at the start only.
`requireAttendees` alerts only for events with at least one other person.
`sound` is a system sound name (Glass, Ping, Submarine); an empty string is silent.
`ignoreCalendars` lists calendar names that never alert.

`webSearches` maps a keyword to a URL template. `{query}` is replaced
with the encoded text. The `g` entry is also the no-match fallback. A
`webSearches` value replaces the whole default list, so keep `c` and `gpt`
if you want them.

Hotkey syntax: modifiers from `command`, `option`, `control`, `shift`
joined with `+`, then a key: a letter, a digit, `space`, `return`
(or `enter`), `escape` (or `esc`), `tab`, `left`, `right`, `up`, `down`,
or `f1`..`f12`.

## Turning commands off

Every keyword command can be turned off. In Settings › Commands, uncheck it;
or list its id or keyword in `config.json`:

```json
"commands": { "disabled": ["weather", "2048", "zalgo"] }
```

A command that is off does not react to its keyword (the word becomes normal
search text), leaves `help`, adds nothing to normal search, and stops its
background work (clipboard history stops watching the clipboard; zones
release their hotkeys). The ids are the names in Settings, and the list in
`Sources/Launcher/Commands.swift`.

## Commands

Each command is a folder in `~/.launcher/commands/` with a `command.json`
and an executable `run`. `make install-commands` copies the bundled set
from `examples/commands/`: projects (`p`), sleep display, lock screen,
empty trash, toggle dark mode, eject disks, toggle Wi-Fi. Use "Reload
Commands" in the menu bar item after adding one. Commands that drive
Finder or System Events through AppleScript ask for Automation permission
the first time.

`command.json`:

```json
{
  "title": "Projects",
  "keyword": "p",
  "subtitle": "Open a folder in ~/Projects",
  "icon": "sf:folder",
  "mode": "list"
}
```

`icon` is an absolute path, a `~` path, or `sf:<SF Symbol name>`.

### mode: action

The command appears as a single result when its title or keyword matches.
Return runs `run` with the full query text as `$1`. Output is ignored.

### mode: list

Typing the keyword and a space hands the rest of the query to the
command. `run` receives it as `$1` and prints JSON to stdout:

```json
{
  "items": [
    {
      "title": "density",
      "subtitle": "~/Projects/density",
      "icon": "sf:folder",
      "action": { "type": "open", "target": "/Users/me/Projects/density" }
    }
  ]
}
```

Action types:

| type | target |
|---|---|
| `open` | A file path or a URL, opened with the default app |
| `shell` | A command string run with `/bin/sh -c` |
| `copy` | Text placed on the clipboard |

A script that exits non-zero, prints invalid JSON, or runs longer than
eight seconds shows one "failed" row with the first line of stderr.

## Layout

- `Sources/LauncherCore`: pure logic with unit tests: matching, frecency,
  config, command manifests, query parsing, calculator, units, events,
  durations, zones, the treemap, solitaire rules, lorem.
- `Sources/Launcher`: the AppKit app: hotkeys, panel, providers, zones,
  keyboard lock, settings window.
- `docs/`: [architecture](docs/architecture.md), [decisions](docs/decisions.md),
  [adding a feature](docs/adding-a-feature.md), and [spec.md](docs/spec.md), a specification
  to build your own launcher like this one with a coding agent.

## Debugging

- `~/.launcher/launcher.log` records hotkey registration, panel show/hide,
  and script failures.
- `make build`, then `.build/release/Launcher --query "safari"`, runs the
  search pipeline without a window and prints the ranked results. It uses
  the live `~/.launcher/config.json`. Build first, or it runs the last release build.
- `kill -USR1 $(pgrep -x Kea)` toggles the panel from a script.
