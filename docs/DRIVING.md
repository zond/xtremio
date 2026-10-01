# Driving the app on a device

How an agent (or a person at a terminal) drives a running Xtremio on an
Android phone without coordinates or screenshots: Flutter's own driver
extension, a handful of JSON commands, and the semantics tree as the
description of what is on screen. Building and installing in general are
in [ANDROID.md](ANDROID.md).

## The second app

Debug and profile builds are a separate package, `com.zond.xtremio.debug`,
labelled "Xtremio debug" (`android/app/build.gradle.kts`). They install
beside the release app and never over it: a debug-signed build cannot
update the release install anyway, and the only other way onto the device
would be to uninstall the release app and lose its login, settings and
downloads. The debug app is a fresh install with data of its own: no
login, no addons beyond the defaults until somebody signs in.

What does not work in it, because it is keyed on the release package and
certificate rather than on anything in this repository:

- the Drive pairing app link (`https://xtremio-xervice.web.app/link`) never
  verifies, so it opens the browser;
- the native Drive picker's Google OAuth client is registered for the
  release package and SHA-1, so it refuses.

## Starting a session

```bash
tool/drive-start -d <device id>   # profile build of lib/main_driver.dart, installed and run
tool/drive-start --stop           # ends the session; the app stays installed
```

`tool/drive-start` runs `flutter run --profile -t lib/main_driver.dart` in
the background and returns once the app's VM service URL is written to
`build/drive/vmservice-url`; Flutter's output is in
`build/drive/flutter-run.log`. A profile build compiles the Rust crate as a
cargo `--release` build (cargokit maps profile to release), so the first one
takes a few minutes and a rebuild with the crate cached about half a minute.
A session survives the app being backgrounded; it ends when the app process
does, and `tool/drive-start` again is the restart.

`lib/main_driver.dart` installs the extension and then runs the app's own
`main`. It and `lib/dev/driver/` are the only code that imports
`flutter_driver` (a dev dependency); `lib/main.dart` never reaches them, so
a release build does not carry the driver.

## Commands

```bash
tool/drive screen                        # routes, the shell's tab, every node worth naming
tool/drive go library                    # discover | search | library | settings
tool/drive go details series tt0238784 tt0238784:6:3
tool/drive go back                       # Android's back button, ladder and all
tool/drive act 42 tap                    # any semantics action: longPress, scrollUp, setText <text> ...
tool/drive find Torrentio 720p --not "Torrentio RD"
tool/drive tap Torrentio H265 --not "Torrentio RD"   # find, then tap the first match
tool/drive wait "1080p" --timeout 30     # poll until something matches
tool/drive player                        # what the player opened, position, state, errors
tool/drive log 80                        # the last lines of the diagnostics ring
tool/drive --json screen                 # the raw answer
```

`screen` prints one line per node: its id, its roles in brackets, its
label, value, hint and tooltip, the actions it takes in braces and its rect
in logical pixels, grouped under the nearest header. Ids are semantics node
ids: stable while the node lives, so read a fresh `screen` after a
navigation. A node marked `hidden` is built but scrolled out of view; a
list builds only what is near the viewport, so scroll (`act <id>
scrollUp`) to reach rows further down. `act`, `tap` and `go` wait for the
screen to settle (at most three seconds, so a spinner does not hang them)
and answer the new screen.

`player` reads the player screen's own state (`PlayerProbe` in
`lib/features/player/player_screen.dart`): the core's URL, what the engine
was handed (a torrent is `xtremio://<media id>`), position, duration,
buffer, playing, buffering, a stuck position and the last engine and open
errors. Every URL in it, and every `log` line unless Verbose logging is on,
goes through the same redaction as the diagnostics report.

The debug app plays as whatever account is signed in to it: a play is
watch progress on that account, and a long press can mark something
watched. On somebody's real account, play something they have not
watched, and only for as long as the check needs.
