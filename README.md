# Xtremio

A native, cross-platform **Stremio client** built on a pure-Rust core with a Flutter UI.

Xtremio is the client half of a two-part project. The other half is
[`zond/stream-server`](https://github.com/zond/stream-server) — a pure-Rust,
headless, zero-external-binary torrent-streaming server. Xtremio pairs that
with [`stremio-core`](https://github.com/Stremio/stremio-core) (the official
Rust engine for addons, catalogs, library, and playback state) and
[`media_kit`](https://pub.dev/packages/media_kit)/libmpv for playback.

> **Status:** early, but the vertical slice is in place: the app boots
> `stremio-core` and the embedded `stream-server` at start-up, Discover
> browses a Cinemeta catalog, tapping a title loads its meta details and
> the streams every installed addon returns, and selecting a stream plays
> it with `media_kit` — torrents through the embedded server, HTTP streams
> directly. A debug-only Settings entry plays a public Big Buck Bunny
> torrent to prove the torrent path without any addon. Ugly on purpose;
> Board, Library, search, episode picking, subtitles and settings are
> still to come.

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
  classes (`lib/core/state/`) over the maps. Typed FRB structs can be added
  for hot paths later if profiling asks for it.
- **The engine runs on our `Env`** (`rust/src/env.rs`): reqwest + rustls for
  HTTP, one JSON file per bucket under the app-support directory with
  temp-then-fsync-then-rename writes, and two lib-owned tokio runtimes
  (concurrent + a single-worker sequential one for ordered persistence).
- **The server is in-process**: `stream_server::start` runs on its own
  thread and runtime; the core's `streaming_server_url` is retargeted to it
  when the persisted profile points at loopback (a remote server URL set by
  the user is left alone). Port 11470 is preferred, ephemeral is the
  fallback.
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
cargo test --test meta_details -- --ignored   # network: meta + streams + Player for a public-domain torrent, refreshes fixtures

# Dart (FFI-backed tests load rust/target/debug/libxtremio_core.* directly)
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
bottom of the player shows the URL libmpv is playing, so a torrent should
read `http://127.0.0.1:11470/dd8255ec…/-1?tr=…`.

`flutter run -d linux` itself has not been exercised yet (this was developed
on a host without the GTK toolchain); cargokit builds the crate through
CMake and `media_kit_libs_video` supplies libmpv there.

### Android

The debug APK builds; running it on an emulator or device is the next step.

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
(`rust/Cargo.toml`) and `rust/cargokit.yaml` forces its `cc` builder. If
clang-sys cannot find libclang, `export LIBCLANG_PATH=/usr/lib/llvm-18/lib`
(or wherever `libclang*.so` lives) before building.

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
**Shift+I** to pin it on/off. It lists output vs container FPS, dropped
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
