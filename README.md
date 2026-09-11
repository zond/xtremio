# Xtremio

![xtremio](assets/branding/xtremio-logo.png)

A native, cross-platform **Stremio client** built on a pure-Rust core with a
Flutter UI.

[![CI](https://github.com/zond/xtremio/actions/workflows/ci.yml/badge.svg)](https://github.com/zond/xtremio/actions/workflows/ci.yml)
[![source: MIT](https://img.shields.io/badge/source-MIT-blue)](#license)
[![binaries: GPL-3.0-or-later](https://img.shields.io/badge/binaries-GPL--3.0--or--later-blue)](#license)

Xtremio is the client half of a two-part project. The other half is
[`zond/stream-server`](https://github.com/zond/stream-server) — a pure-Rust,
headless, zero-external-binary torrent-streaming server, which Xtremio embeds
in its own process. Xtremio pairs that with
[`stremio-core`](https://github.com/Stremio/stremio-core) (the official Rust
engine for addons, catalogs, library, and playback state, built here from a
fork — see [Pinned forks](#pinned-forks)) and
[`media_kit`](https://pub.dev/packages/media_kit)/libmpv for playback.

## What it does

All of this is built and runs today. [docs/STATUS.md](docs/STATUS.md) is the
screen-by-screen inventory; what it does not reach -- casting, subtitle
timing -- is in the document each bullet links.

- **Catalogs and search across every addon installed, and a library.** A
  board of continue-watching and a row per catalog that answered, discover
  over the engine's own filters, a search that asks every addon supporting it
  — and on the board, in search and under a title's sources, a line naming
  the addons that could *not* answer, so a dead addon is never mistaken for a
  title nobody has.
- **Torrent streaming with no external binary.** `stream-server` runs
  in-process on loopback: nothing to ship beside the app, launch, or keep
  alive on mobile. In the default layout a title's sources are one row per
  release rather than one per addon offering it, in a section per resolution,
  ranked by peers per megabyte unless another order is picked; a torrent
  starts behind a card that says what it is doing — checking, finding peers,
  buffering — instead of a spinner.
- **Offline downloads.** A download is a file pinned in the embedded server:
  it is kept, piece by piece, in the one torrent-data root the streaming cache
  uses, and never exists as a whole file. A finished download plays through
  the same in-process server off the pieces already on the device — no peer,
  no tracker, no network — and only once the server answers that it holds the
  file whole. On Android a foreground service keeps one going after the app
  is left.
- **A player rather than a video widget.** Buffered seek bar, keyboard and
  remote shortcuts, audio tracks, embedded and addon subtitles, a stats OSD
  reporting hwdec, the swarm, what this device holds of the stream either
  side of the playhead and what a torrent has committed and moved since it
  went live, and an up-next countdown that hands over to the next episode.
- **Subtitle timing that is nudged or measured, and then remembered.** Shift
  the lines by hand from a panel that survives the controls fading, mark a
  line where it belongs and let two marks give the rate, or have the drift
  measured against another subtitle the viewer says is in sync -- which is
  where a stretch comes from, since nothing here presses a multiplier and no
  declared frame rate decides one. What was fixed is stored against the
  series and the subtitle's release group (a shift against the video release
  too), so the next episode starts right
  ([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- **Android TV and Google TV as their own layout**, not a phone app on a big
  screen: D-pad traversal with a focus memory per tab, a focus ring built to
  read over unknown poster art, remote keys in the player, ten-foot density
  and overscan. Run on a physical Chromecast with Google TV
  ([ANDROID.md](ANDROID.md)).
- **Casting to a Chromecast** from an Android phone, where the receiver can
  decode what the embedded server is already serving. The bytes go over the
  LAN untouched, from a second listener on the server that exists only while
  a cast session does and serves only torrents and archives the app has
  already opened — no control routes, no `/proxy`. The player screen becomes
  a remote, and a cast does not binge: the end of an episode on the
  television never starts the next one. What it refuses, why it refuses
  rather than guesses, and the fact that no real receiver has confirmed it
  yet are in [docs/CASTING.md](docs/CASTING.md).
- **Sharing you can see and stop.** *Share while idle* (Settings, on by
  default) keeps uploading to other peers when nothing is playing; off, the
  server chokes every peer until a player reads from it again. A status light
  on the main screens is lit only while the server measures bytes moving with
  nothing playing, never because of the setting, and pressing it offers
  *Not now* (until the next start) or *Stop sharing*.
- **Addons installed from the web.** An addon site's Install button hands the
  OS a `stremio://` link; where Xtremio can register that scheme it opens
  that addon's details screen, and nothing is installed until the button
  waiting there is pressed. The contract in full, and the registration per
  platform, is in [docs/DEEP_LINKS.md](docs/DEEP_LINKS.md).

## Getting it

Every version tag builds Linux, Windows, macOS and both Android ABIs and
attaches them to a
[GitHub Release](https://github.com/zond/xtremio/releases) — that is where a
build comes from. Nothing is tagged yet, so until the first one that page is
empty and building it yourself is the only way. Two things about those builds
are worth knowing before installing, and the release notes say both: the APKs
are signed with the Flutter template's debug key, and the macOS build is
unsigned.

```bash
flutter pub get
make run DEVICE=linux   # flutter run -d linux, stamped with version and commit
make linux              # a release build; also apk, apk-tv, macos, ios
```

The Makefile only adds two `--dart-define`s, so the Diagnostics screen can say
which build it is; plain `flutter run -d <device>` works too and reports
`app: unknown` (the Windows CI job, whose runner has no `make`, spells the two
defines out instead). A build needs Flutter stable (CI uses 3.47.1) and a Rust
toolchain no older than `rust-version` in `rust/Cargo.toml` (1.97.1): the Rust
crate is compiled by the build itself, through cargokit. Linux desktop also
needs `clang`, `cmake`, `ninja`, `pkg-config`, GTK 3 dev libraries, and
`libmpv-dev` (media_kit links libmpv); Android has a document of its own,
[ANDROID.md](ANDROID.md). Everything else a dev machine wants is in
[docs/OPERATIONS.md](docs/OPERATIONS.md).

## How it works

```
┌──────────────────────────────────────────────────────────────┐
│  Flutter UI (this repo) — screens, navigation, playback UI   │
├──────────────────────────────────────────────────────────────┤
│  Dart ⇄ Rust FFI (flutter_rust_bridge), crate in rust/       │
│   • stremio-core   → addons, catalogs, search, library,      │
│                      account, playback state (the "brain")   │
│   • stream-server  → embedded: settings, stats, storage and  │
│                      downloads as FFI calls                  │
├──────────────────────────────────────────────────────────────┤
│  media_kit / libmpv — fetches the media over loopback HTTP,  │
│  decodes and renders it (direct play; codecs and subtitles   │
│  on-device)                                                  │
└──────────────────────────────────────────────────────────────┘
```

The UI stays thin: discovery/library/addon logic lives in `stremio-core`, the
bytes come from `stream-server`, and the client's job is presentation plus
driving libmpv. `stream-server` runs **in-process**: the Rust crate in `rust/`
links it as a library and starts it on its own thread with its own runtime,
bound to `127.0.0.1` on port 11470 (stremio-core's default) and on an
ephemeral port when that one is taken, so there is no sidecar binary to ship,
launch, or keep alive on mobile. The Dart side never speaks HTTP to it: libmpv
fetches the media routes, the app's own questions — settings, a torrent's
stats, storage, downloads — are FFI calls into the server's library API, and
stremio-core's requests to it carry a per-launch bearer token that only the
Rust side holds. The only HTTP it serves beyond loopback is the media listener
a cast session turns on and off. Because a capable on-device player handles
codecs and subtitles, the server never transcodes — it just gets bytes onto an
HTTP connection. Settings can point stremio-core at a remote streaming server
by URL instead; the embedded one is the default.

How that bridge is built, what crosses it and what every field of the state
means is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Pinned forks

`rust/Cargo.toml` pins every git dependency to a rev, with the reason beside
it:

| Dependency | Pinned to | Why |
|---|---|---|
| `stream-server` (package `server`, and its `enginefs`) | [`zond/stream-server`](https://github.com/zond/stream-server) | The rev where the server stopped keeping its own record of what is pinned and is told at start (`ServerConfig::pins`) from this app's downloads registry, with the retention redesign that arrived with it. Default features are on, which is RAR support — see [License](#license). |
| `librqbit` | [`zond/rqbit`](https://github.com/zond/rqbit) | Only a dev-dependency here, for the real `.torrent` fixtures in `rust/tests/downloads.rs`. It is always the rev stream-server's `enginefs` uses; any other puts two librqbits in the graph. The fork is stream-server's: it follows upstream and adds what a bounded streaming cache needs from the engine. |
| `stremio-core` | [`zond/stremio-core`](https://github.com/zond/stremio-core) | Upstream 0.62.1 plus one commit that keeps a subtitle's addon-specific fields (`fpsMilli`, `subtitleFileName`, `releaseGroup`, …) instead of letting serde drop them — upstream PR Stremio/stremio-core#1045 — and one that pins its `localsearch` dependency by rev rather than by branch. |

Beside those, `stremio-watched-bitfield` is vendored with one line changed so
the graph resolves ([rust/vendor/README.md](rust/vendor/README.md)), and
`flutter_rust_bridge` is exactly 2.13.0 in `pubspec.yaml`, `rust/Cargo.toml`
and the codegen.

## Platform support

The hard constraint is **BitTorrent**: the streaming path needs raw TCP/UDP
sockets, a local HTTP server, disk cache, and libmpv. That decides everything.

| Platform | Support | Notes |
|---|---|---|
| **Linux (desktop)** | ✅ First-class | The easiest target; video is software-rendered until media_kit's Linux renderer lands ([docs/OPERATIONS.md](docs/OPERATIONS.md#linux-video-is-software-rendered-for-now)). |
| **Windows (desktop)** | ✅ Built in CI | Flutter desktop, media_kit and native Rust, as on Linux; registering `stremio://` needs an installer and there is none ([docs/DEEP_LINKS.md](docs/DEEP_LINKS.md)). |
| **macOS (desktop)** | ✅ Built in CI | Native Rust + media_kit; unsigned, and needs a Mac to build yourself — there is none in the project. |
| **Android** | ✅ Supported | Rust cross-compiles to the NDK and is embedded as a native lib; the primary mobile target ([ANDROID.md](ANDROID.md)). |
| **Android TV / Google TV** | ✅ Supported | The same app, not a separate build; install the APK for the ABI the box reports — a Chromecast with Google TV is 32-bit, `make apk-tv` ([ANDROID.md](ANDROID.md)). |
| **iOS** | ❌ Does not build today | CI compiles it and it fails in an upstream crate (`librqbit-dualstack-sockets` 0.7.0 calls a socket2 method iOS does not have). Past that, there is no signing identity here, the App Store is out on GPL-3 (see [License](#license)), and iOS throttles background work. |
| **Web** | ❌ Not possible | A browser cannot do BitTorrent — no raw sockets, no local server, no libmpv. A thin client onto a separate server is a different architecture, not this app. |

**Short version:** desktop and Android are the real targets, iOS does not
build until an upstream crate is fixed, and web is fundamentally off the
table for a self-contained streaming client.

## What is next

What is genuinely not built:

- **Cloud storage sources** (e.g. Google Drive) — stream from a personal cloud
  drive, most naturally via a Stremio addon that resolves cloud files to
  playable URLs. Provider OAuth / API-key setup is the fiddly part.
- **Media3 remuxing for casting**, which is what would let a receiver play a
  stream it cannot decode as it stands. It would happen on the sending device
  with its platform hardware codec (Android MediaCodec first) — never ffmpeg,
  never software transcoding in the pure-Rust core. Until then such a stream
  is refused rather than mangled.

## What is written down where

| Document | What is in it |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | What is built today, screen by screen: phase 3 complete on top of phase 2. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the Rust core is wired in: the bridge, what crosses it as JSON, every model field, and what the app reads from the settings. |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | What to run before a commit, how to see video play, what the server's storage costs, and getting a log off a device. |
| [ANDROID.md](ANDROID.md) | Building, running and verifying on Android and Android TV: prerequisites, the APK, the manifest decisions, the emulators, a real box. |
| [docs/CASTING.md](docs/CASTING.md) | The cast button: what it hands a receiver untouched, and every rule it refuses on. |
| [docs/ADDONS.md](docs/ADDONS.md) | How each installed addon has been answering, and the verdict the Installed tab reads off that record. |
| [docs/DEEP_LINKS.md](docs/DEEP_LINKS.md) | What a `stremio://` link may and may not do, and how the scheme is registered on each platform. |
| [AGENTS.md](AGENTS.md) | How changes are made here: commits, verification, the rules a real device taught us. |
| [docs/phase3-design.md](docs/phase3-design.md) | The design notes behind phase 3 -- action JSON, state shapes, the engine's surprises. |

## Contributing

[AGENTS.md](AGENTS.md) is what a change has to satisfy here: single-concept
commits, the verification that gates them, and the rules a real television
taught us. Read it before opening a pull request. CI runs, on every push to
`main` and every pull request against it:

```bash
dart format --set-exit-if-changed .
flutter analyze
# the FFI-backed Dart tests load rust/target/debug/libxtremio_core.*
cargo build --manifest-path rust/Cargo.toml
flutter test
(cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test)
```

plus a `cargo check` of the core for 32-bit Android, and a check that the
`flutter_rust_bridge` bindings regenerate to what is committed.

## License

The **source** in this repository is MIT (see [LICENSE](LICENSE)). Note that a
**compiled** Xtremio binary that embeds the default build of `stream-server`
links `unrar-rs` (GPL-3.0-or-later), so distributed binaries are covered by
GPL-3.0-or-later. This is intentional and fine for open distribution; it is
also why the iOS App Store is not a target. (`rust/Cargo.toml` notes the way
out: `stream-server` with `default-features = false` drops RAR support and
unrar-rs with it.)
