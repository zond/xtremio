# Driving the app on a device

An agent, or a person at a terminal, can drive a running Xtremio on an
Android phone without coordinates or screenshots. It takes Flutter's own
driver extension, a handful of JSON commands, and the semantics tree as the
description of what is on screen. [ANDROID.md](ANDROID.md) covers building
and installing in general.

## The second app

Debug and profile builds are a separate package, `com.zond.xtremio.debug`,
labelled "Xtremio debug" (`android/app/build.gradle.kts`). They install
beside the release app and never over it. A debug-signed build cannot
update the release install anyway, and the only other way onto the device
would be to uninstall the release app and lose its login, settings and
downloads. The debug app is a fresh install with data of its own: no
login, no addons beyond the defaults until somebody signs in.

Two things do not work in it, because they are keyed on the release
package and certificate rather than on anything in this repository:

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
the background. It returns once the app's VM service URL is written to
`build/drive/vmservice-url`, and Flutter's output goes to
`build/drive/flutter-run.log`. Both are under `$XTREMIO_DRIVE_DIR` when it
is set, and `$XTREMIO_DRIVE_DEVICE` stands in for `-d`. It gives up after
thirty minutes without a URL, or as soon as `flutter run` exits. A profile
build compiles the Rust crate as a cargo `--release` build (cargokit maps
profile to release). The first one takes a few minutes, and a rebuild with
the crate cached about half a minute. A session survives the app being
backgrounded. It ends when the app process does, and running
`tool/drive-start` again restarts it.

`lib/main_driver.dart` installs the extension and then runs the app's own
`main`. It and `lib/dev/driver/` are the only code that imports
`flutter_driver` (a dev dependency). `lib/main.dart` never reaches them, so
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
tool/drive seek 1:02:30                  # h:mm:ss, m:ss, seconds or N%
tool/drive log 80                        # the last lines of the diagnostics ring (default 50)
tool/drive streams x265 1080p --not 2160p  # every source of the open title, numbered
tool/drive play 2                        # play stream #2 as a tap on its row would
tool/drive --json screen                 # the raw answer
```

`screen` prints one line per node: its id, its roles in brackets, its
label, value, hint and tooltip, the actions it takes in braces and its rect
in logical pixels, grouped under the nearest header. Ids are semantics node
ids: stable while the node lives, so read a fresh `screen` after a
navigation. A node marked `hidden` is built but scrolled out of view. A
list builds only what is near the viewport, so scroll (`act <id>
scrollUp`) to reach rows further down. For a title's sources, `streams`
reads them all instead. `act`, `tap`, `go` and `play` wait for the
screen to settle (at most three seconds, so a spinner does not hang them)
and answer the new screen. `find`, `tap` and `wait` match every word given,
ignoring case, against a node's label, value, hint and tooltip. `wait`
polls for twenty seconds unless told `--timeout`.

`streams [<text>...] [--not <text>]` lists every source the open details
screen offers, or the one under the player. It reads them from the list's
own derivation (`SourcesProbe` in `lib/features/details/meta_details_screen.dart`)
rather than from the rows built near the viewport. So a collapsed section,
or a stream far down a list of a hundred, is there too. One line per stream:
its index, its kind (torrent, link, YouTube, external ...; `not playable`
when its row takes no tap), the addon (`Google Drive` and `This device` for
the viewer's own files), what the row says, what was read out of it
(resolution, size, seeders, the source, codec and audio tags, the flags)
and the file the addon names, then `also from` and the other addons when
the row stands for the same stream from several. Filter words work as
`find`'s and keep the unfiltered indices. When there is nothing to list
yet, a note says why: the title not loaded, no episode picked, or an
episode picked whose streams have not come back. It never prints a
stream's URL, info hash or headers, because addon and debrid URLs carry
keys. A link an addon wrote into its text is cut to its origin, as a log
line's is. It names the addons still answering. Until they finish, the
list can grow and its numbers shift, so list again before `play`.

`play <index>` plays that stream through the same dispatcher a tap on its
row calls, so it needs no scrolling. It refuses a stream whose row takes
no tap, and refuses while another page (the player) is over the details
screen. A worked example: list, narrow to a 1080p x265 DDP release, play
it:

```bash
$ tool/drive go details movie tt0063350
$ tool/drive streams
Night of the Living Dead (tt0063350), sectioned: 10 of 10 streams
  #0 torrent | debrid.example | Night.of.the.Living.Dead.1968.2160p.UHD.HDR.DV.x265.Atmos | 👤 12 💾 30 GB | [2160p, 30 GB, 12 seeders, HDR, DV, HEVC, Atmos]
  #1 torrent | Public Domain Movies | 1080p | 💾 1.51 GB | [1080p, 1.51 GB]
  #2 link | debrid.example | Night.of.the.Living.Dead.1968.1080p.BluRay.x265.DDP5.1-GRP | 💾 4.2 GB | via https://debrid.example/… | [1080p, 4.2 GB, BluRay, HEVC] | file Night.of.the.Living.Dead.1968.1080p.BluRay.x265.DDP5.1-GRP.mkv
  #3 torrent | debrid.example | Night.of.the.Living.Dead.1968.720p.x264.DTS | 👤 3 ⚙️ 1337x | [720p, 3 seeders, AVC, DTS]
  #4 external (not playable) | WatchHub | Amazon Prime Video | Subscription
  ...
$ tool/drive streams 1080p x265 ddp --not 2160p
Night of the Living Dead (tt0063350), sectioned: 1 of 10 streams
  #2 link | debrid.example | Night.of.the.Living.Dead.1968.1080p.BluRay.x265.DDP5.1-GRP | 💾 4.2 GB | via https://debrid.example/… | [1080p, 4.2 GB, BluRay, HEVC] | file Night.of.the.Living.Dead.1968.1080p.BluRay.x265.DDP5.1-GRP.mkv
$ tool/drive play 2
played #2 link | debrid.example | Night.of.the.Living.Dead.1968.1080p.BluRay.x265.DDP5.1-GRP | ...
routes: ... > MetaDetailsScreen > PlayerScreen (player) *
...
```

(The streams are the test fixture's, `moreSourcesCore` in
`test/dev/app_driver_test.dart`, with the listing cut short.)

`seek <h:mm:ss|m:ss|seconds|N%>` moves the player the way its seek bar
does. The bar itself takes a tap at a place, and semantics cannot aim one.
It needs exactly one player screen up, and a percentage needs a known
duration. It answers `player` as it stands right after, so poll `player`
for where it lands.

`player` reads the player screen's own state (`PlayerProbe` in
`lib/features/player/player_screen.dart`): the core's URL, what the engine
was handed (`xtremio://<media id>` for a stream played by id), position, duration,
buffer, playing, buffering, a stuck position, whether the media has
loaded, whether it is casting or leaving, and the last engine and open
errors. Every URL in it, and every `log` line unless Verbose logging is on,
goes through the same redaction as the diagnostics report.

The stats panel's rows are text nodes, so `screen` reads them as they are
drawn. That holds for local playback's panel and for the cast panel on the
casting view ([CASTING.md](CASTING.md#the-stats-panel-while-casting)).
`tap "Playback stats"` turns the panel on and off.

The debug app plays as whatever account is signed in to it: a play is
watch progress on that account, and a long press can mark something
watched. On somebody's real account, play something they have not
watched, and only for as long as the check needs.
