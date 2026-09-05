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
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the Rust core is wired in: the bridge, what crosses it as JSON, every model field, and what the app reads from the settings. |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | What to run before a commit, how to see video play, what the server's storage costs, and getting a log off a device. |
| [docs/ADDONS.md](docs/ADDONS.md) | How each installed addon has been answering, and the verdict the Installed tab reads off that record. |
| [docs/CASTING.md](docs/CASTING.md) | The cast button: what it hands a receiver untouched, and every rule it refuses on. |
| [ANDROID.md](ANDROID.md) | Building, running and verifying on Android and Android TV: prerequisites, the APK, the manifest decisions, the emulators, a real box. |
| [AGENTS.md](AGENTS.md) | How changes are made here: commits, verification, the rules a real device taught us. |
| [docs/phase3-design.md](docs/phase3-design.md) | The design notes behind phase 3 -- action JSON, state shapes, the engine's surprises. |

> **Status:** phase 3 (account, library, addons, settings) is complete
> on top of phase 2 (browse → details → play); the roadmap items below are
> not started. The app boots `stremio-core` and the
> embedded `stream-server` at start-up, and nothing in the app talks HTTP
> to that server except libmpv fetching media: the server's control API
> takes a per-launch bearer token that only the Rust side holds
> (stremio-core's requests get it in `Env::fetch`; the app's own control
> calls are FFI). **Board** shows a continue-watching
> row and one row per catalog that answered, with one line at the end for
> the catalogs that could not be loaded (expanding to the addon, what it
> said, and Check addon / Uninstall); **Discover** browses any catalog
> through the engine's type/catalog/genre filters; **Search** asks every
> addon that supports it, groups the hits per addon, and accounts for the
> addons that could not be searched the same way, so a dead addon is never
> mistaken for a title nobody has.
> **Details** shows facts and genres, a season picker and episode list with
> watched state for series (picking an episode loads its streams), and the
> streams every installed addon returns with quality hints parsed into
> chips. The sources list has two layouts and a toggle in its header, worded
> to say which layout is on screen and what tapping switches to, to pick
> one: **sectioned** -- every addon's answers put together and cut into
> **one collapsible section per resolution**, highest first, with the
> streams nothing could be read from last in a section that says it does
> not know rather than guessing a rung -- is the default. The other is
> grouped: a section per addon, in profile order, each addon's own ranking
> intact, which is what the engine hands over and what the sources list
> looked like before the sectioned layout existed. Every resolution section
> starts *collapsed*, on every title, until the viewer opens one, so the
> first thing shown is a compact list of what is available rather than a
> guess at what they want; a *closed* header still says how many streams it
> holds and the best swarm among them -- an empty-looking 2160p and a
> healthy one are different answers. Which sections are open is a global
> preference too, not a per-title one: a section opened on one title stays
> open on the next and survives a restart, and a resolution the current
> title does not offer is simply not shown open, never swapped for some
> other section the viewer did not ask for. Inside a section the
> order is **peers per megabyte** -- ascending size over peers -- because
> every stream in the list is the same film: duration is constant, so size
> is bitrate, bitrate is the demand and peers are the supply, which makes
> the smallest size per peer the best first guess at a stream that arrives
> faster than it is watched. Chips in the header offer largest first or
> most peers instead. A stream missing either number cannot be ranked by
> the ratio and sits after every ranked one in the addons' own order --
> never as a zero and never as a best guess -- while a swarm known to be
> empty is ranked, and ranked last of the ranked. Each row names the addon
> it came from and is badged with what could actually be read off the
> stream, size and peers included -- nothing is badged that is not known.
> The layout, the order and which sections are open are all global and
> persisted (`streamsSectioned`, `streamsOrder` and `openStreamSections` in
> the preferences file), so they follow the user to the next title and
> survive a restart -- an install from before the layout was renamed keeps
> its choice too, read from the older `streamsFlat` key it was stored
> under. **One release is one
> row**: two addons offering the same torrent (or one addon offering it
> twice) collapse on what they *are* -- info hash plus file index, or the
> direct URL, the identity a download pin already uses -- never on what
> they look like, so two different releases with the same resolution and
> size both stay. The sectioned list collapses after sorting and across
> the whole list, so the best-ranked instance is the one kept and a source
> two addons described differently cannot appear in two sections; it says
> "Also from ..." when
> another addon had it too (silently when one addon simply repeated
> itself); the grouped list keeps a copy in each addon's group, marked the
> same way, since the groups are what that layout is for. The row that
> survives carries the **union of every listing's `announce` list**,
> deduplicated and in first-seen order, and that merged stream is what
> playback, a download and the stats poll are handed -- so the server adds
> the torrent with every tracker any addon knew about. An addon that answered
> with an error is named from the profile
> rather than by its host and offers to be checked or uninstalled on the
> spot; details routes are video-aware, so coming back from the player
> lands on the right episode. **On a television** the top of that screen is
> a different shape: the title's own artwork fills the panel -- *under* the
> overscan band, since the artwork is the one thing here meant to be
> cropped -- and over it sit the logo, one line of year, runtime, genres and
> rating, and two lines of description, with no poster, because at three
> metres the poster was a third of the layout of a picture already on
> screen. What darkens the artwork is a gradient scrim over it: never
> opacity on the text (dimmed text over a busy frame is unreadable in a way
> a dimmed picture behind solid text is not) and never a blur, which the
> Chromecast's Mali GPU cannot afford full-screen. No backdrop falls back to
> the poster, one that will not load falls back the same way, and neither
> leaves the brand ground. metahub names an image's size in its URL, so what
> is asked for is the `medium` one rather than Cinemeta's small poster
> stretched across the panel, and the decode is bounded to the panel's own
> pixels. The logo's box is the same height whether the logo arrives, never
> arrives or answers 404 a few seconds later: an image given only a height
> holds that height from its first frame, and the name that stands in for
> one that failed has to hold it too, or the header and every row under it
> jump up under a focus ring somebody is using. A series' episodes are a
> **row of cards** there rather than the vertical list, under the season
> pills that were already a row: a remote
> walks a row with two keys and a list with a hundred. A card carries what
> its list row carried -- the still with the episode number on it, the
> title, the air date, a check when it has been watched, a badge when it is
> kept on the device -- plus a bar saying how far into that episode the
> viewer got, which is the library item's own resume point and so appears
> on at most one card of a series. Every card is built at once, because
> directional focus only considers widgets that have been built and a lazy
> row hands the D-pad back halfway through the season; each still is
> decoded no larger than the card it is drawn in, which is what that costs
> instead. The row scrolls to the selected card, so resuming at episode
> nineteen does not start the remote at episode one, and an episode that
> has not aired is drawn saying so and takes no press and no focus. The
> **sources** are the last two rows rather than a pane down the right: a card
> per group -- a resolution rung or an addon, whichever the same
> `streamsSectioned` preference already says, never a second setting --
> carrying the line a collapsed section header carries on a phone, and under
> whichever card is chosen a row of that group's sources. The group row stays
> put with the chosen card marked, so another group is a sideways press away
> rather than a press back and a press down; the order chips still order
> inside one; a press past either end of a row stays in the row, since the
> nearest node to the right of the last card is not in the row at all but in
> the header three rows up; the last-used shortcut is a card of its own above
> them and the place the remote starts, and it appears the first time a title
> is played without moving the remote off the card the viewer chose from; and
> Back puts the open row away before it leaves the screen, a rung on the same
> ladder the player comes down -- while there is a row to put away, which is
> a group still carrying the open label rather than the label on its own.
> Which group is open is deliberately *not* the phone's
> `openStreamSections`: that is a
> global set of resolutions kept across restarts, and this is one row at a
> time that Back closes -- the same word for two different things. What the
> addons did other than answer -- the ones that failed, the ones that had
> nothing, and nobody having anything at all -- is the last card of that row,
> counting on its own line so a viewer who never chooses it is still told,
> and naming them in the row it opens -- a card each, since a joined line
> clips at the fourth name and a remote has no press that unfolds one, and
> each card takes a press to that addon's own details. The
> **player** plays torrents through the
> embedded server and HTTP streams directly, with its own controls (seek
> bar with the buffered range, play/pause, seek buttons, volume,
> fullscreen, keyboard shortcuts, playback speed), embedded and addon
> subtitles styled from the profile settings, audio track selection, a
> stats OSD, an up-next countdown
> that hands off to the next episode, and a pre-playback progress overlay
> for torrents that shows the server's start-up phase (checking existing
> data, finding peers, buffering the start) with percentages and download
> speed instead of a bare spinner, and an open that fails while the torrent
> is still resolving, checking or buffering is retried a few times behind
> that card rather than failing outright. **Settings → Developer** ships in
> release builds: entries that play or download a public Big Buck Bunny
> torrent to prove the torrent path without any addon, and **Diagnostics**,
> which shows the core's recent log (its own and the embedded server's) and
> copies it, redacted, to the clipboard. **Library** lists every added title over the engine's
> `LibraryWithFilters` model (type and sort filters, cumulative paging,
> long-press to remove, mark watched, rewind or mute notifications), and
> the details header has a bookmark to add or remove a title, wearing on a
> television the same focus ring everything else there wears rather than
> Material's tint. **Downloads**
> keeps a torrent stream on the device: the download button on a stream tile
> pins the file through the embedded server and becomes a delete button once
> the file is whole, so the tile that took a download is the tile that undoes
> it -- asking, as the list does, whether the bytes go with the entry. On a
> television that button cannot be focused (directional traversal skips a
> node inside the focused one's rect, and it is inside the stream tile), so
> the tile's long press -- hold select, or the remote's menu key -- does
> whatever the button would.
> Badges on the episode list and
> the details header say what is kept and how far along -- an episode's
> badge is the same delete button once its file is whole, while the header's
> counts several downloads and stays a count. The Downloads
> screen -- from the details app bar, the running player's menu, the
> "Downloaded" chip in the Library or Settings, so the list is one tap from
> whatever the downloads are of -- lists
> everything with its progress, plays a finished one, retries a stopped one,
> deletes one with or without its bytes, and says where the files go --
> a folder to pick on Android, a path to type elsewhere. Opened from the
> player it offers no play of its own: a second player over the running one
> would load the same shared `player` field and start an engine beside it. On Android the
> app picks that folder itself on a first run: its own external files
> directory, which the system leaves alone, rather than the cache it may
> reclaim mid-download. On Android a download goes on
> after the user leaves the app: a `dataSync` foreground service holds the
> process up with an ongoing notification -- how many titles, how far
> along, tappable to the Downloads screen, with a Cancel all on it -- for
> exactly as long as something is unfinished. A stream whose
> video is already kept from another release is offered as a replacement,
> and a *finished* one is named in a confirmation first, because taking the
> new pin deletes the old file. Downloading a
> title also adds it to the library, which is what makes the player record
> progress with no network. **Addons**
> (from Settings) lists the installed and community addons and installs,
> updates, uninstalls or configures one by manifest URL, links out to
> [stremio-addons.net](https://stremio-addons.net) and pulls the account's
> addons down again on demand. An addon found on the web installs from
> inside the app: its site's Install button hands the platform a
> `stremio://` link, which Xtremio registers and opens as that addon's
> details screen (see "Installing an addon from the web" below). **Settings** holds
> the Stremio account (sign in, create an account, sync, log out), the
> engine's own settings (player, subtitles, interface, streaming server)
> and the state of the embedded server. The design notes behind phase 3
> are in [docs/phase3-design.md](docs/phase3-design.md).
>
> **Android TV / Google TV** is supported as a first-class layout, not as a
> phone app on a big screen. At start-up `DeviceProfile.detect()` asks the
> `xtremio/device` platform channel what kind of device this is:
> `MainActivity` answers `isTv` (`UiModeManager.currentModeType ==
> UI_MODE_TYPE_TELEVISION`, or the `android.software.leanback` feature) and
> `hasTouch` (`FEATURE_TOUCHSCREEN`); every other platform answers locally
> without a channel call, and any error means "a phone". The answer goes
> down the tree as a `DeviceScope`, and that is the only thing the TV
> layout keys on — which is also how the widget tests put a screen on a
> television. When it says television: the shell keeps the rail at every
> width and gives each tab its own focus memory, tiles mark focus with a
> two-stroke ring (near-black outside, near-white inside, four logical
> pixels: one colour cannot read over unknown poster art in a room that is
> not dark), a 5 % zoom and a shadow, lift their own caption to full
> strength and scroll themselves into view — Settings → Interface →
> "Focus highlight" offers Bold, which thickens that ring and dims
> everything the remote is not on, for a projector in a bright room — the
> D-pad walks rows and columns (a held centre key is a long press, the
> context-menu key opens the same menu a long press does), the player takes
> the remote's centre and media keys and is immersive-fullscreen the whole
> time it is up, posters and text grow (1.15x text, a roomier density,
> 48 dp targets), every screen holds 5% of every edge clear of overscan
> except the video itself and the Details backdrop, and the controls a
> remote cannot work (the volume slider, the fullscreen toggle, scrollbar
> thumbs) are not drawn.

## Goals (beyond current Stremio clients)

The point of Xtremio is to go past what existing Stremio apps do:

- **Offline downloads** — cache a full episode or movie to the device and keep
  watching with no connection (through a tunnel, on a plane), the way Netflix
  does. Built (see **Downloads** above): the whole file is fetched, pinned so
  it is never evicted, managed from a screen of its own, put somewhere the
  platform will not purge it, and played straight off the disk as a
  `file://` stream — so a finished download needs no server, no network and
  no torrent, and on Android a foreground service keeps it going after the
  user leaves the app.
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
| **Android TV / Google TV** | ✅ Supported | Chromecast with Google TV, the Google TV Streamer, and other Android TV boxes all run Android — one build covers them (leanback manifest is in place), as long as it is built for the ABI the box reports: a Chromecast with Google TV runs a 32-bit userspace and wants `make apk-tv`. The **D-pad/remote-focused UI** is in: focus traversal, remote keys in the player, ten-foot density and overscan, all keyed on the `xtremio/device` channel's answer (see Status). Verified on a headless `android-36;android-tv;x86_64` AVD and run on a physical Chromecast with Google TV (`sabrina`, Android 14), which is where the ABI above and the remote-input fixes came from. Low-RAM devices (the 2 GB Chromecast) make the lightweight pure-Rust server and a bounded piece cache matter. |
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
