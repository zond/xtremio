# Running and checking Xtremio

What to run before a commit, how to see video play, and the two screens
that answer "what is this build doing" -- server storage and Diagnostics.

## Verifying on a dev machine

```bash
# Rust crate
cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
cargo test --test cinemeta -- --ignored       # network: loads a Cinemeta catalog, refreshes the fixture
cargo test --test meta_details -- --ignored   # network: meta + streams + Player + continue watching for a public-domain torrent, plus a series (seasons, selected episode, watched), refreshes fixtures
cargo test --test board -- --ignored          # network: Board rows + a search over the default addons, refreshes fixtures
cargo test --test library_addons -- --ignored # network: ctx (logged out), installed/remote addons, addon details (Cinemeta), library fixtures
cargo test --test downloads -- --ignored      # no network: rebuilds downloads_registry.json (a finished movie, a half-done episode, an empty one) from two torrents it builds itself
cargo test --test embedded -- --ignored       # no network: rewrites background_traffic.json, what server_background_traffic answers on a server that has just started (deterministic: everything dark)
cargo test --release --test subtitle_threshold -- --ignored   # network: re-measures where CONVINCING sits over ~39,000 pairings of real subtitle files (downloads ~70 MB into $XTREMIO_SUBTITLE_CORPUS or a temp dir, ~15 min); refreshes subtitle_threshold.json
cargo test --test subtitles -- --ignored      # no network: rewrites subtitle_starts.json from XTREMIO_SUBTITLE_PLAYING and XTREMIO_SUBTITLE_REFERENCE
# ctx_logged_in.json is hand-authored (a fake account); there is no recorder for it, and a real session must never be committed

# Dart (FFI-backed tests load rust/target/debug/libxtremio_core.* directly;
# rebuild after touching rust/src or they run against a stale library)
cargo build --manifest-path rust/Cargo.toml
flutter pub get && dart format --set-exit-if-changed . && flutter analyze && flutter test

# Bindings must be committed
flutter_rust_bridge_codegen generate && git diff --exit-code lib/src/rust rust/src/frb_generated.rs
```

## Seeing video play

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev \
  libsecret-1-dev
flutter run -d linux
```

`libmpv-dev` is what media_kit links against. `libsecret-1-dev` is for
`flutter_secure_storage`, where the Drive pairing's refresh token is kept
(`lib/core/secret_store.dart`): on Linux that is libsecret, which is the
Secret Service API, which needs a keyring daemon — `gnome-keyring`, KWallet
or another provider — *running* as well as installed. A machine with none
has no secure store at all, and the app says so rather than pretending: the
pairing works for the run and is gone after a restart
(`DriveLinkOutcome.thisRunOnly`). Building without the dev package fails in
cmake; running without a daemon fails at the first read, which is handled.

Then either **Discover → a title → a stream**, or **Settings → Developer →
"Play test torrent"** (Big Buck Bunny from a public torrent through the
embedded server; "Play test HTTP stream" is the direct-play path). The
stats OSD (Shift+I) ends with the URL libmpv is playing, so a torrent
should read `http://127.0.0.1:<port>/dd8255ec…/-1?tr=…`, on whatever port
the embedded server bound this launch.

## Where torrent data lives, and what it costs

