# Xtremio

![xtremio](assets/branding/xtremio-logo.png)

A native, cross-platform **Stremio client** built on a pure-Rust core with a Flutter UI.

Xtremio is the client half of a two-part project. The other half is
[`zond/stream-server`](https://github.com/zond/stream-server) — a pure-Rust,
headless, zero-external-binary torrent-streaming server. Xtremio pairs that
with [`stremio-core`](https://github.com/Stremio/stremio-core) (the official
Rust engine for addons, catalogs, library, and playback state) and
[`media_kit`](https://pub.dev/packages/media_kit)/libmpv for playback.

## What is written down where

| Document | What is in it |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | What is built today, screen by screen: phase 3 is complete on top of phase 2, and the roadmap below is not started. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the Rust core is wired in: the bridge, what crosses it as JSON, every model field, and what the app reads from the settings. |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | What to run before a commit, how to see video play, what the server's storage costs, and getting a log off a device. |
| [ANDROID.md](ANDROID.md) | Building, running and verifying on Android and Android TV: prerequisites, the APK, the manifest decisions, the emulators, a real box. |
| [docs/CASTING.md](docs/CASTING.md) | The cast button: what it hands a receiver untouched, and every rule it refuses on. |
| [docs/ADDONS.md](docs/ADDONS.md) | How each installed addon has been answering, and the verdict the Installed tab reads off that record. |
| [AGENTS.md](AGENTS.md) | How changes are made here: commits, verification, the rules a real device taught us. |
| [docs/phase3-design.md](docs/phase3-design.md) | The design notes behind phase 3 -- action JSON, state shapes, the engine's surprises. |

## Goals (beyond current Stremio clients)

The point of Xtremio is to go past what existing Stremio apps do:

- **Offline downloads** — cache a full episode or movie to the device and keep
  watching with no connection (through a tunnel, on a plane), the way Netflix
  does. Built (see **Downloads** in [docs/STATUS.md](docs/STATUS.md)): the
  whole file is fetched, pinned so it is never evicted, managed from a screen
  of its own, put somewhere the platform will not purge it, and played
  straight off the disk as a `file://` stream — so a finished download needs
  no server, no network and no torrent, and on Android a foreground service
  keeps it going after the user leaves the app.
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

How that bridge is built, what crosses it and what every field of the state
means is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Installing an addon from the web (`stremio://` links)

Addon directories — [stremio-addons.net](https://stremio-addons.net) above
all — install an addon by taking its own manifest URL and swapping the
scheme: `https://host/manifest.json` becomes `stremio://host/manifest.json`,
handed to the OS as a link. Xtremio registers that scheme and treats such a
link as **one thing only: open this addon's details screen**.

The contract, in full:

- **The URL is passed to the engine unmodified.** stremio-core's
  `AddonDetails` does the `stremio://` → `https://` rewrite itself, on the
  whole URL string, so a port, a path segment carrying a configuration and a
  query all survive. The app never reconstructs the URL (stremio-web does,
  and drops the port and the query doing it).
- **A link never installs anything.** It lands on the details screen with the
  manifest fetched and the Install button waiting. Visiting a page cannot add
  an addon; a press does. There is no code path from a link to `InstallAddon`,
  and a test pins that.
- **A link replaces a details screen already open** rather than stacking a
  second one, because `addon_details` is one field holding one addon, and
  does nothing at all when that screen is already showing that addon.
- **A host-less link (`stremio:///addons`) is dropped** with a log line that
  does not include the URL — a manifest URL can carry a debrid API key. Those
  are the official clients' own in-app routes, not manifest URLs.

The pieces: `lib/shell/deep_link.dart` (the source, over
[`app_links`](https://pub.dev/packages/app_links), and
`deepLinkAddonManifestUrl`, which decides what a link means), the listener in
`XtremioApp` next to the lifecycle one, and the app's `navigatorKey` — a link
arrives from the platform with no `BuildContext` to navigate with.

Registration, per platform:

| Platform | How | State |
|---|---|---|
| **Android** | `VIEW`/`BROWSABLE` intent-filter with `<data android:scheme="stremio"/>` on the already-`singleTop` `MainActivity` | Wired |
| **iOS / macOS** | `CFBundleURLTypes` in `Runner/Info.plist` | Wired (unbuilt here — no Mac) |
| **Linux** | `linux/com.zond.xtremio.desktop` (`MimeType=x-scheme-handler/stremio;`, `Exec=xtremio %u`) plus a runner that is a single instance handling its own command line | Wired; the .desktop file must be installed by hand or by a package (see the file) |
| **Windows** | A `HKCU\Software\Classes\stremio` URL-protocol key, which only an installer can write | **Not wired** — there is no installer in this repo |

The Linux path is the one that was exercised end to end: with the app
running, `./build/linux/x64/debug/bundle/xtremio
"stremio://v3-cinemeta.strem.io/manifest.json"` exits immediately without
starting a second copy, and the running instance pushes the addon-details
route (a second, different link replaces it). Android was not run against a
device here; the `adb` line for it is in ANDROID.md.

No App Links / Universal Links verification is possible for any of these: the
host in a `stremio://` URL is the *addon's* domain, which could be anyone's,
so there is no domain this app could claim with an `assetlinks.json` or an
`apple-app-site-association`. A custom scheme is all this can be, which is
what the official Stremio clients register too.

**On a television**, where a remote cannot work a browser, the route is the
other one on the Addons screen: install the addon on the website *into your
Stremio account* from a phone or a laptop, then press "Refresh addons from
account" (`PullAddonsFromAPI`) on the TV.

## Platform support

The hard constraint is **BitTorrent**: the streaming path needs raw TCP/UDP
sockets, a local HTTP server, disk cache, and libmpv. That decides everything.

| Platform | Support | Notes |
|---|---|---|
| **Linux (desktop)** | ✅ First-class | Flutter desktop + media_kit + native Rust. Easiest target. |
| **Windows (desktop)** | ✅ First-class | Same as Linux, except that `stremio://` links are not registered: that needs an installer writing a URL-protocol registry key, and this repo has none. |
| **macOS (desktop)** | ✅ First-class | Native Rust + media_kit; needs a Mac to build. |
| **Android** | ✅ Supported | Rust cross-compiles to the NDK; embedded as a native lib. Proven by existing Stremio clients. Primary mobile target. |
| **Android TV / Google TV** | ✅ Supported | Chromecast with Google TV, the Google TV Streamer, and other Android TV boxes all run Android — one build covers them (leanback manifest is in place), as long as it is built for the ABI the box reports: a Chromecast with Google TV runs a 32-bit userspace and wants `make apk-tv`. The **D-pad/remote-focused UI** is in: focus traversal, remote keys in the player, ten-foot density and overscan, all keyed on the `xtremio/device` channel's answer (see [docs/STATUS.md](docs/STATUS.md)). Verified on a headless `android-36;android-tv;x86_64` AVD and run on a physical Chromecast with Google TV (`sabrina`, Android 14), which is where the ABI above and the remote-input fixes came from. Low-RAM devices (the 2 GB Chromecast) make the lightweight pure-Rust server and a bounded piece cache matter. |
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

How badly, in numbers rather than feel, is what the stats OSD says: see
[docs/OPERATIONS.md](docs/OPERATIONS.md#the-stats-osd).

## Getting started

```bash
flutter pub get
flutter run -d linux      # or -d windows, -d macos, or an Android device
```

Linux desktop needs `clang`, `cmake`, `ninja`, GTK 3 dev libraries, and
`libmpv-dev` (media_kit links libmpv); Android needs the Android SDK/NDK.

What to run before a commit, and everything else a dev machine wants, is in
[docs/OPERATIONS.md](docs/OPERATIONS.md).

## License

The **source** in this repository is MIT (see [LICENSE](LICENSE)). Note that a
**compiled** Xtremio binary that embeds the default build of `stream-server`
links `unrar-rs` (GPL-3.0-or-later), so distributed binaries are covered by
GPL-3.0-or-later. This is intentional and fine for open distribution; it is
also why the iOS App Store is not a target. (A build without RAR support keeps
the binary MIT.)
