# Xtremio

![xtremio](assets/branding/xtremio-logo.png)

A native, cross-platform **Stremio client** built on a Rust core with a
Flutter UI, for Android TV and Google TV, Android phones and tablets, and
Linux, Windows and macOS desktops. iOS is not carried
([Platform support](#platform-support)).

[![CI](https://github.com/zond/xtremio/actions/workflows/ci.yml/badge.svg)](https://github.com/zond/xtremio/actions/workflows/ci.yml) [![source: MIT](https://img.shields.io/badge/source-MIT-blue)](#license) [![binaries: GPL-3.0-or-later](https://img.shields.io/badge/binaries-GPL--3.0--or--later-blue)](#license)

Xtremio is the client half of a two-part project. The other half is
[`zond/stream-server`](https://github.com/zond/stream-server), a headless
torrent-streaming server written in Rust, which Xtremio embeds in its own
process. It also embeds [`stremio-core`](https://github.com/Stremio/stremio-core),
the official Rust engine for addons, catalogs, library and playback state,
built here from a [fork](docs/ARCHITECTURE.md#pinned-forks). Playback is
[`media_kit`](https://pub.dev/packages/media_kit)/libmpv.

## What it does

This app does what Stremio's own apps do -- catalogs and search across every
installed addon, a library, an account, playback state -- through the same
engine, [`stremio-core`](https://github.com/Stremio/stremio-core). It draws
them its own way. Discover names the catalogs that could *not* answer, so a
dead addon is never mistaken for a title nobody has. A title's sources are a
row per release, a section per resolution, ranked by peers per megabyte.
The list below is what it does that they do not. All of it runs today, and
[docs/STATUS.md](docs/STATUS.md) is the screen-by-screen inventory.

- **Torrent streaming with no external binary.** `stream-server` runs
  in-process on loopback: nothing to ship beside the app, launch, or keep
  alive on mobile. A torrent starts behind a card that says what it is doing
  (checking, finding peers, buffering) instead of a spinner. A later stall
  says *Buffering from the torrent* with the swarm's numbers. The server
  caches every stream the app plays and reads it ahead of the player, inside
  one bounded cache: a torrent, an addon's direct link, a debrid link, a
  Drive file.
- **Offline downloads of any source.** A download is a pin in the embedded
  server, and never exists as a whole file. A torrent file is kept piece by
  piece; an addon link or a Google Drive file is kept in the same cache. It
  plays offline through the same server once the server answers that it
  holds the file whole. On Android a foreground service keeps a download
  going after the app is left.
- **Google Drive as a source.** A phone pairs the app with a Drive account
  through a QR code and picks files. They appear under the titles they
  match and play through the server, which renews the token itself. They
  download like any other source and play offline once downloaded. The
  grant lives in the platform's secure store and is never in a URL or a log.
- **A player rather than a video widget.** Buffered seek bar, keyboard and
  remote shortcuts, audio tracks, embedded and addon subtitles, and an
  up-next countdown that hands over to the next episode. A stats OSD reports
  hwdec, the swarm, how much of the stream this device holds either side of
  the playhead, and what a torrent has committed and moved since it went live.
- **Subtitle timing that is nudged or measured, and then remembered.** Shift
  the lines by hand from a panel that survives the controls fading. Or mark
  a line where it belongs, and two marks give the rate. Or have the drift
  measured against another subtitle the viewer says is in sync. A stretch
  comes only from those last two: nothing here presses a multiplier, and no
  declared frame rate decides one. The fix is stored against the series and
  the subtitle's release group (a shift against the video release too), so
  the next episode starts right
  ([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#subtitles)).
- **Android TV and Google TV as their own layout**, not a phone app on a big
  screen: D-pad traversal with a focus memory per tab, a focus ring built to
  read over unknown poster art, remote keys in the player, ten-foot density
  and overscan. It has run on a physical Chromecast with Google TV
  ([docs/ANDROID.md](docs/ANDROID.md)).
- **Casting to a Chromecast** from an Android phone. The app learns what the
  film is from mpv's report of the bytes alone, never from a file name. A
  film the receiver decodes goes over the LAN untouched. An H.264 or HEVC
  film in Matroska, or one whose sound the receiver will not take, goes
  repackaged as one fragmented MP4: its sound converted to AAC, its picture
  never re-encoded. So a picture no receiver decodes is refused up front,
  with a sentence saying why. The receiver fetches from a listener that
  exists only while a cast does and serves published tokens and nothing
  else. The player screen becomes a remote with its own stats panel. One
  real receiver, a Chromecast with Google TV 4K, has played and seeked it
  ([docs/CASTING.md](docs/CASTING.md)).
- **Sharing you can see and stop.** Xtremio shares while you watch and while
  a torrent download is on its way. With *Share while idle*, on by default,
  it also shares your downloads and the last thing you watched until you
  watch something else, except on a phone in the background. A status light
  on the main screens is lit only while bytes move with nothing playing: up
  for uploading, down for an offline download filling in. Pressed, it
  offers *Not now*, *Stop sharing*, or a *Cancel* per download on its way.
- **More like this.** A row of suggestions on every title. This project's
  own service asks a model once per title for everybody, so the app holds no
  key. A row is shown only when a catalogue confirms the title and year
  ([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#recommendations)).
- **Addons installed from the web.** An addon site's Install button hands the
  OS a `stremio://` link. The link opens that addon's details screen where
  Xtremio can register the scheme, and nothing is installed until the button
  waiting there is pressed. [docs/DEEP_LINKS.md](docs/DEEP_LINKS.md) has the
  contract in full and the registration per platform.

## Getting it

Every version tag builds Linux, Windows, macOS and both Android ABIs and
attaches them to a [GitHub Release](https://github.com/zond/xtremio/releases).
The macOS build is unsigned. The APKs carry this project's own release key.
To Android a signing certificate *is* the app's identity, so upgrading from
a build signed with another key needs an uninstall first. Once installed,
the app looks for a newer release once a day and offers it. On Android it
first cleans the server's cache to make room (never a kept download), then
downloads, verifies and installs it behind Android's own confirmation
([docs/ANDROID.md](docs/ANDROID.md#updating-from-inside-the-app)).

## Building, testing, driving, releasing

You need Flutter stable and a Rust toolchain, or the Nix shells.
`make run DEVICE=linux` runs the app and `make check` runs every gate CI
runs. The setup and the targets are in [docs/OPERATIONS.md](docs/OPERATIONS.md),
the Android and TV builds in [docs/ANDROID.md](docs/ANDROID.md), driving a
running build from a terminal in [docs/DRIVING.md](docs/DRIVING.md), and the
gates and the rules a test keeps in [AGENTS.md](AGENTS.md). A release is a
version tag ([docs/OPERATIONS.md](docs/OPERATIONS.md#cutting-a-release)).

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
│  media_kit / libmpv — reads the media from the server by id  │
│  (xtremio://, no HTTP), decodes and renders it (direct play; │
│  codecs and subtitles on-device)                             │
└──────────────────────────────────────────────────────────────┘
```

The UI stays thin. Discovery, library and addon logic lives in
`stremio-core`, the bytes come from `stream-server`, and the client's job is
presentation plus driving libmpv. `stream-server` runs **in-process**. The Rust crate in `rust/` links it as a
library and starts it on its own thread with its own runtime, bound to
`127.0.0.1` on a port the OS picks. stremio-core is pointed at the address
it reads back, the only server the app streams from. So no sidecar binary
ships, and no fixed port is lost to a desktop Stremio.

The Dart side never speaks HTTP to the server. libmpv reads what it plays by
media id through an `xtremio://` protocol registered on its handle
(`rust/src/mpv_stream.rs`), and fetches a loopback route only for a link the
server reads forward. The app's own questions -- settings, a torrent's
stats, storage, downloads, publishing a cast -- are FFI calls into the
server's library API. stremio-core's requests to the server carry a
per-launch bearer token that only the Rust side holds. The only HTTP the
server serves beyond loopback is the media listener a cast session turns on
and off. A capable on-device player handles codecs and subtitles, so the
server never transcodes a picture. It gets bytes to the player, and for a
cast at most repackages them and converts the sound.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) says how that bridge is built,
what crosses it and what every field of the state means.

Every git dependency in `rust/Cargo.toml` is pinned to a rev with its
reason beside it. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#pinned-forks)
lists the three forks.

## Platform support

The hard constraint is **BitTorrent**: raw sockets, a local server, a disk
cache and libmpv. That decides everything.

| Platform | Support | Notes |
|---|---|---|
| **Linux (desktop)** | ✅ First-class | The easiest target; video is software-rendered until media_kit's Linux renderer lands ([docs/OPERATIONS.md](docs/OPERATIONS.md#linux-video-is-software-rendered-for-now)). |
| **Windows (desktop)** | ✅ Built weekly in CI (`build.yml`) | Flutter desktop, media_kit and native Rust, as on Linux; registering `stremio://` needs an installer and there is none ([docs/DEEP_LINKS.md](docs/DEEP_LINKS.md)). |
| **macOS (desktop)** | ✅ Built weekly in CI (`build.yml`) | Native Rust + media_kit. Unsigned; building it yourself needs a Mac, and the project has none. |
| **Android** | ✅ Supported | Rust cross-compiles to the NDK and is embedded as a native lib; the primary mobile target ([docs/ANDROID.md](docs/ANDROID.md)). |
| **Android TV / Google TV** | ✅ Supported | The same app, not a separate build; install the APK for the ABI the box reports. A Chromecast with Google TV is 32-bit: `make apk-tv` ([docs/ANDROID.md](docs/ANDROID.md#running-on-a-physical-device)). |
| **iOS** | ❌ Does not build as checked in | Two upstream dependencies do not build for iOS as released. It compiles with the two changes in [docs/OPERATIONS.md](docs/OPERATIONS.md#building-for-ios). Past that, there is no signing identity here, the App Store is out on GPL-3 (see [License](#license)), and iOS throttles background work. |
| **Web** | ❌ Not possible | A browser cannot do BitTorrent -- no raw sockets, no local server, no libmpv. A thin client onto a separate server is a different architecture, not this app. |

## What is next

What is genuinely not built, and why, is in
[docs/WISHLIST.md](docs/WISHLIST.md): subtitles on a receiver, pictures a
receiver cannot decode (refused, never re-encoded), the remote's own search
key, Continue watching on the Google TV home screen, and archives the server
cannot yet read inside.

## What is written down where

| Document | What is in it |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | What is built today, screen by screen. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it works: the bridge and what crosses it, the wire conventions, the embedded server, the player, subtitles, downloads, Google Drive, the library, recommendations, and the pinned forks. |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Setting up, building and running, cutting a release, re-recording fixtures, server storage, diagnostics, the stats OSD, and what an iOS build needs. |
| [docs/ANDROID.md](docs/ANDROID.md) | Android and Android TV: prerequisites, the APK, manifest and channels, display frame rate, downloads in the background, emulators, a real box. |
| [docs/DRIVING.md](docs/DRIVING.md) | Driving a running app from a terminal or an agent: the side-by-side debug app, `tool/drive-start`, `tool/drive` and its commands. |
| [docs/CASTING.md](docs/CASTING.md) | The cast button: what it hands a receiver untouched, what it repackages, and every rule it refuses on. |
| [docs/ADDONS.md](docs/ADDONS.md) | How each installed addon has been answering, and the verdict the Installed tab reads off that record. |
| [docs/DEEP_LINKS.md](docs/DEEP_LINKS.md) | What a `stremio://` link may and may not do, and how the scheme is registered on each platform. |
| [docs/WISHLIST.md](docs/WISHLIST.md) | What is deliberately not built yet, and why. |
| [AGENTS.md](AGENTS.md) | The rules a change has to keep: commits, the verification gates, tests and fixtures, and the invariants the code depends on. |
| [xtremio-xervice/README.md](xtremio-xervice/README.md) | The Firebase service behind Drive pairing, Drive play tracking and recommendations. |
| [tool/recommendations/README.md](tool/recommendations/README.md) | How the recommendation model and question were chosen, and the benchmarks. |

## Contributing

[AGENTS.md](AGENTS.md) is what a change has to satisfy here: single-concept
commits, the verification that gates them (CI runs the same checks on every
push and pull request), and the rules a real television taught us. Read it
before opening a pull request.

## License

The **source** here is MIT ([LICENSE](LICENSE)). A **compiled** Xtremio embeds
`stream-server`, which links `unrar-rs` (GPL-3.0-or-later) so a RAR archive in
a torrent plays. So **distributed binaries are GPL-3.0-or-later**
([LICENSE-GPL-3.0](LICENSE-GPL-3.0)). unrar-rs asks that a binary reproduce its
licence file, the unRAR restriction included, so that text ships in the app too
([LICENSE-unrar-rs](LICENSE-unrar-rs); Settings → About → Open source
licences). `stream-server` with `default-features = false` drops both.
