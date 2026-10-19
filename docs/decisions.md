# Decisions

Why Kea works the way it does. Many behaviors here were asked for by the author in
exact terms. If a behavior looks strange, check this file before you change
it, and ask the author before you change anything marked **the author's choice**.

## Platform and structure

- **Native Swift and AppKit, no Electron or SwiftUI panel.** Speed and a
  small memory footprint. AppKit gives direct control of the panel, the
  table, and focus.
- **Swift package, not an Xcode project.** It builds from the shell with
  `swift build`, so agents and scripts can build and test it. The Makefile
  assembles and signs the `.app`.
- **`LauncherCore` has no AppKit.** Anything that can be tested without a
  window (parsers, ranking, zone geometry) is in core with
  tests. This is the main safety net for changes.
- **Signed with the author's Apple Development certificate.** macOS ties privacy
  grants to the signature. Ad-hoc signing reset them on every build, and
  the author saw the Documents prompt many times.

## Speed

The author asked for the panel to open "as fast as possible", and to never
defocus the app behind it.

- The panel is a `.nonactivatingPanel`. Kea never activates for the panel,
  so the frontmost app keeps focus and its window keeps its state. This is
  also why Cmd shortcuts are forwarded to the main menu by hand.
- The panel is ordered in once at launch to build its views and layers. What
  happens between uses depends on the macOS version (`keepWarm` in
  PanelController; the author chose OS-based, with no setting):
  - **macOS 26 and later** (the author's Mac): it stays ordered at alpha 0, and showing
    it is an alpha change plus `makeKey`. Ordering in costs 0 ms.
  - **Before macOS 26**: it is ordered out, and showing it needs
    `orderFrontRegardless`, which measured 28–40 ms on the author's Mac (window server
    round trip, a full draw, the blur). A contributor added this because on macOS 14 an
    alpha-0 window that joins all Spaces shows during the Space-switch
    animation, so the panel flashed on every desktop switch.
  the author chose speed and never saw the flash on macOS 26; do not order out there. The log line "panel shown: … order=N key=N" gives
  the cost of each step.
- The recent list is computed after each hide, and every provider runs once
  at launch to fill icon and dictionary caches.
- Spotlight file results are debounced and appended below. The author asked that
  instant results stay pinned and do not move when late results arrive.

## Commands as a registry

- Kea had about 35 keyword commands wired through one long `if` chain, one
  long keyword list, and a hand-kept help list. Every new command touched the
  same shared lines, and every one of the first four outside pull requests conflicted
  there. The author asked for it to be "super hyper extensible" with commands that are
  easy to turn on and off.
- Now each command describes itself with a `KeaCommand` next to its own code,
  and `Commands.swift` lists them. Dispatch, `help`, Settings checkboxes, and
  `commands.disabled` all read that one list.
- The refactor was checked with `scripts/query-snapshot.sh`: 67 queries gave the
  same rows before and after. Run it around any change to search or dispatch.
- The panel does not change size as it opens, in any theme (the author asked for the
  spring-scale to go). The fade and the Opal light sweep stay.

## Hotkey and startup

- **Carbon `RegisterEventHotKey`**: global hotkeys with no Accessibility
  permission. The default in code is Option+Space; the author's config uses
  Command+Space.
- **LaunchAgent, not `SMAppService.mainApp`.** Login items started Kea one
  to two minutes after boot. A LaunchAgent starts when the login session
  starts. It restarts Kea after a crash and not after Quit.
- **Single instance.** The agent and a Dock click could both start Kea.
  The first copy wins; see the "Two copies" gotcha in AGENTS.md.
- **`LSUIElement`** (menu bar app). Kea is pinned in the Dock at the author's
  request; a Dock click shows the panel.

## Search behavior

- Apps rise to the top with use (frecency), so "chr" opens Chrome without
  a hard-coded alias. Apps get a 1.3× weight and files 0.6×.
- Finder is in the app results (it lives in CoreServices, and a helper-app
  filter hid it at first).
