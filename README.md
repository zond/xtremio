# Xtremio

![xtremio](assets/branding/xtremio-logo.png)

A native, cross-platform **Stremio client** built on a pure-Rust core with a
Flutter UI.

[![CI](https://github.com/zond/xtremio/actions/workflows/ci.yml/badge.svg)](https://github.com/zond/xtremio/actions/workflows/ci.yml)
[![source: MIT](https://img.shields.io/badge/source-MIT-blue)](#license)
[![binaries: GPL-3.0-or-later](https://img.shields.io/badge/binaries-GPL--3.0--or--later-blue)](#license)

Xtremio is the client half of a two-part project. The other half is
[`zond/stream-server`](https://github.com/zond/stream-server) — a pure-Rust,
headless, zero-external-binary torrent-streaming server. Xtremio pairs that
with [`stremio-core`](https://github.com/Stremio/stremio-core) (the official
Rust engine for addons, catalogs, library, and playback state) and
[`media_kit`](https://pub.dev/packages/media_kit)/libmpv for playback.

## What it does

All of this is built and runs today. [docs/STATUS.md](docs/STATUS.md) is the
screen-by-screen inventory; what it does not reach -- casting, subtitle
timing -- is in the document each bullet links.

- **Catalogs, search and a library across every addon installed.** A board of
  continue-watching and a row per catalog that answered, discover over the
  engine's own filters, a search that asks every addon supporting it — and
  throughout, a line naming the addons that could *not* answer, so a dead
  addon is never mistaken for a title nobody has.
- **Torrent streaming with no external binary.** `stream-server` runs
  in-process on loopback: nothing to ship beside the app, launch, or keep
  alive on mobile. A title's sources are one row per release rather than one
  per addon offering it, ranked by peers per megabyte, and a torrent starts
  behind a card that says what it is doing — checking, finding peers,
  buffering — instead of a spinner.
- **Offline downloads.** Pin a file through the embedded server, keep it
  where the platform will not purge it, and play it back as a `file://`
  stream: a finished download needs no server, no network and no torrent. On
  Android a foreground service keeps one going after the app is left.
- **A player rather than a video widget.** Buffered seek bar, keyboard and
  remote shortcuts, audio tracks, embedded and addon subtitles, a stats OSD
  reporting hwdec and the swarm, and an up-next countdown that hands over to
  the next episode.
- **Subtitle timing that is nudged or measured, and then remembered.** Shift
  the lines by hand from a panel that survives the controls fading, mark a
  line where it belongs and let two marks give the rate, or have the drift
  measured against another subtitle the viewer says is in sync -- which is
  where a stretch comes from, since nothing here presses a multiplier and no
  declared frame rate decides one. What was fixed is stored against the
  series and the release, so the next episode starts right
  ([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- **Android TV and Google TV as their own layout**, not a phone app on a big
  screen: D-pad traversal with a focus memory per tab, a focus ring built to
  read over unknown poster art, remote keys in the player, ten-foot density
  and overscan. Run on a physical Chromecast with Google TV.
- **Casting to a Chromecast** where the receiver can decode what the embedded
  server is already serving — the bytes go over the LAN untouched, and the
  player screen becomes a remote. What it refuses, why it refuses rather than
  guesses, and the fact that no real receiver has confirmed it yet are in
  [docs/CASTING.md](docs/CASTING.md).
- **Addons installed from the web.** An addon site's Install button hands the
  OS a `stremio://` link; Xtremio registers that scheme and opens that
  addon's details screen, and nothing is installed until the button waiting
  there is pressed. The contract in full, and the registration per platform,
  is in [docs/DEEP_LINKS.md](docs/DEEP_LINKS.md).

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
flutter run -d linux      # or -d windows, -d macos, or an Android device
```

Linux desktop needs `clang`, `cmake`, `ninja`, GTK 3 dev libraries, and
`libmpv-dev` (media_kit links libmpv); Android has a document of its own,
[ANDROID.md](ANDROID.md). What to run before a commit, and everything else a
dev machine wants, is in [docs/OPERATIONS.md](docs/OPERATIONS.md).

## How it works

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

How that bridge is built, what crosses it and what every field of the state
means is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Platform support

The hard constraint is **BitTorrent**: the streaming path needs raw TCP/UDP
sockets, a local HTTP server, disk cache, and libmpv. That decides everything.

| Platform | Support | Notes |
|---|---|---|
| **Linux (desktop)** | ✅ First-class | The easiest target; video is software-rendered until media_kit's Linux renderer lands ([docs/OPERATIONS.md](docs/OPERATIONS.md#linux-video-is-software-rendered-for-now)). |
| **Windows (desktop)** | ✅ First-class | Flutter desktop, media_kit and native Rust, as on Linux; registering `stremio://` needs an installer and there is none ([docs/DEEP_LINKS.md](docs/DEEP_LINKS.md)). |
| **macOS (desktop)** | ✅ First-class | Native Rust + media_kit; built in CI, unsigned, and needs a Mac to build yourself. |
| **Android** | ✅ Supported | Rust cross-compiles to the NDK and is embedded as a native lib; the primary mobile target ([ANDROID.md](ANDROID.md)). |
| **Android TV / Google TV** | ✅ Supported | One build covers the boxes, given the ABI the box reports — a Chromecast with Google TV is 32-bit ([ANDROID.md](ANDROID.md)). |
| **iOS** | ⚠️ With effort | Background execution is throttled, the App Store is out on GPL-3 (see [License](#license)), and the build is blocked on an upstream crate today. Sideload only. |
| **Web** | ❌ Not possible | A browser cannot do BitTorrent — no raw sockets, no local server, no libmpv. A thin client onto a separate server is a different architecture, not this app. |

**Short version:** desktop and Android are the real targets, iOS works if you
sideload and accept the background limits, and web is fundamentally off the
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
taught us. Read it before opening a pull request.

## License

The **source** in this repository is MIT (see [LICENSE](LICENSE)). Note that a
**compiled** Xtremio binary that embeds the default build of `stream-server`
links `unrar-rs` (GPL-3.0-or-later), so distributed binaries are covered by
GPL-3.0-or-later. This is intentional and fine for open distribution; it is
also why the iOS App Store is not a target. (A build without RAR support keeps
the binary MIT.)
