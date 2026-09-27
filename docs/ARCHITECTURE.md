# How the app is built

Where the Dart side and the Rust core meet, what crosses between them, and
how each part of the app works on top of that. The shape of the thing is in
the [README](../README.md#how-it-works); the rules a change has to keep are
in [AGENTS.md](../AGENTS.md); running and checking it is in
[OPERATIONS.md](OPERATIONS.md).

**Contents:**
[The bridge](#the-bridge) ·
[What crosses the bridge](#what-crosses-the-bridge) ·
[Wire conventions](#wire-conventions) ·
[The Rust side](#the-rust-side) ·
[The app's own preferences](#the-apps-own-preferences) ·
[Engine settings and the account](#engine-settings-and-the-account) ·
[The embedded server](#the-embedded-server) ·
[The player](#the-player) ·
[Subtitles](#subtitles) ·
[Downloads and offline play](#downloads-and-offline-play) ·
[Google Drive](#google-drive) ·
[The library](#the-library) ·
[Addons](#addons) ·
[Recommendations](#recommendations) ·
[Casting](#casting) ·
[Pinned forks](#pinned-forks)

## The bridge

[flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge)
2.13.0 with the cargokit backend. The codegen, the Dart package and the Rust
crate must be the exact same version (FRB refuses to start otherwise). The
crate is `rust/` (package `xtremio_core`: cdylib + staticlib, plus rlib for
its own tests); `rust_builder/` is the generated FFI-plugin glue that builds
it per platform; `lib/src/rust/` and `rust/src/frb_generated.rs` are
generated and committed. After changing anything under `rust/src/api`, run
`flutter_rust_bridge_codegen generate` and commit the result (CI fails on
drift).

The FFI surface, by file under `rust/src/api/`:

| File | Functions |
|---|---|
| `hello.rs` | `init_app` (FRB's start-up hook); `bridge_version`, `core_schema_version` (test and diagnostic only) |
| `core.rs` | `core_init`, `core_dispatch`, `core_get_state`, `core_events`, `core_shutdown`, `core_is_initialized` |
| `server.rs` | `server_start`/`stop`/`base_url` (test and diagnostic only: `core_init` starts the app's server); `server_set_background`; `server_settings`, `server_update_settings`; `server_torrent_stats`; `server_note_duration`, `server_note_player_opened`, `server_note_player_stalled`; `server_storage_report`, `server_cache_usage`, `server_clean_cache_now`; `server_background_traffic`; `server_stream_numbers`; `server_dht_status`; `server_drive_open`, `server_drive_grant`; `server_close_proxy_streams`; `server_set_lan_media`, `server_lan_media_running`, `server_lan_media_requests_served`, `server_lan_media_base_url` |
| `downloads.rs` | `downloads_add`, `downloads_remove`, `downloads_list`, `downloads_open`, `downloads_events`, `downloads_start_fresh` |
| `prefs.rs` | `prefs_get_all`, `prefs_set` |
| `subtitles.rs` | `subtitles_match` |
| `addon_health.rs` | `addon_health_report`, `addon_health_forget` |
| `diagnostics.rs` | `diagnostics_snapshot`, `diagnostics_log` |

Dart wraps them in clients (`CoreClient`, `ServerClient`, `DownloadsClient`,
`PrefsClient`, ...) handed down the tree by scopes, which is what lets
widget tests swap in the fakes in `test/support/`.

## What crosses the bridge

**State crosses as JSON.** `core_dispatch` takes a stremio-core `Action` as
JSON, `core_get_state(field)` returns one model field as JSON, and
`core_events` streams `RuntimeEvent`s (`NewState` lists the fields that
changed). Every stremio-core type already derives serde, so this costs no
per-type mirroring and survives engine upgrades; Dart keeps small view
classes (`lib/core/state/`) over the maps.

The model (`XtremioModel`, `rust/src/model.rs`) has `ctx`,
`continue_watching_preview`, `board`, `search`, `discover`, `meta_details`,
`streaming_server`, `player`, `library`, `installed_addons`,
`remote_addons` and `addon_details`; `lib/core/fields.dart` mirrors the
list.

- `ctx` serializes as `{profile, notifications, events}` only -- its
  library, streams and server-URL buckets are `#[serde(skip)]` -- so the
  Library screen reads its own `library` field
  (`LibraryWithFilters<NotRemovedFilter>`).
- Where the raw model lacks what the UI needs, `XtremioModel::snapshot` adds a
  sibling key rather than reshaping the field: `meta_details` gains
  `watchedVideoIds`, `board`/`search` gain `catalogLabels` (catalog and
  addon names resolved from the profile's manifests, aligned with
  `catalogs`).
- `board` and `search` are the one reshape. They are `GridCatalogs`, which
  do not follow the library (stremio-core marks them changed on every
  library change only because stremio-web merges library flags into the
  board), and an item crosses as what a poster tile draws -- `id`, `type`,
  `name`, `poster`, `posterShape`, `releaseInfo` (`GridItem`) -- not the
  whole `MetaItemPreview`, whose `links` were most of a 1.4 MB board.
- `core_get_state` takes an owned snapshot under the model's read lock and
  serializes after releasing it (`FieldSnapshot`), so a board pull does not
  park every dispatch behind it.

## Wire conventions

What the engine's serde shapes mean for a caller. The pinned source is the
authority; these are the ones that have bitten.

- **The envelope** is `{"field": <snake-case model field | null>, "action":
  {...}}`, and `Action` is `#[serde(tag = "action", content = "args")]`
  with every sub-enum nested the same way. `CoreActions`
  (`lib/core/actions.dart`) builds them; screens never hand-write one.
- **Routing.** `field: null` runs `Ctx` *and every field*, so a null
  `Unload` clears everything: unload per field. A `Ctx` action sent with any
  other field is silently ignored, so every `Ctx` action goes with
  `field: "ctx"`. `NewState` is emitted before the effect-produced events of
  the same update, so when `UserAuthenticated` arrives a `ctx` pull already
  has the new profile.
- **Casing is mixed.** Most of the model is camelCase, but `Event` args,
  `LibraryWithFilters.selectable.next_page` (Discover's is `nextPage`),
  `StreamUrls`, `DescriptorLoadable.transport_url` (while
  `AddonDetails.selected.transportUrl`), `LibraryItem._id/_ctime/_mtime`
  and `state.video_id` are not. Every view class is tested against recorded
  JSON for this reason.
- **Selectables carry their requests.** Discover, the library and the addon
  lists publish each filter option with the exact request that selects it,
  and the UI dispatches that verbatim.
- **Library pages are cumulative**: page N is the first N×100 items, so the
  grid replaces its list rather than appending.
- **`UpdateSettings` takes the whole `Settings` object**, which has no serde
  defaults; a map missing a key fails at dispatch as "invalid action JSON".
- **Errors** are `{"type": "API"|"Env"|"Other", "code", "message"}`, and an
  `Error` event names its `source` event. The `Other` codes the UI handles:
  3 (addon already installed), 5 (protected addon), 6 (configuration
  required), 7 (addons locked).
- **The engine does not serialize its status** (`CtxStatus`), so "signing
  in" and "syncing" are local UI state cleared by the event that ends them.

## The Rust side

**What the crate keeps between calls is one value** (`rust/src/state.rs`):
`AppState`, grouped by concern (`core`, `server`, `downloads`, `prefs`,
`addon_health`, `addon_observer`), behind the one process static there is.
`core_init` creates it (or adopts the one the event-stream subscribe made
just before), and `core_shutdown` takes the whole value out, so a second
boot starts clean. Every lock is a field inside it, never one around it, so
nothing coarse is held across the server's blocking calls. What stays a
`static` says why (`env.rs`'s `STORAGE_DIR`, the tokio runtimes and HTTP
client, `logging.rs`'s `INIT`).

**The engine runs on our `Env`** (`rust/src/env.rs`):

- reqwest + rustls, trusting Mozilla's compiled-in roots rather than the
  device store (`http_client_builder` says why: on Android the platform
  verifier parses CRLs in Java on every handshake);
- every body read under a cap, chunk by chunk (`MOST_JSON_BYTES`, 32 MiB;
  4 MiB for a subtitle), so an answer that inflates past it is abandoned;
- no error out of `fetch` or `fetch_text` carries the URL (`without_url`);
- one JSON file per storage bucket under the app-support directory, written
  temp-then-fsync-then-rename on a single-worker runtime, and a bucket
  write never lands over a newer one of the same file;
- a bucket that will not parse at boot is moved aside as
  `<key>.json.corrupt-<seconds>` and read as empty; one the disk will not
  read refuses the boot (the Dart boot screen says why) rather than start
  an anonymous profile the first persist would write over the real one. A
  failed stremio-core schema migration refuses the boot the same way;
- `core_shutdown` waits up to 5 s for queued storage writes.

## The app's own preferences

`rust/src/prefs.rs` keeps `<storage_dir>/xtremio_prefs.json`: a flat JSON
object of this device's choices, written with the same atomic write.
Deliberately not stremio-core `Settings` (the engine's, synced to the
account) and not a Dart preferences package. The FFI is `prefs_get_all()`
and `prefs_set(key, value_json)`, so a new choice costs a key and no
regenerated bindings; `PrefsClient` (`lib/core/prefs_client.dart`) reads it
once at start-up into `AppPrefs`, handed down as `PrefsScope`.

The file is forgiving and additive: a write is a read-modify-write of one
key, a key from a newer build survives it, and a file that will not parse
is moved aside (`xtremio_prefs.json.corrupt-<seconds>`) and reads as
nothing set. A file the disk will not read is an error to `prefs_get_all`
and refuses `prefs_set`, since writing one key over an unread file loses
the rest. Nothing secret goes in it.

| Key | What it holds |
|---|---|
| `streamsSectioned` | Details sources sectioned by resolution (default) rather than grouped by addon; the older `streamsFlat` is read as a fallback and never written |
| `streamsOrder` | Order inside a section: peers per megabyte (default), largest, most peers |
| `openStreamSections`, `openStreamAddons` | Which resolution sections / addon groups are open; empty means all closed on purpose |
| `bufferAhead` | How far ahead playback buffers (see [The player](#the-player)) |
| `focusEmphasis` | Settings → Interface → "Bold focus", television only |
| `shareWhileIdle` | Whether the server uploads while nothing plays; on unless turned off |
| `verboseDiagnostics` | Settings → Developer → "Verbose logging" |
| `subtitleSync`, `subtitlePicks` | What the viewer fixed about subtitle timing, and what they picked (see [Subtitles](#subtitles)) |
| `similarSuggestions` | "More like this" answers already fetched |
| `driveLinkedFiles`, `driveTokenDead`, `drivePendingSession` | Linked Drive files, a grant Google has refused, a pairing not yet collected |
| `addonHealth` | Written by the Rust side (see [docs/ADDONS.md](ADDONS.md)) |

`similarApiKey` and `similarModel`, from builds that asked a model
directly, are deleted on load.

## Engine settings and the account

**Settings are the engine's.** `ctx.profile.settings` is stremio-core's
`Settings` and the only way to change one is `UpdateSettings` with the
whole object. `ProfileSettings.withValue(key, value)`
(`lib/core/state/profile.dart`) copies the map with one key changed; every
control writes exactly that, nothing writes while `ctx` is unknown, and the
map last sent is what the next write builds on until the following pull,
so two quick changes do not revert each other. Settings are device-local
(the API's `saveUser` carries only the user record).

What the app reads: `seekTimeDuration` and `seekShortTimeDuration` (Shift +
arrow, the *short* seek), `bingeWatching`, `nextVideoNotificationDuration`
(the up-next countdown; 0 plays the next at once), `pauseOnMinimize`,
`escExitFullscreen`, `subtitlesSize` / `subtitlesTextColor` /
`subtitlesBackgroundColor` (`SubtitleStyle.fromSettings`: 32 px scaled by
the percentage, `#RRGGBBAA`, a transparent background meaning no box), and
`hardwareDecoding` (applied to the next player that opens).
`streamingServerUrl` is not offered: it is always the embedded server's.
`quitOnClose` and `hideSpoilers` are stored but not honoured; the rest pass
through untouched.

**Account.** Settings → Account dispatches `Authenticate` (`Login`, or
`Register` with the GDPR consent the API requires, `from: xtremio`) and
`Logout`, plus the housekeeping stremio-web does on window focus:
`PullAddonsFromAPI` at every start-up, and `PullUserFromAPI`,
`SyncLibraryWithAPI` and `PullNotifications` for a signed-in profile on
start-up, resume and `UserAuthenticated`. Signing in *replaces* the
anonymous library and resets the settings, and the UI says so. A failed
addon-collection fetch at login sets `addonsLocked`, which disables every
addon mutation until a pull succeeds.

## The embedded server

**In-process.** `stream_server::start` runs on its own thread and runtime.
Both its ports are ephemeral -- HTTP and BitTorrent -- so nothing collides
with a desktop Stremio. The core's `streaming_server_url` is pointed at the
address read back at every launch (`core::pin_to_embedded`), and again on
`UserAuthenticated` / `UserLoggedOut`, since login and logout reset the
settings to `http://127.0.0.1:11470/`. It is the only server the app
streams from: there is no remote-server choice, because everything the app
asks of a server goes to the embedded one over FFI.

**The control API takes a per-launch bearer token that only Rust holds.**
`ServerConfig::default()` generates it; every non-media route -- exactly the
handful stremio-core calls (`/settings`, `/network-info`, `/device-info`,
`/get-https`, `/casting`, `/create`, `/{infoHash}/create`,
`/{infoHash}/{fileIdx}/stats.json`) -- answers 401 without it. stremio-core
reaches the server only through `Env::fetch`, which adds the header when
the request's scheme, host and effective port are the embedded server's
(`server::token_for`). The media routes libmpv fetches
(`/{infoHash}/{fileIdx}`, the archive routes, `/proxy`, `/drive/stream`,
`/downloads/{key}/stream`) and the `/local-addon` stubs stay open.

Everything the app asks is a `ServerHandle` call over FFI (the table in
[The bridge](#the-bridge)), wrapped by `ServerClient`
(`lib/core/server_client.dart`). The app's one write to the server's
settings is `server_update_settings` -- what `POST /settings` runs.

**In the background it goes lean, unless something needs its peers.**
stream-server's `ServerHandle::set_background` (`server_set_background`)
keeps every torrent running on a few peers instead of the configured limit
and prunes the peer tables -- the share of a backgrounded server's memory
measured to be both the largest and still growing, on a television whose
low-memory killer takes the fattest background process first.
`ServerFootprint` (`lib/shell/server_footprint.dart`) sends it lean when the
app is hidden or paused and full when it resumes, and keeps it full while a
download is on its way (unfinished and not in error, the foreground
service's own test), a cast session is up, or the LAN media listener runs --
it stands in front of that listener as the tree's `LanMediaControl`, which
is how it hears the listener stop. Any of those ending while the app is away
sends the server lean then.

**Idle sharing is one settings key.** The server keeps uploading after
playback when its `seedingEnabled` is true; false chokes the whole session
while no player reads (one `set_upload_enabled` on the backend: nothing is
paused, no peer dropped, downloads untouched). Since an unpinned engine
nothing streams is removed five minutes after going idle whatever the
setting says, what the switch really decides is whether those minutes
upload. `IdleSharingPolicy` (`lib/features/sharing/idle_sharing.dart`)
decides the value from the viewer's `shareWhileIdle` alone -- on by
default everywhere; nothing asks what the connection costs -- pushes only
changes, serialized, and holds it false for the run after "Not now"
(`pauseUntilRestart`, which only a switch that is on can take).

**The status light says what is happening, never what is configured.**
`SharingLight` (`lib/features/sharing/sharing_light.dart`) is drawn in the
shell's top right while the server says bytes moved to or from peers with
no player reading (`server_background_traffic`, a peek that creates no
engine, polled every five seconds by `SharingActivityMonitor` only while the
shell's own route is current). One slot, three glyphs: up while
uploading, down while downloading, `swap_vert` for both. Pressed, it offers
a stop for what is lit, and only rows that do something: the sharing rows
("Not now", "Stop sharing", or a sentence when the switch is already off or
paused), and one "Cancel <name>" per offline download on its way
(`DownloadsClient.remove` with its files, the only stop a pin has). The
placement is pinned on every shell screen by
`test/features/sharing_light_placement_test.dart`.

## The player

**Playback goes through the engine's `Player` model.** The UI dispatches
`Load Player` with the raw stream JSON plus the stream and meta requests;
stremio-core publishes `player.stream` as `{StreamUrls, converted stream}`,
whose `streaming_url` is the direct URL for a `url` stream and
`<server>/{infoHash}/{fileIdx}?tr=…` for a torrent (the server creates the
engine on first GET). The player opens that in media_kit/libmpv and reports
`TimeChanged` / `PausedChanged` / `Ended` back so the library follows.
`PlaybackEngine` (`lib/features/player/playback_engine.dart`) is the thin
interface over media_kit; widget tests swap in `FakePlaybackEngine` through
`PlaybackScope`.

### Streams, the proxy and the cache

**Every stream reaches mpv as a URL on our own server.** A torrent already
is one; anything on another host -- a debrid link, an addon's HTTP URL -- is
wrapped in the server's `/proxy` route (`lib/core/stream_proxy.dart`): the
target's origin percent-encoded into a `d=` segment, its own path and query
after it, so a signed link keeps its signature and the file name stays
visible. The base comes from `CoreInitInfo`, settled before the first
`open`. A loopback URL (already the server, including a kept download's) is
left alone. `force-seekable` is set only for the server's own torrent
routes, never for `/proxy`.

**How far ahead to buffer is the viewer's choice**, sent as
`?buffer=normal|large|maximum` on a torrent URL (`withBufferAhead`,
`lib/core/buffer_ahead.dart`): 90 s, four minutes, or a day of the film at
its own bitrate. Seconds need the film's length, which the player reports
(`server_note_duration`); until then every profile reads ahead the same
small fallback, so start-up is equally fast. Settings → Player → "Buffer
ahead" is the standing choice; the player's own sheet overrides it for the
playback on screen, re-opening the stream at its position. **"Download the
whole file"** pins the stream as an offline download while it plays; a
device that cannot fit it is told the numbers and keeps buffering.

**There is one cache on the device and it is the server's.** The player is
started with `cache-on-disk=no` and never writes it again: media_kit's
default creates a file mpv unlinks at once, invisible to every instrument
and to the server's budget. The server's cache has named files, a limit
(`min(cacheSize, occupied + available - floor)`, the floor being
`enginefs::free_space_floor`), and owners that give back what nobody plays
or kept. `/proxy` caches by byte range under the same retention as a
torrent's pieces, so a backward seek inside the window is local.

**What the player holds is memory, deliberately small.**
`MediaKitEngine.memoryCacheBytes` (32 MiB ahead) and `backCacheBytes`
(8 MiB behind, one ten-second press back up to about 6.7 Mbps); the
reasoning is on the constants. A seek outside is a range request answered
from the server's cache. A television has 2 GB of RAM for everything, and
the cushion belongs in the server's bounded cache.

**A player that is left ends its own reads.** Each player screen mints a
token (`player-1`, ...), writes it into its `/proxy` URLs as `p=`, and on
the way out calls `server_close_proxy_streams` (`ProxyStreamControl`): the
server ends those reads and answers `410 Gone` to the token afterwards, so
ffmpeg's reconnect cannot revive them. The token is a name, not a
credential: the route is on the loopback control API only, and the token is
stripped before the origin is asked.

### Archives and disc images

Some sources serve a container rather than the film: a debrid `.rar`, a
torrent whose one file is a `.zip` or an ISO. When a stream fails before it
loads, the player reads its start and names the container by signature
(`lib/features/player/archive_sniff.dart`: RAR, ZIP, 7-Zip, ISO 9660), then
hands it to the server, which serves the member as ranges of the container
-- nothing extracted, nothing written (`docs/design/translated-sources.md`
in stream-server). `lib/features/player/archive_route.dart` is that half: for a
stream on another host, `POST /{rar|zip|7zip|iso}/create` with the `/proxy`
URL the engine was handed, then `GET /{fmt}/stream/{key}`, whose redirect
names the member; for a torrent file, `GET
/{fmt}/stream/torrent:<info hash>/<file name>` with no create. The member URL
(`_translatedUrl`) stands in front of the core's URL at every later `open`,
while `_opened` stays what the core published; it is also what a cast sends
(see [CASTING.md](CASTING.md)).

A container that cannot be played is said honestly: the server answers
`415` (`compressed`, `encrypted`, `solid`, `noRandomAccess`,
`unsupported`), `422` (`malformed`) or `501` (`noRanges`, `noReader`), and
`archiveRefusal` shows the app's wording or the server's sentence where it
names something concrete. `noReader` names a cargo feature and so is never
shown. Addon-declared archives (`rarUrls`/`zipUrls`) are untouched by this:
stremio-core builds their `/create` URL itself.

### Leaving the player

Every way out goes through `PlayerScreen._leave`, in one order: `_detach`,
send `quit`, close the proxied streams, await the teardown with the video
still in the tree, then pop.

- **`_detach` first** ends every subscription, listener and timer before the
  first `await`. Waiting with the screen up is a state the handlers were not
  written for: media_kit's own `stop` pushes a position of zero, which
  reaches the core as a `TimeChanged` and resets continue-watching. Input
  stands down too (keys swallowed, hovers refused, the fade timer not
  re-armed).
- **`_stillOurs`** (`mounted && !_leaving`) is what every continuation that
  can reach the engine, the core, the cast client or the navigator asks --
  `mounted` is true during the wait, so it no longer answers that question.
  A continuation that already started something unwinds it.
  `test/features/player/player_leaving_awaits_test.dart` lists them.
- **`quit` is the kill**, sent asynchronously on media_kit's handle
  (`PlaybackEngine.quit`), never `mpv_terminate_destroy`. Sent first, it is
  ahead of media_kit's `stop` on mpv's queue; measured, a teardown behind it
  returns in 92-230 ms even against a wedged socket. A refused command is
  thrown, not discarded.
- **`PlayerScreen.teardownBound`** (2 s) bounds the viewer's wait, not the
  teardown: past it the screen pops, the teardown continues, and a line is
  logged (another if a late one lands). It is kept as the instrument for
  the one unexplained failure: a player on a Chromecast that kept
  downloading after its screen was left.

### Seeking

mpv's seek is exact (`hr-seek=yes`), which on a 32-bit box decoding through
`mediacodec-copy` is a visible stall per press. So every press that says
*further on* -- seek keys, a remote's transport keys, the buttons beside
play, a double tap, the focused seek bar's left and right -- is
`PlaybackEngine.scanBy`, `seek <n> relative+keyframes`. Relative matters: a
keyframe seek to an absolute target lands on the keyframe *before* it, so
a step shorter than the keyframe gap would go backwards. A tap or drag on
the bar, and Shift + arrow (the short step), are exact. A held key
accelerates (`SeekHold`): ten presses at `seekTimeDuration`, fifteen at
twice it, then five times it; a fresh press starts again at one.

### Controls and keys

`PlayerScreen` switches media_kit's controls off and draws its own: a top
bar (back, title, next episode, subtitles, audio, stats, settings) and a
bottom bar (seek bar with the buffered range and drag scrubbing,
play/pause, ± the seek step, time, volume on wide layouts, fullscreen). The
controls fade after 3 s while playing and stay while paused or buffering.
On a television they fade whatever holds focus, taking focus back to the
video; Back comes down a ladder (up-next card, then an OSD that can fade,
then the player). Subtitles sit 4.5 % of the picture above the bottom and
are lifted clear of the bar while it is up, measured off the laid-out bar
and pushed with `VideoState.setSubtitleViewPadding`.

Keyboard: Space/K play-pause, ←/→ or J/L the seek step, Shift+←/→ the short
step, ↑/↓ volume, M mute, F fullscreen, Esc (leaves fullscreen first when
`escExitFullscreen` is on), S subtitles, Shift+S subtitle timing, A audio, N
next episode, Shift+I stats. The remote's keys are in
[ANDROID.md](ANDROID.md#driving-it-with-the-remote).

### Torrent start-up and stalls

From `open` until the media loads, a torrent shows a card instead of a
spinner: the screen polls `server_torrent_stats` every 500 ms
(`TorrentStatsRequest.forStream`: `infoHash`, `fileIdx` and the `announce`
list, falling back to torrent-level stats) and maps the server's `phase` to
words -- fetching metadata, checking existing data (with a percentage),
finding peers (with the discovery counts), buffering the window the reader
waits for, starting playback, or the server's error. **A window inside one
piece is said in pieces**, from `inFlightPiece`: "Waiting for piece 137, 6.3
of 16.0 MiB…", with three rules each tested -- full is not finished (the bar
holds until `verified`), it never runs backwards (a failed hash is
discarded silently), and null is not zero (the older wording over an
indeterminate bar). A failed open while the torrent is still resolving,
checking or buffering is retried behind the card.

When a started playback runs dry, a torrent gets the same card
(`torrent_stall_overlay.dart`), polled every 2 s, in the present tense, and
always with the speed and the swarm, zeros included. The swarm line
(`TorrentProgressCard.formatSwarm`) is our live connections, then the
tracker-scraped seeds and swarm size; a scrape that never answered leaves
those out rather than printing 0.

**An engine error is not a failed playback.** media_kit turns mpv's error
log lines into `errors` events, so "Playback failed" is shown only until the
file has loaded (a duration or a position past zero); after that an error is
a log line, and what gives up is a false end of file (re-opened) or a
position that stands still. An addon subtitle mpv could not fetch is passed
over by the auto-pick, the previous selection is restored, and the viewer is
told for six seconds.

**Next episode.** `player.nextVideo`/`nextStream` come from the core. On
`Ended` with `bingeWatching` on, an up-next card counts down
`nextVideoNotificationDuration` (35 s by default); playing it dispatches
`NextVideo` and either replaces the route with a player for `nextStream`
(skipping its own `Unload`, so the session's subtitle preference survives)
or pops with a `PlayerScreenResult` so Details loads that episode's streams.
A finished download of the next episode, then a linked Drive file of it, is
preferred to the core's own next stream.

## Subtitles

The rules are in [AGENTS.md](../AGENTS.md#nothing-re-times-a-subtitle-but-the-viewer);
this is how the feature works and why.

**Why nothing is automatic.** A subtitle cut for 25 fps played against a
23.976 fps film drifts about four seconds a minute, and OpenSubtitles says
which rate an upload was cut for (`fpsMilli`, on about nine entries in ten).
But the claim is about the release, not the timing: ten English files for
one film declaring six different rates all end within 1 % of the same
runtime, while five Gilmore Girls files at 25 fps really do run 4.27 %
short. Nothing in the metadata separates the two populations, so anything
applied unasked fixes one and silently breaks the other. The declared rate
decides nothing; libmpv's `container-fps` is read only for the display (see
[ANDROID.md](ANDROID.md#telling-the-television-what-rate-the-film-is)).

### The menu

After the media opens the screen dispatches `VideoParamsChanged` with the
best filename it knows (the stream's `behaviorHints.filename`, else a URL
segment that looks like one), which is what makes the core ask the subtitle
addons. The menu lists the tracks in the file first, then every addon file
from `player.subtitles`, the stream's `subtitles` and the converted
stream's, **one row per language** (`groupSubtitlesByLanguage`,
`lib/features/player/subtitle_groups.dart`), sorted on the language's
printed name, with "N other <language> files" as a sibling row beneath (a
sibling, so a remote reaches it moving down). Files are deduplicated on what
they are (`SubtitleInfo.identityKeys`: the normalized URL with no query
parameter removed, and the addon's `id` scoped by language). A file is named
by the addon plus the best thing it offers -- its `label`, release group,
cleaned `subtitleFileName`, `movieReleaseName`, then `Option N` -- with a
position suffix where two names collide, run through `wellFormedText` and cut
to 60 characters.

**Inside a language the order is the release.** `subtitlesByRelease` puts
first the files whose `releaseGroup` or `movieReleaseName` names the video
playing, then files from a group the viewer already adjusted for this series
(the correction goes back on when applied, and the rank asks
`SubtitleSyncMemory` exactly what applying will ask), then the addons'
order. `subtitleMatchesRelease` compares both sides as lower-case runs of
letters and digits, extension stripped, and the claim must be a contiguous
run of whole tokens: `DFN` never claims a DFNX rip, tokens scattered across
the name do not count, a lone number or two-letter tag does not count, and a
release *name* must reach past the front of the filename -- against a real
OpenSubtitles answer, eleven of twelve "matches" claimed only the show,
episode and title that every upload carries. A match earns two words on the
row (`SubtitleMenu.releaseNote`); a rate is never shown.

**At most two languages are lifted** under a heading of their own: the ones
this viewer picks most (`SubtitlePickMemory.pinned`, a language counted
`pinThreshold` times and offered by this episode). They are lifted, not
copied; a winner the file itself carries takes its slot with no row, and a
slot that lifts nothing is not handed to the next language
(`test/features/player/subtitle_pins_test.dart`). A pinned row cannot move
under a finger, since counts change only on a pick and a pick closes the
sheet.

**Which track is active** comes from mpv's own `sid`/`aid`, so a default
track mpv chose shows as selected. A pick dispatches
`SubtitlePreferenceChanged`, which the core keeps for the session; the next
episode's player applies it to the first matching file once loaded, out of
the same ordered list (`PlayerScreen._offeredSubtitles`). Text subtitles are
drawn by Flutter (media_kit's `libass: false`), so size, colour and box are a
`TextStyle`; bitmap subtitles (PGS, VobSub) are listed but not drawn.

### Adjusting timing

**Adjust timing** is the last entry of the subtitle menu while a subtitle
is showing (Shift+S opens it directly). The panel is not part of the OSD:
the bar fades while it stays, it has its own focus scope and Back rung on
every device, every control wears the focus ring, and it scrolls in the
height it gets (a 360 dp phone held sideways leaves it under 300).

- **Shift** is a stepper on `sub-delay` in 0.1 s presses, counted in whole
  presses so ten forward and ten back land at zero. A hold accelerates
  through ten steps of a tenth, fifteen of a second, then five-second
  strides (`SubtitleTimingOverlay.shiftStrideAt`), because the offsets span
  three orders of magnitude -- an uncorrected PAL file is 115 s out by the
  end of an episode.
- **Speed** is shown and cannot be pressed: it is only ever measured, and
  the number is the one thing on screen that tells a subtitle right now
  from one right for the next ten minutes.
- **Reset** returns to 1.0 and 0.0 and discards the marks.

Every path that changes what is on screen -- another file, an embedded
track, subtitles off, the next video, the auto-pick restoring the tracks
after a refusal -- goes through `PlayerScreen._resetSubtitleTiming`, which
replaces the whole `SubtitleTiming` with what is remembered for the file
going on screen, or untouched. Both values are re-applied after a re-open,
the addon file first (a re-open is a fresh `loadfile`, and nothing
`sub-add` put in survives one). A pick from the menu or a press on the panel
stops the session preference's auto-pick for that media
(`_subtitlesChosenByHand`).

### Matching against another subtitle

"Match to another subtitle" solves for the ratio and offset mapping the
playing file onto one the viewer says keeps time (`rust/src/subtitles.rs`,
`subtitles_match`; `SubtitleMatchClient` in
`lib/features/player/subtitle_match.dart`). Rust fetches both and turns
each into a bitmap of **when it has text on screen**, from both timestamps
of every cue. Comparing cue starts instead fails when a translator merges
lines: a Swedish Gilmore Girls file has 690 cues against the English 1024,
only 54 % of its starts within a third of a second. A bitmap does not mind
merged lines.

- **One damaged cue does not decide the length.** `cue_spans` drops a cue
  reaching further past the body of the file than a tenth of it or ten
  minutes, with a six-hour stop for a file with no body (a stretched
  timeline dilutes chance, and a huge one is an allocation that aborts).
- **Overlapping cues are one lit interval** (`Bitmap::of` takes the union),
  and a bin is lit when text covers at least half of it.
- **The score is overlap above chance**: `(dice - chance) / (1 - chance)`,
  chance from the two files' densities, since subtitles cover about two
  thirds of an episode and unrelated files already overlap heavily.
- **`CONVINCING` is 0.45, measured.** Over 39,000 pairings of 717 real
  files (forty titles, thirty-seven languages), pairings whose transform is
  right have a fifth percentile of 0.54 and a median of 0.81; the best of
  30,918 mismatches reaches 0.376. The populations overlap, so the line is
  drawn above the mismatches and refuses about one real pairing in fifty
  (files with very different on-screen shares, where Dice's ceiling holds
  the score down -- a scoring problem, not a threshold one).
  `rust/tests/subtitle_threshold.rs` records the corpus and the cost of each
  neighbouring threshold, and its guard tests pin the constant.
- **The search** covers rates 0.90 to 1.10 (PAL is 4.27 % away), coarse to
  fine: a second per bin over the whole window, then 100 ms and 20 ms near
  the winner, with the ratio step derived from the file's length.
- **A refusal says what was found**, the score and the transform. Fewer than
  fifty cues on either side (`FEWEST_CUES`) is a different answer, naming
  both counts and carrying no score.
- **The reference is always the viewer's pick**, from a sheet shaped like
  the menu, and the option is not drawn with nothing to pick. A subtitle URL
  is never quoted back (`fetch_text` strips it). An answer that lands after
  the subtitle changed is dropped.

### Marks

For a language with one file, or several sharing the same bad timing, a
match has nothing to measure against. **This is right** records where the
line on screen belongs: the cue's own time in the file (libmpv's
`sub-start`, which is the raw time -- measured against libmpv 0.41.0 with a
real transform applied, and written down at
`MediaKitEngine.subtitleCueStart`) paired with the video position the cue is
drawn at under the transform in force, never the instant of the press,
which is a reaction time. One mark changes nothing: the viewer already put
the line there. Two at least two minutes apart give the line through both,
so the rate; a mark within half a minute of another replaces it, and the
pair used is the two furthest apart (`SubtitleCalibration`,
`lib/features/player/subtitle_calibration.dart`). The panel says which of
offset or rate was learnt. Marks belong to the file that was playing and go
with it; only what they derive is kept.

### What is remembered

**Timing** (`SubtitleSyncMemory`, `lib/core/subtitle_sync.dart`, the
`subtitleSync` preference) stores a multiplier and an offset in seconds.
A *speed* is keyed on the series and the lower-cased `releaseGroup`, since
what a file was timed against belongs to where it came from and releases of
one show share a frame rate. Never the addon's `g`: measured over 506 real
answers it is a per-answer cluster index (one Swedish batch reads `g=6, 5,
4, 1` across four episodes), and rows keyed on it are dropped. A *shift* is
keyed on the video release too (the whole filename from `castFilename`),
because an offset depends on both sides' pre-roll. A key part nobody can
name means nothing is remembered; Reset forgets; the store is bounded by
recency. Only a press on the panel writes (`_adjustTiming`), and the write
waits (`_pendingSync`) until the adjusting ends, since a held key repeats
eight times a second and overlapping `prefsSet` calls land in no order.
`PlayerScreen._rememberedSpeed` checks a stored multiplier against mpv's
`0.1-10.0`, because media_kit discards the property write's return code.

**Picks** (`SubtitlePickMemory`, `lib/core/subtitle_picks.dart`, the
`subtitlePicks` preference) keep one row per show -- the language as the
menu prints it, the release group of the file picked where there was one,
or Off -- and a count per language for the pins. The engine's own
`subtitle_preference` is session state cleared by `Unload`, so on a fresh
start the row is what the auto-pick falls back to: a file of the remembered
group preferred, else the head of the language, and nothing at all for a
language the episode does not offer or a show never watched. Only a pick by
hand writes, and a preference synthesized from the row is never dispatched.
Counts halve when their total passes a ceiling, so they follow a changing
taste without going stale while the app is closed.

## Downloads and offline play

**A download is a pin plus a registry.** The server keeps the chosen file
wanted and un-evictable (`ServerHandle::pin_download`) -- a retention
property, not a location. `rust/src/downloads.rs` keeps what the server
does not know in `<storage_dir>/downloads.json`, keyed
`"{metaId}:{videoId}"`: the raw stream JSON `Load Player` takes back, a
`MetaItem` snapshot so Details renders offline, the stream and meta
requests, and `createdAt`/`completedAt`/`lastPlayedAt`. The UI reaches it
through one `DownloadsClient` (`lib/core/downloads_client.dart`) and
`DownloadView` (`lib/core/state/download.dart`).

- **Progress** is merged from the server's `downloads()`, never stored twice.
  `downloads_events` ticks about once a second while something is
  unfinished and pushes only the rows that moved, and of each only
  `{key, downloaded, size, state, path, error, completedAt}`.
- **A second stream for a title** replaces the entry and releases the pin it
  replaces, unless another entry names the same file (the server's pins are
  a set with no reference count, so that removal answers `unpinned:
  false`).
- **A stream with no `fileIdx`** (or `-1`) is resolved the way the media
  route resolves `/{infoHash}/-1`, so what is kept is the file that
  streamed.
- **A refused pin** comes back as `{"ok":false,"error":{"kind":…}}`;
  `insufficientSpace` carries the byte counts, since a full disk is
  something to show.
- **Links and Drive files** are downloads too: the row's key is the
  server's 64-hex cache key (`proxy_download_key`), and a Drive download is
  filled with the grant the Rust side holds.
- **Reading is forgiving, never at the cost of what is on disk.** Unknown
  keys and unparseable entries are kept and still named in the pin set the
  launch hands the server; a file that is not this build's shape at all is
  `registryUnreadable`, the server is told nothing and keeps everything, and
  only the user's `downloads_start_fresh` moves it aside.
- **At boot** every unfinished entry is pinned again on a blocking thread,
  and `reconcile_pins` marks a finished row the server does not hold as
  `gone` ("Not on this device"), without re-pinning it.

**A finished download plays off this device, and there is no file.**
Torrent data is one file per piece, so the `path` the server reports is a
name. `downloads_open(key)` answers the server's own media route
(`{base}/{infoHash}/{fileIdx}`), or the `playUrl` it reports for a link or
Drive download (`/downloads/{key}/stream`), and stamps `lastPlayedAt` -- but
only when the row says `complete` *and* the server says it holds the file
whole now. Otherwise it refuses: `unknown`, `incomplete`, `unavailable` (no
server) or `notHeld`. Details and the Downloads screen hand the player that
URL as a plain `url` stream (`lib/features/downloads/offline_play.dart`),
with the *original* stream and meta requests, which is what keeps
continue-watching moving offline. The kept copy wins over the addon's
stream only for the release that was downloaded, and binge-advance asks the
same of the next episode, so a downloaded season plays through offline.

*Known consequence:* the synthesized `url` stream becomes that video's
persisted last stream. stremio-core resolves it against the addon's answers
by source (a `Url` never matches a `Torrent`) and then by binge group, which
is why `offlineStream` keeps `behaviorHints.bingeGroup`; for an addon that
sets none, "Continue with last source" disappears after an offline play
until the title is played from an addon again, and the next play starts
with no remembered subtitle or audio track.

**Android keeps a download going while the app is away** with a `dataSync`
foreground service (`DownloadsForegroundService`,
`lib/features/downloads/downloads_service.dart`); see
[ANDROID.md](ANDROID.md#downloads-while-the-app-is-away).

### Where torrent data lives

Everything a torrent puts on the device is under the server's `cacheRoot`:
the piece store the streaming cache and kept downloads share
(`<cacheRoot>/rqbit-downloads/.pieces/<infoHash>/<bucket>/<piece>`), the
session's records, and the proxy cache. There is no downloads folder and
nothing to move a download to.

- **Its default** is the directory the app hands `server_start`
  (`XtremioBootstrap.dataDirectory`, `lib/main.dart`): the app cache
  directory everywhere but Android, and on Android the app-specific external
  files directory, since `getCacheDir()` is the system's to reclaim.
- **Its setting** is `cacheRoot`, written through `server_update_settings`
  from Settings → Server storage
  (`lib/features/diagnostics/server_storage_screen.dart`). The server
  validates it (absolute, created, writable, stored resolved), a persisted
  value outranks the default for ever, and a change takes effect at the next
  start; nothing already there is moved.
- **An upgraded Android install** whose persisted root is inside the app
  cache directory is moved once at boot (`moveOffPurgeableRoot`), comparing
  resolved paths, because the server fills its own default only when the key
  is empty. Everywhere else it writes nothing.

Storage costs and cleaning are in
[OPERATIONS.md](OPERATIONS.md#where-torrent-data-lives-and-what-it-costs).

## Google Drive

Drive is a source of files the viewer owns: they are linked once and then
appear as sources, in the library, as downloads and in the player.

**Pairing** needs a client secret a sideloaded app cannot hold, so the
[xtremio-xervice](../xtremio-xervice/README.md) Firebase service at
`https://xtremio-xervice.web.app` does the two things that need it:
exchanging an authorization code and refreshing an access token.
`DrivePairingScreen` (`lib/features/drive/drive_pairing_screen.dart`) asks
for a session (`lib/core/drive_pairing.dart`):

- a **television** draws the link as a QR for a phone to open;
- a **phone or desktop** opens it itself; a phone asks for a hand-back, so
  the pick page ends by navigating to `stremio:///pair`, which brings the app
  forward and is otherwise dropped (see [DEEP_LINKS.md](DEEP_LINKS.md));
- a **phone with this app installed** that opens a television's link gets it
  as a verified app link and picks with Android's own picker
  (`drive_native_pair_screen.dart`, `lib/core/drive_native_pick.dart`),
  because the web Picker cannot select more than one file on a device with
  no keyboard.

Collecting a session is destructive -- the service deletes it as it answers
-- so a collected answer is never retried. The collecting is the account's
job rather than the screen's (`lib/core/drive_pairing_job.dart`), and the
session id is written down (`drivePendingSession`) so a pairing that
reached the service is collected when the library next opens, even after
the app was killed.

**The account** (`DriveAccount`, `lib/core/drive_account.dart`) is one
refresh token and a list. The token is kept in `SecretStore`; on Linux that
needs a running keyring, and without one a pairing lasts the run
(`DriveLinkOutcome.thisRunOnly`). The linked files -- ids, names, mime types
-- are the `driveLinkedFiles` preference (`lib/core/drive_link.dart`). The
list is what to show, not a set of grants: `drive.file` grants accumulate
per user and client, so one token reaches every file ever picked, and there
is no unlinking one file. When the service answers `pairAgain`, that is
stored (`driveTokenDead`) and every screen asks for a fresh pairing.
**Reload** asks Drive what the files are called now
(`lib/core/drive_listing.dart`), and only a complete listing writes -- a
partial one deletes nothing.

**Matching** a file to a title uses its name alone
(`lib/features/drive/drive_match.dart`): a loose title plus a strict check,
since a real poster for the wrong film is worse than none. A matched file
is listed as a source on that title's details screen as an
`xtremio-drive:<fileId>` row (`lib/core/drive_source.dart`) that nothing
ever fetches; an unmatched one is played from the library's Remote list.

**Playback.** `server_drive_open(file_id, refresh_token, name)` opens the
file as a `DriveSource` in the server and answers `{ok, url, name?,
contentType, length}` or `{ok: false, reason}`; the URL is
`http://127.0.0.1:<port>/drive/stream/<random key>`, an open media route
carrying no credential. The grant is an in-process argument, which is why
this is not an HTTP request. `openLinkedDriveFile`
(`lib/core/drive_playback.dart`) turns `pairAgain` into
`DriveAccount.notePairAgain`, and the player gets a hand-built stream
(`driveStreamJson`) named after the file, with the name in
`behaviorHints.filename` for the cast check.

**Tracking.** A Drive play of a known title is loaded with a stream request,
because stremio-core writes the resume position, the watched mark and
Continue Watching only when the selection has one. `driveStreamRequest`
names this app's own service, `https://xtremio-xervice.web.app/manifest.json`
-- a truthful manifest offering no streams, every `stream/...` a static
`{"streams":[]}` cached a day -- rather than crediting an installed addon.
Addon health skips it (`is_own_stub`). The player finds a linked Drive file
of the next episode itself. A Drive download stores the request, and an
older row without one gets it at play time
(`DownloadsScreen.streamRequestOf`). An unmatched file plays with none.

## The library

The Library screen (`lib/features/library/library_screen.dart`) is the
engine's `library` field -- type pills and sorts from `selectable`, each
dispatched verbatim, cumulative pages, per-item remove, mark watched,
rewind and notifications -- plus two things the engine knows nothing about,
merged into the list and never written to the engine's library or synced:

- **Downloaded titles** appear whether or not they were added, one card per
  title the grid has no card for, of the selected type, once the engine has
  no page left to send (`_kept`).
- **Matched linked Drive files** appear the same way (`_appended`); files
  that matched nothing appear under All and Other.

**Downloaded** and **Remote** are filter chips on a row under the types, and
they filter whatever the engine answered: they combine with the type pills
and the sort, dispatch nothing, and are not turned off by the engine's
controls. Remote shows everything linked, matched or not, with a Reload
button beside it. The app bar holds the way to the Downloads screen and
`RemoteFilesButton`, where files are linked from. One matching pass runs
per screen (`DriveMatchRun`). Tests: `test/features/library_merge_test.dart`,
`library_remote_test.dart`, `library_screen_test.dart`.

## Addons

The Addons screen (Settings → Addons, or "Browse addons" on an empty board)
reads `installed_addons` (`InstalledAddonsWithFilters`) and `remote_addons`
(`CatalogWithFilters<Descriptor>` over an `addon_catalog` resource); whether
a community entry is installed is computed from `ctx.profile.addons` by
manifest URL. "Add addon" and every tile open `AddonDetailsScreen`, which
loads `addon_details` for one manifest URL and offers Install, Update
(`UpgradeAddon` when versions differ), Uninstall (never for a protected
addon) and Configure (the manifest URL with `manifest.json` → `configure`,
opened through `url_launcher` behind `ExternalLinkScope`). A
`configurationRequired` manifest cannot be installed, so Configure is its
primary action; `profile.addonsLocked` disables every mutation behind a
banner. How each addon has been answering, and the verdict drawn from it,
is [docs/ADDONS.md](ADDONS.md); installing from a web page is
[docs/DEEP_LINKS.md](DEEP_LINKS.md).

## Recommendations

"More like this" is a row of posters on a title (`similar_row.dart`),
filled from the xtremio-xervice function at `GET
https://xtremio-xervice.web.app/similar/{type}/{id}`
(`lib/features/similar/xtremio_similar_titles.dart`). The function holds the
owner's Gemini key, builds the question from Cinemeta's name and year for
the id, and keeps the first answer for a title for everybody; the app holds
no key and sends nothing but a type and an id. Only `movie` and `series` are
asked. `more_like_this.dart` is the order: the answer this install already
has (`SimilarMemory`, the `similarSuggestions` preference, kept for the
life of the install per question version), else the server, then the guard.
**The guard is where correctness lives** (`similar_resolver.dart`): a model
invents titles, and a catalogue search for an invented one succeeds with a
different film, so a suggestion is kept only when a catalogue answers with
the same title and a year within one. Nothing in this path throws; every
failure is an empty row. Which model is asked, and how that was measured, is
[tool/recommendations/README.md](../tool/recommendations/README.md).

## Casting

The cast button, what it hands a receiver untouched, the LAN media listener
and every rule it refuses on are in [CASTING.md](CASTING.md).

## Pinned forks

`rust/Cargo.toml` pins every git dependency to a rev, with the reason beside
it; read the current revs there.

| Dependency | Pinned to | Why |
|---|---|---|
| `stream-server` (package `server`, and its `enginefs`) | [`zond/stream-server`](https://github.com/zond/stream-server) | The server this app embeds. It keeps no record of what is pinned and is told at start (`ServerConfig::pins`) from this app's downloads registry. Default features are on, which is RAR support -- see [the README](../README.md#license). |
| `librqbit` | [`zond/rqbit`](https://github.com/zond/rqbit) | A dev-dependency only, for the real `.torrent` fixtures in `rust/tests/downloads.rs`. Always the rev stream-server's `enginefs` uses, or two librqbits end up in the graph: bump the two together. |
| `stremio-core` | [`zond/stremio-core`](https://github.com/zond/stremio-core) | Upstream plus one commit that keeps a subtitle's addon-specific fields (`fpsMilli`, `subtitleFileName`, `releaseGroup`, …) in a flattened `other` map instead of letting serde drop them (upstream PR Stremio/stremio-core#1045), one that pins its `localsearch` dependency by rev, and one that relaxes `stremio-watched-bitfield`'s `flate2 = "1.0.*"` to `"1"` -- stream-server's tree needs flate2 ≥ 1.1 and Cargo will not pick two 1.x versions, so without it the graph does not resolve. Built with the `derive` + `env-future-send` features. |

To bump one: change the rev, `cargo update -p <crate>`, run `cargo test`,
and re-record any fixture whose shape moved. A stremio-core bump has to
keep the fork's `flate2` relaxation. Beside those, `flutter_rust_bridge` is
exactly 2.13.0 in `pubspec.yaml`, `rust/Cargo.toml` and the codegen.
