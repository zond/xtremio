# Xtremio

![xtremio](assets/branding/xtremio-logo.png)

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
> pixels. The **player** plays torrents through the
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
> the details header has a bookmark to add or remove a title. **Downloads**
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
- **What the crate keeps between calls is one value** (`rust/src/state.rs`):
  `AppState`, grouped by concern (`core` — the Runtime, its event sink and
  the events buffered before one arrives; `server` — the running handle;
  `downloads` — the registry file's lock, the progress sink and the ticker
  flag), behind the one process static there is. `core_init` creates it, or
  adopts the one the event-stream subscribe made just before it, and
  `core_shutdown` takes the whole value out of the process, so a second
  boot starts clean instead of inheriting the first one's sinks. Every lock
  is a field inside it, never one around it: a caller clones the `Arc` and
  takes only what it needs, so nothing coarse is held across the server's
  blocking calls. What stays a `static` says why it has to
  (`env.rs`'s `STORAGE_DIR`, because `Env` is a trait on a *type* with no
  `self` to hang a directory on; the tokio runtimes and the HTTP client,
  which are process-wide by nature; `logging.rs`'s `INIT`, which guards
  `tracing`'s own global).
- **The engine runs on our `Env`** (`rust/src/env.rs`): reqwest + rustls for
  HTTP, one JSON file per bucket under the app-support directory with
  temp-then-fsync-then-rename writes, and two lib-owned tokio runtimes
  (concurrent + a single-worker sequential one for ordered persistence).
- **The app's own preferences are a file beside those buckets**
  (`rust/src/prefs.rs`, `<storage_dir>/xtremio_prefs.json`): a flat JSON
  object of client-side choices -- how a list is laid out, which view a
  screen comes up in -- written with the same atomic write. They are
  deliberately *not* stremio-core `Settings` fields (that struct is the
  engine's and is synced to the account; a field there means forking the
  core) and deliberately not a Dart preferences package (the directory is
  already ours). The FFI is `prefs_get_all()` and `prefs_set(key,
  value_json)` (`rust/src/api/prefs.rs`) -- two calls, so a new choice
  costs a key and no regenerated bindings -- wrapped by `PrefsClient` in
  `lib/core/prefs_client.dart` and read once at start-up into `AppPrefs`,
  which `XtremioApp` hands down as a `PrefsScope`. The file is forgiving
  and additive like the downloads registry: a write is a read-modify-write
  of one key, a key from a newer build survives it, and a file that cannot
  be parsed reads as "nothing set" rather than as a failure. Today it holds
  six keys: `streamsSectioned` (the Details screen's sources list,
  sectioned by resolution -- the default -- rather than grouped by addon;
  an install from before the rename is read from the older `streamsFlat`
  name it was stored under, never written back), `openStreamSections`
  (which resolution sections are expanded, empty meaning every one
  collapsed on purpose rather than "unset"), `streamsOrder` (what order the
  streams inside one of those sections are in), `bufferAhead` (how far
  ahead playback buffers, below), `focusEmphasis` (Settings ->
  Interface -> "Focus highlight", offered on a television only: `standard`
  is the two-stroke ring with its zoom and shadow, `bold` thickens the ring
  and dims everything the remote is not on, for a bright room a display
  cannot fight; an unreadable or absent value is `standard`) and
  `subtitleSync` (the subtitle timings the viewer has fixed by hand, most
  recent first, bounded by recency -- see Subtitles). Nothing
  secret goes in it.
- **How far ahead playback buffers is the viewer's choice.** The streaming
  server reads ahead of the play head by a window sized for a healthy
  connection and a patient player; a spotty link, or a receiver with a
  shallower buffer than mpv's, wants more, and a fast link on mobile data
  wants less. The server takes that as `?buffer=normal|large|maximum` on
  the stream URL (x1, x2, x4 on the playback read-ahead; the startup window
  is the same under all three, so nothing starts more slowly). The app adds
  it in `withBufferAhead` (`lib/core/buffer_ahead.dart`) to the URL
  stremio-core resolved, and only for a torrent served over http(s) -- an
  addon's own host and an offline `file://` URL know nothing about it. It
  is additive on the wire: a server that predates the parameter ignores it.
  Settings -> Player -> "Buffer ahead" is the standing choice
  (`AppPrefs.bufferAhead`); the player's own settings sheet overrides it
  for the playback on screen and reverts with the next one. Changing it
  mid-playback re-opens the stream at the position it is at -- one `open`
  on the same engine, no `Load Player` and no restart -- because the window
  only reaches libmpv through the URL it is already fetching. The top of
  the scale is not a window at all: **"Download the whole file"** pins the
  stream as an offline download while it plays, which is the existing
  mechanism (it appears in Downloads and is deleted there, and the server's
  free-space check guards it exactly as it guards a pin from Details). A
  device that cannot fit the file is told so, with the numbers the server
  refused on, and left buffering as far ahead as it can instead.
- **The server is in-process**: `stream_server::start` runs on its own
  thread and runtime; the core's `streaming_server_url` is retargeted to it
  when the persisted profile points at loopback (a remote server URL set by
  the user is left alone). Port 11470 is preferred, ephemeral is the
  fallback; the BitTorrent listener itself is on an ephemeral port
  (`ServerConfig::embedded()`). Login and logout reset the profile's
  settings to stremio-core's defaults (`http://127.0.0.1:11470/`), so the
  event pump re-applies the retarget on `UserAuthenticated` /
  `UserLoggedOut`.
- **The server's control API requires a bearer token; only Rust has it.**
  `ServerConfig::embedded()` generates a token per launch, and every
  non-media route (`/settings`, `/network-info`, `/device-info`,
  `/casting`, `/create`, the `stats.json` routes, `/heartbeat`) answers
  401 without `Authorization: Bearer <token>`; the media routes libmpv
  fetches (`/{infoHash}/{fileIdx}`, archives, `/proxy`) and the
  `/local-addon` stubs stay open. stremio-core reaches the server only
  through `Env::fetch`, so `rust/src/env.rs` adds the header when the
  request's scheme, host and effective port are the embedded server's
  (`server::token_for`; any other host, loopback included, gets nothing).
  The Dart side never sees the token and never speaks HTTP to the server:
  the app's own control calls are FFI functions over `ServerHandle`'s
  library API in `rust/src/api/server.rs` — `server_torrent_stats(info_hash,
  file_idx, trackers)` (the per-file or torrent-level `stats.json` as
  JSON), `server_settings()` and `server_update_settings(patch_json)`
  (`GET`/`POST /settings`), plus `server_storage_report()`,
  `server_cache_usage()` and `server_clean_cache_now()` (see "What the
  server's storage costs") — wrapped by `ServerClient` in
  `lib/core/server_client.dart`. Nothing logs the token; the header value
  is marked sensitive. `media_kit`'s `Media.httpHeaders` could carry it to
  mpv should a media route ever need it; none does.
- **Offline downloads are a pin plus a registry.** The server keeps the
  chosen file of a torrent wanted and un-evictable
  (`ServerHandle::pin_download`, a validated `downloadsDir` setting,
  `pinned`/`complete` per file in `stats.json`); `rust/src/downloads.rs`
  keeps everything it has no idea about in `<storage_dir>/downloads.json` —
  keyed `"{metaId}:{videoId}"`, holding the raw stream JSON `Load Player`
  takes back, a `MetaItem` snapshot so Details renders offline, and
  `createdAt`/`completedAt`/`lastPlayedAt`. The FFI is
  `rust/src/api/downloads.rs`: `downloads_add(request_json)`,
  `downloads_remove(key, delete_files)`, `downloads_list()`,
  `downloads_open(key)`, `downloads_set_dir(path)`,
  `downloads_apply_default_dir(path)` and a `downloads_events()` stream that
  ticks about once a second, only while something is unfinished, and pushes
  just the rows that moved -- and of each row only what moves
  (`{"version":1,"progress":[{"key","downloaded","size","state","path",
  "error","completedAt"}]}`, not the whole entry with its meta snapshot and
  stream JSON, which is what a `downloads_list` is for). The file follows
  the same rule: a tick that moved nothing but a byte count does not
  rewrite it, since that number is a cache of the server's own and the next
  write that matters carries it; a state, a path, an error or a finished
  file goes to disk at once. Progress is merged from the server's
  `downloads()`, never stored twice.
  Downloading a second stream for a title replaces the entry and releases
  the pin it replaces (with its bytes, unless another entry names the same
  file), so no torrent is left downloading behind the registry's back. That
  sharing cuts the other way too: the server's pins are a set with no
  reference count, so removing one of two entries that name the same file
  drops only the registry row and answers `unpinned: false`, leaving the
  pin — and the bytes — to the one still playing it. A stream that names no
  `fileIdx` (or the `-1` sentinel the player's URL carries) is resolved the
  way the media route resolves `/{infoHash}/-1` — the `fileMustInclude`
  match, else the largest media file — so what is kept offline is the file
  that streamed, not file 0. A refused pin comes back as
  `{"ok":false,"error":{"kind":…}}` — `insufficientSpace` carries the byte
  counts, the rest the server's client-safe message, which names no local
  path — because a full disk is something to show, not an exception.
  Reading the registry is forgiving on purpose, and never at the cost of
  what is on disk: a file from a newer build keeps its `version` and its
  unknown keys, an entry this build cannot parse is kept verbatim and
  written back untouched (it is left out of the list payload, not out of
  the file), and a wholly unreadable file is moved aside as
  `downloads.json.corrupt-<seconds>` before an empty one takes its place.
  At boot every entry that is not complete is pinned again, on a blocking
  thread, since a pin waits on magnet metadata and nothing on screen waits
  on it. The UI reaches all of that through one `DownloadsClient`
  (`lib/core/downloads_client.dart`), which `XtremioApp` builds and
  disposes and a `DownloadsScope` hands down the tree -- one client,
  because the progress sink is one -- with `DownloadView`
  (`lib/core/state/download.dart`) reading the registry it answers with.
- **Where the files land is the platform's question.** The server's own
  default keeps a pinned torrent in its cache root
  (`<cache>/rqbit-downloads`) with everything else, which is right on a
  desktop and wrong on Android, where `<cache>` is the OS's to reclaim
  whenever it wants room. So start-up settles it once
  (`applyDefaultDestination`, `lib/features/downloads/destination.dart`,
  called by `XtremioApp`): on
  Android the server is pointed at the app-specific external files
  directory --
  `/storage/emulated/0/Android/data/com.zond.xtremio/files/downloads`,
  which needs no storage permission at all on `minSdk` 24 and which the
  system keeps until the app is uninstalled -- through
  `downloads_set_dir`, which is `POST /settings` with its validation (the
  path must be absolute, creatable, writable and not at or above a cache
  root). Everywhere else nothing is written and the server keeps deciding.
  An answer already given is never overridden: what start-up asks is the
  registry's own record of where the downloads were answered to go
  (`Registry::destination`, written as `destinationSettled` and
  `destinationChoice`), because a null `downloadsDir` is not only the
  unset state -- it is also "put them back with the cache" chosen by hand,
  and what the server writes for itself when it clears a destination it
  cannot use at boot (an SD card that is not in the device). The record
  says which of four situations it is: nothing asked, the platform default
  the app applied itself (`downloads_apply_default_dir`, which does *not*
  answer for the user), the cache on purpose, or a folder chosen
  (`downloads_set_dir`). A chosen folder the settings no longer have is
  the server having dropped it, so start-up asks for it again -- and if
  the volume is really gone the platform default stands in (on Android the
  external files directory, never the purgeable cache) while the folder
  stays on record, so the next launch tries it again and the Downloads
  screen can say which folder is missing. A `downloadsDir` left by a build
  from before any of this was recorded is adopted as the answer rather
  than overwritten. The Downloads
  screen's picker offers the same directories
  (`getExternalStorageDirectories()`, so an SD card is among them) plus a
  typed path off Android. With a destination set, each pin
  gets a folder of its own (`<downloadsDir>/<infoHash>/`), and only pins
  taken from then on move there: the server relocates an already-managed
  torrent when it is pinned again, which for an unfinished download is
  the next boot's re-pin and for a finished one never (its bytes stay
  where they were downloaded, and the registry keeps naming that path).
  A download whose volume is not mounted reads as `missing` rather than
  as an error. **On Android a download keeps going while the app is
  away**: `DownloadsForegroundService`
  (`lib/features/downloads/downloads_service.dart`) puts a `dataSync`
  foreground service up over the `xtremio/downloads` channel as soon as
  one entry is unfinished and takes it down when none is (ANDROID.md,
  "Downloads while the app is away", for what Android still reserves the
  right to do to it). The registry and the server's own pin set survive
  the process dying either way, and the boot re-pin picks the unfinished
  ones up again.
- **A finished download is played from the file, not from the server.**
  `downloads_open(key)` answers the `file://` URL of a download whose
  bytes are all here and whose file really is where it was left, and
  stamps the entry's `lastPlayedAt` as it does. Details and the Downloads
  screen hand the player that URL as a plain `url` stream
  (`lib/features/downloads/offline_play.dart`) together with the
  *original* `streamRequest` and `metaRequest`, which is what keeps
  continue-watching moving: stremio-core's `TimeChanged` writes progress
  only with a stream request and a library item, and offline the library
  item comes out of the `ctx` bucket the download put the title into.
  There is no torrent for the player to wait on, so the start-up overlay
  (which keys on `infoHash`) never appears. The file wins over the server
  even with a connection -- but only for the release that was
  downloaded; picking another stream is a request for that source. A
  download whose file went away with its volume streams instead and says
  so, rather than opening a player on a URL with no file behind it.
  Binge-advancing asks the same question about the next episode before it
  hands over, so a downloaded season plays through off the disk -- and
  offline that is the only way it advances at all, since the next
  episode's streams never load and the engine finds nothing to move on
  to.
  *Known consequence:* the synthesized `file://` stream is what
  stremio-core records as that video's last stream, and it is persisted.
  `MetaDetails` resolves the last stream against the addon's current
  responses by `Stream::is_source_match` (which compares the source, so a
  `Url` never matches the `Torrent` the addon offers) and then by
  `Stream::is_binge_match`. The binge match is why `offlineStream` keeps
  `behaviorHints.bingeGroup` -- but an addon that sets none leaves neither
  match to make, so after one play off the disk that title's "Continue
  with last source" tile is gone until it is played from an addon stream
  again, and `StreamsItem::adjusted_state` starts the next play of it with
  no remembered subtitle or audio track (playback speed survives). The
  download itself is unaffected: its badge, its row, and playing it from
  the release's own stream tile all still work.
- **Settings are the engine's.** `ctx.profile.settings` is stremio-core's
  `Settings` struct (camelCase; `docs/phase3-design.md` §4 lists it) and
  the only way to change one is `Ctx::UpdateSettings` with the *entire*
  object — it has no serde defaults, so a map missing a key fails at
  dispatch with "invalid action JSON" and never reaches the engine.
  `ProfileSettings.withValue(key, value)` (`lib/core/state/profile.dart`)
  copies the map with one key changed, and every control in Settings and
  in the player's settings sheet writes exactly that; nothing writes while
  the `ctx` field is still unknown, and the map last sent is what the
  controls show and the next write builds on until the following `ctx`
  pull, so two quick changes do not revert each other. Settings are device-local (the API's
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
  tap, mouse or key; they stay while paused or buffering. On a television
  they fade whether or not a control holds the remote, taking focus back to
  the video with them so nothing is left focused on something invisible;
  the D-pad stays inside them once it is there, and Back comes down a
  ladder, most transient first -- the up-next card, then an OSD that is up
  and free to go, then the player. A bar that cannot fade is not a rung:
  paused, buffering, with a menu open or at the end of a film (where
  playback has stopped and the up-next card was the rung), Back leaves,
  because appearing to do nothing would be worse. Subtitles ride above the
  bar: at rest they sit 4.5 % of the picture's height off the bottom, and
  while the controls are up they are lifted clear of what the bar actually
  covers, measured off the laid-out bar rather than assumed. media_kit's
  `SubtitleView` reads its padding out of the configuration once and never
  again, so the lift is *pushed* into it
  (`VideoState.setSubtitleViewPadding`, one call per change) rather than
  configured -- configuring it moves nothing after the first frame. Keyboard:
  Space/K play-pause, ←/→ or J/L ± the seek step (10 s by default),
  Shift+←/→ ± the short seek step (3 s), ↑/↓ volume, M mute, F
  fullscreen, Esc leaves fullscreen first when `escExitFullscreen` is on
  and the player otherwise, S subtitles, Shift+S subtitle timing, A
  audio, N next episode, Shift+I stats. Everything is a stream or method on
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
  synthetic `auto`/`no` entries) first and in a section of their own --
  they need no download and always match the release -- and below them
  every file from `player.subtitles`, the stream's own `subtitles` and
  the converted stream's, **one row per language**. That list is
  deduplicated on what a file *is*, not on the URL string
  (`SubtitleInfo.identityKeys`): the normalized URL -- scheme and host
  lower-cased, a default port, a fragment and trailing slashes dropped,
  the query's parameters in a fixed order but *nothing* removed from
  them, because OpenSubtitles v3's only parameter is `senc`, which picks
  the encoding of the bytes it returns -- and the addon's own `id`,
  scoped by language, so two addons mirroring one upload collapse while
  two that both number their answers from 1 do not. What is left is
  ordered by **the release it was cut for**. A subtitle timed for 25 fps
  played against a 23.976 fps film *can* drift about four seconds a
  minute, and
  OpenSubtitles says which rate an upload was cut for (`fpsMilli`, on
  about nine entries in ten) -- but the claim is about the release the
  upload was made for, not about its timing. Ten English files for one
  film declaring six different rates all end within 1 % of the same
  runtime, while five Gilmore Girls files at 25 fps really do run 4.27 %
  short against the five at 23.976, and nothing in the metadata
  separates those two populations. So **nothing is corrected
  automatically** -- a multiplier applied unasked would fix one
  population and silently break the other -- and nothing is *ordered* by
  the rate either. What the addon says about which release an upload was
  cut for says more, because two files made for one release keep its
  time. `subtitlesByRelease` puts a language's files whose `releaseGroup`
  or `movieReleaseName` names the video actually playing first, then the
  ones from a subtitle group the viewer has already adjusted for this
  series (the correction goes back on when the file is applied, so it
  arrives fixed, and the rank asks the memory exactly what applying it
  will ask), then everything else in the order the addons answered.
  Between languages nothing moves, and inside a rank the addon that
  answered first still wins -- which matters, because the head of a
  language is the file its row applies and the file the auto-pick plays.
  Nothing is dropped or hidden. The video is named by the same
  `castFilename` a remembered shift is keyed on (the file the server says
  it opened, else the addon's claim); both sides are cut into lower-case
  runs of letters and digits, since release names are written with dots,
  underscores, spaces and any case, and the claim has to appear as a
  contiguous run of *whole tokens*. A false match is worse than no match
  -- it would put a file at the head of its language with nobody looking
  -- so part of a word is not a match (`DFN` never claims a DFNX rip),
  tokens scattered through the name are not (`BluRay` and `x264` from
  opposite ends describe a kind of encode, not this one), and a lone bare
  number or two-letter tag is not, because a year and a resolution are
  what a bad parse leaves in those fields. A release *name* has to reach
  past the front of the filename as well: a run that starts at the first
  token and stops short of the last is the show, the episode and its
  title, which every upload of that episode carries. Of the twelve files
  in the real OpenSubtitles answer for one Gilmore Girls episode whose
  claim appeared in the playing filename, eleven claimed only that (one
  claimed `Gilmore Girls` and matched every filename tried), and each was
  marked "same release" and sent to the head of its language ahead of the
  one file that named the rip -- which on that episode meant a 25 fps
  file first on a 23.976 fps picture. A release *group* is never the
  show's title and still counts wherever in the name it sits. Both sides
  lose a trailing container extension before any of this, since agreeing
  where a name ends is what "to the end" needs and an addon writing
  `.mkv` where the server opened the `.mp4` is naming the same release. A
  claim matching every file of a language costs nothing, since a rank
  keeps the addons' order inside it; the shape that hurts is a generic
  claim on *one* file of a language, which is what the rule above is
  for. A row carries the addon that offered the file and, where it earned
  one, two words saying it was cut for this release -- a fact about the
  upload, never a rate and never a verdict about its timing. What the
  video's own rate still decides is the direction of the panel's speed
  button, and nothing else. The drift is linear, so when a viewer judges
  it one press removes the whole of it: a film of N frames sits at
  `N / fps_sub` in the subtitle and at `N / fps_video` in the picture, so
  25 against 23.976 is 1.0427 (`SubtitleTiming.speedStep`, written
  through `PlaybackEngine.setSubtitleSpeed`), and the reciprocal is the
  mistake to make here, since it doubles the drift rather than removing
  it. The video's rate comes from an observation of libmpv's
  `container-fps` through `PlaybackEngine.videoFrameRate`, which reports
  whenever mpv works the rate out: the demuxer has to probe the container
  first, and a torrent's container is only there once the pieces holding
  it have arrived, so on a thin swarm the answer legitimately lands
  minutes into the film. A read taken at a fixed moment after the media
  loaded took that silence for "no rate" and left the panel offering both
  buttons for the rest of the episode. The stats OSD polls the same
  property, but only while it is on screen, and this has to be known
  whether or not anyone ever opens it. Only what the
  container *declares* is trusted: `estimated-vf-fps` is an average of
  the last ten frame durations, which mpv itself calls unstable for the
  imprecise timestamps a torrent stream is full of, and a stall rendering
  12 frames a second would point the speed button off a number it
  invented. Rates within 0.01 fps are the same rate (a container rounding
  23.976 to 23.98), and so are rates a telecine or a doubling apart -- an
  SRT is timed in seconds, not frames, so 23.976 film in a 29.97
  container is the same seconds, five frames drawn for every four. That
  reduction is what places a video in its family: a 50 fps PAL encode is
  25 fps material and a 29.97 fps container is 23.976 fps film, so both
  families are walked and the rate is read as whichever base it reduces
  to. An engine that cannot say what the video runs at simply leaves the
  panel offering both directions. Every
  path that changes what is on screen -- another file, an embedded
  track, subtitles off, the next video, and the auto-pick putting the
  tracks back after the engine refused one -- goes through the one
  `PlayerScreen._resetSubtitleTiming`, which puts both properties back to
  untouched, because they belong to the player rather than to the file
  and one left behind ruins a subtitle that was correct. The drift itself
  is the viewer's to judge. **Adjust timing** opens a small panel; it is
  the last entry of the subtitle menu (the toolbar's subtitle button, or
  S), and it is
  there only while a subtitle is actually showing, since there is nothing
  to move otherwise. Shift+S opens and closes it directly, and on a
  television the remote lands on its first stepper, walks the rows with
  the direction keys and closes it with Back. It holds two controls. The
  **shift** is a stepper in 0.1 s steps on libmpv's `sub-delay`
  (positive delays the lines, which is mpv's own sign); it repeats while
  it is held, by pointer or by the remote's centre key, because twenty
  presses for a two-second offset is a chore rather than an adjustment,
  and it is counted in whole presses (`SubtitleTiming` in
  `lib/features/player/subtitle_timing.dart`) so that ten forward and ten
  back land exactly where they started. The **speed** is a *toggle*, and
  the video points it. Frame rates are two lineages -- film (23.976, 24,
  and the 29.97, 30, 47.952, 48, 59.94, 60 telecined or doubled off
  them, all the same seconds) and PAL (25, 50, which run 4.27 % faster)
  -- and drift appears only between the two, so a film-family video can
  only be facing a PAL-sourced file and needs it stretched, a PAL-family
  video the reverse (`subtitleSpeedDirection`). One button, therefore,
  and a second press is exactly 1.0 rather than the ratio squared, which
  is nine per cent out and a state nobody means to reach; the toggle
  does not repeat under a held key, since at the stepper's rate it would
  flip eight times a second. Two buttons appear in exactly one case: a
  container that declares no rate at all, or one in neither family,
  where no direction can be chosen and a stream would otherwise be
  unfixable. The other time both appear is not a case at all but the
  toggle kept reachable: a correction already in force keeps its own
  button whatever the video says, because a gap cannot be pressed and
  the button that *is* drawn would swap the direction for its reciprocal
  rather than reach 1.0. The rate arrives when mpv has probed the
  container and not before, so a press made while it still says nothing
  can be in the direction the answer then rules out. Reset goes back to
  untouched, 1.0 and 0.0,
  because with nothing else writing either property that is what "undo
  what I did" means. What the viewer fixes is **remembered, keyed on what caused
  it** (`SubtitleSyncMemory`, `lib/core/subtitle_sync.dart`, under the
  one `subtitleSync` preference), so the same correction is not made
  again on the next episode, and `_resetSubtitleTiming` puts it back
  whenever that file goes on screen. The two keys are deliberately
  different because the causes are. A *speed* is remembered against the
  series and the addon's own grouping of its files (`g`), since what a
  file was timed against is a property of where it came from -- across
  two Gilmore Girls episodes `g=1` is all 23.976 and `g=3` all 25, while
  `g=6` holds one file claiming 23.976 and one claiming 25 that end at
  exactly the same moment, synced to each other whatever they claim --
  and since video releases of one show share a frame rate, so a speed
  carries from one to the next. A *shift* is remembered against the
  video release as well, because an offset is the video's pre-roll less
  whatever the subtitle's source assumed and changing either side
  changes the answer; the release is the whole filename the player knows
  (the file the server says it opened, else the addon's claim), not a
  release group parsed out of it, because a parse is a guess and two
  encodes by one group can still start in different places. Any part of
  a key nobody can name -- an addon that sends no `g`, a torrent nothing
  has named the file of -- means that adjustment is simply not
  remembered: a narrower key is forgotten more often, and that is the
  price of never being wrong. A remembered speed whose direction this
  video's own family contradicts is not put back either -- a stretch
  says the group's files are PAL-timed, and against a PAL video that
  needs nothing rather than needing the reciprocal -- though it stays in
  the file, since the next release of the show is likely to be the
  family it was learned on. Because the rate is observed, on a torrent
  the answer usually arrives *after* the file went on and the speed with
  it, so the same rule runs again when it lands and takes back off what
  it has just ruled out; a speed the viewer *pressed* is a judgement
  about the drift in front of them and is never withdrawn. Reset *forgets* rather than storing a
  correction of none, since nothing remembered is what nothing applied
  looks like next time; the store is bounded by recency, so a viewer who
  fixes twenty shows does not pay for the twenty-first; and only a press
  on the panel is written down, because every other call on the timing
  is the machine putting a file back the way it found it. The write is
  made when the adjusting is over -- the panel closing, something
  changing what is on screen, the player going away -- rather than on
  each press, since the shift repeats eight times a second under a held
  key and a preferences file is not a keystroke log. The last of those
  waits until after the screen has dropped its preferences listener,
  because a write notifies synchronously and a notification answered
  from inside `dispose` is a `setState` on an element Flutter has
  already marked defunct. From the first
  press the session preference's auto-pick stops
  looking for a file of its own for this media -- a viewer judging the
  subtitle in front of them has answered the question that guess exists
  to ask, and a guess that keeps swapping the file under them is the
  wrong answer to it. Picking a subtitle from the menu ends it for the
  same reason. Both values are re-applied after the stream is re-opened,
  since they belong to the playback rather than
  to the file the demuxer just re-read -- and the addon file goes back
  first, because a re-open is a fresh `loadfile` and nothing `sub-add`
  put in survives one. The panel is deliberately not part of the OSD: the
  bar fades on its three-second timer while the panel stays, because
  adjusting means pressing and then watching the picture for several
  seconds, and it takes a rung of its own on the Back ladder -- above the
  bar, and on every device rather than only on a television. Every button
  on it, Reset and the close cross included, wears the same two-pixel
  focus ring, since this is the one surface meant to be operated after
  the bar has gone, and a toggle that is on is filled as well as
  counted. Where the video has ruled a direction out and nothing is in
  force in it, the button's place is left empty rather than filled with a
  second control, so the value and the button stay in the columns the
  shift row put them in. Then
  `groupSubtitlesByLanguage` (`lib/features/player/subtitle_groups.dart`)
  makes one row per language, since OpenSubtitles answers a single movie
  with 69 files, nineteen of them Spanish. Codes group on what they mean
  (`en` and `eng` are one row); a code `languageName` does not know is
  its own row, labelled with the code itself. Nothing that reaches it is
  hidden: a language with more than one file carries a row beneath it ("14 other
  English files") that opens them all, each named by the addon that
  offered it plus whatever the file itself is worth calling: the addon's
  `label` if it sent one, else its release group (`DFN`, or `DFN BluRay`
  with the format), else its `subtitleFileName` cleaned up into words,
  else its `movieReleaseName`, and only then `Option N`. A derived name
  only earns its place by differing from its neighbours, and an addon
  repeats itself -- all three Czech files OpenSubtitles answers for The
  Godfather are named `1.srt` -- so any name two files of one language
  both derive gets its position back on the end (`1 (2)`). Those come from
  the addon's own properties the pinned stremio-core keeps
  (`SubtitleInfo` in `lib/core/state/player.dart`); OpenSubtitles v3
  sends no label, so before that pin fifteen English uploads were fifteen
  numbers. Every one of them is addon text on its way to the screen and
  goes through `wellFormedText` (`lib/core/well_formed_text.dart`), which
  drops the half characters Flutter's text layout refuses to draw, and
  every one is cut to the same 60 characters -- an addon's
  `movieReleaseName` runs to a hundred and twenty, and a menu row is
  something to choose between, not a paragraph (the rows cap at two lines
  on top of that, since a `ListTile` grows to fit whatever it is given). That
  row is a *sibling* of the language row rather than a button inside it,
  so a remote reaches it by moving down (directional traversal skips a node
  inside the focused one's rect). Whichever file is playing is what its
  language row shows as selected and what it re-applies, so a pick two
  rows deep survives the list being rebuilt when a slow addon answers.
  The menu is reachable before the media loads, so a pick can predate the
  rate; nothing is taken away when it lands, and the panel picks up the
  direction as soon as the engine has answered. The list itself waits for
  nothing: a torrent whose server has not yet named the file it opened is
  a video nothing can be said to have been cut for, and the addons' order
  stands until it is.
  Which track is active comes from mpv's
  own `sid`/`aid` (observed through `NativePlayer.observeProperty`), so a
  default or forced track mpv picked by itself shows as selected too —
  media_kit's `stream.track` only follows its own setters. Picking one
  dispatches `SubtitlePreferenceChanged`, which the core keeps for the
  Player session; the next episode's player applies it automatically to
  the first matching track once the media is loaded (mpv refuses
  `sub-add` while it is still between files) -- the automatic pick comes
  out of the same ordered list the menu shows
  (`PlayerScreen._offeredSubtitles`, the one place either consumer gets
  it from), since it is the one path that applies a file without anybody
  looking at it, and it applies it exactly as it stands. A backend with no
  rate to report -- a cast device, an offline file, a container that
  declares nothing -- simply stays silent, and an unknown rate decides
  nothing. Text subtitles are rendered by Flutter
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
  server's stats every 500 ms over FFI (`server_torrent_stats`, the same
  function its `stats.json` routes run; `TorrentStatsRequest.forStream`
  takes the stream's `infoHash`, `fileIdx` and `announce` list — the three
  things the core builds the stream URL from, `announce` being its `tr=` —
  and a poll falls back to the torrent-level stats when the server has no
  answer for the file) and maps the server's `phase` to a label:
  `resolvingMetadata` → "Fetching torrent metadata…", `checking` →
  "Checking existing data…" with `checkedBytes/checkTotalBytes`,
  `buffering` → "Finding peers…" with the `peerDiscovery` counts while no
  peer is live, else the window the reader is waiting for -- which is
  piece-aligned and follows the reader, so after a seek it describes the
  bytes actually being fetched. **A window one piece wide is said in
  pieces, not in percent**: librqbit credits verified pieces and nothing
  in between, so with 8-16 MiB pieces and a window inside one of them the
  percentage could only ever read 0 or 100, and it read 0 for tens of
  seconds while the download ran perfectly. What moves instead is the
  server's `inFlightPiece` -- the byte progress of the very piece the
  reader is sitting on -- which reads "Waiting for piece 137, 6.3 of
  16.0 MiB…" over a bar at `downloadedBytes/totalBytes`, with an estimate
  from `downloadSpeed` for that piece's own remainder. The bar owes three
  rules to what the number actually means (`stream-server`'s README, "The
  in-flight piece"), and each has a test: **full is not finished** -- a
  chunk counts when it is written, the hash is only checked once the last
  one is in, so the bar holds at 97% while `verified` is false and lets
  `verified` fill it; **it never runs backwards** -- a decrease is a piece
  that failed its check and was discarded, so the bar stays where it got
  to rather than animating down, while a *different* piece (the reader
  moved) starts where that piece is, at once and with no transition; and
  **null is not zero** -- no reader open, no metadata, no chunk map, or a
  server from before the field -- and then it is the wording it always
  had ("Waiting for the first piece (16 MiB)…", "next piece"
  mid-playback) over the indeterminate sweep, never a bar sitting at 0. A
  window that genuinely spans several pieces keeps "Buffering start…" and
  its percentage, and a server that sends no `pieceLength` keeps it too. `ready` → "Starting
  playback…", `error` → "The torrent failed to start" with the server's
  `error` string as the detail; no answer yet → "Connecting to server…".
  The bar is determinate whenever there is a percentage; `downloadSpeed`
  and, once anything is connected, the swarm line (`connected 4 ·
  seeds 137 · swarm 539`) show when non-zero. While it is still finding
  peers there is nothing connected to count, so that line is the
  `peerDiscovery` counts plus, when a tracker answered, `137 seeds in the
  swarm`. Polling pauses when the media loads (see
  the stall card below) and ends on an engine error and on dispose; direct
  HTTP streams get nothing extra. The `TorrentStatsClient` comes from
  `PlaybackScope`, so tests feed phases through a fake. The stream's
  `fileMustInclude` (`f=`) filters are not part of the library call: a
  stream without a `fileIdx` polls the torrent-level stats.
- **Mid-playback stall card.** When playback that has started runs out of
  data (`buffering` from the engine), a torrent gets the same card rather
  than the spinner and sentence it used to: the polling that paused at
  media-load resumes for as long as the stall lasts, at 2 s instead of
  500 ms, with the first poll fired at once (the torrent's engine exists
  by then, so there is no ordering to respect). The phases read in the
  present tense — `checking` keeps its percentage, `buffering` means the
  head window is still filling and its percentage — or, one piece wide,
  the same in-flight piece the start-up card draws — is what playback is
  waiting for, `ready`/unknown is "Buffering from the torrent…" with an
  *indeterminate* bar (past the head of the file the server measures no
  target, so a full bar would be a lie), `error` is "The torrent stopped"
  with the server's reason. The detail line always says `downloadSpeed`
  and the swarm, zeros included — during a stall `0 B/s · connected 0`
  is the diagnosis, and whether the swarm holds a *seed* at all is the
  difference between a slow swarm and one that cannot finish the file.
  The swarm line is one formatter (`TorrentProgressCard.formatSwarm`,
  rendered by the start-up card, the stall card and the progress card
  alike) saying three numbers: our live connections, the tracker-scraped
  `swarmSeeders`, and `swarmSeeders + swarmLeechers` for the whole swarm.
  Only the first is ours to count; a scrape that never answered leaves
  the other two *missing*, never printed as a 0 or a dash, because a
  swarm we could not ask about is not an empty one — so a torrent with no
  trackers says just `connected 4`, and seeders without leechers stops at
  `seeds`. Connections that hold the whole file (`connectedSeeders`) and
  addresses merely discovered are not on this line; the stats overlay
  still shows both. Playback
  resuming drops the card, the timer and the last answer; an answer that
  arrives after the stall ended is discarded.
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
  of the `zond/stremio-core` fork (`cfd27a7`: release 0.62.1 plus one
  commit that keeps an addon's own subtitle properties -- `fpsMilli`,
  `subtitleFileName`, `releaseGroup` and the rest -- in a flattened
  `other` map instead of letting serde drop them; upstream PR
  Stremio/stremio-core#1045, drop the fork once it lands) with the
  `derive` + `env-future-send`
  features, `zond/stream-server` at a fixed rev (`4dceb21`: generated
  bearer token, library API on `ServerHandle`, ephemeral torrent port,
  `/local-addon` stubs, `connectedSeeders` and the tracker-scraped swarm
  counts, the buffer profiles behind `?buffer=`, cache usage and
  on-demand cleaning, a DHT bootstrap list trimmed to the two hosts that
  actually answer and resolved over DNS-over-HTTPS when the system
  resolver will not, with the IPv6 literals dropped on a device that has
  no route to them -- and named in the log as route-dropped rather than
  counted as a name DNS failed on, the piece-aligned start-up window that
  follows the reader plus the `pieceLength` it is measured in,
  `inFlightPiece`, the byte progress of the one piece the reader is
  sitting on, and
  `ServerHandle::dht_status` for the diagnostics screen). To bump: change the rev, `cargo update -p <crate>`, run
  `cargo test`, re-record any fixture whose shape moved, move the
  `[patch]` key along if the source URL changed (it names the URL being
  patched, and a stale key silently patches nothing), and re-copy
  `rust/vendor/stremio-watched-bitfield` from the new stremio-core rev
  when that crate changed (it carries a one-line `flate2` relaxation the
  combined graph needs; see `rust/vendor/README.md`).

### Verifying on a dev machine

```bash
# Rust crate
cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
cargo test --test cinemeta -- --ignored       # network: loads a Cinemeta catalog, refreshes the fixture
cargo test --test meta_details -- --ignored   # network: meta + streams + Player + continue watching for a public-domain torrent, plus a series (seasons, selected episode, watched), refreshes fixtures
cargo test --test board -- --ignored          # network: Board rows + a search over the default addons, refreshes fixtures
cargo test --test library_addons -- --ignored # network: ctx (logged out), installed/remote addons, addon details (Cinemeta), library fixtures
cargo test --test downloads -- --ignored      # no network: rebuilds downloads_registry.json (a finished movie, a half-done episode, an empty one) from two torrents it builds itself
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

### What the server's storage costs

**Settings → Developer → Server storage** answers the question a
misbehaving playback raises first: is the cache over the limit its cleaner
is supposed to hold it to. The same number is in the copied diagnostics
header too (alongside the device's free space, which lives only there),
since it is what a person should look at before reading a single log line.

The cache-vs-limit number comes straight from the pinned server
(`ServerHandle::cache_usage()`, `rust/src/server.rs`
`cache_usage()`/`server_cache_usage()`): a read-only walk in the cleaner's
own occupancy accounting (allocated blocks, not apparent length), reporting
`totalBytes`/`limitBytes` and, separately, `protectedBytes`/
`protectedFiles` — what a live engine is writing or a pinned download keeps
right now, which a clean pass can never touch. The device's free/total
space (a different concern — is the disk full, not is the cache over its
limit) is still measured on the Rust side, in `rust/src/storage.rs`
(`server_storage_report()`), and shown only in the diagnostics header.

"Clean cache now" runs `ServerHandle::clean_cache_now()`
(`server_clean_cache_now()`) — the exact function the server's own
scheduled sweep calls (`server/src/cache_cleaner.rs`, on a debounce after
cache writes and hourly otherwise), only on demand. **Nothing here stops
playback**: unlike restarting the server, which was the only way to ask for
a sweep before the server exposed this call, the running server keeps
answering throughout. The same protections apply as ever — nothing a live
engine is writing or a pin keeps is ever evicted — so a clean that leaves
the cache still over its limit is not a failure: the screen names what
`protectedBytes`/`protectedFiles` (or the report's `protected`/
`protectedFiles`) are holding, rather than saying the clean failed.

### Diagnostics off a device

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

Everything shown and copied goes through `redactSecrets`
(`lib/features/diagnostics/diagnostics_report.dart`) first: the embedded
server's bearer token, any `Authorization` value, auth and API keys,
passwords and the path of an addon manifest URL (a debrid key rides there)
never reach the clipboard. Nothing in that class is logged in the first
place -- this is the second lock, not the first.

The header's app version and commit are whatever the build passed in as
`--dart-define`s, and with nothing passed they read `unknown` -- which is
the one line that says which build the rest of the report is about. A plain
`flutter build` passes neither, so the build to type is the `Makefile`'s:

```bash
make apk          # release APK for a phone or a 64-bit TV box (arm64)
make apk-tv       # release APK for a Chromecast with Google TV (armeabi-v7a)
make apk-split    # release APKs per ABI
make linux        # release Linux desktop bundle
make run          # flutter run, stamped the same way
make version      # what would be stamped
```

Each of those adds `XTREMIO_VERSION` (from `pubspec.yaml`) and
`XTREMIO_GIT_COMMIT` (`git rev-parse --short HEAD`, suffixed `-dirty` when
the tree was not clean, because a report from a modified build must not
name a commit as if it were that commit), and takes the usual extra flags
through `FLAGS=`. Building by hand instead is the same two defines:

```bash
flutter build apk --release \
  --dart-define=XTREMIO_VERSION="$(sed -n 's/^version: //p' pubspec.yaml)" \
  --dart-define=XTREMIO_GIT_COMMIT="$(git rev-parse --short HEAD)"
```

`flutter run -d linux` itself has not been exercised yet (this was developed
on a host without the GTK toolchain); cargokit builds the crate through
CMake and `media_kit_libs_video` supplies libmpv there.

### Android

The debug APK builds and boots on a headless x86_64 emulator (Discover
loading a Cinemeta catalog with posters end to end) and on a headless
Android TV emulator, where Board → Details → player was driven entirely by
`adb shell input keyevent`; a physical device or TV box has not been tried
yet, and no emulator session has ever decoded video. See [ANDROID.md](ANDROID.md) for the
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

**Typing with a remote.** On Android TV the app window keeps input focus
while the on-screen keyboard is up, so every D-pad press is delivered to
Flutter and moves Flutter's focus: the keyboard can never move its own
selection, which makes it decorative and sign-in impossible. The cause is
`IME_FLAG_NO_FULLSCREEN`, which Flutter sets on every field it creates and
which Dart cannot unset -- fullscreen ("extract") mode is precisely the mode
in which the keyboard takes window focus and owns the remote. So on a
television the app hosts no text field at all. `TvTextField`
(`lib/widgets/tv_text_field.dart`) draws the field's decoration around its
current value and, on select, asks `MainActivity` over the `xtremio/device`
channel for `TextEntryActivity` -- one plain `EditText` on a screen of its
own, carrying none of those flags -- then takes back the string. Back
cancels and nothing moves; Done returns the text, which is delivered to the
field's `onChanged` and `onSubmitted` because confirming there is the
remote's way of pressing Done. A password is masked, asks the keyboard to
learn nothing from it (`IME_FLAG_NO_PERSONALIZED_LEARNING`), is kept out of
autofill and runs behind `FLAG_SECURE`. Off a television `TvTextField` is
the ordinary Flutter `TextField` every one of those places always had.

A field that can be emptied takes an `onClear`, and the button that does it
is the field's own, never part of the decoration: off a television it is the
`suffixIcon` inside the box, as it has always been, and on one it sits
*beside* the box. Inside, a remote could neither reach it (the field takes
focus as a whole, so there is nothing to the right of the text to step to)
nor press it (`RemotePress` is above every descendant and takes select for
the typing screen), which is a button drawn where the remote cannot go.

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
Cinemeta posters proves HTTPS end to end. For D-pad work create a second
AVD from `system-images;android-36;android-tv;x86_64` with `-d tv_1080p`
and drive it with `adb shell input keyevent` — the same x86_64 debug APK
installs on it; ANDROID.md lists the keycodes. On a physical phone or TV box
(USB debugging, `adb devices` shows `device`) build for the ABI that box
reports from `adb shell getprop ro.product.cpu.abilist` -- `make apk` for a
phone, `make apk-tv` for a Chromecast with Google TV, which is 32-bit and
refuses the arm64 APK outright (ANDROID.md, "Running on a physical device").

## Casting to a Chromecast

A cast button on the player's top bar, once a receiver has answered. It hands
the stream to the receiver **untouched** — the bytes the embedded server
already serves, with no processing anywhere — and turns the player screen into
a remote while the television plays. Media3 remuxing, which is what would let
the other three quarters of the streams out there be cast, is not built.

Because nothing is converted, the honest part of this is the refusal.

**The compatibility rule, as implemented**
(`lib/features/cast/cast_compatibility.dart`): MP4 or WebM, H.264, HEVC, VP8
or VP9 video, and audio the container is allowed to carry — AAC or MP3 in an
MP4, Opus or Vorbis in a WebM. The audio half is keyed on the container
because that is where a receiver draws the line; the video half is one list
for every device, which is a known approximation in both directions — HEVC
and VP9 want a Chromecast Ultra or newer, and a WebM claiming H.264 would be
called ready — and the comment on the table says why fixing it means asking
the session what the receiver in the room supports.

- The **container** comes from the name of the file the embedded server says
  it opened (`streamName` in the `stats.json` the player already polls), then
  the converted stream's filename, then `behaviorHints.filename`, then a URL
  path that ends in a real file name. The server comes first because a
  torrent's streaming URL is `/{infoHash}/{fileIdx}` and says nothing, and the
  addon is often silent or guessing: it says what it believes it linked to,
  the server says what it opened. (For a torrent the converted stream is the
  same claim — `Stream::to_converted` clones `behavior_hints` verbatim — while
  an offline play, where it really is the file on disk, has no server behind
  it at all.) A container nothing identifies is a **refusal**, not a maybe. A
  guess here is a guess about whether the evening works.
- The **codecs** come from mpv while the stream is playing locally
  (`video-codec` and `audio-codec-name`, sampled while the receiver list is
  open), and otherwise from what the release claims about itself — the
  `StreamFacts` tags and the filename. A claim is believed when it says
  something is *wrong* and never taken as proof that something is right, so a
  codec nothing mentions passes on the container's strength alone, and mpv
  overrules a release name that disagrees with the decoder.
- A `/proxy` or `/ftp` URL is refused before any of that. Those routes are
  each an open proxy and are deliberately not mounted on the LAN listener, so
  a stream stremio-core plays through the proxy cannot be cast at all.

A refusal is a dialog that says what is wrong and that the conversion which
would fix it does not exist yet; `CastRefusal` names which rule refused, which
is the seam Media3 fills.

One refusal is not a verdict. In the first seconds of a torrent the server has
not opened a file yet, so nothing anywhere names it; that is
`CastRefusal.containerPending`, headed "Still working out what this file is"
rather than "This stream cannot be cast", and it answers itself — the poll that
names the file makes the same button work, with nothing reopened. The name is
kept for as long as the player is on that stream, because the polling stops
once playback is under way while which file this is does not go stale, and it
is only ever taken from an answer about the file being streamed: the
torrent-level fallback's `streamName` is the file the server *guessed*.

**The URL the receiver is given.** A Chromecast cannot fetch from
`127.0.0.1`, so a loopback URL is rebuilt on the server's **LAN media
listener** — a second HTTP listener with no control routes on it at all, and
deliberately without `/proxy` and `/ftp` (`rust/src/server.rs`,
`server_set_lan_media`). A stream served from somewhere else on the internet is
handed over as it is; the receiver has a connection of its own, and no listener
is started for it. If no local interface can reach the receiver, the app says
the device is unreachable rather than casting a URL that could never be
fetched.

**The listener lives exactly as long as a session**, and that is made hard to
get wrong rather than merely intended: it is closed when the session ends, when
the session ends from the television or another phone, when a start fails, on
`dispose`, and defensively right after the server starts — stream-server binds
a configured `lan_media_addr` at boot, so `start_in` shuts it again as the
first thing it does. Turning it on also grants the server's `lanMediaEnabled`
veto and turning it off takes it back, so what is on disk while nothing is
casting is "no".

**While casting** the player screen shows the title, the position, play/pause,
seek and stop, all from the receiver's own status — a pause from its remote
shows up here too. Local playback is stopped and its own reports ignored, and
ending the session resumes it where the receiver had got to. The core hears the
same three actions local playback dispatches — `TimeChanged`, `PausedChanged`,
`Ended` — so the library and continue-watching do not notice which device the
pixels were on.

The button is never built on Android TV: a TV is a receiver, not a sender.

The pieces: `lib/features/cast/` (`cast_client.dart` — the interface,
`CastScope` and the types; `google_cast_client.dart` — the implementation over
[`flutter_chrome_cast`](https://pub.dev/packages/flutter_chrome_cast);
`cast_compatibility.dart`; `cast_widgets.dart`), the session in
`PlayerScreen`, and `LanMediaControl` on `ServerClient`. Widget tests drive it
through `FakeCastClient`/`FakeLanMediaControl` (`test/support/`) and never
touch the plugin; `rust/tests/lan_media.rs` drives the listener itself.

**Not verified against a real Chromecast** — there is no receiver on this
machine. What is verified: the LAN listener over real HTTP (it serves media
routes, answers `/proxy` and `/heartbeat` with 404, and is gone after a stop
and after a shutdown), the Android manifest merge, and every decision the app
makes around a fake sender.

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

## Which addons are worth keeping

A profile collects addons. Some of them die quietly — the host goes away, a
debrid key expires, a catalog 404s — and nothing in a Stremio client tells
you which. Xtremio keeps a small record of **how each installed addon has
been answering**, and the Installed tab reads a verdict off it, so the
question "which of these can I uninstall?" has an answer that is not a
guess.

**Three outcomes, never two.** Every settled answer is counted as *answered
with content*, *answered with nothing*, or *failed*. Empty is its own
bucket and that is the whole point: a public-domain catalog legitimately
has nothing for this year's blockbuster, and folding that into "failed"
turns a specialist into a broken addon. The counts are kept per addon *and*
per resource kind (`catalog`, `meta`, `stream`, `subtitles`, only the ones
the manifest declares), so an addon with good streams and a dead catalog
reads as exactly that.

**What is counted, and by whom.** The Rust side counts and the app judges.
`rust/src/addon_observer.rs` watches the runtime's event pump, so every
board row, search, discover page, details load and subtitle list is
observed with no per-screen opt-in; `rust/src/addon_health.rs` holds the
counts and writes them to the preferences file at most once a minute (and
on shutdown). `lib/features/addons/addon_health.dart` holds the rule, as
one pure function over an immutable record, tested against a table of
cases. Changing the rule therefore changes no stored data.

**The verdicts**, in the order they are decided:

| Verdict | When |
| --- | --- |
| **Not used yet** | Fewer than 5 observations on every kind |
| **Often unreachable** | Some kind asked ≥ 5 times failed at least half of them, **and** the addon has answered nothing at all in over 7 days |
| **Rarely has anything** | Every declared kind was asked ≥ 20 times and carried content in under 5% of them |
| **Working · streams 34%** | Anything else, with how often the kind it is asked for most actually had something |

Both halves of *unreachable* are required. The ratio alone condemns an
addon that is failing right now but worked an hour ago — that is the
network, not the addon — and the silence alone condemns one that is simply
rarely asked. *Rarely has anything* needs **every** declared kind to be
answering nothing, so one live resource rescues an addon, and a declared
kind nothing has asked for yet keeps the verdict off entirely. Five percent
is deliberately far below what a catalog addon manages: a stream specialist
that answers one title in twenty is working as intended.

**Counts decay rather than accumulate**: every count halves every 14 days,
one multiply on read and write, so the record is constant-sized and
self-healing — an addon that was broken for a week in March is not still
being argued with in June. Two timestamps ride along, because no decayed
float can say "it last worked three days ago". Tapping a verdict shows all
of it: when the addon last worked, and the three counts for every kind it
declares, with a kind nothing has asked for reading *not asked yet* — the
pump only sees what a screen actually requested, which is also why "not
used yet" is a first-class verdict and not a placeholder.

**A broken network is charged to nobody.** The addons on a board are asked
together and, with no connection, they fail together. One field's worth of
settled answers is held back as a *sweep* and committed only if at least
one addon in it did not fail; a sweep in which everything failed changes no
count at all. No reachability probe and no DHT dependency — just the
observation that a result where nothing worked is a result about the
connection. When *nothing* has answered since the app started, the Installed
tab says so in a banner, which is exactly when a list of freshly-failed
addons is most tempting to act on.

**What it never does.** It never records against the embedded server or the
profile's local addon, and it never labels a protected addon — two separate
rules, so a bad server release cannot put a verdict on Cinemeta. It adds no
way to remove an addon: Uninstall is the same menu item it always was,
absent for a protected addon and disabled while the profile is locked,
because a wrong verdict that silently removed a working addon would be
unrecoverable. "Forget this addon's history" drops one addon's record for
when the verdict is wrong — typically right after a debrid key was
replaced, where the old key's failures describe a configuration that no
longer exists. Nothing about health is synced to the account: it measures
*this device's* network.

**What is stored** is a single `addonHealth` key in the preferences file,
under `host[:port]#<12 hex of sha256(transport URL)>`. The URL itself is
never written down — a manifest URL can carry a debrid API key — and
neither is any query string, the resource id (that would be a viewing
history), a per-request timestamp, or an error message (a transport error
can carry the URL back in its own text). The app derives the same key by
hashing the transport URL it already holds, so the URL never leaves the
profile. At most 200 addons are remembered, and an addon the profile has
not had for 30 days is dropped at start-up.

Deliberately not built: latency or "slow" verdicts (a hang becomes a
failure at the 60-second client timeout, and nothing else is claimed), any
event log or per-title history, an active prober (traffic nobody asked for,
and it tests the manifest rather than the resource), and auto-uninstall or
auto-disable — the whole ask was to *decide*.

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

To judge playback performance by numbers rather than feel, the player has a
stats OSD (like mpv's): move the mouse over the video to show it, or press
**Shift+I** (or the stats button in the top bar) to pin it on/off. It lists
output vs container FPS, dropped
frames, the **hwdec** in use (or `software` when libmpv is decoding on the
CPU), codec and resolution, video bitrate, and demuxer cache / buffering
state, sampled twice a second only while it is on screen.

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
