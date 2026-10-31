# Running and checking Xtremio

This covers setting up a machine, building and running the app, cutting a
release, re-recording fixtures, and the screens and log lines that say what
a build is doing. The checks that gate a commit are in
[AGENTS.md](../AGENTS.md#verification-with-real-exit-codes). Everything
specific to Android and Android TV (the SDK, the APKs, the emulators, a
real box) is in [ANDROID.md](ANDROID.md).

## Setting up a dev machine

A build needs Flutter stable (CI uses 3.47.1) and a Rust toolchain no older
than `rust-version` in `rust/Cargo.toml` (1.97.1), because the build itself
compiles the crate, through cargokit. Linux desktop also needs:

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev \
  libsecret-1-dev
```

`libmpv-dev` is what media_kit links against. `libsecret-1-dev` is for
`flutter_secure_storage`, which keeps the Drive pairing's refresh token
(`lib/core/secret_store.dart`). On Linux that is the Secret Service API,
which also needs a keyring daemon *running*: `gnome-keyring`, KWallet or
another. With none, a Drive pairing lasts only the run
(`DriveLinkOutcome.thisRunOnly`) and the app says so. Building without the
dev package fails in cmake.

### With Nix

`flake.nix` has the same tools as development shells, for Linux (x86_64,
aarch64) and Apple-silicon macOS, the systems nixpkgs builds Flutter 3.47
for:

```bash
nix develop               # Flutter, rustup, FRB codegen + cargo-expand, ffmpeg,
                          # libmpv; on Linux the desktop libraries above
nix develop .#android     # ...plus JDK 21, the SDK and NDK docs/ANDROID.md names,
                          # the emulator and a phone and a TV image for this host
nix develop .#xervice     # Node 22 and firebase-tools, for xtremio-xervice/
```

The shells provide tools and nothing else. `make` builds as it does outside
them. Three things are worth knowing:

- **Rust is rustup's, not Nix's.** cargokit builds with `rustup run stable
  cargo build` and adds targets with `rustup target add`, so the shell
  provides `rustup` and the toolchain lives in `~/.rustup` as usual. On
  entry it says so if `stable` is missing or older than `rust-version`.
- **libmpv is built against FFmpeg 6.** `rust/src/libav.rs` refuses any
  other FFmpeg major, and nixpkgs' own mpv links a newer one, so the shell
  rebuilds mpv (a few minutes, once) and points `XTREMIO_LIBMPV` at it. The
  FFmpeg tests in `rust/tests/` then run rather than print `SKIPPED`.
- **macOS builds still need Xcode**, from the App Store. There the shell
  has no Nix C compiler, unsets `DEVELOPER_DIR` and `SDKROOT`, and takes
  the Nix GNU userland (`sed`, `cut`, `find`, ...) off `PATH`, so
  `xcodebuild`, CocoaPods and plugin scripts get the Xcode and BSD tools
  they are written for. `media_kit_libs_macos_video`'s podspec runs a
  Makefile that GNU `sed` and `cut` fail, which surfaces only at link time
  as `ld: framework 'Mpv' not found`. The failure stays in a pub cache that
  a shell without this fix got to first, because Flutter skips `pod install`
  when nothing changed. Repair it once from inside the shell:
  `make -C ~/.pub-cache/hosted/pub.dev/media_kit_libs_macos_video-*/macos -B Frameworks/.symlinks`.

The `android` shell accepts the Android SDK licence on the user's behalf:
androidenv refuses to compose an SDK until it is.

## Building and running

```bash
flutter pub get
make run DEVICE=linux   # flutter run, stamped with version and commit
make linux              # release Linux bundle
make apk                # release APK, arm64 (a phone, a 64-bit TV box)
make apk-tv             # release APK, armeabi-v7a (Chromecast with Google TV)
make apk-split          # release APKs per ABI
make apk-debug          # debug APK for the x86_64 emulator
make macos              # release macOS .app
make ios                # does the iOS half compile (see below)
make version            # what would be stamped
make check              # every gate a commit passes (AGENTS.md)
```

Each target adds `XTREMIO_VERSION` (from `pubspec.yaml`) and
`XTREMIO_GIT_COMMIT` (`git rev-parse --short HEAD`, suffixed `-dirty` for an
unclean tree) as `--dart-define`s. The Diagnostics header names the build
by them, and a plain `flutter run` or `flutter build` reports
`app: unknown`. Extra flags go through `FLAGS=`. The APK targets also stamp
the version codes `apk-split` produces (1001 for armeabi-v7a, 2001 for
arm64), so a single-ABI build installs over a split one instead of being
refused as a downgrade. By hand, the same two defines:

```bash
flutter build apk --release \
  --dart-define=XTREMIO_VERSION="$(sed -n 's/^version: //p' pubspec.yaml)" \
  --dart-define=XTREMIO_GIT_COMMIT="$(git rev-parse --short HEAD)"
```

Every version tag builds Linux, Windows, macOS and both Android ABIs in
`.github/workflows/build.yml` and attaches them to a GitHub Release. That
workflow also runs weekly and on demand.

## Cutting a release

Only this repository is tagged. stream-server, rqbit and stremio-core are
pinned by rev.

1. **Bump `version:` in `pubspec.yaml`** to `0.1.N+1` and commit it alone
   as "Version 0.1.N". The `+1` build number reaches no APK: `make apk` and
   `make apk-tv`, which the Android jobs run, stamp 2001 and 1001 over it.
2. **Tag it, annotated**: `v0.1.N`. Its message is the tag name, a blank
   line, then the notes for people: a one-line lede, then bold-led
   paragraphs, ending with **Underneath.** for what changed inside.
3. **Push `main`, then the tag.** The tag starts `build.yml`: two Android
   ABIs, Linux, Windows and macOS, then a `release` job that creates the
   GitHub Release as a draft, uploads every file and publishes it, with a
   body that is the downloads table and the install notes and nothing else.
   v0.1.15's run took about 25 minutes.
4. **The workflow does not carry the tag's notes.** Prepend them to the
   body it wrote: `gh release edit v0.1.N -R zond/xtremio --notes-file
   <notes, then the existing body>`. Name the repository, because in a fork
   `gh` defaults to upstream's.

The last was v0.1.15, at 8620717.

## Seeing video play

Run the app, then either **Discover → a title → a stream**, or **Settings →
Developer → "Play test torrent"**, which plays Big Buck Bunny from a public
torrent through the embedded server. "Play test HTTP stream" is the
direct-play path, and "Download test torrent" proves the download path.

The stats OSD (Shift+I) ends with two rows. `stream` is the stream's own URL
as stremio-core names it. For a torrent it reads
`http://127.0.0.1:<port>/dd8255ec…/-1?tr=…`, on whatever port the embedded
server bound this launch. Nobody fetches it; it only says which stream this
is. `read` is what mpv was handed, when that differs: `xtremio://<id>` for a
stream read by id through the server, the `/proxy` URL for an origin read
only forward. `tool/drive player` shows the same two
([DRIVING.md](DRIVING.md#commands)).

### Linux video is software-rendered, for now

`media_kit_video` 2.0.1 cannot share Flutter 3.38+'s EGL context (the
embedder makes it current only on the raster thread,
[media-kit #1404](https://github.com/media-kit/media-kit/issues/1404)), so it
falls back to software rendering on both X11 and Wayland. Playback works, and
`--profile`/`--release` builds are much smoother than debug. The fix is the
renderer redesign in
[media-kit PR #1346](https://github.com/media-kit/media-kit/pull/1346), not
yet released. `flutter pub upgrade media_kit_video` enables hardware
rendering, with no code change here, once a `media_kit_video` release
carries it. Android is unaffected.

## Re-recording fixtures

The `#[ignore]` tests write the model-field fixtures under
`rust/tests/fixtures/`. Run them from `rust/`:

```bash
cargo test --test cinemeta -- --ignored        # network: a Cinemeta catalog
cargo test --test meta_details -- --ignored    # network: meta, streams, Player and continue watching for a public-domain torrent, plus a series
cargo test --test board -- --ignored           # network: Discover's rows and a search over the default addons
cargo test --test library_addons -- --ignored  # network: ctx (logged out), installed/remote addons, addon details, library
cargo test --test downloads -- --ignored       # no network: downloads_registry.json, from two torrents it builds itself
cargo test --test embedded -- --ignored        # no network: background_traffic.json on a server that has just started
cargo test --test subtitles -- --ignored       # no network: subtitle_starts.json from XTREMIO_SUBTITLE_PLAYING and XTREMIO_SUBTITLE_REFERENCE
cargo test --release --test subtitle_threshold -- --ignored   # network, ~15 min, ~70 MB into $XTREMIO_SUBTITLE_CORPUS or a temp dir: re-measures CONVINCING, refreshes subtitle_threshold.json
```

`ctx_logged_in.json` is hand-authored with a fake account and has no
recorder. Nor has `addon_streams_recorded.json`. It holds live addons'
answers, recorded once and trimmed by hand to one row per field shape
(`loadRecordedStreams`, `test/support/fixtures.dart`). It is the
specification the source parser in `lib/features/details/stream_facts.dart`
is held to.

## Where torrent data lives, and what it costs

**Settings → Streaming server → Server storage** names the one root that
holds everything a torrent puts on this device: the server's `cacheRoot`
(see [ARCHITECTURE.md](ARCHITECTURE.md#where-torrent-data-lives)). It also
answers the question a misbehaving playback raises first: is the cache over
its limit. The same number is in the copied Diagnostics header, beside the
device's free space.

- **The cache against its limit** comes from the server
  (`server_cache_usage`). It counts what the piece store and the proxy cache
  say they hold, in allocated blocks, as `totalBytes`/`limitBytes`.
  Separately, `protectedBytes`/`protectedFiles` are what a pinned download
  or the window of the title played last keeps right now.
- **Free and total space** is measured on the Rust side
  (`rust/src/storage.rs`, `server_storage_report`): a different question,
  whether the disk is full.
- **"Clean cache now"** (`server_clean_cache_now`) asks the torrent engine
  and the proxy cache for everything nobody is playing and nobody kept.
  There is no scheduled sweep for it to run early, since each owner gives
  back as it goes. Nothing it does stops playback. Pins and the last
  title's window are never taken, so a clean that leaves the cache over its
  limit says what is protected rather than that it failed.
- **"Clear the cache"** (`server_clear_cache`, here beside the clean and in
  Settings → Streaming server) is the one that stops playback. It asks for
  a confirmation first ("Stops what is streaming and deletes everything
  cached. Downloads you kept stay."), and on a television focus starts on
  Cancel. Then the server stops every torrent that streams, all but a kept
  download's. It fails every read open on one, so a player in the middle of
  a film shows the error it shows for a failed read. It deletes every piece
  and proxied chunk no download keeps, the last title's window included. The
  snackbar says what it freed and how many torrents it stopped ("Freed
  1.2 GB, stopped 2 torrents"). Kept downloads, the settings, where each
  file was last played and the app's image cache stay. An update that
  does not fit runs it too, after the clean (see
  [ANDROID.md](ANDROID.md#updating-from-inside-the-app), "Room first").
- **Moving the root** writes one validated settings key and takes effect at
  the next start. Nothing is copied. At that start every finished download
  the server no longer holds is marked **Not on this device**, with a button
  that fetches it again. Nothing fetches it automatically. Playing one is
  refused (`notHeld`) and the title streams instead. On Android the picker
  offers `getExternalStorageDirectories()`, so an SD card needs no
  permission. Elsewhere a path is typed.

## Diagnostics off a device

**Settings → Developer → Diagnostics** shows the last few hundred `tracing`
lines the Rust core kept in memory: its own and the embedded server's, which
share one subscriber (`rust/src/logging.rs`). A header above them names the
build, the cache against its limit, the free space where the server writes,
the device (on Android the release, API level and model), the embedded
server, an `incoming connections:` line saying whether peers can connect in
through the router, and the pinned `stream-server` and `stremio-core` revisions. The
screen copies it all to the clipboard. It ships in release builds on purpose:
it is the only way to get a log off a phone without ADB. Over ADB, every
line the app keeps also goes to logcat under the tag `xtremio`
(`adb logcat -s xtremio`).

**Redaction.** Everything shown and copied goes through `redactSecrets`
(`lib/features/diagnostics/diagnostics_report.dart`) while Verbose logging
is off. The bearer token, `Authorization` values, keys and passwords never
reach the clipboard. Every URL is cut to what `DiagnosticsLog.safeUrl` keeps
(the origin, a `/proxy/…` URL's target host, a path only on this device or
the LAN listener). This is the second lock. The first is that nothing in
that class is logged in the first place. With Verbose logging **on**, the
report is copied as logged and redacts nothing, full stream links and the
credentials in them included. The switch says so in those words.

**Settings → Developer → Verbose logging** adds the server's retention
trace, mpv's demuxer, stream and cache lines, and whole stream URLs.

Lines worth knowing:

- `seek to <n>s did not take: the position is back at <m>s` means mpv
  refused a seek rather than waiting for it (a demuxer reporting itself
  unseekable). On screen it is just the film jumping back. The player checks two
  seconds after each run of presses. The stats OSD's `seekable` and
  `ranges` rows are the demuxer's side of it.
- The header's `image cache` line is Flutter's decoded-image cache against
  its ceiling (`ImageCacheUsage`, `lib/core/image_cache_usage.dart`; the
  ceiling and why it is 16 MiB are
  `XtremioBootstrap.imageCacheCeilingBytes` in `lib/main.dart`).
- `the cast ended after <time>: the receiver ...; <n> requests, <bytes>
  sent` -- one line per cast, whichever way it ended, saying how often the
  receiver stopped to buffer and what this device served it
  (`_logCastEnd`, `lib/features/player/player_screen_casting.dart`;
  [CASTING.md](CASTING.md#the-stats-panel-while-casting)).

## The stats OSD

Move the mouse over the video, or press **Shift+I** (or the top bar's stats
button), to see mpv-style numbers: output against container fps, dropped
frames, the **hwdec** in use (or `software`), codec and resolution, video
bitrate, sampled twice a second while it is on screen
(`PlaybackEngine.statsInterval`). On a television it is set larger. A row
with nothing measured is absent, never a dash (the rule is in
[AGENTS.md](../AGENTS.md#the-stats-panel-draws-a-reading-or-nothing-at-all)). While
casting, the same button shows the cast panel instead
([CASTING.md](CASTING.md#the-stats-panel-while-casting)).

**A cast whose picture the phone converts** shows it in two rows of that
panel ([Converting the picture](CASTING.md#converting-the-picture)):

```
sending  rendition (video/mp4) · video av1 → hevc 10-bit 16.0 Mbps · audio eac3 5.1 → aac 2.0 192 kbps
made     36 s ahead · 1.5x · converting at 3.1x
```

`sending` names the film's codec, what it is made as (`h264`, `hevc`,
`hevc 10-bit`) and the bitrate. `converting at` is how much film the newest
run makes per second of the phone's work. Below 1.0x the phone cannot keep
up, and the receiver will stop to buffer. It is absent for a copied picture
and until the run has reported, never a dash.

The panel's mpv rows are one `mpv      collecting…` row until mpv's first
sample. The server's rows below are drawn as usual, since what is on the
disk is what is worth watching in a stream that has not started yet.

**`cache` is two caches at two cadences.** First comes mpv's own demuxer
cache, labelled `mpv` (`0.4s mpv  buffering 40%` while it has run dry). Then
comes what this device's server holds unbroken behind and ahead of the
playhead, each with the watching it is worth. The player asks the server for
that every five seconds (`PlayerScreen.streamNumbersInterval`):

```
cache    2.3s mpv · behind 340 MB (2 min) · ahead 512 MB (3 min)
```

The server's half is there under every cache budget, including one that
covers the whole file. It is absent only where the server has no playhead
for the stream: one it holds nothing of (an addon's direct link, a file on
the device), or one no reader has been inside yet (6677606). The times are
the server's, from each head's own read rate, not mpv's `video-bitrate`
(e861525). A head nothing has measured yet shows its bytes alone.

**`sharing` is a torrent's, over its current live period**: what it has
committed to the swarm and what it has moved.

```
sharing  820 MB committed · ↑ 2.1 GB ↓ 4.8 GB · 0.44 since it last went live
```

The counters start at zero each time the torrent goes live, so a pause and
resume, or the idle sweep dropping the engine, restarts them. They are
neither the torrent's total nor the evening's. A ratio against nothing
downloaded is left out. A proxied stream has no sharing row, and neither has
a torrent whose counters cannot be read (paused, checking, stopped for
space, in error).

**`unver.` is bytes fetched and not yet hash-checked**, plus the reclaims
the cache asked for and was refused:

```
unver.   38.0 MB fetched, not hash-checked · 2 reclaims refused
```

A level, not a verdict: a piece still in flight and the deliberate second
copy of a chunk taken from a faster peer both sit in it. A few per cent of
what was played is that. A multiple of it, beside refused reclaims, is the
cache fetching what its own next pass deletes. Absent where `sharing` is.

**`seekable` and `ranges` are about seeking.** The player sets
`force-seekable` on a stream the embedded server serves, so `seekable` reads
`forced`. That is our claim, not a reading. `partially-seekable` beside it
is the demuxer's own answer. **`forced · partially yes`** is the demuxer
saying it could not seek (the Matroska index not arrived yet) and being
overruled. `forced · partially no` means the fault is elsewhere. An addon's
own URL is not forced and reads straight. `ranges` is what the cache can
serve a seek from without the demuxer. It reads `none` for the first seconds
of every file while every seek works, so read it next to `seekable`.

**A torrent adds the swarm**, from the same `stats.json` as the start-up
card. The rows are download speed; `connected` seeds (holding the whole file); `<live>
connected / <seen> found` peers; a `swarm` row that is what the trackers
last said about everyone (`137 seeds / 402 peers · 4 min ago`, or `not
reported`); the phase while not ready; the piece length (nothing is readable
until a whole piece is verified); an `inflight` row for the piece the reader
is on (`inflight #137 · 6.3 of 16.0 MiB · unverified`); the server's
reason when it stopped; a `dht` row only while the DHT has found no
node; and a `router` row whenever the server asks the router to let peers in
(`Open through <router>, port <n>`, or why not). The `dht` and `router` rows
are read once, when the torrent's polling starts. The rest are polled
every five seconds while the panel is up and the app in front (`PlayerScreen.torrentStatsOverlayInterval`). During a stall they
are polled every two seconds, panel or not, because the stall card reads
them too.

On Android a `display` row gives the refresh rate the display settled on;
see [ANDROID.md](ANDROID.md#telling-mpv-when-the-screen-refreshes) for how
it and the `hwdec` row are read.

## Building for iOS

iOS is not built in CI and not shipped. `make ios` compiles an unsigned
release build, and fails. Getting past it takes a change to each of two
upstream dependencies, and this project carries no forks for a platform it
does not ship. It compiles with both of these changes, and needs nothing
else:

1. **The Cast plugin's iOS floor.** `flutter_chrome_cast` 1.5.0 declares
   iOS 15 in its `Package.swift` and podspec, but the GoogleCast SDK it
   pulls in requires iOS 16, so Xcode refuses the plugin's Swift package
   target. The project's own minimum is already 16 (`ios/Podfile`,
   `ios/Runner.xcodeproj`), but no setting here reaches a plugin's package
   target. Either raise the plugin's `.iOS("15.0")` and podspec to 16.0 (a
   fork, depended on by git in `pubspec.yaml`), or build through CocoaPods:
   run `flutter config --no-enable-swift-package-manager` before building,
   and pin every pod target in the Podfile's `post_install` hook:

   ```ruby
   target.build_configurations.each do |config|
     config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
   end
   ```

2. **The socket crate's device bind.** `librqbit-dualstack-sockets` 0.7.0
   (upstream rqbit's) binds a socket to an interface by index under
   `target_os = "macos"` and by name everywhere else. socket2 has the
   by-name call on Linux, Android and Fuchsia only, so iOS fails with
   ``no method named `bind_device` found for reference `&Socket` ``. The fix
   widens both gates in `src/bind_device.rs` to `target_vendor = "apple"`.
   Apply it with `[patch.crates-io]` in `rust/Cargo.toml`, pointing at a copy
   with that change. A plain git dependency would not do: `librqbit-utp`,
   also from crates.io, depends on the same crate and re-exports its
   `BindDevice`, so a git dependency adds a second copy whose types do not
   match.
