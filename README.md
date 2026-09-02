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

Not yet exercised on a device or desktop build (this was developed on a
host without the GTK toolchain): `flutter run -d linux` itself (cargokit
builds the crate through CMake; `media_kit_libs_video` supplies libmpv) and
`flutter build apk` (cargokit drives the NDK; the first cross-compile has
to prove that aws-lc-sys/ring build under it). On **Android**, reqwest's
rustls uses `rustls-platform-verifier`, which needs a one-time JNI init with
the app `Context` (plus its small Kotlin component) before any HTTPS fetch
works; that hook is still to be added to `MainActivity`.

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
