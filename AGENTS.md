# Kea: guide for agents

Kea is a native macOS launcher, window manager, and toolbox, written in Swift with AppKit.
Read this file first. Then read [docs/architecture.md](docs/architecture.md) (how the code
is organized), [docs/decisions.md](docs/decisions.md) (why things work the way they do),
[docs/adding-a-feature.md](docs/adding-a-feature.md) (the checklist for a new command), and
the [README](README.md) (the user manual). [docs/spec.md](docs/spec.md) describes the whole
launcher for an agent that builds one from nothing.

## Rules

1. **Speed is the main feature.** The panel opens in about 10 ms. Nothing slow runs on a
   keystroke or when the panel opens. Readings of other processes run off the main thread.
2. **Keyboard first, never steal focus.** The panel is a non-activating panel.
3. **One keyword, one feature.** A bare keyword shows the state or the choices; the keyword
   with text shows a preview row; Return does it.
4. **Preview before action.** The row title says exactly what Return does. Deletion goes to
   the Trash; a permanent action asks again.
5. **Stable results.** Instant rows never move when slow rows arrive.
6. **Config is a JSON file** (`~/.launcher/config.json`); every key is optional and has a
   default, and the Settings window edits the same file.
7. **Pure logic lives in `LauncherCore` and has tests.** AppKit, EventKit and Accessibility
   code lives in `Launcher`.
8. **Ask before power.** Root access, keyboard capture and other strong permissions come only
   with the feature that needs them, and only when the user asks for it.

## Build, test, install

```bash
make test      # swift test: all LauncherCore tests
make build     # release build
make install   # build, bundle, sign, copy to /Applications/Kea.app
make reload    # restart the installed app
```

The Makefile signs with the first "Apple Development" identity in the keychain. A stable
signature keeps the macOS privacy permissions across rebuilds; ad hoc signing makes macOS ask
again after every build. Without an Apple Development identity, run
`sh scripts/make-signing-cert.sh` one time to make a self-signed one.

Do not use `make run` while the installed Kea runs: the second copy registers the same
hotkeys and writes the same files.

## Check your work

- `make build`, then `.build/release/Launcher --query "text"` runs the full search with no
  window and prints the rows. Use it for every change to rows.
- `scripts/query-snapshot.sh` prints the rows for a fixed list of queries. Run it before and
  after a change to search or dispatch, and compare.
- Snapshot flags draw a window into a PNG with no window on screen: `--paint-snapshot`,
  `--sol-snapshot`, `--diskmap-snapshot <folder>`, `--zonedrop-snapshot`, `--panel-snapshot`,
  `--settings-snapshot`, `--2048-snapshot`.
- `~/.launcher/launcher.log` has one line for each important event.

## Code

- Swift 5.9, language mode 5, macOS 14.
- Each keyword command is a `KeaCommand` in its own file, listed in
  `Sources/Launcher/Commands.swift`.
- `Package.swift` can build extra private features from folders named `Personal/`; the public
  repository has none, and `PersonalStub.swift` gives the empty versions.
- Write documents in plain, simple English: short sentences, one idea in each.