- `/Applications` and other quick folders open in Finder from search.
- A bare `cal` opens Calendar.app first. Calendar events have no fn+Delete.
- `c` and `gpt` open the Claude and ChatGPT desktop apps when installed.
- The lorem "phrase" is in sentence case (the author uses it for post titles).
- Timer confirmations read "Start a 2h30m timer".
- `log weight` with no value lists the weight history.

## Window zones

The author did not like the window managers on the market and asked for zones
declared per display, moved through with Cmd+Shift+arrows.

- **Cmd+Shift+arrows** are global. They replace the text selection
  shortcuts in all apps. The author was told and chose them anyway. The keys are
  in config.
- **Left and Right go through one loop across all displays**: displays left
  to right, and zones in reading order in each display. From the last zone
  Right wraps to the first. Example with `cols(zone, rows 2)`: 1 is left,
  2 is top right, 3 is bottom right.
- **A window that is not in a zone starts on the side you press.** Right
  goes to the first zone on the display's right edge; Left goes to zone 1.
  So after Up (maximize), Right gives the right half. From an unsnapped
  window, Left goes 1, 3, 2 on the layout above.
- **Up is not "move up".** Up restores the app's last minimized window if it
  has no window up; otherwise it maximizes (with the zone gap); on a maximized
  window it goes to focus view (centred, 60% × 85%); on focus view it
  maximizes again.
- **Down minimizes** (by pressing the yellow button, which is the same as
  Cmd+M). When all of the app's windows are minimized, Down restores the
  most recent one. After minimizing the last window Kea reactivates the app
  (macOS otherwise moves focus to another app, and the next Down would act on
  the wrong app).
- No window animation: the Accessibility API is too slow in some apps for
  smooth animation.
- Moom and Rectangle were uninstalled; Kea is the only window manager.

- **Drop zones** (2026-10-07): the author asked for "hot drop zones": hold Shift while dragging a
  window, see low-opacity gray rectangles, drop in one and the window takes its size. The
  zones are the same ones the keys use. A drop near the border of zones spans them; that
  part is Kea's addition, in the manner of FancyZones. Shift must still be down at the
  drop, so letting go of Shift is the way to cancel. The overlay does not animate.
  the author asked for the lightest form: Kea watches the mouse only while Shift is down.

## Tidy

- The author's disk was 95% full. `tidy` was designed with the author: report first, never
  clear without a Return, Trash before delete, and a fixed list of places.
- "Clear All Safe" covers only rebuildable output and package caches. App
  caches were left out of it (an app is slower while its cache rebuilds), and
  so were Downloads (the author wanted a review list), iCloud, Docker, and old projects.
- iCloud Drive files that are uploaded and not opened in 30 days can be made
  cloud-only; the author asked for this. Files that are not uploaded are never touched.
- No low-space alert yet; it was offered and not asked for.
- The name `clean` was taken by the keyboard lock, so the command is `tidy`.

## Weather

- `weather` shows now, what to wear, the next 12 hours, and 7 days. Open-Meteo
  needs no key; only coordinates leave the Mac.
- What to wear is advice, not a forecast: clothing for the coldest "feels like"
  of the hours you are likely out, a layer for a 15°F swing, umbrella vs. rain
  jacket by rain chance and wind, boots for snow, sunscreen for UV. The rules
  and thresholds are in `Weather.advice` (core, tested), in °F internally.
- The default place preloads in the background once a day: 5 seconds after
  launch, then at the first panel open of a new day (the author asked for this). So
  `weather` shows rows at once; an old answer shows while a new one loads. The
  preload never causes the Location Services prompt, and a failed load is tried
  again at the next panel open.

## Keyboard lock

- For cleaning the keyboard. It must never lock the author out: the mouse still
  works, the Unlock button is always on screen, the lock ends by itself, and
  the maximum is 15 minutes, enforced in `lock(seconds:)` for every path.
- The power button and Touch ID cannot be blocked by any app.

## Autoclicker

