# Adding a feature

Most features are a keyword command: `word [argument]` in the search box.
Follow these steps. Look at `Caffeinate.swift` (small, stateful) or
`KeyboardLock.swift` (recent, self-contained) as a model.

## 1. Put the logic that can be tested in LauncherCore

Parsing, math, formatting, and file formats go in `Sources/LauncherCore/`
as `public` types, with tests in `Tests/LauncherCoreTests/`. Reuse what exists:

- `DurationParser.parse("1h 30m")` for durations. It returns seconds and a trailing label.
  Check `label.isEmpty` when a word such as "1password.com" must not count as a duration.
- `CSVLog.quote` and `CSVLog.fields` for CSV rows.
- `FuzzyMatcher`, `Ranker`, and `Frecency` for ranking.
- `HotKeySpec.parse` for hotkey strings (letters, digits, space, return, escape, tab, f1–f12, arrows).

Run `make test`.

## 2. Add the command in the app

Create `Sources/Launcher/<Feature>.swift`. It holds the feature's code and a
`KeaCommand` that describes it (see `KeaCommand.swift`). A small example:

```swift
enum CoinFlip {
    static var command: KeaCommand {
        KeaCommand(id: "coin", name: "Coin Flip", keywords: ["coin", "flip"],
                   help: [.init(keyword: "coin", summary: "Flip a coin", example: "coin")],
                   results: { ctx in
                       [Result(id: "coin:flip", title: Bool.random() ? "Heads" : "Tails", subtitle: "Return copies",
                               icon: nil, action: .none)]
                   })
    }
}
```

Then add one line to the list in `Sources/Launcher/Commands.swift`:

```swift
CoinFlip.command,
```

That is all the wiring. The keyword is routed, `help` lists it, Settings shows
a checkbox for it, and `commands.disabled` can turn it off.

What to put in the `KeaCommand`:

- `id`: stable and unique; it is what `commands.disabled` and Settings store. Never rename one.
- `keywords`: every word that starts the command. Check the alias table in
  architecture.md; a keyword that another command has logs a warning at launch
  and the earlier command wins. A built-in keyword also hides a user's web
  search or script command with the same keyword.
- `results`: given the keyword, the argument, and frecency.
  - Empty argument: show the current state and the choices.
  - An argument: show one preview row whose title says exactly what Return does.
  - Text that does not parse: one row "Could not read …" with an example in the subtitle.
- `live`: `(interval, isLive)` when rows change while they are on screen (a scan, a download).
- `context.refresh()`: call it when an async answer arrives, to redraw once.
- `search`: rows for plain search, if the feature should show without its keyword.
- `help`: one line, or several for a command with distinct uses.

Other points:

- Actions are `.custom { [weak self] in ... }` closures. If the action needs the
  Return key to be released first (for example it captures the keyboard), delay it about 0.3 s.
- Give each row a stable `id` (`"feature:thing"`); frecency uses it.
- A feature with state is a class the coordinator owns: add a property to
  `SearchCoordinator`, create it in `init`, and write `var command: KeaCommand`
  in an extension in the feature's own file (see `TidyCommand.swift`).
- If it does background work (polling, hotkeys), start that only when
  `coordinator.isEnabled("<id>")` is true (see `AppDelegate`).
- If it needs the menu bar, add a callback (like `Caffeinate.onChange`) and
  update the title in `AppDelegate.updateStatusTitle()`.

## 3. Config (if the feature has settings)

In `Sources/LauncherCore/Config.swift`:

1. Add a nested `Codable` struct with defaults.
2. Write `init(from:)` with `(try? c.decodeIfPresent(T.self, forKey: .key)) ?? default`
   for every key. The `try?` makes a value of the wrong type fall back to the
   default without failing the whole config. An old config file must always load.
3. Add the property to `Config`, its key to `CodingKeys`, and the same kind of line in `Config.init(from:)`.
4. Add a case to `ConfigTests.swift` if the key has special decoding.

If the author should edit it in the GUI, add fields to `SettingsWindow.swift`:
the control, a row in the grid, `load()`, and validation in `validate()`.
Multi-line boxes must use `scroll(_:height:)`, a local function inside
`buildForm()` (it fixes their width), and must be added to the text view list
in `snapshot(to:)`. Check the result with
`/Applications/Kea.app/Contents/MacOS/Kea --settings-snapshot /tmp/form.png`
after `make install`.

## 4. Permissions

- Accessibility: check `ZoneManager.trusted` and call `ZoneManager.requestAccess()` when it is missing.
- Notifications: go through `TimerManager` or check `Bundle.main.bundleIdentifier != nil` first.
- New privacy prompts need a usage string in `Info.plist.template`.
- Anything that needs root belongs in a conversation with the user first.

## 5. Document it

- A row in the README feature table (what to type, what happens, limits).
- The `help` lines in its `KeaCommand` (that is what `help` shows).
- A row in the feature table in `docs/architecture.md`, and a section if it is not simple.
- A note in `docs/decisions.md` for any behavior the author specified.

## 6. Verify

1. `make test`.
2. `make build`, then `.build/release/Launcher --query "<keyword> <argument>"` for the rows.
   For a change to search or dispatch itself, run `scripts/query-snapshot.sh > before.txt`
   first and again after, and diff the two files: 67 queries must give the same rows.
3. `make install && make reload`, then check `~/.launcher/launcher.log`.
4. For behavior in the running app, add a hook like `--kblock`
   (a `DistributedNotificationCenter` notification named
   `directory.kea.launcher.<feature>`, posted from `main.swift`), so you can test
   without clicking. Read "Check your work without disturbing the author" in AGENTS.md first.
5. Commit with a message that says what changed for the user.
