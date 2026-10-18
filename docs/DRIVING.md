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
tool/drive hwprobe status                # the codec probe (below); tool/hwprobe wraps it
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
polls for twenty seconds unless told `--timeout`. A settings row's icon is
a node of its own, a button with the tooltip "What is this?" and no label.
So `tap <title>` still taps the row, and `act <id> tap` on the icon opens
the row's explanation.

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

## The codec probe

The codec probe measures the phone's video codecs. It exists to answer
one question before the picture conversion is built: can this phone's
hardware encoder re-encode a film while it casts? It is a developer
tool. It goes, with its Kotlin and its script, when the real conversion
is built.

The probe is Kotlin (`HwProbe.kt`, its device-free parts in
`HwProbeRules.kt`). The codec list and the heat and battery readings
have no NDK equivalent, so it cannot be Rust. It drives the codecs the
way the Rust side will: synchronous dequeue loops with a 10 ms wait, on
one worker thread. Only the driver calls it, through
`tool/drive hwprobe <method> [<json args>]`. `tool/hwprobe` wraps that
and needs a driver session (`tool/drive-start -d <device>`).

```bash
tool/hwprobe codecs > codecs.json         # every video codec and what it claims
tool/hwprobe push film.mkv                # copy a clip to the phone; prints its path
tool/hwprobe run '{"path": "/sdcard/Download/hwprobe/film.mkv", "label": "4k-main10"}'
tool/hwprobe stop                         # end the run; what it measured is kept
tool/hwprobe instances '{"mime": "video/hevc", "width": 3840, "height": 2160, "encoders": 4, "decoders": 4}'
tool/hwprobe pull 4k-main10               # the run's mp4, when it asked for one
```

`codecs` lists every codec whose types are video. For each it gives the
profiles and levels by name, the sizes and frame rates it claims at 1080p
and 2160p, the bitrate modes, the colour formats, and the features.
An HEVC or H.264 encoder also gives the platform's answer on P010 input
at Main10 or High10 (`supportsP010Main10at1080` and `...at2160`).

`push` grants the debug app `READ_MEDIA_VIDEO` first, since the app opens
the clip by its path. The clip goes to `/sdcard/Download/hwprobe/`.

`run` starts a run, prints a line every 10 seconds, and saves the report
to `build/hwprobe/<label>.json` when the run ends. Each line has the
frames made, the speed, the thermal status, the battery temperature and
current, and whether the screen is on. Ctrl-C stops the run and still
saves the report. The summary at the end gives the speed overall and in
the slowest 5 s window, the frames in and out, and the pts that went
missing. For a per-slot run it also says whether each slot starts on a
key frame and whether two runs made the same bytes.

The speed is `madeX`: seconds of film made per second of wall time. The
conversion has to stay above 1.0, so the slowest window matters more than
the average. The battery current's sign is the phone maker's choice.

A run's arguments (only `path` is required):

| Argument | Default | Meaning |
|---|---|---|
| `path` | | The clip: a file path or a `content://` URI. Its first video track is used. |
| `label` | mode and file name | Names the report and the mp4. |
| `mode` | `transcode` | `transcode`, `decodeOnly`, `perSlot`, `requestSync` or `transcodeP010`. |
| `mime` | `video/hevc` | What to encode to: `video/hevc` or `video/avc`. |
| `profile` | `auto` | `main`, `main10`, `main10hdr10`, `high` (H.264). `auto` picks Main10 for a 10-bit source. |
| `perSlot` | false | `transcodeP010`: a fresh encoder at every slot, as in the `perSlot` mode. |
| `bitrate` | 12000000 | Bits per second. |
| `bitrateMode` | `cbr` | `cbr`, `vbr` or `cq`. |
| `seconds` | 600 | Film time to make. The clip loops until then. |
| `slotSeconds` | 10 | `perSlot`: the shortest slot. A slot starts at a source key frame. |
| `requestSyncAt` | `[100, 400, 700]` | `requestSync`: the frames a key frame is asked for at. |
| `repeat` | 1 | Runs of the whole plan. Two shows whether the bytes come out the same. |
| `iFrameInterval` | 1, or 3600 per slot | Seconds between the encoder's own key frames. |
| `maxBframes` | 0 | B-frames the encoder may use. |
| `wakeLock` | true | Holds the CPU awake for the run. |
| `writeMp4` | false | Writes the first run's output to `Download/hwprobe/<label>.mp4`. |

The modes:

- `transcode` decodes into the encoder's input surface and drains the
  encoder.
- `decodeOnly` decodes alone, which gives the decoder's own speed.
- `perSlot` starts a fresh encoder at every slot. The decoder moves to
  the new encoder with `setOutputSurface`. If that throws, the decoder
  is rebuilt at the slot's key frame instead, and the report says which
  happened. Each slot records its frames, its encoder start time, its
  bytes and their hash, and whether its first frame is a key frame.
- `requestSync` asks the encoder for a key frame at the given frames and
  reports how many frames later each one came. Give it a long
  `iFrameInterval`, or the encoder's own key frames answer first.
- `transcodeP010` decodes to 10-bit P010 buffers and copies each picture
  into the encoder's input buffers, at Main10 (High10 for H.264). It
  shows whether an encoder whose surface gives 8-bit makes real 10-bit
  from buffers. The report's `p010` part gives both sides' layouts and
  the copy's time per frame. A decoder that will not put out 10-bit ends
  the run with its colour format in the error.

The probe needs Android 10 or later. Its channel is in every Android
build, release too, but nothing in the app calls it.