- The author asked for it on 2026-10-18 ("add the autoclicker please", with the keyword
  `autoclicker` and the aliases `click` and `clicker`). It replaces his Hammerspoon
  autoclicker, which is the last reason to keep Hammerspoon. This is a new power
  (synthetic mouse clicks with Kea's Accessibility access), and the author agreed to it.
- The behavior is the same as Hammerspoon's: Ctrl+Option+Cmd+C toggles, a left click at
  the current pointer every 0.02 s, the pointer can move, the first click comes one
  interval after the start, and clicks carry no modifier flags.
- Hammerspoon showed an alert on start and stop and played no sound. Kea plays no sound
  and shows the state in the menu bar (a cursor icon, "Clicking 50/s"), like `caff`.
- Kea adds stops that Hammerspoon did not have: Esc, sleep, screen lock, and quit. A
  clicker that runs on by mistake clicks on whatever is under the pointer.
- The interval is at least 0.01 s. Faster ticks only fill the event queue.
- While Hammerspoon runs, it can hold the same hotkey. Kea logs "autoclick hotkey taken"
  and goes on; Kea does not quit or change Hammerspoon.
- No `--click` hook, because any process of the user could post it.

## Hyper key

- The author asked on 2026-10-18: "can you rewire capslock into a meta key across the entire
  mac?" He chose a Hyper key in Kea: Caps Lock acts as Control+Option+Command+Shift held
  together, in every app, so that his own shortcuts clash with nothing. This is a new power
  (a keyboard remap for the whole Mac and a tap that changes every key while Caps Lock is
  held), and the author agreed to it. Do not widen it (for example to other keys) without asking.
- **Off by default** (`hyperKey.enabled: false`). Nothing changes until the author turns it on in
  config, or with `hyper on` for one session. `hyper on` is not saved: the row "Turn On at
  Every Start" copies the config line instead, because Kea never writes config by itself.
- **Two parts, `hidutil` and a tap.** A tap alone cannot use Caps Lock: Caps Lock is a
  toggle with a lock state, and macOS reports it as a modifier change, not as a key down and up.
  `hidutil` remaps Caps Lock to F18 in the HID driver. F18 has a real down and up, and no Mac
  keyboard has an F18 key, so no app uses it. Karabiner-Elements would also do this, but it
  is a driver and a second app; `hidutil` is part of macOS and needs no permission.
- **Kea changes only its own entry** in `UserKeyMapping`. It reads the list, removes any
  other Caps Lock entry (a key can have one mapping), adds Caps Lock to F18, and writes the
  list back. Off puts back the Caps Lock entry from before (for example Caps Lock to Control).
  A list that Kea cannot read is not written: that could remove mappings it did not understand.
- **The remap lasts only while Kea runs.** Quit, SIGTERM, and `hyper off` restore the
  mapping. SIGKILL and a crash cannot: Caps Lock then stays F18 (it does nothing) until Kea
  starts and stops Hyper again, or until a restart of the Mac (hidutil mappings do not survive
  one). This is the reason the remap is not a LaunchAgent of its own.
- **Remap only after the tap works.** Without Accessibility there is no tap, and a remap
  alone would make Caps Lock dead. So Kea asks for Accessibility and leaves Caps Lock as it is.
- **The tap is at the HID level** (`.cghidEventTap`), with the session tap as a fallback. The
  HID tap comes before the other taps and before hotkeys are matched, so Kea's own Carbon
  hotkeys with all four modifiers fire with Caps+key. The four flags are added to key downs
  and key ups only; clicks are not changed (a click only marks the press as "not a tap").
- **A stuck Hyper must not happen**: it would make every key a shortcut. Hyper lets go when
  the tap is turned off by macOS (timeout or secure input, when the F18 key up can be lost),
  at sleep, at a fast user switch, and when the HID state says F18 is up although no key up
  came. That last check is used only when the HID state showed F18 down at the press.
- **Re-apply after wake and after a keyboard connects.** hidutil mappings can reset then.
  Kea waits 1.5 s and writes the mapping again even when `--get` shows it, because a new
  keyboard may not have it yet. The keyboard notice is an IOKit matching notice, which does
  not open the device and needs no Input Monitoring permission.
- **Tap for Esc** (`hyperKey.tapEscape`, off by default): a press of Caps Lock alone, with no
  other key or click and not longer than 0.5 s (`HyperState.tapLimit`), sends Esc. A longer
  hold sends nothing, so a hold that changed its mind does not type Esc. Key repeat of Caps
  Lock does not restart the 0.5 s.
- **System Settings wins over Kea.** A Caps Lock entry in System Settings > Keyboard >
  Keyboard Shortcuts > Modifier Keys (stored as `com.apple.keyboard.modifiermapping.*` in the
  global preferences of the host) is applied before `UserKeyMapping`, so Caps Lock never
  becomes F18 and Caps+key sends only that modifier (the author saw only Control on 2026-10-18).
  Kea does not change System Settings: the `hyper` rows and the log say which entry to set back
  to "Caps Lock".
- **`hidutil --get` can print a table** with one row for each HID service (`RegistryID Key
  Value`) instead of one value. A table with only `(null)` rows means no mapping; a table with
  a value is not read, so Kea does not write over mappings it did not understand.
- `hyper+k` in any Kea hotkey setting means `control+option+command+shift+k`.
- **Caps+Left and Caps+Right change Spaces** (`hyperKey.arrowSpaces`, on by default). The author
  asked on 2026-10-18: "can you map hyper+arrow to change spaces?" The tap sends these two
  keys with Control only, so they match the macOS shortcuts Control+Left and Control+Right.
  This changes the real key event, not a new synthetic one, and needs no change in System
  Settings. Up and Down stay Hyper. If the author changes the Space shortcuts in System Settings,
  Caps+arrow still sends Control+arrow.
- No `--hyper` hook, because any process of the user could post it and remap the keyboard.
- Tests and agents must not run `hidutil property --set` on the author's Mac: it changes his live
  keyboard. The merge, the parse of `--get`, and the held state are tested in core.

## Snippets, kill, layouts

- Snippets replace the three date triggers of a Hammerspoon expander
  (`;td`, `;tm`, `;yd`). The Hammerspoon expander is off since 2026-10-04, and
  Hammerspoon goes away after the autoclicker port. The tap keeps only as
  many characters as the longest trigger, in memory, and types the text as
  Unicode key events so the clipboard is not changed.
- `port` and `kill` always ask before a signal. Only a normal app Quit does
  not ask. `port` and `kill` read `lsof` (about 0.5 s) and `ps` off the main thread
  and show the last answer; a list is read again when it is older than 2 seconds.
- Kea does not write `snippets.json` or `layouts.json` while the file has a JSON
  error: a save would replace every entry in it. The command shows the error.
- A layout records one window for each app (the focused or first one).

## Disk map

- The author asked for WinDirStat in Kea. He chose the treemap only (no folder tree and no
  file-type list as views) and the whole disk as the default target.
- He chose to give Kea Full Disk Access for it. macOS gives the same access to every
  process Kea starts, which includes the script commands.
  Kea does not ask for the grant by itself: the first `du` row opens the pane.
- The author asked for free space as a block with diagonal lines and light shading. It shows only
  on the map of the whole disk at the top level, and it is not selectable.
- `disk` is not a keyword, so that `disk` and `disk utility` still find Disk Utility.
- The only way to remove something is the Trash, and a folder asks first. Do not add
  permanent deletion.
- The tree is dropped when the window closes: a whole disk is several hundred MB.
- Not built on purpose: clone detection, updates when files change, duplicate search.

## Meeting alerts

- The author asked for a clone of InYourFace, which he removed (2026-10-18): a full-screen alert
  before each meeting, on every display, so that a meeting is never missed.
- Defaults: 1 minute before, no second alert at the start, all-day and declined events left
  out, a 1-minute snooze, the Glass sound. An event with no other attendees still alerts
  by default, so no event is missed; `requireAttendees` turns that off.
- The alert does not activate Kea. It is a non-activating panel that takes the keys, the same
  as the search panel.
- Zoom `/j/` links and Teams links open in their app (`zoommtg:`, `msteams:`) when it is
  installed, so no browser tab is left behind. Other links open in the browser.

## Paint

- The author asked for "an mspaint style app for quick drawings or doodles". It is a bitmap, not
  a list of marks like `ie`: what is drawn cannot be moved later, as in Paint.
- Lines have smooth edges (not the hard pixels of the real Paint), because the purpose is
  a quick sketch to paste somewhere.
- The author asked for "a tiny bit of natural smoothing". Keep it small (`PaintCanvas.follow`):
  more makes the pen lag behind the hand.
- Return copies the drawing and closes the window (the author's request), the same as in `ie`.
  The drawing stays saved, so `paint` shows it again.
- The canvas has one fixed size and there is one drawing. These were chosen for a small
  first version, not asked for by the author; a text tool and a selection tool are also not built.

## Uninstall, tidy additions, shot, rec, conv, qr

- The author removed Stability Matrix and Ollama by hand with an agent on 2026-10-05 and asked
  for `uninstall` after that. It only ever moves things to the Trash, and only after the
  list is shown and confirmed. The matching is strict on purpose (`Uninstall.belongs`): a
  loose match would put another app's data in the Trash. Group Containers are not touched,
  because their names start with a team id that several apps can share.
- `tidy` deletes a simulator runtime for good (`simctl runtime delete` has no Trash). That
  is why the row is not "safe", needs its own Return, and never offers the newest runtime.
- `tidy` ejects a disk image without force, so an image in use stays mounted. Only image
  files in temporary folders and in Downloads go to the Trash; an image elsewhere may be
  storage that the person made.
- `rec` uses the `screencapture` tool and not ScreenCaptureKit: it is much less code, and
  the tool already has the region and time-limit options. A recording stops after 5 minutes.
- `conv` never changes or replaces the original file.

## Solitaire

- The author asked for Sawayama Solitaire first, and for FreeCell and Spider later. The rules
  follow the author's own web version (and Zachtronics' game): all cards face up,
  the stock dealt by three one time, the empty stock is a free cell, any card to an empty
  column, a foundation for each suit, and a card does not come back from a foundation.
- The author asked that the whole dealt stock shows all the time. So the waste is one row along
  the top with every card's rank and suit in view, and the foundations are a column at
  the right to make room. Do not go back to showing only the last three.
- Undo has no limit and no penalty (his web version has undo; the Zachtronics game does not).
- Cards that are safe go to the foundations by themselves, as in the Zachtronics games.
  "Safe" is strict: both cards of the other color and one rank lower are already home.
- A click never moves a lone card or a whole column to an empty column or to the cell:
  it would change nothing or spend the cell. A drag can do it.
- A game counts as played at the person's first move. Deals are random and some cannot be solved.
- `solitaire` is not a keyword, so that it still finds The Zachtronics Solitaire Collection.

## Press

- The author asked for the function of the app DiskPress in Kea (2026-10-13): free disk space with
  no deleted files, by compression in place and less duplicated storage.
- Apple's `ditto` does the compression, and `clonefile` does the sharing. Kea does not write
  the compression format itself: a mistake there loses a file.
- A change is never made in place. The new file is made next to the old one, compared with
  it byte for byte, and then renamed over it. A failure at any step leaves the old file.
- The first Return only reads. The press needs a second Return and a confirmation, because
  there is no undo button.
- Left alone on purpose: `~/Library`, files that are open, files that changed in the last
  day, databases, disk images, files with hard links, cloud-only files, and folders that a
  cloud service keeps (a changed file there goes up to the service again, uncompressed).
- The estimate must not promise space that the press cannot free. The first version measured
  only the start of each file and said 8.6 GB for a folder where the true number is less
  than 1 GB (model files have text at the start and numbers after it).
- Do not test `press` or `--press-apply` on the author's folders. Use a new folder in a temporary
  directory. `--press-plan` only reads and is safe on any folder.
- Not built: a way to decompress again, a schedule, and parallel compression.

## `t`: a terminal command (2026-10-19)

The author asked for `t <command>` with Ghostty as the default terminal. Kea drives Ghostty through
its AppleScript dictionary (Ghostty 1.3): a new window with `initial input` set to the command
and Return. The command is typed into the user's interactive shell, not run as the window's
program, so aliases, PATH, and shell history work, and the shell stays after the command ends.
`open -na Ghostty.app --args -e` was not used: it starts a second Ghostty process for each
window. The working directory is the home folder. The log gets the length of the command
only, because a command can hold a secret. Terminal.app is the only other terminal that Kea
knows (`do script`).
