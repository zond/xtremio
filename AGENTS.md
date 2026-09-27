# Working on Xtremio

The rules a change to this repository has to keep. The [README](README.md)
says what the app is; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains
how each part works and why. This file states each rule once, says where it
lives in the code and what test holds it, and points at the explanation
rather than repeating it. When a doc and the code disagree, the code wins
and the doc is fixed.

## Read first

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), at least
  [What crosses the bridge](docs/ARCHITECTURE.md#what-crosses-the-bridge) and
  [Wire conventions](docs/ARCHITECTURE.md#wire-conventions) before touching
  anything that dispatches an action or reads a model field.
- The pinned stremio-core source (`rust/Cargo.toml` names the rev) is the
  authority on wire shapes. Do not guess a field name; read the `serde`
  attributes.

## Commits

- Small, single-concept commits whose message says what changed and why,
  in prose. Do not push unless asked.
- Every commit an agent wrote ends with a `Co-Authored-By: <model name>
  <noreply@anthropic.com>` trailer naming the model that wrote it.
- Latest dependency versions. `flutter_rust_bridge` is the same exact
  version in `pubspec.yaml`, `rust/Cargo.toml` and the codegen. Nothing
  under `rust/src/api` changes without regenerating the bindings and
  committing them.

## Verification, with real exit codes

Run these before every commit and read the exit codes, not the tail of the
output. Never pipe a test command into `tail`/`head`/`grep` before an
`&&`-gated commit (the pipe's exit code is the filter's); redirect to a log
and `echo EXIT=$?`.

```bash
dart format --set-exit-if-changed lib test; echo EXIT=$?
flutter analyze; echo EXIT=$?
# FFI-backed Dart tests load rust/target/debug/libxtremio_core.*: rebuild it
# after touching rust/src, or they run against a stale library.
cargo build --manifest-path rust/Cargo.toml; echo EXIT=$?
flutter test > /tmp/flutter-test.log 2>&1; echo EXIT=$?
# Rust changes:
(cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test); echo EXIT=$?
# Anything under rust/src/api:
flutter_rust_bridge_codegen generate && git diff --exit-code lib/src/rust rust/src/frb_generated.rs; echo EXIT=$?
# Kotlin with no Android in it (FrameRateMode, DownloadsProgressBar):
(cd android && ./gradlew :app:testDebugUnitTest); echo EXIT=$?
```

CI (`.github/workflows/ci.yml`) runs four jobs: the Rust checks above, a
`cargo check --target armv7-linux-androideabi`, the Flutter checks (it
formats `.` rather than `lib test`), and the codegen drift check.
`build.yml` builds every platform weekly and on tags.

New behaviour needs a test that fails without it. Prove at least one by
stashing the `lib/` (or `rust/src`) change and running the new test
(`git stash push -- lib && flutter test <file>; git stash pop`).

## Tests and fixtures

- Widget tests run against `FakeCoreClient`, `FakePlaybackEngine` and the
  other fakes in `test/support/`; nothing in `test/features` touches FFI or
  libmpv. `test/core/core_client_test.dart` and `rust/tests/core.rs` are the
  FFI and engine tests.
- Model-field states come from fixtures under `rust/tests/fixtures/`,
  recorded by the `#[ignore]` tests in `rust/tests/` (the commands are in
  [docs/OPERATIONS.md](docs/OPERATIONS.md#re-recording-fixtures)) and loaded
  through `test/support/fixtures.dart`. Refresh a fixture by re-running its
  recorder, never by hand-editing recorded JSON; trim large catalogs. The
  downloads recorder is idempotent on purpose (it fixes the tmp path and the
  timestamps the Dart tests quote); keep it that way.
- `ctx_logged_in.json` is hand-authored with a fake account. Never commit a
  recorded session; redact `auth.key`, `_id` and `email` from anything
  captured against a real account.

## Never log auth material

Four things are never logged, printed, put in a URL, a fixture, a test, a
bug report or the text of a logged exception (log the exception's *type*):

- **The Stremio password and session key.** `Authenticate` actions and the
  `UserAuthenticated` / `Error{source}` events carry the password;
  `ctx.profile.auth.key` is the session key. Log event names and
  `source.event` only -- never `RuntimeCoreEvent.args`, a `Ctx` action's
  args, or the `ctx` JSON.
- **The embedded server's bearer token** (`ServerHandle::auth_token`, read
  by `server::token_for` in `rust/src/env.rs`). It never crosses FFI and
  exists only inside the Rust crate.
- **The Google Drive refresh token.** It does not expire and reaches every
  file the account ever picked through this OAuth client. It lives in
  `SecretStore` (`lib/core/secret_store.dart`), reached only through
  `DriveAccount`; never in `xtremio_prefs.json`. The one copy outside it is
  Rust memory while linked (`DriveAccount.grantSink` →
  `server_drive_grant`, `null` on unlink and `pairAgain`), for the Drive
  pins nobody presses a button for. Rust writes it nowhere.
- **Addon, debrid and subtitle URLs**, which carry keys in the path as well
  as the query. `DiagnosticsLog.write` (`lib/core/diagnostics_log.dart`)
  rewrites every `http(s)` URL through `DiagnosticsLog.url` before the line
  is stored -- nothing below FFI redacts, and `rust/src/logging.rs` re-emits
  every line to logcat. `redactSecrets` is the second lock on the copied
  report. Verbose logging is the one deliberate exception, and says so.
  A fetch error is stripped of its URL (`without_url`, `rust/src/env.rs`)
  before it becomes a message.

Tests: `test/features/diagnostics_test.dart`, `test/core/drive_*_test.dart`,
`test/core/actions_test.dart`.

## The app never speaks HTTP to the embedded server

libmpv fetches the open media routes, and stremio-core's `StreamingServer`
model calls its handful of control routes through `Env::fetch`, which adds
the bearer token. Everything the app itself asks of the server -- settings,
stats, storage, downloads, Drive, the LAN listener -- is an FFI function
over `ServerHandle` in `rust/src/api/server.rs` or
`rust/src/api/downloads.rs`, returning JSON. A new need is a new Rust
function there: never a `dart:io` `HttpClient` call, and never a new route
on the server (stream-server's `AGENTS.md`, "Routes"). The only HTTP the Dart side makes to it is on media routes:
the player reading the start of a stream that failed
(`archive_sniff.dart`) and handing the container to the archive routes
(`archive_route.dart`). The player
keeps no disk cache of its own (`cache-on-disk=no`); every storage question
is `server_storage_report`. See
[The embedded server](docs/ARCHITECTURE.md#the-embedded-server).

## The downloads registry

`rust/src/downloads.rs` owns what is kept offline; the server owns the pin
and the bytes. See
[Downloads and offline play](docs/ARCHITECTURE.md#downloads-and-offline-play).
Tests: `rust/tests/downloads.rs`, the unit tests in `rust/src/downloads.rs`,
`test/core/downloads_client_test.dart`, `test/features/downloads_*_test.dart`.

- **Progress has one source of truth, and the registry is not it.**
  `downloaded`/`size`/`path`/`state` are merged from the server's
  `downloads()` and cached in the file. Never compute progress locally or
  add a field the server could answer. A tick that moved only `downloaded`
  does not rewrite the file, and a tick pushes the narrow `progress` row,
  never a whole entry.
- **The file is forgiving and additive.** camelCase, unknown keys survive a
  round trip, an entry this build cannot parse is written back verbatim, a
  new field is optional with a default. A file that is not the shape this
  build writes is an error, never an empty registry (empty is the pin set
  that sweeps every download).
- **The row leads the server in and follows it out.** `add` writes the row
  (with `replaces`) before the pin; `remove` marks `pendingRemoval` before
  the unpin and drops the row after; `reconcile_pins_in` finishes either at
  boot. Keep every new server call on that side of its write.
- **One client, one sink.** One `DownloadsClient`, built in `XtremioApp` and
  handed down through `DownloadsScope`; widget tests put
  `FakeDownloadsClient` there.
- **A download has no location.** One torrent-data root, the server's
  `cacheRoot`; a pin decides bytes are kept, never where. The registry
  records no destination. The only write the app makes to `cacheRoot` on
  its own is `moveOffPurgeableRoot` (`lib/main.dart`).
- **A kept download is not a file.** `downloads_open` answers a URL on the
  embedded server, never `entry.path`.
- **The row is not evidence; ask the server.** `downloads_open` hands back a
  URL only when the server also says it holds the file whole, and refuses
  with `notHeld` otherwise (a URL for a hash the session lacks would start
  a magnet add). At boot a finished row the server does not hold becomes
  `gone` and is never re-pinned by itself.
- **A row's source is its stream, keyed by the server.** A torrent row is
  `(infoHash, fileIdx)`; a link or Drive row is the server's 64-hex key and
  `0` (`is_proxy_key`), asked for before the row is written
  (`proxy_download_key`).

## Deep links open an addon; they never install one

A `stremio://host/manifest.json` link opens that addon's details screen and
stops. `lib/shell/deep_link.dart` decides, `XtremioApp` acts; tests in
`test/app_deep_link_test.dart` through `FakeDeepLinks`. See
[docs/DEEP_LINKS.md](docs/DEEP_LINKS.md).

- **Nothing is dispatched but the `Load`**; no path reaches `InstallAddon`.
- **The URL is passed on unmodified**; stremio-core's `AddonDetails` does
  the scheme rewrite on the whole string. Do not parse and rebuild it.
- **A link never logs the URL**, only the scheme.
- **A host-less link is dropped**, including the Drive pairing's
  `stremio:///pair` hand-back. Do not give that link a meaning.

## Nothing re-times a subtitle but the viewer

A declared frame rate says where an upload came from, not how it is timed,
so it decides nothing about a subtitle. `sub-speed` and `sub-delay` are
written only through the "Adjust timing" panel's state (`SubtitleTiming`,
`lib/features/player/subtitle_timing.dart`). The behaviour and the
measurements behind each rule are in
[Subtitles](docs/ARCHITECTURE.md#subtitles); tests are
`test/features/player/subtitle_*_test.dart`,
`test/features/player/player_subtitle_*_test.dart`, `rust/src/subtitles.rs`
and `rust/tests/subtitle_threshold.rs`.

- **A multiplier is measured, never judged or declared**: from a match
  against another file (`subtitles_match`) or from two marks
  (`SubtitleCalibration`). Never derive one from a rate an addon or a
  container claims, and never read `PlaybackEngine.videoFrameRate` for a
  subtitle -- its one consumer is `DisplayFrameRate`.
- **A mark pairs the cue's raw time with where it is drawn**, never with the
  instant of the press. `sub-start` is the raw time in the file; that was
  measured against a running libmpv, is written down at
  `MediaKitEngine.subtitleCueStart` (the only reader), and is the one rule
  no test can reach.
- **The panel shows the multiplier and cannot press it.** The shift
  accelerates only under a hold (`shiftStrideAt`); every tap is a tenth.
- **Every path that changes what is shown goes through
  `PlayerScreen._resetSubtitleTiming`**, which replaces the whole
  `SubtitleTiming`. A new path gets its reset and its test.
- **Only a press on the panel is remembered** (`_adjustTiming`), and the
  write waits (`_pendingSync`) until the adjusting ends. The flush in
  `dispose` runs after the preferences listener is removed.
- **Memory keys** (`SubtitleSyncMemory`, `lib/core/subtitle_sync.dart`): a
  speed on the series and the lower-cased `releaseGroup` (never `g`, a
  per-answer index); a shift on those plus the video release
  (`castFilename`). A key part nobody can name means nothing is remembered;
  Reset forgets rather than storing zero. `_rememberedSpeed` refuses a
  stored multiplier outside mpv's `0.1-10.0`.
- **A re-open restores the addon file before the timing**
  (`_restoreExternalSubtitle` then `_applySubtitleTiming`).
- **A pick or a press by hand stops the auto-pick** for that media
  (`_subtitlesChosenByHand`); a late auto-pick revert undoes only its own
  id and moves `_timing` inside a `setState`.
- **The panel is not the OSD**: drawn outside the fade, its own focus scope
  and Back rung, and it scrolls in whatever height it gets.
- **The match** (`rust/src/subtitles.rs`) compares on-screen bitmaps from
  both timestamps of every cue, scores overlap above chance, and applies
  only at `CONVINCING` (0.45). That number was measured; do not move it
  without re-running `cargo test --release --test subtitle_threshold --
  --ignored`. The reference is always the viewer's pick, and a subtitle URL
  is never quoted back.
- **Ordering**: every consumer goes through `PlayerScreen._offeredSubtitles`.
  `subtitlesByRelease` ranks files cut for the playing release, then a group
  already adjusted for; `subtitleMatchesRelease` matches whole contiguous
  tokens only. Language rows are alphabetical; the menu lifts at most two
  most-picked languages (`SubtitlePickMemory.pinned`) and never hands an
  unused slot down. A row names the addon and why it is first, never a rate.
- **Pick memory** (`SubtitlePickMemory`, `lib/core/subtitle_picks.dart`):
  only a pick by hand writes, nothing is preselected that the episode does
  not offer, Off is a value, and a synthesized preference is never
  dispatched as `SubtitlePreferenceChanged`.

## The stats panel draws a reading or nothing at all

`lib/features/player/playback_stats_overlay.dart`: a number that does not
exist takes its row (or its half of one) away, never a dash. Tests:
`test/features/player/player_stats_osd*_test.dart`,
`test/features/player/playback_stats_test.dart`. What each row means is in
[The stats OSD](docs/OPERATIONS.md#the-stats-osd).

- No retention policy, no window; no bitrate, no time. A proxied stream has
  no sharing row. mpv's `collecting…` holds back only mpv's readings.
- The transfer counters cover the torrent's current live period and the row
  says `since it last went live`. Label them; never persist them.
- The server is asked with the URL the engine was handed
  (`_heldStreamUrl`), and only when this device's server serves it
  (`_servedHere`, which also gates the torrent stats poll, since a stats
  call creates the engine it asks about).
- Nothing outlives its poll (`_stopStreamNumbers`); a late answer for
  another video is dropped. One unit ladder (`formatBitrate`, `formatBytes`,
  `formatAge`, `TorrentProgressCard.formatSpeed`): decimal, binary only for
  piece lengths.

## The addon health record keys on a hash, never the URL

`rust/src/addon_health.rs` keys every record by `key_for`: `host[:port]#`
plus 12 hex of `sha256(transport URL)`. The URL, its query, the resource
id, request timestamps and error strings are never stored.
`lib/features/addons/addon_health.dart` mirrors `key_for`; the two are
pinned by `the_key_is_the_digest_the_app_computes` and "is the digest the
Rust side computes" -- change one only with the other. Rust counts, Dart
judges (`AddonHealth.verdict`, a pure function). See
[docs/ADDONS.md](docs/ADDONS.md).

## Rules a real device taught us

Each is easy to write again, and each has a test in `test/features/tv/`
unless it says otherwise.

- **Nothing vetoes the OSD's fade on a focus.** `PlayerScreen._canAutoHide`
  does not list "a control has focus"; `_hideControls` hides the bar and
  hands the remote back to the video as one act.
- **A direction key never leaves a layer**, and Back comes down a ladder,
  most transient first. A rung exists only while it visibly does something,
  and asks what is on screen, never a field. An on-screen back arrow is not
  on the ladder: it leaves outright (`_leavePlayer`, the details app bar's
  own `leading`), never `Navigator.maybePop`.
- **A button drawn inside a focusable thing is not a button.** Put it
  beside the thing, outside its `RemotePress` (`TvTextField.onClear`, the
  addon verdict chip). `FocusableTile` wraps its child in `ExcludeFocus` on
  a television.
- **A subtitle's position is pushed, not configured**:
  `VideoState.setSubtitleViewPadding`, on the next frame, only on change.
  No widget test can see this.
- **A scrolling strip clips, so a focused tile needs room**
  (`_RowLayout.focusSlack`, television only).
- **A row a remote walks is built all at once** (`SingleChildScrollView`
  over a `Row`, never `ListView.builder`); bound each image's decode
  instead. Its test walks to the last item of a row longer than the screen.
- **A sideways press at the end of a row stays in the row**
  (`TvCardStrip`; `RootShell._onRailKey` for the rail).
- **Anything the remote can land on wears the app's own focus indicator.**
  Two ways: `FocusTheme`, the floor derived into `ThemeData`, and the ring
  put on by hand (`FocusHighlighted`, `FocusMarked`, with `FocusTreatment`
  saying how much of it a surface family wears). **Prefer the floor**; wrap
  only what it cannot reach or what sits over video or poster art, and say
  which in a comment. A ring turns the floor's fill off only where the
  surface owns the ink (`FocusableTile`); two or three marks is normal. A
  television pins `AlwaysShowFocus`. `focus_reach_test.dart` walks every
  screen through its `drawn`, `opened` and `unopened` tables, and fails on a
  `*_screen.dart` in neither; an `unopened` entry is driven by
  `proveNothingOpens`, not trusted.
- **An image holds its box before it arrives**: pending, failed and loaded
  are one size (`TvBackdrop`, `EpisodeThumbnail`, `TvMetaHeader`).
- **A sliver that comes and goes is keyed**, or focus is lost when it
  appears.
- **A width shared between N things is clamped at zero.** `(width - gaps) /
  n` goes negative on a phone; debug builds throw where release clamps.

## Brand assets are generated, never hand-edited

Every icon, the Android TV banner, the splash mark and the README logo come
from `tool/generate_branding.sh` (ImageMagick 7, Cantarell Extra Bold).
Change a colour or a coordinate there and re-run it; never touch the PNGs,
the `ic_launcher_*` XML or `values*/ic_launcher_background.xml`. The
adaptive icon's foreground keeps the mark inside the circle every launcher
mask leaves; widening the X means checking that.

## Use cheaper models for mechanical work

When an agent delegates, mechanical subtasks (formatting, renames, moving
code, re-recording fixtures, running the checks above) go to a smaller
model; keep the larger one for design and for reading stremio-core to
decide a wire shape.
