# Xtremio

A native, cross-platform **Stremio client** built on a pure-Rust core with a Flutter UI.

Xtremio is the client half of a two-part project. The other half is
[`zond/stream-server`](https://github.com/zond/stream-server) — a pure-Rust,
headless, zero-external-binary torrent-streaming server. Xtremio pairs that
with [`stremio-core`](https://github.com/Stremio/stremio-core) (the official
Rust engine for addons, catalogs, library, and playback state) and
[`media_kit`](https://pub.dev/packages/media_kit)/libmpv for playback.

> **Status:** phase 3 (account, library, addons, settings) is complete
> on top of phase 2 (browse → details → play); the roadmap items below are
> not started. The app boots `stremio-core` and the
> embedded `stream-server` at start-up. **Board** shows a continue-watching
> row and one row per catalog of every installed addon; **Discover** browses
> any catalog through the engine's type/catalog/genre filters; **Search**
> asks every addon that supports it and groups the hits per addon.
> **Details** shows facts and genres, a season picker and episode list with
> watched state for series (picking an episode loads its streams), and the
> streams every installed addon returns with quality hints parsed into
> chips; details routes are video-aware, so coming back from the player
> lands on the right episode. The **player** plays torrents through the
> embedded server and HTTP streams directly, with its own controls (seek
> bar with the buffered range, play/pause, seek buttons, volume,
> fullscreen, keyboard shortcuts, playback speed), embedded and addon
> subtitles styled from the profile settings, audio track selection, a
> stats OSD, an up-next countdown
> that hands off to the next episode, and a pre-playback progress overlay
> for torrents that shows the server's start-up phase (checking existing
> data, finding peers, buffering the start) with percentages and download
> speed instead of a bare spinner. A debug-only Settings entry plays a
> public Big Buck Bunny torrent to prove the torrent path without any
> addon. **Library** lists every added title over the engine's
> `LibraryWithFilters` model (type and sort filters, cumulative paging,
> long-press to remove, mark watched, rewind or mute notifications), and
> the details header has a bookmark to add or remove a title. **Addons**
> (from Settings) lists the installed and community addons and installs,
> updates, uninstalls or configures one by manifest URL. **Settings** holds
> the Stremio account (sign in, create an account, sync, log out), the
> engine's own settings (player, subtitles, interface, streaming server)
> and the state of the embedded server. The design notes behind phase 3
> are in [docs/phase3-design.md](docs/phase3-design.md).

## Goals (beyond current Stremio clients)

The point of Xtremio is to go past what existing Stremio apps do:

- **Offline downloads** — cache a full episode or movie to the device and keep
  watching with no connection (through a tunnel, on a plane), the way Netflix
  does. This fits the architecture naturally: the torrent engine already writes
  to a local cache; offline support means downloading the *whole* file, pinning
  it so it is never evicted, and a library UI to manage what is saved. No
  transcoding is needed here either — playback is just libmpv decoding the
  original file bytes off disk, the same as any local video.
- **Cloud storage sources** (e.g. Google Drive) — stream from a personal cloud
  drive, most naturally via a Stremio addon that resolves cloud files to
  playable URLs. Provider OAuth / API-key setup is the fiddly part.

## Parity (what current Stremio clients already do)

Xtremio also has to match what the official apps already offer. These are
table stakes, not differentiators:

- **Casting** to plain Chromecast / Cast-enabled TVs (the Cast *sender*
  protocol), in addition to running natively on Android TV devices. Where the
  receiver can already decode the source, this is a direct cast over the LAN —
  the server still does no transcoding. Where it can't, the *sending* device
  transcodes in real time using its **platform hardware codec** (Android
  MediaCodec first; VideoToolbox/VAAPI later) before casting — never ffmpeg,
  never pure-Rust software transcoding, so the pure-Rust core stays untouched.
  This is scoped to devices with a hardware encode path; where none exists,
  casting is limited to formats the receiver supports natively.
- **Android TV / Google TV** as a native, D-pad-driven app (see Platform
  support below).

All of the above is roadmap, not built yet.

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  Flutter UI (this repo) — screens, navigation, playback UI   │
├────────────────────────────────────────────────────────────┤
│  Dart ⇄ Rust FFI                                             │
│   • stremio-core   → addons, catalogs, search, library,      │
│                      account, playback state (the "brain")   │
│   • stream-server  → torrent/archive bytes over local HTTP   │
├────────────────────────────────────────────────────────────┤
│  media_kit / libmpv — decodes & renders the video the        │
│  server streams (direct play; codecs & subtitles on-device)  │
└────────────────────────────────────────────────────────────┘
```

The UI stays thin: discovery/library/addon logic lives in `stremio-core`, the
bytes come from `stream-server`, and the client's job is presentation plus
driving libmpv. `stream-server` runs **in-process**: the Rust crate in `rust/`
links it as a library and starts it on its own thread (loopback only,
port 11470 with an ephemeral fallback), so there is no sidecar binary to
ship, launch, or keep alive on mobile. Because a capable on-device player handles codecs and
subtitles, the server never transcodes — it just gets bytes onto an HTTP
connection.

### How the Rust core is wired in

- **Bridge:** [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge)
  2.13.0 with the cargokit backend. Codegen, Dart package and Rust crate must
  be the exact same version (FRB refuses to start otherwise). The crate lives
  in `rust/` (package `xtremio_core`, cdylib + staticlib, plus rlib for its
  own tests); `rust_builder/` is the generated FFI-plugin glue that builds it
  for each platform; `lib/src/rust/` and `rust/src/frb_generated.rs` are
  generated and committed. After changing anything under `rust/src/api`, run
  `flutter_rust_bridge_codegen generate` and commit the result (CI fails on
  drift).
- **State crosses as JSON.** `core_dispatch` takes a stremio-core `Action`
  as JSON, `core_get_state(field)` returns one model field as JSON, and
  `core_events` streams `RuntimeEvent`s (`NewState` lists the fields that
  changed). Every stremio-core type already derives serde, so this costs no
  per-type mirroring and survives engine upgrades; Dart keeps small view
  classes (`lib/core/state/`) over the maps. Where the raw model lacks what
  the UI needs, `get_state_json` (`rust/src/model.rs`) adds a sibling key
  rather than reshaping the field: `meta_details` gains `watchedVideoIds`,
  `board`/`search` gain `catalogLabels` (catalog and addon names resolved
  from the profile's manifests, aligned with `catalogs`). The model
  (`XtremioModel`) has `ctx`, `continue_watching_preview`, `board`,
  `search`, `discover`, `meta_details`, `streaming_server`, `player`,
  `library`, `installed_addons`, `remote_addons` and `addon_details`;
  `lib/core/fields.dart` mirrors the list. `ctx` serializes as
  `{profile, notifications, events}` only — the library, streams and
  server-URL buckets it also holds are `#[serde(skip)]` — so the Library
  screen reads its own `library` field (`LibraryWithFilters<NotRemovedFilter>`,
  snake_case keys such as `next_page`). Typed FRB structs can be added
  for hot paths later if profiling asks for it.
- **The engine runs on our `Env`** (`rust/src/env.rs`): reqwest + rustls for
  HTTP, one JSON file per bucket under the app-support directory with
  temp-then-fsync-then-rename writes, and two lib-owned tokio runtimes
  (concurrent + a single-worker sequential one for ordered persistence).
- **The server is in-process**: `stream_server::start` runs on its own
  thread and runtime; the core's `streaming_server_url` is retargeted to it
  when the persisted profile points at loopback (a remote server URL set by
  the user is left alone). Port 11470 is preferred, ephemeral is the
  fallback. Login and logout reset the profile's settings to stremio-core's
  defaults (`http://127.0.0.1:11470/`), so the event pump re-applies the
  retarget on `UserAuthenticated` / `UserLoggedOut`.
- **Settings are the engine's.** `ctx.profile.settings` is stremio-core's
  `Settings` struct (camelCase; `docs/phase3-design.md` §4 lists it) and
  the only way to change one is `Ctx::UpdateSettings` with the *entire*
  object — it has no serde defaults, so a map missing a key fails at
  dispatch with "invalid action JSON" and never reaches the engine.
  `ProfileSettings.withValue(key, value)` (`lib/core/state/profile.dart`)
  copies the map with one key changed, and every control in Settings and
  in the player's settings sheet writes exactly that; nothing writes while
  the `ctx` field is still unknown. Settings are device-local (the API's
  `saveUser` carries only the user record). What the app reads: the player
  takes `seekTimeDuration` (arrows, the seek buttons, double-tap) and
  `seekShortTimeDuration` (Shift + arrows — the *short* seek, as
  stremio-core names it), `bingeWatching` and
  `nextVideoNotificationDuration` (the up-next countdown after an episode
  ends; 0 plays the next one at once, and with binge watching off nothing
  moves on by itself), `pauseOnMinimize` (through `AppLifecycleListener`),
  `escExitFullscreen`, and `subtitlesSize` / `subtitlesTextColor` /
  `subtitlesBackgroundColor` (`SubtitleStyle.fromSettings`: 32 px scaled
  by the percentage, `#RRGGBBAA` colours, a transparent background means
  no box); `XtremioApp` creates each `MediaKitEngine` with
  `hardwareDecoding` as the video controller's hardware acceleration, so
  it applies to the next video that opens. `streamingServerUrl` is the
  "Embedded server" (the URL init reported) / "Remote server" (a validated
  http(s) URL) choice. `quitOnClose` and `hideSpoilers` are stored but not
  yet honoured (no tray to hide to; the details screen shows thumbnails
  and summaries regardless); the remaining fields pass through untouched.
- **Account.** Settings → Account dispatches `Authenticate` (`Login` or
  `Register` with the GDPR consent the API requires, `from: xtremio`),
  `Logout`, and the housekeeping stremio-web does on window focus
  (`PullAddonsFromAPI` at every start-up, plus `PullUserFromAPI`,
  `SyncLibraryWithAPI` and `PullNotifications` for a signed-in profile, on
  start-up, resume and `UserAuthenticated`). The engine does not serialize
  its "authenticating" status, so the pending spinner is local state
  cleared by `UserAuthenticated` or the `Error` whose `source` is it.
  Signing in *replaces* the anonymous library and resets the settings;
  the UI says so. **Privacy:** `AuthRequest` serializes the password, so
  `UserAuthenticated{auth_request}` and its `Error{source}` carry it, and
  `ctx.profile.auth.key` is the session key — nothing in the app logs
  `RuntimeCoreEvent.args` or dumps `ctx`, and `ctx_logged_in.json` is a
  hand-authored fixture with a fake account, never a recorded session.
- **Playback goes through the engine's `Player` model.** The UI dispatches
  `Load Player` with the raw stream JSON (plus the stream/meta requests);
  stremio-core converts the source and publishes `player.stream` as
  `{StreamUrls, converted stream}` — its `streaming_url` is the direct URL
  for `url` streams and `<server>/{infoHash}/{fileIdx}?tr=…` for torrents
  (the server auto-creates the engine from the info hash on first GET). The
  player opens whatever that URL is in `media_kit`/libmpv and reports
  `TimeChanged`/`PausedChanged`/`Ended` back so the library follows along.
  `StreamUrls` is snake_case on the wire, unlike the rest of the model.
  `PlaybackEngine` (`lib/features/player/`) is the thin interface over
  media_kit; widget tests swap in a fake through `PlaybackScope`.
- **The player UI is ours, driven by the engine and the core.**
  `PlayerScreen` switches media_kit's built-in controls off
  (`controls: NoVideoControls`) and draws its own dark-M3 overlay: a top
  bar (back, title, next episode, subtitles, audio, stats, settings) and a
  bottom bar (seek bar with buffered range and drag scrubbing, play/pause,
  ± the seek step, elapsed/remaining time, volume on wide layouts,
  fullscreen). The controls fade after 3 s while playing and return on
  tap, mouse or key; they stay while paused or buffering. Keyboard:
  Space/K play-pause, ←/→ or J/L ± the seek step (10 s by default),
  Shift+←/→ ± the short seek step (3 s), ↑/↓ volume, M mute, F
  fullscreen, Esc leaves fullscreen first when `escExitFullscreen` is on
  and the player otherwise, S subtitles, A audio, N next episode, Shift+I
  stats. Everything is a stream or method on
  `PlaybackEngine` (`tracks`, `buffer`, `volume`, `setAudioTrack`,
  `setSubtitleTrack`, `setExternalSubtitle`, ...) or a core action, so the
  screen is tested against `FakePlaybackEngine` and `FakeCoreClient`
  alone; fullscreen goes through an injectable `FullscreenController`
  (media_kit_video's native window / immersive helpers by default).
- **Subtitles.** After the media opens the screen dispatches
  `VideoParamsChanged` with the best filename it knows (the stream's
  `behaviorHints.filename`, else the URL's last segment when it looks
  like one, else none — never a stand-in like the stream's label) — that
  is what makes the core ask the subtitle addons. The menu lists the
  tracks embedded in the file (from libmpv's track list, minus the
  synthetic `auto`/`no` entries) and every file from
  `player.subtitles`, the stream's own `subtitles` and the converted
  stream's, deduplicated by URL. Which track is active comes from mpv's
  own `sid`/`aid` (observed through `NativePlayer.observeProperty`), so a
  default or forced track mpv picked by itself shows as selected too —
  media_kit's `stream.track` only follows its own setters. Picking one
  dispatches `SubtitlePreferenceChanged`, which the core keeps for the
  Player session; the next episode's player applies it automatically to
  the first matching track once the media is loaded (mpv refuses
  `sub-add` while it is still between files). Text subtitles are rendered by Flutter
  (media_kit's default `libass: false` sets mpv `sub-visibility=no` and
  feeds the text lines to a `SubtitleView`), so size, colour and the
  background box are a `TextStyle` in `SubtitleViewConfiguration`, not
  mpv `sub-*` properties — identical on Linux and Android with no fonts
  to ship. **Limitation:** bitmap subtitles (PGS, VobSub) are listed but
  not drawn on this path; that needs `libass: true` and font shipping.
  The style is the profile's subtitle settings (see *Settings are the
  engine's*); the player's settings sheet edits the same keys.
- **Torrent start-up overlay.** From `open` until the engine first reports
  the media loaded (a duration, or playing), a torrent shows a card instead
  of a spinner. Once `open` has been issued, the screen polls the embedded
  server's `/{infoHash}/{fileIdx}/stats.json` every 500 ms (plain `dart:io`
  HTTP, like the stream URL itself; `TorrentStats.statsUrlFor` derives it
  from the core's streaming URL, index and `tr=`/`f=` query kept, and a poll
  falls back to `/{infoHash}/stats.json` while the per-file route still
  404s on an unresolved magnet) and maps the server's `phase` to a label:
  `resolvingMetadata` → "Fetching torrent metadata…", `checking` →
  "Checking existing data…" with `checkedBytes/checkTotalBytes`,
  `buffering` → "Finding peers…" with the `peerDiscovery` counts while no
  peer is live, else "Buffering start…" with
  `initialWindowReadyBytes/initialWindowBytes`, `ready` → "Starting
  playback…", `error` → a failure; no answer yet (404, unreachable) →
  "Connecting to server…". The bar is determinate whenever there is a
  percentage; `downloadSpeed` and `peers` show when non-zero. Polling
  stops when the media loads, on an engine error and on dispose; direct
  HTTP streams get nothing extra. The `TorrentStatsClient` comes from
  `PlaybackScope`, so tests feed phases through a fake.
- **Next episode.** `player.nextVideo`/`nextStream` come from the core.
  On `Ended`, with `bingeWatching` on, an up-next card counts down
  `nextVideoNotificationDuration` (35 s by default); playing it dispatches
  `NextVideo` and either replaces the player route with one for the
  engine's `nextStream` (same addon, matching binge group) — the old
  screen then skips its `Unload` so the session's subtitle preference
  survives — or pops with a `PlayerScreenResult` so the details screen
  loads that episode's streams when the engine found no stream.
- **Addons are three model fields and one external link.** The Addons
  screen (Settings → Addons, or "Browse addons" on an empty board) reads
  `installed_addons` (`InstalledAddonsWithFilters`, snake_case) and
  `remote_addons` (`CatalogWithFilters<Descriptor>`, Discover's shape over
  an `addon_catalog` resource); whether a community entry is installed is
  not in the model and is computed from `ctx.profile.addons` by manifest
  URL. "Add addon" and every tile open `AddonDetailsScreen`, which loads
  `addon_details` for one manifest URL and offers Install (the fetched
  descriptor), Update (`UpgradeAddon` when versions differ), Uninstall
  (never for a protected addon) and Configure — the manifest URL with
  `manifest.json` → `configure`, opened in the system browser through
  `url_launcher` behind `ExternalLinkScope` so tests assert the URL. A
  `configurationRequired` manifest cannot be installed (`Other` code 6),
  so Configure is its primary action; `profile.addonsLocked` disables
  every mutation behind a banner, and failed mutations (`Error` events
  sourced from `AddonInstalled`/`AddonUninstalled`/`AddonUpgraded`) show
  as a SnackBar.
- **Pinned upstreams** (`rust/Cargo.toml`): `stremio-core` at a fixed rev
  with the `derive` + `env-future-send` features, `zond/stream-server` at a
  fixed rev. To bump: change the rev, `cargo update -p <crate>`, run
  `cargo test`, and re-copy `rust/vendor/stremio-watched-bitfield` from the
  new stremio-core rev (it carries a one-line `flate2` relaxation the
  combined graph needs; see `rust/vendor/README.md`).

### Verifying on a dev machine

```bash
# Rust crate
cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
cargo test --test cinemeta -- --ignored       # network: loads a Cinemeta catalog, refreshes the fixture
cargo test --test meta_details -- --ignored   # network: meta + streams + Player + continue watching for a public-domain torrent, plus a series (seasons, selected episode, watched), refreshes fixtures
cargo test --test board -- --ignored          # network: Board rows + a search over the default addons, refreshes fixtures
cargo test --test library_addons -- --ignored # network: ctx (logged out), installed/remote addons, addon details (Cinemeta), library fixtures
# ctx_logged_in.json is hand-authored (a fake account); there is no recorder for it, and a real session must never be committed

# Dart (FFI-backed tests load rust/target/debug/libxtremio_core.* directly;
# rebuild after touching rust/src or they run against a stale library)
cargo build --manifest-path rust/Cargo.toml
flutter pub get && dart format --set-exit-if-changed . && flutter analyze && flutter test

# Bindings must be committed
flutter_rust_bridge_codegen generate && git diff --exit-code lib/src/rust rust/src/frb_generated.rs
```

### Seeing video play

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev
flutter run -d linux
```

Then either **Discover → a title → a stream**, or **Settings → Developer →
"Play test torrent"** (Big Buck Bunny from a public torrent through the
embedded server; "Play test HTTP stream" is the direct-play path). The
stats OSD (Shift+I) ends with the URL libmpv is playing, so a torrent
should read `http://127.0.0.1:11470/dd8255ec…/-1?tr=…`.

`flutter run -d linux` itself has not been exercised yet (this was developed
on a host without the GTK toolchain); cargokit builds the crate through
CMake and `media_kit_libs_video` supplies libmpv there.

### Android

The debug APK builds and boots on a headless x86_64 emulator (Discover
loading a Cinemeta catalog with posters end to end); a physical device or
Android TV box has not been tried yet. See [ANDROID.md](ANDROID.md) for the
full build/run reference, the manifest and network decisions, and exactly
what has been verified so far.

**Prerequisites.** Android SDK with platform 36, build-tools 36.0.0 and NDK
28.2.13676358 (the versions Flutter 3.47 pins; `android/app/build.gradle.kts`
takes them from the Flutter Gradle plugin, minSdk 24), JDK 21, Rust via
rustup (cargokit runs `rustup target add` itself, but pre-installing
`aarch64-linux-android x86_64-linux-android armv7-linux-androideabi` keeps
the first Gradle run predictable), and `cargo` on the PATH of whoever runs
Gradle (`build.gradle.kts` calls `cargo metadata` to find the Kotlin half of
`rustls-platform-verifier`). Builds for **x86_64 or armv7** additionally need
**libclang** on the host: `aws-lc-sys` only ships pregenerated bindings for
aarch64-linux-android, so those targets enable its `bindgen` feature
(`rust/Cargo.toml`), `rust/cargokit.yaml` forces its `cc` builder and the
vendored cargokit is patched to point bindgen at the NDK sysroot
(`rust_builder/README.md`). Verified with Ubuntu's `libclang-18`, found
without any `LIBCLANG_PATH`; set it only if clang-sys cannot locate
`libclang*.so` on your host.

**Build.** Always redirect to a log and check the real exit code; the first
Rust cross-compile takes several minutes per target.

```bash
flutter build apk --debug --target-platform android-x64            # emulator only
flutter build apk --debug --target-platform android-arm64,android-x64   # phone/TV + emulator
flutter build apk --release --target-platform android-arm64        # arm64 only, no bindgen needed
flutter build apk --release --split-per-abi                        # arm, arm64, x64 APKs
```

Debug builds always add x86_64 for the emulator (cargokit mirrors Flutter's
rule; the vendored copy is patched to no longer add x86, which Flutter 3.47
cannot package -- see `rust_builder/README.md`). Output:
`build/app/outputs/flutter-apk/app-debug.apk`.

**What the Android glue does.** `MainActivity.onCreate` calls
`NativeInit.initTlsVerifier(applicationContext)` (a JNI hook in
`rust/src/android.rs`) before the Flutter engine starts: on Android reqwest's
rustls verifies certificates through `rustls-platform-verifier`, which needs
the app `Context` once, and both the stremio-core `Env` and the embedded
stream-server share that global. Its Kotlin component is an AAR shipped inside
the crate; Gradle locates it through `cargo metadata` and a ProGuard keep rule
(`android/app/proguard-rules.pro`) protects it from R8 in release builds. The
main manifest declares `INTERNET` (Flutter's template only does so for
debug/profile) and `usesCleartextTraffic="true"`: that flag only governs
dart:io (`Image.network` posters from self-hosted http:// addons, calls to the
loopback server), while Rust sockets and libmpv ignore the policy either way.
The embedded server needs no environment: Android app processes have no
`HOME`, and nothing on `stream-server`'s startup path fails without it; every
effective path (settings, logs, torrent session and DHT state) comes from the
config and cache directories the app hands it (`<files>/server` and
`<cache>/server`, from `path_provider`), which override the environment-based
defaults it may still look at.

**Emulator (headless, KVM).** The x86_64 `google_apis` image is the one that
runs on an x86_64 Linux host (which is why the bindgen path above matters);
the user must be in the `kvm` group.

```bash
export ANDROID_HOME=~/Android/Sdk
export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH
yes | sdkmanager --install "emulator" "system-images;android-36;google_apis;x86_64"
echo no | avdmanager create avd -n xtremio_api36 -k "system-images;android-36;google_apis;x86_64" -d pixel_7
emulator -avd xtremio_api36 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -memory 4096 &
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 5; done
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.zond.xtremio/.MainActivity
```

Verify: `adb logcat -d | grep -E "flutter|xtremio|stream_server|rustls"` should
show the embedded server starting and no "Expect rustls-platform-verifier to
be initialized"; `adb forward tcp:11470 tcp:11470 && curl -s
http://127.0.0.1:11470/heartbeat` reaches the server (if 11470 was taken the
app fell back to an ephemeral port, read it from logcat); Discover showing
Cinemeta posters proves HTTPS end to end. For D-pad work use the
`system-images;android-36;android-tv;x86_64` image instead. A physical
phone/TV box (USB debugging, `adb devices` shows `device`) takes the arm64
APK the same way.

## Platform support

The hard constraint is **BitTorrent**: the streaming path needs raw TCP/UDP
sockets, a local HTTP server, disk cache, and libmpv. That decides everything.

| Platform | Support | Notes |
|---|---|---|
| **Linux (desktop)** | ✅ First-class | Flutter desktop + media_kit + native Rust. Easiest target. |
| **Windows (desktop)** | ✅ First-class | Same as Linux. |
| **macOS (desktop)** | ✅ First-class | Native Rust + media_kit; needs a Mac to build. |
| **Android** | ✅ Supported | Rust cross-compiles to the NDK; embedded as a native lib. Proven by existing Stremio clients. Primary mobile target. |
| **Android TV / Google TV** | ✅ Supported | Chromecast with Google TV, the Google TV Streamer, and other Android TV boxes all run Android — the same APK installs (leanback manifest is in place). The real work is a **D-pad/remote-focused UI**, not the build. Low-RAM devices (the 2 GB Chromecast) make the lightweight pure-Rust server and a bounded piece cache matter. |
| **iOS** | ⚠️ With effort | Rust + media_kit build for iOS, but: background execution is throttled (a torrent server suspends when backgrounded), and **the App Store is out** (App Store terms are incompatible with GPL-3, which the shipped binary is — see License). Sideload / TestFlight / AltStore only. |
| **Web** | ❌ Not possible | A browser **cannot do BitTorrent** — no raw sockets (only HTTP/WebSocket/WebRTC), so the torrent swarm is unreachable, and there's no way to run a local server or libmpv. WebTorrent only reaches the tiny WebRTC-capable subset of peers. The only "web" that works is a *thin client talking to a separate streaming server* (the stremio-web model) — a different architecture, not this app. |

**Short version:** desktop and Android are the real targets, iOS works if you
sideload and accept the background limits, and web is fundamentally off the
table for a self-contained streaming client.

### Known issue: Linux video is software-rendered (for now)

On Linux desktop, `media_kit_video` 2.0.1 cannot share Flutter 3.38+'s EGL
context (the embedder only makes it current on the raster thread — see
[media-kit #1404](https://github.com/media-kit/media-kit/issues/1404)), so it
falls back to software rendering on **both X11 and Wayland**. Playback works,
but is CPU-rendered; `--profile`/`--release` builds are much smoother than
debug. The fix is the Linux renderer redesign in
[media-kit PR #1346](https://github.com/media-kit/media-kit/pull/1346), not
yet released. **No code change is needed here**: once a `media_kit_video`
release includes it, `flutter pub upgrade media_kit_video` enables hardware
rendering automatically. Android (the primary target) is unaffected.

To judge playback performance by numbers rather than feel, the player has a
stats OSD (like mpv's): move the mouse over the video to show it, or press
**Shift+I** (or the stats button in the top bar) to pin it on/off. It lists
output vs container FPS, dropped
frames, the **hwdec** in use (or `software` when libmpv is decoding on the
CPU), codec and resolution, video bitrate, and demuxer cache / buffering
state, sampled twice a second only while it is on screen.

## Getting started

```bash
flutter pub get
flutter run -d linux      # or -d windows, -d macos, or an Android device
```

Linux desktop needs `clang`, `cmake`, `ninja`, GTK 3 dev libraries, and
`libmpv-dev` (media_kit links libmpv); Android needs the Android SDK/NDK.

## License

The **source** in this repository is MIT (see [LICENSE](LICENSE)). Note that a
**compiled** Xtremio binary that embeds the default build of `stream-server`
links `unrar-rs` (GPL-3.0-or-later), so distributed binaries are covered by
GPL-3.0-or-later. This is intentional and fine for open distribution; it is
also why the iOS App Store is not a target. (A build without RAR support keeps
the binary MIT.)