**Settings → Streaming server → Server storage** names the one root
everything a torrent puts on this device is under (the server's
`cacheRoot`: the piece store the streaming cache and the kept downloads
share, the session's records, the proxy cache), and answers the question a
misbehaving playback raises first: is the cache over the limit the server
sizes it against. The same number is in the copied diagnostics
header too (alongside the device's free space, which lives only there),
since it is what a person should look at before reading a single log line.

Moving the root writes one settings key (`cacheRoot`, through
`server_update_settings`), which the server validates -- absolute, created
if missing, writable, stored resolved -- and it takes effect at the **next
start**: the running librqbit session was opened on the old root and
cannot be moved onto another one, and nothing copies what is already
there. On Android the picker offers `getExternalStorageDirectories()`, so
an SD card is reachable without a permission; elsewhere a path is typed.

What a move costs is the downloads that were under the old root: nothing
follows them, and at the next start the reconciliation marks each finished
row the server no longer holds as **Not on this device**, with a button on
the row that fetches it again. It never fetches one by itself — a moved
root would otherwise mean every kept film re-downloaded over whatever
connection the device is on. Playing such a row is refused (`notHeld`) and
the title streams instead, which is also what happens between the move and
that next start.

The cache-vs-limit number comes straight from the pinned server
(`ServerHandle::cache_usage()`, `rust/src/server.rs`
`cache_usage()`/`server_cache_usage()`): counted from what the piece store
and the proxy cache say they hold, not from a walk, in allocated blocks
rather than apparent length, reporting `totalBytes`/`limitBytes` and,
separately, `protectedBytes`/`protectedFiles` — what a pinned download or
the window of the title played last keeps right now, which a clean can
never take. The device's free/total
space (a different concern — is the disk full, not is the cache over its
limit) is still measured on the Rust side, in `rust/src/storage.rs`
(`server_storage_report()`), and shown beside the root on that screen and
in the diagnostics header.

"Clean cache now" runs `ServerHandle::clean_cache_now()`
(`server_clean_cache_now()`). There is no scheduled sweep for it to run
early: the torrent engine and the proxy cache each own their bytes and give
back what nobody is playing and nobody kept as they go, and a clean asks
both for that slack at once (`server/src/cache_cleaner.rs`, which keeps its
old name and no cleaner). **Nothing here stops playback**: the running
server keeps answering throughout. A pin and the window of the title played
last (kept with the player closed, until something else is played) are
never taken, so a clean that leaves the cache still over its limit is not a
failure: the screen names what
`protectedBytes`/`protectedFiles` (or the report's `protected`/
`protectedFiles`) are holding, rather than saying the clean failed.

## Diagnostics off a device

**Settings → Developer → Diagnostics** shows the last few hundred `tracing`
lines the Rust core kept in memory -- its own and the embedded
stream-server's, which share the one subscriber (`rust/src/logging.rs`) --
under a header naming the build, the cache against its limit, the free
space where the server writes, the device (on Android the release, the
API level and the model -- `dart:io` only has the build fingerprint there,
which names none of them, and the model is what decides whether a codec is
decoded on a chip or on the CPU), the embedded server and the pinned
`stream-server` / `stremio-core` revisions, and copies the lot to the
clipboard. This section is in release builds on purpose: it is the only way
to get a log off a phone without ADB.

One playback event in there is worth knowing about, because it is
invisible from the sofa: `seek to <n>s did not take: the position is back
at <m>s`. mpv refuses a seek it cannot serve rather than waiting for it --
a demuxer that reports itself unseekable makes it restore the position --
and the film jumping back is all that shows. The player checks two seconds
after each run of presses and writes one line when the position is still
where the run began; the stats OSD carries the demuxer's own answer
(`seekable`, `partially-seekable`, `ranges`) beside it.

With Verbose logging off, everything shown and copied goes through
`redactSecrets` (`lib/features/diagnostics/diagnostics_report.dart`)
first: the embedded server's bearer token, any `Authorization` value, auth
and API keys and passwords never reach the clipboard, and every `http(s)`
URL is cut down to what `DiagnosticsLog.safeUrl` keeps of it -- the
origin, a `/proxy/…` URL's target host, and a path only on this device or
the LAN listener a receiver was handed. That covers the whole-URL lines the
Rust half writes (archive and proxy fetches) and the lines written whole
while Verbose logging was on, which are still in the ring after it is
turned off. Nothing in that class is logged by the app in the first place
-- this is the second lock, not the first.

With Verbose logging **on**, the report is copied as it was logged, with
no scrub: full stream links, which can carry an addon's debrid key. The
switch's own description says so.

### What the image cache is holding, over ADB

The same figures the Diagnostics header carries also go into the log, so
they can be followed while somebody drives the app rather than read off a
television by hand (`ImageCacheLog`, `lib/core/image_cache_log.dart`).
Every thirty seconds, in every build:

```
$ adb logcat -s xtremio
… INFO xtremio_core::app: images: image cache: 33.0 MB of 33.6 MB ceiling ·
  80 images, 413 kB each on average · 0 held live by a widget, which no
  eviction frees · 0 decoding
```

Behind **Verbose logging**, one line more per picture as it decodes -- the
size it decoded to, what that costs, and the URL with the bound the widget
asked for on the end of it:

```
… INFO xtremio_core::app: images: image decoded: 312×468 px, 584 kB
  resident · https://images.metahub.space/poster/medium/tt0063350/img -
  Resized(312×null)
```

That is the line that says whether a picture decoded larger than the box it
is drawn in. It is a line per tile of every row scrolled past, so it is off
by default, and it is read as an image is submitted to the cache: turning
the switch on says nothing about pictures that are already decoded. To make
a screen decode again, put the app in the background and come back -- that
empties the cache (`XtremioApp`) -- then browse.

The header's app version and commit are whatever the build passed in as
`--dart-define`s, and with nothing passed they read `unknown` -- which is
the one line that says which build the rest of the report is about. A plain
`flutter build` passes neither, so the build to type is the `Makefile`'s:

```bash
make apk          # release APK for a phone or a 64-bit TV box (arm64)
make apk-tv       # release APK for a Chromecast with Google TV (armeabi-v7a)
make apk-split    # release APKs per ABI (what goes to Drive)
make linux        # release Linux desktop bundle
make run          # flutter run, stamped the same way
make version      # what would be stamped
```

Each of those adds `XTREMIO_VERSION` (from `pubspec.yaml`) and
`XTREMIO_GIT_COMMIT` (`git rev-parse --short HEAD`, suffixed `-dirty` when
the tree was not clean, because a report from a modified build must not
name a commit as if it were that commit), and takes the usual extra flags
through `FLAGS=`. `apk` and `apk-tv` also stamp the version codes the split
build ends up with (2001 for arm64, 1001 for armeabi-v7a), so a single-ABI
build installs over a Drive build instead of being refused as a downgrade.
Building by hand instead is the same two defines:

```bash
flutter build apk --release \
  --dart-define=XTREMIO_VERSION="$(sed -n 's/^version: //p' pubspec.yaml)" \
  --dart-define=XTREMIO_GIT_COMMIT="$(git rev-parse --short HEAD)"
```

`flutter run -d linux` itself has not been exercised yet (this was developed
on a host without the GTK toolchain); cargokit builds the crate through
CMake and `media_kit_libs_video` supplies libmpv there.

## The stats OSD

To judge playback performance by numbers rather than feel, the player has a
stats OSD (like mpv's): move the mouse over the video to show it, or press
**Shift+I** (or the stats button in the top bar) to pin it on/off. It lists
output vs container FPS, dropped frames, the **hwdec** in use (or
`software` when libmpv is decoding on the CPU), codec and resolution, and
video bitrate, sampled twice a second only while it is on screen.

**The `cache` row is two caches, at two cadences.** The first number is
mpv's own demuxer cache and buffering state, labelled `mpv` because
unlabelled it read as though it were the disk. What follows is the
retention window: what this device's embedded server holds of the stream
either side of the playhead, each half with the watching it is worth at
the bitrate on the row above.

```
cache    2.3s mpv · behind 340.0 MB (2 min) · ahead 512.0 MB (3 min)
```

mpv's half is sampled twice a second with the rows above it
(`PlaybackEngine.statsInterval`); the window is asked of the server every
five seconds (`PlayerScreen.streamNumbersInterval`), the ask costing it a
listing of the stream's own directories. So one row carries two readings
of different ages, and a report about it should say which half it means.
The window is absent altogether where nothing bounds the stream -- a
torrent the storage budget covers has no retention policy, and an addon's
direct link is not on this server at all -- and the minutes go missing
while mpv has answered no bitrate yet, which is the first seconds of every
file.

**The `sharing` row is a torrent's, and says which stretch it covers.**
The same answer carries what the torrent has committed to the swarm --
bytes advertised and promised never to be reclaimed -- and what it has
moved.

```
sharing  820.0 MB committed · ↑ 2.1 GB ↓ 4.8 GB · 0.44 since it last went live
```

Those transfer counters belong to the torrent's live state and start at
zero every time it goes live, so a pause and resume restarts them, and so
does the idle sweep dropping the engine before a later stream re-adds it.
`since it last went live` is on the row for that reason, and a report that
reads the numbers as the torrent's total, or as the evening's, is reading
them wrong. A ratio against nothing downloaded is left out rather than
drawn `0.00`, so a torrent seeding a complete file shows both byte counts
and the period with no ratio between them. A stream that is not a torrent
is proxied rather than seeded and has no row here at all, and neither has
a torrent whose counters cannot be read -- paused, checking, stopped for
space, in error.

Both of those rows are asked for only while the panel is on screen, about
the URL the player handed mpv, and only when this device's own server is
the one serving that stream. With a streaming server configured on another
machine a torrent plays straight off it, so nothing here is asked and
neither row appears -- what is on screen then is `cache    2.3s mpv` and
nothing beside it.

Two more rows are about seeking rather than performance: mpv's `seekable`
and `partially-seekable` on one, the demuxer's own seekable ranges out of
`demuxer-cache-state` on the other. They are there because
"fast-forwarding past the downloaded part makes the position jump back" is
a demuxer refusing the seek rather than a slow one serving it: mpv
restores the position when it says it cannot seek, and nothing else on
screen tells that apart from a seek that worked and then rewound.

**Read `seekable` knowing whose answer it is.** On a stream the embedded
server is serving the player sets `force-seekable`, so the row reads
`forced` rather than `yes`/`no` — it is our claim, not a reading, and the
demuxer's own conclusion has moved to the row beside it. mpv sets
`partially-seekable` alongside a forced `seekable`, so **`seekable
forced · partially yes` is the demuxer saying it could not seek and being
overruled** — the Matroska index that had not arrived — while `forced ·
partially no` says the demuxer was content and the fault is somewhere
else. An addon's own URL is not forced and both rows read straight, `no`
included. Both rows are absent when mpv answered neither, since a dash
there would be a measurement nobody made.

**`ranges none` is not a fault on its own.** The ranges say what the
cache can serve a seek from without going back to the demuxer, not
whether a seek can be made — that is the `seekable` row. Nothing is
recorded there until a whole keyframe range has been queued, so every
file reads `none` for its first seconds while every seek works. Read it
next to the row above, as "which parts land without a wait"; `ranges`
says `none` only when mpv answered with no ranges, and the row is absent
when it did not answer.

For a torrent it also carries the swarm, from the same `stats.json` the
start-up and stall cards read: download speed, `<connectedSeeders>
connected` seeds, `<live> connected / <seen> found` peers, a `swarm` row,
the phase (with its percentage) while the torrent is not ready yet, the
torrent's piece length -- the one number that explains why a wait is long,
since nothing is readable until a whole piece is verified -- an `inflight`
row naming the piece the open reader is sitting on and how far into it the
bytes have come (`inflight #137 · 6.3 of 16.0 MiB · unverified`, where
`unverified` is the difference between complete enough to be hashed and
servable), and the server's reason when it stopped. The first two rows are *our
connections* — who we are talking to, and how many of them hold the whole
file. The `swarm` row is not a measurement at all but what the torrent's
trackers last said about everyone (`137 seeds / 402 peers · 4 min ago`,
the age being `swarmScrapeAgeSecs`), and it reads `not reported` when no
tracker answered, since a swarm nobody could ask about is not an empty
one. They are polled while the panel is up, every five seconds when
playback is fine and at the faster stall cadence when it is not, so opening
the panel is what asks and closing it is what stops -- as does minimising
the app, which is nobody watching either. What the panel last showed stays
with it while it is down, so hovering it back on a desktop shows the swarm
rather than a blank waiting for the next answer; numbers nobody was
watching are dropped instead, so a stall long afterwards starts from the
server. On a television the whole panel is set in a larger size, since it
is read from a sofa.

## Linux video is software-rendered (for now)

Which is what the panel above will say on a Linux desktop, so this is why.
`media_kit_video` 2.0.1 cannot share Flutter 3.38+'s EGL context (the
embedder only makes it current on the raster thread — see
[media-kit #1404](https://github.com/media-kit/media-kit/issues/1404)), so it
falls back to software rendering on **both X11 and Wayland**. Playback works,
but is CPU-rendered; `--profile`/`--release` builds are much smoother than
debug. The fix is the Linux renderer redesign in
[media-kit PR #1346](https://github.com/media-kit/media-kit/pull/1346), not
yet released. **No code change is needed here**: once a `media_kit_video`
release includes it, `flutter pub upgrade media_kit_video` enables hardware
rendering automatically. Android (the primary target) is unaffected.

## Building for iOS

The CI's iOS job compiles an unsigned release build (`make ios`) and fails,
on purpose: getting past it takes a change to each of two upstream
dependencies, and this project does not carry forks for a platform it does
not ship. With both of these it compiles -- the build workflow on
`c578980` passed its iOS job (run 35310774992) -- and nothing else was
needed:

1. **The Cast plugin's iOS floor.** `flutter_chrome_cast` 1.4.8 declares
   iOS 15 in its `Package.swift` and podspec, but the GoogleCast SDK it
   pulls in now requires iOS 16, so Xcode refuses the plugin's Swift
   package target. The project's own minimum is already 16
   (`ios/Podfile`, `ios/Runner.xcodeproj`), but no setting here reaches a
   plugin's package target. Either raise the plugin's `.iOS("15.0")` and
   podspec to 16.0 (a fork, depended on by git in `pubspec.yaml`), or build
   through CocoaPods, where the Podfile does govern: run
   `flutter config --no-enable-swift-package-manager` before building,
   and pin every pod target in the Podfile's `post_install` hook:

   ```ruby
   target.build_configurations.each do |config|
     config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
   end
   ```

2. **The socket crate's device bind.** `librqbit-dualstack-sockets` 0.7.0
   (upstream rqbit's) binds a socket to an interface by index under
   `target_os = "macos"` and by name everywhere else, and socket2 has the
   by-name call on Linux, Android and Fuchsia only -- so iOS fails with
   ``no method named `bind_device` found for reference `&Socket` ``.
   The fix is widening both gates in `src/bind_device.rs` to
   `target_vendor = "apple"`. It has to go in with
   `[patch.crates-io]` in `rust/Cargo.toml`, pointing at a copy with that
   change: `librqbit-utp`, also from crates.io, depends on the same crate
   and re-exports its `BindDevice`, so a plain git dependency adds a
   second copy and the two types do not match.
