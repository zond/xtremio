# How the app is built

Where the Dart side and the Rust core meet, what crosses between them, and
how each part of the app works on top of that. The shape of the thing is in
the [README](../README.md#how-it-works). The rules a change has to keep are
in [AGENTS.md](../AGENTS.md). Running and checking it is in
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
[Local videos](#local-videos) ·
[Addons](#addons) ·
[Recommendations](#recommendations) ·
[Ratings](#ratings) ·
[What xervice keeps for an account](#what-xervice-keeps-for-an-account) ·
[Casting](#casting) ·
[Pinned forks](#pinned-forks)

## The bridge

[flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge)
2.13.0 with the cargokit backend. The codegen, the Dart package and the Rust
crate must be the exact same version (FRB refuses to start otherwise). The
crate is `rust/` (package `xtremio_core`: cdylib + staticlib, plus rlib for
its own tests). `rust_builder/` is the generated FFI-plugin glue that builds
it per platform. `lib/src/rust/` and `rust/src/frb_generated.rs` are
generated and committed. Run `flutter_rust_bridge_codegen generate` after
changing anything under `rust/src/api`, and commit the result (CI fails on
drift).

The FFI surface, by file under `rust/src/api/`:

| File | Functions |
|---|---|
| `hello.rs` | `init_app` (FRB's start-up hook); `bridge_version`, `core_schema_version` (test and diagnostic only) |
| `core.rs` | `core_init`, `core_dispatch`, `core_get_state`, `core_events`, `core_shutdown`, `core_is_initialized` |
| `server.rs` | `server_start`/`stop`/`base_url` (test and diagnostic only: `core_init` starts the app's server); `server_set_background`, `server_set_idle_sharing_held`; `server_settings`, `server_update_settings`; `server_torrent_stats`; `server_note_duration`, `server_note_player_opened`, `server_note_player_stalled` and `server_stream_numbers` (for a stream played by its URL; one played by id uses `media.rs`'s); `server_storage_report`, `server_cache_usage`, `server_clean_cache_now`, `server_clear_cache`; `server_background_traffic`; `server_dht_status`, `server_port_forwarding_status`; `server_drive_open`, `server_drive_grant`; `server_close_proxy_streams`, `server_release_player`; `server_set_lan_media`, `server_lan_media_running`, `server_lan_media_requests_served`, `server_lan_media_bodies_served`, `server_lan_media_base_url` |
| `media.rs` | `media_register`, `media_register_drive`, `media_register_local_path`, `media_register_local_fd`, `media_resolve`; `media_set_play`, `media_set_buffer`, `media_set_resume`, `media_note_position`; `media_note_duration`, `media_note_player_opened`, `media_note_player_stalled`, `media_read_wait`, `media_stream_numbers`; `mpv_stream_register`; for a cast, `media_publish`, `media_publish_rendition`, `media_prepare_rendition`, `media_rendition_readiness`, `media_renditions_available`, `media_cast_numbers`, `media_unpublish` ([CASTING.md](CASTING.md)) |
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
per-type mirroring and survives engine upgrades. Dart keeps small view
classes (`lib/core/state/`) over the maps.

The model (`XtremioModel`, `rust/src/model.rs`) has `ctx`,
`continue_watching_preview`, `board`, `search`, `discover`,
`meta_details`, `streaming_server`, `player`, `library`,
`installed_addons`, `remote_addons` and `addon_details`.
`lib/core/fields.dart` mirrors the list. `board` is stremio-core's name for
the model behind Discover's rows (`CatalogsWithExtra`), of one type or all.
`discover` is the one catalog Discover opens.

- `ctx` serializes as `{profile, notifications, events}` only. Its
  library, streams and server-URL buckets are `#[serde(skip)]`, so the
  Library screen reads its own `library` field
  (`LibraryWithFilters<NotRemovedFilter>`).
- `XtremioModel::snapshot` adds a sibling key where the raw model lacks
  what the UI needs, rather than reshaping the field: `meta_details` gains
  `watchedVideoIds` and `rememberedStream` (see
  [The last stream, when its addon fails](#the-last-stream-when-its-addon-fails)),
  `board`/`search` gain `catalogLabels` (catalog and
  addon names resolved from the profile's manifests, aligned with
  `catalogs`).
- `board` and `search` are the one reshape. They are `GridCatalogs`, which
  do not follow the library. (stremio-core marks them changed on every
  library change only because stremio-web merges library flags into the
  board.) An item crosses as what a poster tile draws (`GridItem`: `id`,
  `type`, `name`, `poster`, `posterShape`, `releaseInfo`), not the whole
  `MetaItemPreview`, whose `links` were most of a 1.4 MB board.
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
  the same update, so a `ctx` pull already has the new profile when
  `UserAuthenticated` arrives.
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
  defaults. A map missing a key fails at dispatch as "invalid action JSON".
- **Errors** are `{"type": "API"|"Env"|"Other", "code", "message"}`, and an
  `Error` event names its `source` event. The `Other` codes the UI handles:
  3 (addon already installed), 5 (protected addon), 6 (configuration
  required), 7 (addons locked).
- **The engine does not serialize its status** (`CtxStatus`), so "signing
  in" and "syncing" are local UI state cleared by the event that ends them.

## The Rust side

**What the crate keeps between calls is one value** (`rust/src/state.rs`):
`AppState`, grouped by concern (`core`, `server`, `downloads`,
`addon_health`, `addon_observer`, `media`), behind the one process static
there is.
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
  `<key>.json.corrupt-<seconds>` and read as empty. One the disk will not
  read refuses the boot, and the Dart boot screen says why. Starting an
  anonymous profile instead would let the first persist write over the
  real one. A failed stremio-core schema migration refuses the boot the
  same way;
- `core_shutdown` waits up to 5 s for queued storage writes.

## The app's own preferences

`rust/src/prefs.rs` keeps `<storage_dir>/xtremio_prefs.json`: a flat JSON
object of this device's choices, written with the same atomic write. It is
deliberately not stremio-core `Settings` (the engine's, synced to the
account) and not a Dart preferences package. The FFI is `prefs_get_all()`
and `prefs_set(key, value_json)`, so a new choice costs a key and no
regenerated bindings. `PrefsClient` (`lib/core/prefs_client.dart`) reads
the file once at start-up into `AppPrefs`, handed down as `PrefsScope`.

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
| `titleRatings` | A title's scores already fetched (see [Ratings](#ratings)) |
| `driveLinkedFiles`, `driveTokenDead`, `drivePendingSession` | Linked Drive files, a grant Google has refused, a pairing not yet collected |
| `localMedia`, `localFolders`, `localFolderBookmarks` | The videos on this device and what each matched, a desktop's folders, and macOS's bookmarks for them (see [Local videos](#local-videos)) |
| `detailsVisits` | Which season and episode each title's details screen was left on |
| `viewerId` | This install's name for its viewer, the first half of every player token (`p=<viewer>.<screen>`) |
| `updateCheckedAt`, `updateSkippedTag` | When the app last asked GitHub for its latest release, and the tag "Skip this version" was pressed for |
| `addonHealth` | Written by the Rust side (see [docs/ADDONS.md](ADDONS.md)) |

`similarApiKey` and `similarModel`, from builds that asked a model
directly, are deleted on load.

## Engine settings and the account

**Settings are the engine's.** `ctx.profile.settings` is stremio-core's
`Settings` and the only way to change one is `UpdateSettings` with the
whole object. `ProfileSettings.withValue(key, value)`
(`lib/core/state/profile.dart`) copies the map with one key changed, and
every control writes exactly that. Nothing writes while `ctx` is unknown.
The next write builds on the map last sent until the following pull, so
two quick changes do not revert each other. Settings are device-local
(the API's `saveUser` carries only the user record).

What the app reads: `seekTimeDuration` and `seekShortTimeDuration` (Shift +
arrow, the *short* seek), `bingeWatching`, `nextVideoNotificationDuration`
(the up-next countdown; 0 plays the next at once), `pauseOnMinimize`,
`escExitFullscreen`, `subtitlesSize` / `subtitlesTextColor` /
`subtitlesBackgroundColor` (`SubtitleStyle.fromSettings`: 32 px scaled by
the percentage, `#RRGGBBAA`, a transparent background meaning no box), and
`hardwareDecoding` (applied to the next player that opens).
`streamingServerUrl` is not offered: it is always the embedded server's.
`quitOnClose` and `hideSpoilers` are stored but not honoured. The rest pass
through untouched.

**Account.** Settings → Account dispatches `Authenticate` (`Login`, or
`Register` with the GDPR consent the API requires, `from: xtremio`) and
`Logout`. It also does the housekeeping stremio-web does on window focus:
`PullAddonsFromAPI` at every start-up, and `PullUserFromAPI`,
`SyncLibraryWithAPI` and `PullNotifications` for a signed-in profile on
start-up, resume and `UserAuthenticated`. Signing in *replaces* the
anonymous library and resets the settings, and the UI says so. A failed
addon-collection fetch at login sets `addonsLocked`, which disables every
addon mutation until a pull succeeds.

## The embedded server

**In-process.** `stream_server::start` runs on its own thread and runtime.
Both its ports, HTTP and BitTorrent, are ephemeral, so nothing collides
with a desktop Stremio. The core's `streaming_server_url` is pointed at the
address read back at every launch (`core::pin_to_embedded`), and again on
`UserAuthenticated` / `UserLoggedOut`, since login and logout reset the
settings to `http://127.0.0.1:11470/`. It is the only server the app
streams from: there is no remote-server choice, because everything the app
asks of a server goes to the embedded one over FFI.

**The control API takes a per-launch bearer token that only Rust holds.**
`ServerConfig::default()` generates it. Every non-media route answers 401
without it. Those routes are exactly the handful stremio-core calls
(`/settings`, `/network-info`, `/device-info`, `/get-https`, `/casting`,
`/create`, `/{infoHash}/create`, `/{infoHash}/{fileIdx}/stats.json`). stremio-core
reaches the server only through `Env::fetch`, which adds the header when
the request's scheme, host and effective port are the embedded server's
(`server::token_for`). The media routes (`/{infoHash}/{fileIdx}`, the
archive routes, `/proxy`, `/drive/stream`, `/downloads/{key}/stream`) and
the `/local-addon` stubs stay open. libmpv reads every stream by media id
instead. It fetches only the `/proxy` of an origin that will not range, and
the routes the server serves by URL alone.

Everything the app asks is a `ServerHandle` call over FFI (the table in
[The bridge](#the-bridge)), wrapped by `ServerClient`
(`lib/core/server_client.dart`). The app's one write to the server's
settings is `server_update_settings`, which is what `POST /settings` runs.

**In the background it goes lean, unless something needs its peers.**
stream-server's `ServerHandle::set_background` (`server_set_background`)
keeps every torrent running on a few peers instead of the configured limit,
and prunes the peer tables. The peer tables were measured as the largest
share of a backgrounded server's memory, and still growing, on a television
whose low-memory killer takes the fattest background process first.
`ServerFootprint` (`lib/shell/server_footprint.dart`) sends it lean when the
app is hidden or paused, and full when it resumes. It keeps it full while a
download is on its way (unfinished and not in error, the foreground
service's own test), a cast session is up, or the LAN media listener runs.
It stands in front of that listener as the tree's `LanMediaControl`, which
is how it hears the listener stop. Any of those ending while the app is away
sends the server lean then.

**Idle sharing is one settings key and one hold.** The server's upload
switch is one for the whole session: one `set_upload_enabled` on the
backend, so nothing is paused, no peer dropped, downloads untouched. It is
on while a player reads and while a torrent download is on its way,
whatever the app says, since downloading is activity, not idling. The app
decides the rest: whether the kept downloads and the last thing the viewer
watched go on uploading when nothing is happening. The last thing watched
is the server's idle share from leaving it until something else plays.
Its torrent runs only while that sharing is allowed (8ce5427). That
decision is `seedingEnabled`. `IdleSharingPolicy`
(`lib/features/sharing/idle_sharing.dart`) makes it from the viewer's
`shareWhileIdle`, which is on by default everywhere; nothing asks what the
connection costs. The policy pushes only changes, serialized. It holds the
switch false for the run after "Not now" (`pauseUntilRestart`, which only
a switch that is on can take). On a phone or a tablet
(`DeviceProfile.isHandheld`: not a television, and a touchscreen), the
policy also tells the server to hold the idle sharing off while the app is
in the background (`server_set_idle_sharing_held`, never persisted). The
same lifecycle listener as `ServerFootprint` feeds it, and it lets go on
resume. A download on its way goes on sharing while held. A television and
a desktop are never held. The settings tile says so on the devices it
applies to.

**The status light says what is happening, never what is configured.**
`SharingLight` (`lib/features/sharing/sharing_light.dart`) is drawn in the
shell's top right while the server says bytes moved to or from peers with
no player reading. That answer is `server_background_traffic`, a peek that
creates no engine, polled every five seconds by `SharingActivityMonitor`
only while the shell's own route is current. On a television the light
sits at the right end of the band across the top of Discover, Search and
the Library, which have no app bar there (`_Destination.barlessOnTv`).
One slot, three glyphs: up while
uploading, down while downloading, `swap_vert` for both. Pressed, it offers
a stop for what is lit, and only rows that do something: the sharing rows
("Not now", "Stop sharing", or a sentence when the switch is already off or
paused), and one "Cancel <name>" per offline download on its way
(`DownloadsClient.remove` with its files, the only stop a pin has). The
placement is pinned on every shell screen by
`test/features/sharing_light_placement_test.dart`.

## The player

**Playback goes through the engine's `Player` model.** The UI dispatches
`Load Player` with the raw stream JSON plus the stream and meta requests.
stremio-core publishes `player.stream` as `{StreamUrls, converted stream}`,
whose `streaming_url` is the direct URL for a `url` stream and
`<server>/{infoHash}/{fileIdx}?tr=…` for a torrent (the server creates the
engine on first GET). The player opens that in media_kit/libmpv and reports
`TimeChanged` / `PausedChanged` / `Ended` back so the library follows.
`PlaybackEngine` (`lib/features/player/playback_engine.dart`) is the thin
interface over media_kit. Widget tests swap in `FakePlaybackEngine` through
`PlaybackScope`.

### Where the picture goes

**A film is drawn one of two ways** (`VideoOutput`,
`lib/features/player/video_output.dart`).

- **The texture**, media_kit's way and the only one off Android. mpv draws
  each frame with OpenGL into a texture, and Flutter draws that texture into
  the app's picture. It shows every codec, at the cost of two GPU passes over
  every pixel of every frame, and HDR is converted to SDR.
- **The surface**, what Android uses whenever hardware decoding is on
  (`surfaceAllowed`). MediaCodec decodes straight into a
  `SurfaceView` of its own (`VideoSurface.kt`, `video_surface.dart`, mpv's
  `vo=mediacodec_embed`), shown through hybrid composition. The display
  hardware shows the film at the panel's resolution, the GPU does nothing per
  frame, and an HDR10 or HLG film reaches the display as HDR. On a Galaxy Tab
  S9 FE with a 4K HDR10 film the GPU went from 59-62% busy to 0%, and the
  layer was `BT2020_ITU_PQ` with its HDR metadata. It has played 4K films on
  a phone and on a television, from a torrent and from Real-Debrid.

**The surface shows only what MediaCodec decodes**, so a film is placed on it
by rules, all in `video_output.dart` and pinned by `video_output_test.dart`.
A player on the surface starts with no video output and no video decoding
(`surfaceStartOverrides`). Started with nowhere to draw, MediaCodec fails at
init and the player reads that as a failed open. Once mpv's track list names
the codec, a codec mpv sends to MediaCodec (`surfaceCodecs`, the same list as
`hwdec-codecs`) goes to the surface, and anything else to the texture. If the
decoder still ends up in software (`hwdec-current` says `no`), the film moves
to the texture. With hardware decoding off, every film goes to the texture.

**The surface is attached in media_kit's own order** (`surfaceAttach`: `vo`
off, size, `wid`, `vo` on, `vid` again, then a seek to where it was) and
taken off whenever it goes away (`surfaceDetach`), the app going to the
background included. Subtitle text on the surface is drawn by `SubtitleLines`,
which matches media_kit's own subtitle view. Picture subtitles are not drawn
on either output.

**The screen stays on while a film plays, on either output.**
`ScreenAwakeWhilePlaying` (`screen_awake.dart`) wraps both outputs and follows
mpv's play and pause. The surface builds no media_kit `Video`, and the
texture's `Video` is built with its own hold off, so the flag has one owner.

### Streams, the proxy and the cache

**Every stream reaches mpv as a media id, `xtremio://<id>`.** The player
registers what it was handed with the embedded server (`MediaIds`,
`lib/core/media_ids.dart`). What it was handed is one of these:

- a URL on the server as the core built it (a torrent, a `/proxy` link, an
  archive's `/create`, a kept torrent download: `media_register`);
- a link on another host, wrapped in the server's `/proxy` first;
- a linked Drive file, by its `xtremio-drive:<fileId>`
  (`media_register_drive`);
- a file on this device, by its path (`media_register_local_path`);
- an Android `content://` document, by a descriptor the
  `xtremio/local_media` channel opens and detaches (`openFd` →
  `media_register_local_fd`).

The player then records the play the reads are, its player token and
buffer (`media_set_play`). It has the server resolve the id
(`media_resolve`) before mpv is handed it. Resolving waits for a magnet's
metadata, probes a link, renews a Drive grant and reads the head for a
container, and an open inside mpv cannot be cancelled. libmpv reads the id
through a protocol registered on each player's handle
(`mpv_stream_register`, `rust/src/mpv_stream.rs`, over libmpv's
`stream_cb` API). Its callbacks are the server's blocking `MediaReader` on
mpv's own threads: no HTTP, no URL of the server's. media_kit carries
one vendored change for it (`third_party/media_kit/PATCHES.md`). Stream
numbers and the duration, opened and stalled hints go by id too
(stream-server `docs/design/media-pipeline.md` §2.4-2.5). An id the server
let go is registered again once.

**Two kinds of stream are still a URL.** An origin that will not serve
ranges (a live playlist) resolves `inProcess: false`, and mpv is handed the
`/proxy` URL the server answers with and reads it forward. A route the
server serves but names no id for yet (`/ftp`, YouTube) is refused
`notYet`/`unrecognisedUrl` and handed to mpv as it is. `force-seekable` is
set for `xtremio://` and the server's own loopback routes, never for
`/proxy`. With no embedded server at all, the stream is played as the core
published it.

**How far ahead to buffer is the viewer's choice**, `normal`, `large` or
`maximum`, carried with the play (`media_set_play`): 90 s, four minutes, or
a day of the film at its own bitrate. Seconds need the film's length,
which the player reports (`media_note_duration`). Until then every profile
reads ahead the same small fallback, so start-up is equally fast. Settings
→ Player → "Buffer ahead" is the standing choice. The player's own sheet
overrides it for the playback on screen. The override is told to the
server by id (`media_set_buffer`), and the reader takes it at its next
seek without re-opening anything. **"Download the whole file"** pins the
stream as an offline download while it plays. A device that cannot fit it
is told the numbers and keeps buffering.

**There is one cache on the device and it is the server's.** The player is
started with `cache-on-disk=no` and never writes it again: media_kit's
default creates a file mpv unlinks at once, invisible to every instrument
and to the server's budget. The server's cache has named files, a limit
(`min(cacheSize, occupied + available - floor)`, the floor being
`enginefs::free_space_floor`), and owners that give back what nobody plays
or kept. `/proxy` caches by byte range under the same retention as a
torrent's pieces, so a backward seek inside the window is local.

**What the player holds is memory, deliberately small.** It holds
`MediaKitEngine.memoryCacheBytes` (32 MiB ahead) and `backCacheBytes`
(8 MiB behind, one ten-second press back up to about 6.7 Mbps). The
reasoning is on the constants. A seek outside is a range request answered
from the server's cache. A television has 2 GB of RAM for everything, and
the cushion belongs in the server's bounded cache.

**A player that is left ends its own reads, and lets go of its torrent.**
A read by id ends with the quit, which cancels mpv's `stream_cb` read. A
link read forward over HTTP carries the player screen's token
(`<viewer>.<screen>`) in its `/proxy` URL as `p=`. On the way out the
screen calls `server_close_proxy_streams` (`ProxyStreamControl`). The
server ends those reads and answers `410 Gone` to the token afterwards, so
ffmpeg's reconnect cannot revive them. The token is a name, not a
credential: the route is on the loopback control API only, and the token
is stripped before the origin is asked. The server holds a screen's
torrent from its first read until the screen says it is gone
(`server_release_player`, `ProxyStreamControl.releasePlayer`). It holds it
while the screen is paused, stalled or has nothing open, since only the
app knows when it stops using it. A cast published from the screen holds
the torrent on its own until unpublished.

### Archives and disc images

Some sources serve a container rather than the film: a debrid `.rar`, a
torrent whose one file is a `.zip` or an ISO. **The server finds out when it
resolves the id.** It reads the head of the file for a container signature.
On a hit, it indexes the container and resolves the id to the member the
archive routes' rule picks (`Resolved.member`; stream-server
`docs/design/media-pipeline.md` §2.9). mpv reads the member as ranges of
the container, with nothing extracted and nothing written. So mpv's report,
which is what the cast check judges, is about the film and not the
container. The player keeps the member's name
(`MediaResolution.memberName`), so a member is never handed to a receiver
as the link it came in (see [CASTING.md](CASTING.md)).
Addon-declared archives (`rarUrls`/`zipUrls`) come as stremio-core's own
`/create` URL, which registers as an id the same way.

A container that cannot be played is the server's refusal, with its
sentence (`compressed`, `encrypted`, `solid`, `noRandomAccess`,
`unsupported`, `malformed`, `noRanges`, `noReader`), shown as the playback's
failure. A head that did not arrive within the server's bound is answered
as the plain file (`sniffed: false`), which then fails in mpv like any file
it cannot read.

### Leaving the player

Every way out goes through `PlayerScreen._leave`, in one order: report the
position (to the core, and to the server by `media_note_position`),
`_detach`, send `quit`, close the proxied streams, release the screen's
torrent, await the teardown with the video still in the tree, then pop.

- **`_detach` first** ends every subscription, listener and timer before the
  first `await`. Waiting with the screen up is a state the handlers were not
  written for: media_kit's own `stop` pushes a position of zero, which
  reaches the core as a `TimeChanged` and resets continue-watching. Input
  stands down too (keys swallowed, hovers refused, the fade timer not
  re-armed).
- **`_stillOurs`** (`mounted && !_leaving`) is what every continuation asks
  that can reach the engine, the core, the cast client or the navigator.
  `mounted` is true during the wait, so it no longer answers that question.
  A continuation that already started something unwinds it.
  `test/features/player/player_leaving_awaits_test.dart` lists them.
- **`quit` is the kill**, sent asynchronously on media_kit's handle
  (`PlaybackEngine.quit`), never `mpv_terminate_destroy`. Sent first, it is
  ahead of media_kit's `stop` on mpv's queue. A teardown behind it was
  measured to return in 92-230 ms, even against a wedged socket. A refused
  command is thrown, not discarded.
- **`PlayerScreen.teardownBound`** (2 s) bounds the viewer's wait, not the
  teardown: past it the screen pops, the teardown continues, and a line is
  logged (another if a late one lands). It is kept as the instrument for
  the one unexplained failure: a player on a Chromecast that kept
  downloading after its screen was left.

### Seeking

mpv's seek is exact (`hr-seek=yes`), which on a 32-bit box decoding through
`mediacodec-copy` is a visible stall per press. So every press that says
*further on* is `PlaybackEngine.scanBy`, `seek <n> relative+keyframes`:
seek keys, a remote's transport keys, the buttons beside play, a double
tap, the focused seek bar's left and right. Relative matters: a
keyframe seek to an absolute target lands on the keyframe *before* it, so
a step shorter than the keyframe gap would go backwards. A tap or drag on
the bar, and Shift + arrow (the short step), are exact. A held key
accelerates (`SeekHold`): ten presses at `seekTimeDuration`, fifteen at
twice it, then five times it. A fresh press starts again at one.

### Controls and keys

`PlayerScreen` switches media_kit's controls off and draws its own: a top
bar (back, title, cast, next episode, subtitles, audio, stats, settings)
and a bottom bar (seek bar with the buffered range and drag scrubbing,
play/pause, ± the seek step, time, volume on wide layouts, fullscreen). The
controls fade after 3 s while playing and stay while paused or buffering.
On a television they fade whatever holds focus, taking focus back to the
video. Back comes down a ladder (up-next card, then an OSD that can fade,
then the player). Subtitles sit 4.5 % of the picture above the bottom and
are lifted clear of the bar while it is up. The lift is measured off the
laid-out bar and pushed with `VideoState.setSubtitleViewPadding`.

Keyboard: Space/K play-pause, ←/→ or J/L the seek step, Shift+←/→ the short
step, ↑/↓ volume, M mute, F fullscreen, Esc (leaves fullscreen first when
`escExitFullscreen` is on), S subtitles, Shift+S subtitle timing, A audio, N
next episode, Shift+I stats. The remote's keys are in
[ANDROID.md](ANDROID.md#driving-it-with-the-remote).

On the picture, a mouse click plays or pauses at once and a double-click
also toggles fullscreen (its two clicks toggle playback twice, so it ends
where it was). A click calls off the up-next card while it counts down. A
touch tap shows or hides the controls instead, and a double tap on the left
or right third skips the seek step.

### Torrent start-up and stalls

A torrent shows a card instead of a spinner from `open` until the media
loads. The screen polls `server_torrent_stats` every 500 ms
(`TorrentStatsRequest.forStream`: `infoHash`, `fileIdx` and the `announce`
list, falling back to torrent-level stats). It maps the server's `phase` to
words: fetching metadata, checking existing data (with a percentage),
finding peers (with the discovery counts), buffering the window the reader
waits for, starting playback, or the server's error. **A window inside one
piece is said in pieces**, from `inFlightPiece`: "Waiting for piece 137, 6.3
of 16.0 MiB…". Three rules hold it, each tested: full is not finished (the
bar holds until `verified`), it never runs backwards (a failed hash is
discarded silently), and null is not zero (the older wording over an
indeterminate bar). A failed open while the torrent is still resolving,
checking or buffering is retried behind the card.

When a started playback runs dry, a torrent gets the same card
(`torrent_stall_overlay.dart`), polled every 2 s, in the present tense, and
always with the speed and the swarm, zeros included. The swarm line
(`TorrentProgressCard.formatSwarm`) is our live connections, then the
tracker-scraped seeds and swarm size. A scrape that never answered leaves
those out rather than printing 0.

**The card also comes from the server's word that a read is parked.** mpv
blocked in a `stream_cb` read reports no stall and no cache to wait for.
The picture just stops: after the head, in the container index, at the
resume point. The player asks `media_read_wait` every 500 ms for a torrent
played by id, once the media has loaded. The card is up while a read has
waited a second, the picture has been still since the last ask, and mpv
says it plays. It comes down at the first ask that finds reads flowing, or
the moment film moves. A position standing still with every read answered
is logged ("the position has not moved…"), not called a wait for the
torrent. Only a stream with no media id still shows the card from that
guess.

**A resumed torrent asks for its resume point early.** The player tells the
server where it resumes and the length the last playback reported
(`media_set_resume`, beside `media_set_play`), and where the viewer left it
(`media_note_position`, on leaving). The server asks the swarm for the
region around the resume point when mpv opens the file, beside the head.
Both are needed before the first frame, so their waits should not add up.
The region is placed by where the last session ended when that is near the
resume time, and by the resume time's share of the file otherwise. It is
asked for from there outward, 16 MiB at a time (stream-server's
`docs/design/media-pipeline.md` §2.11).

**An engine error is not a failed playback.** media_kit turns mpv's error
log lines into `errors` events, so "Playback failed" is shown only until the
file has loaded (a duration or a position past zero). After that an error
is a log line. A false end of file is re-opened where it stopped, at once
and then after a growing wait capped at ten seconds. A torrent still
starting, or a magnet whose metadata did not come, is opened again on the
same backoff. **Nothing gives up on a stream whose bytes have not come**:
a dead swarm waits under the start-up and stall cards until the viewer
leaves. Only an answer is a failure: a refusal that says the stream cannot
be played, or a torrent that is ready and still will not open. An addon
subtitle mpv could not fetch is passed over by the auto-pick, the previous
selection is restored, and the viewer is told for six seconds.

**Next episode.** `player.nextVideo`/`nextStream` come from the core. An
up-next card counts down `nextVideoNotificationDuration` (35 s by default)
on `Ended` with `bingeWatching` on. Playing it dispatches `NextVideo` and
either replaces the route with a player for `nextStream`
(skipping its own `Unload`, so the session's subtitle preference survives)
or pops with a `PlayerScreenResult` so Details loads that episode's streams.
A finished download of the next episode, then a video on this device
matched to it, then a linked Drive file of it, is preferred to the core's
own next stream (`player_screen_next.dart`).

## Subtitles

The rules are in [AGENTS.md](../AGENTS.md#nothing-re-times-a-subtitle-but-the-viewer).
This is how the feature works and why.

**Why nothing is automatic.** A subtitle cut for 25 fps played against a
23.976 fps film drifts about four seconds a minute, and OpenSubtitles says
which rate an upload was cut for (`fpsMilli`, on about nine entries in ten).
But the claim is about the release, not the timing: ten English files for
one film declaring six different rates all end within 1 % of the same
runtime, while five Gilmore Girls files at 25 fps really do run 4.27 %
short. Nothing in the metadata separates the two populations, so anything
applied unasked fixes one and silently breaks the other. The declared rate
decides nothing. libmpv's `container-fps` is read only for the display (see
[ANDROID.md](ANDROID.md#telling-the-television-what-rate-the-film-is)).

### The menu

After the media opens the screen dispatches `VideoParamsChanged` with the
best filename it knows (the stream's `behaviorHints.filename`, else a URL
segment that looks like one), which is what makes the core ask the subtitle
addons. The menu lists the tracks in the file first, then every addon file
from `player.subtitles`, the stream's `subtitles` and the converted
stream's. It has **one row per language** (`groupSubtitlesByLanguage`,
`lib/features/player/subtitle_groups.dart`), sorted on the language's
printed name. "N other <language> files" is a sibling row beneath, so a
remote reaches it moving down. Files are deduplicated on what they are
(`SubtitleInfo.identityKeys`: the normalized URL with no query parameter
removed, and the addon's `id` scoped by language). A file is named by the
addon plus the best thing it offers: its `label`, release group, cleaned
`subtitleFileName`, `movieReleaseName`, then `Option N`. A position
suffix tells two colliding names apart. The name is run through
`wellFormedText` and cut to 60 characters.

**Inside a language the order is the release.** `subtitlesByRelease` puts
first the files whose `releaseGroup` or `movieReleaseName` names the video
playing, then files from a group the viewer already adjusted for this series
(the correction goes back on when applied, and the rank asks
`SubtitleSyncMemory` exactly what applying will ask), then the addons'
order. `subtitleMatchesRelease` compares both sides as lower-case runs of
letters and digits, extension stripped, and the claim must be a contiguous
run of whole tokens: `DFN` never claims a DFNX rip, tokens scattered across
the name do not count, a lone number or two-letter tag does not count, and a
release *name* must reach past the front of the filename. Against a real
OpenSubtitles answer, eleven of twelve "matches" claimed only the show,
episode and title that every upload carries. A match earns two words on the
row (`SubtitleMenu.releaseNote`); a rate is never shown.

**At most two languages are lifted** under a heading of their own: the ones
this viewer picks most (`SubtitlePickMemory.pinned`, a language counted
`pinThreshold` times and offered by this episode). They are lifted, not
copied. A winner the file itself carries takes its slot with no row. A
slot that lifts nothing is not handed to the next language
(`test/features/player/subtitle_pins_test.dart`). A pinned row cannot move
under a finger, since counts change only on a pick and a pick closes the
sheet.

**Which track is active** comes from mpv's own `sid`/`aid`, so a default
track mpv chose shows as selected. A pick dispatches
`SubtitlePreferenceChanged`, which the core keeps for the session. The next
episode's player applies it to the first matching file once loaded, out of
the same ordered list (`PlayerScreen._offeredSubtitles`). Text subtitles are
drawn by Flutter (media_kit's `libass: false`), so size, colour and box are a
`TextStyle`. Bitmap subtitles (PGS, VobSub) are listed but not drawn.

### Adjusting timing

**Adjust timing** is the entry under **Off** in the subtitle menu while a
subtitle is showing (Shift+S opens it directly). The menu always opens with
the remote on Off, its top row, whatever is ticked further down. The panel
is not part of the OSD: the bar fades while it stays, it has its own focus
scope and Back rung on every device, every control wears the focus ring,
and it scrolls in the height it gets (a 360 dp phone held sideways leaves
it under 300). It sits over the picture being judged, so it is kept short:
Reset shares the header with Close, and the read-only speed row is as tall
as its text. Its ground is black at 70 %.

- **Shift** is a stepper on `sub-delay` in 0.1 s presses, counted in whole
  presses so ten forward and ten back land at zero. A hold accelerates
  through ten steps of a tenth, fifteen of a second, then five-second
  strides (`SubtitleTimingOverlay.shiftStrideAt`), because the offsets span
  three orders of magnitude. An uncorrected PAL file is 115 s out by the
  end of an episode.
- **Speed** is shown and cannot be pressed: it is only ever measured, and
  the number is the one thing on screen that tells a subtitle right now
  from one right for the next ten minutes.
- **Reset**, in the header beside Close, returns to 1.0 and 0.0 and
  discards the marks.

Every path that changes what is on screen goes through
`PlayerScreen._resetSubtitleTiming`: another file, an embedded track,
subtitles off, the next video, the auto-pick restoring the tracks after a
refusal. It replaces the whole `SubtitleTiming` with what is remembered for
the file going on screen, or untouched. Both values are re-applied after a re-open,
the addon file first (a re-open is a fresh `loadfile`, and nothing
`sub-add` put in survives one). A pick from the menu or a press on the panel
stops the session preference's auto-pick for that media
(`SubtitleAutoPick.byHand`).

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
  right have a fifth percentile of 0.54 and a median of 0.81. The best of
  30,918 mismatches reaches 0.376. The populations overlap, so the line is
  drawn above the mismatches and refuses about one real pairing in fifty.
  Those are files with very different on-screen shares, where Dice's
  ceiling holds the score down: a scoring problem, not a threshold one.
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

A match has nothing to measure against for a language with one file, or
several sharing the same bad timing. **This is right** records where the
line on screen belongs. It pairs the cue's own time in the file with the
video position the cue is drawn at under the transform in force. It never
uses the instant of the press, which is a reaction time. The cue's own time
is libmpv's `sub-start`, which is the raw time. That was measured against
libmpv 0.41.0 with a real transform applied, and is written down at
`MediaKitEngine.subtitleCueStart`. One mark changes nothing: the viewer
already put the line there. Two marks at least two minutes apart give the
line through both, and so the rate. A mark within half a minute of another
replaces it. The pair used is the two furthest apart (`SubtitleCalibration`,
`lib/features/player/subtitle_calibration.dart`). The panel says which of
offset or rate was learnt. Marks belong to the file that was playing and go
with it. Only what they derive is kept.

### What is remembered

**Timing** (`SubtitleSyncMemory`, `lib/core/subtitle_sync.dart`, the
`subtitleSync` preference) stores a multiplier and an offset in seconds.
A *speed* is keyed on the series and the lower-cased `releaseGroup`, since
what a file was timed against belongs to where it came from and releases of
one show share a frame rate. It is never keyed on the addon's `g`, which is
a per-answer cluster index, measured over 506 real answers (one Swedish
batch reads `g=6, 5, 4, 1` across four episodes). Rows keyed on it are
dropped. A *shift* is
keyed on the video release too (the whole filename from `castFilename`),
because an offset depends on both sides' pre-roll. A key part nobody can
name means nothing is remembered. Reset forgets. The store is bounded by
recency. Only a press on the panel writes (`_adjustTiming`), and the write
waits (`_pendingSync`) until the adjusting ends, since a held key repeats
eight times a second and overlapping `prefsSet` calls land in no order.
`PlayerScreen._rememberedSpeed` checks a stored multiplier against mpv's
`0.1-10.0`, because media_kit discards the property write's return code.

**Picks** (`SubtitlePickMemory`, `lib/core/subtitle_picks.dart`, the
`subtitlePicks` preference) keep one row per show and a count per language
for the pins. The row holds the language as the menu prints it and the
release group of the file picked where there was one, or Off. The engine's
own `subtitle_preference` is session state cleared by `Unload`, so the row
is what the auto-pick falls back to on a fresh start. It prefers a file of
the remembered group, else the head of the language. It picks nothing at
all for a language the episode does not offer or a show never watched. The
best candidate in so far goes up at once and is **upgraded as addons
answer**. Every answer runs the pick again, and a strictly better one
replaces what is on screen. `_subtitleRank` ranks a file of the remembered
group first, then any file of the language, then the video's own track as
a stopgap. For a show watched on its track the order is the other way
round. It settles once nothing can
beat what is up or every addon has answered, and a pick by hand ends it.
Only a pick by hand writes, and a preference synthesized from the row is
never dispatched.
The menu lifts the two languages picked most often ("You usually pick"),
among those this episode offers, once one has been picked by hand at least
`SubtitlePickMemory.pinThreshold` (2) times. Counts halve when their total
passes a ceiling, so they follow a changing taste without going stale while
the app is closed.

## Downloads and offline play

**A download is a pin plus a registry.** The server keeps the chosen file
wanted and un-evictable (`ServerHandle::pin_download`). That is a retention
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
- **A refused pin** comes back as `{"ok":false,"error":{"kind":…}}`.
  `insufficientSpace` carries the byte counts, since a full disk is
  something to show.
- **Links and Drive files** are downloads too: the row's key is the
  server's 64-hex cache key (`proxy_download_key`), and a Drive download is
  filled with the grant the Rust side holds.
- **Reading is forgiving, never at the cost of what is on disk.** Unknown
  keys and unparseable entries are kept and still named in the pin set the
  launch hands the server. A file that is not this build's shape at all is
  `registryUnreadable`. Then the server is told nothing and keeps
  everything, and only the user's `downloads_start_fresh` moves the file
  aside.
- **At boot** every unfinished entry is pinned again on a blocking thread,
  and `reconcile_pins` marks a finished row the server does not hold as
  `gone` ("Not on this device"), without re-pinning it.

**A finished download plays off this device, and there is no file.**
Torrent data is one file per piece, so the `path` the server reports is a
name. `downloads_open(key)` answers what the download is of: the server's
own media route (`{base}/{infoHash}/{fileIdx}`) for a torrent, or the link
or `xtremio-drive:<fileId>` for a link or Drive download. The player
registers that as a media id, and the server resolves it off the disk
before it asks any origin. `downloads_open` also stamps `lastPlayedAt`. It
does both only when the row says `complete` *and* the server says it holds
the file whole now. Otherwise it refuses: `unknown`, `incomplete`,
`unavailable` (no server) or `notHeld`. Details and the Downloads screen
hand the player that URL as a plain `url` stream, with the *original*
stream and meta requests. Those requests are what keep continue-watching
moving offline. `lib/features/downloads/offline_play.dart` builds the
stream and carries a link's `proxyHeaders` along, since the server keys a
link's download on its headers too. The kept copy wins over the addon's
stream only for the release that was downloaded, and binge-advance asks the
same of the next episode, so a downloaded season plays through offline.

*Known consequence:* the synthesized `url` stream becomes that video's
persisted last stream. stremio-core resolves it against the addon's answers
by source (a `Url` never matches a `Torrent`) and then by binge group, which
is why `offlineStream` keeps `behaviorHints.bingeGroup`. When the addon sets
none, "Continue with last stream" disappears after an offline play until
the title is played from an addon again.

**What a download is doing** comes from one `DownloadDetailPoller`
(`lib/features/downloads/download_detail.dart`), built in `XtremioApp` and
handed down through `DownloadDetailScope`. It follows the registry like the
foreground service does: one listing, the feed folded in, a fresh listing
for a key no listing has named. While any download is on its way
(`isOnItsWay`) it asks the server for each torrent's `stats.json` every 2 s,
the stall card's cadence (`PlayerScreen.torrentStallStatsInterval`). With
none on its way its timer stops and it asks nothing. An errored entry is
never asked about. A link or Drive download has no stats, and the server's
`DownloadInfo` carries no rate, so its speed is the rate the server's own
byte count grew between two polls. Each download becomes a
`DownloadDetail`: phase, transfer, bytes and the piece a reader waits on.
Every phrase comes from `TorrentProgressCard` (the buffering card's phase
words, `formatSpeed`, `formatSwarm`, `peerSearch`, `pieceWaitOf`) or
`download_labels.dart`, so the card, a Downloads row and the notification
say the same thing about the same numbers. The rows show
`DownloadDetail.line`, and the notification shows `DownloadDetail.lines`.

**Android keeps a download going while the app is away** with a `dataSync`
foreground service (`DownloadsForegroundService`,
`lib/features/downloads/downloads_service.dart`). See
[ANDROID.md](ANDROID.md#downloads-while-the-app-is-away).

### Where torrent data lives

Everything a torrent puts on the device is under the server's `cacheRoot`:
the piece store the streaming cache and kept downloads share
(`<cacheRoot>/media-cache/.pieces/<infoHash>/<bucket>/<piece>`), the
session's records, and the proxy cache. There is no downloads folder and
nothing to move a download to.

- **Its default** is `server/` under the data directory the app hands
  `core_init` (`dataDirectory`, `lib/main.dart`): the app cache
  directory everywhere but Android, and on Android the app-specific external
  files directory, since `getCacheDir()` is the system's to reclaim.
- **Its setting** is `cacheRoot`, written through `server_update_settings`
  from Settings → Server storage
  (`lib/features/diagnostics/server_storage_screen.dart`). The server
  validates it (absolute, created, writable, stored resolved). A persisted
  value outranks the default for ever. A change takes effect at the next
  start, and nothing already there is moved.
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
- a **phone or desktop** opens it itself. A phone asks for a hand-back, so
  the pick page ends by navigating to `stremio:///pair`, which brings the app
  forward and is otherwise dropped (see [DEEP_LINKS.md](DEEP_LINKS.md));
- a **phone with this app installed** that opens a television's link gets it
  as a verified app link and picks with Android's own picker
  (`drive_native_pair_screen.dart`, `lib/core/drive_native_pick.dart`),
  because the web Picker cannot select more than one file on a device with
  no keyboard.

Collecting a session is destructive: the service deletes it as it answers.
So a collected answer is never retried. The collecting is the account's
job rather than the screen's (`lib/core/drive_pairing_job.dart`). The
session id is written down (`drivePendingSession`), so a pairing that
reached the service is collected when the library next opens, even after
the app was killed.

**The account** (`DriveAccount`, `lib/core/drive_account.dart`) is one
refresh token and a list. The token is kept in `SecretStore`. On Linux that
needs a running keyring, and without one a pairing lasts the run
(`DriveLinkOutcome.thisRunOnly`). The linked files (ids, names, mime types)
are the `driveLinkedFiles` preference (`lib/core/drive_link.dart`). The
list is what to show, not a set of grants: `drive.file` grants accumulate
per user and client, so one token reaches every file ever picked, and there
is no unlinking one file. When the service answers `pairAgain`, that is
stored (`driveTokenDead`) and every screen asks for a fresh pairing.

**Where the grant lives.** The device's secure store is the primary copy.
Rust memory holds it while linked (`grantSink`). A pairing also puts it in
the account's vault on xtremio-xervice while signed in to Stremio
(`DriveVault`, `lib/core/drive_vault.dart`; `PUT /vault/drive`, sealed
there with AES-256-GCM under the `GRANT_KEY` secret). A device of the same
account with no grant takes it from there at start and at a sign-in
(`GET`, through `DriveAccount.adoptSharedGrant`: the same store and the
same `grantSink` as a pairing). It then lists and matches every file the
grant reaches (`fillSharedDrive`), so the titles have their Drive sources
before the Library is opened. A device with a grant of its own, or one
Google refused, never takes the vault's. Only a pairing writes the vault,
so **Forget my Drive access everywhere** (Settings, `DELETE`) stays
forgotten. It then points at myaccount.google.com/permissions, which is
where the grant itself is revoked. Tests: `test/core/drive_vault_test.dart`,
`test/features/drive_shared_grant_test.dart`, `test/app_xervice_test.dart`.
**Reload** lists every file the grant reaches (`files.list`, a thousand a
page, shared drives included; `lib/core/drive_listing.dart`). Stored files
take Drive's current names, and stored files the listing no longer names
are dropped. Files it names that are not stored, picked on another device
of the same Google account, are added (folders aside), then matched. Only
a complete listing writes. A partial one changes nothing.

**Matching** a file to a title uses its name alone
(`lib/features/drive/drive_match.dart`): a loose title plus a strict check,
since a real poster for the wrong film is worse than none. A matched file
is listed as a source on that title's details screen as an
`xtremio-drive:<fileId>` row (`lib/core/drive_source.dart`), which is also
what the player plays by id. An unmatched one is played from the library's
Remote list.

**Playback.** `server_drive_open(file_id, refresh_token, name)` registers
the file as a Drive media id and resolves it: the grant renewed, the file
probed, its head read. It answers `{ok, url, name, contentType, length}` or
`{ok: false, reason}`. The URL is `xtremio-drive:<fileId>`, which the
player registers (`media_register_drive`) and finds already resolved. The
token is spent once, in-process, which is why this is not an HTTP request.
Later resolves read the grant `server_drive_grant` left in Rust memory, and
a finished Drive download resolves off the disk with none. `openLinkedDriveFile`
(`lib/core/drive_playback.dart`) turns `pairAgain` into
`DriveAccount.notePairAgain`, and the player gets a hand-built stream
(`driveStreamJson`) named after the file, with the name in
`behaviorHints.filename` for the subtitle memory's release key.

**Tracking.** A Drive play of a known title is loaded with a stream request,
because stremio-core writes the resume position, the watched mark and
Continue Watching only when the selection has one. `driveStreamRequest`
names this app's own service, `https://xtremio-xervice.web.app/manifest.json`,
rather than crediting an installed addon. It is a truthful manifest offering
no streams: every `stream/...` is a static `{"streams":[]}` cached a day.
Addon health skips it (`is_own_stub`). The player finds a linked Drive file
of the next episode itself. A Drive download stores the request, and an
older row without one gets it at play time
(`DownloadsScreen.streamRequestOf`). An unmatched file plays with none.

## The library

The Library screen (`lib/features/library/library_screen.dart`) is the
engine's `library` field: type pills and sorts from `selectable`, each
dispatched verbatim, cumulative pages, per-item remove, mark watched,
rewind and notifications. It adds two things the engine knows nothing
about, merged into the list and never written to the engine's library or
synced:

- **Downloaded titles** appear whether or not they were added, one card per
  title the grid has no card for, of the selected type, once the engine has
  no page left to send (`_kept`).
- **Matched linked Drive files** and **matched local videos** appear the
  same way (`_appended`). Files that matched nothing appear under All and
  Other, under their own pill.

**Downloaded**, **Remote** and **Local** are filter chips on a row under the types, and
they filter whatever the engine answered: they combine with the type pills
and the sort, dispatch nothing, and are not turned off by the engine's
controls. Remote shows everything linked, matched or not, with a Reload
button beside it. The app bar holds "Sync now" (signed in), "Manage
downloads" (while there are any) and `RemoteFilesButton`, where files are
linked from. On a television there is no app bar: the types, the sort (an icon, its words
the tooltip) and those buttons are one band across the top, with the
filter chips the row under it (8c530e6). One matching pass runs
per screen (`DriveMatchRun`). Tests: `test/features/library_merge_test.dart`,
`library_remote_test.dart`, `library_local_test.dart`,
`library_screen_test.dart`.

**A film's watched state on its details page** is a check beside the
bookmark (`watched_button.dart`). Watched is the library item's
`timesWatched`, which is stremio-core's own `LibraryItem::watched` and what
marking and clearing move. (`flaggedWatched` is left by a playback and not
cleared by a mark.) Pressing the check sends `MetaItemMarkAsWatched` with
the other value. For a film the library has never seen, that makes the
temporary item a finished playback would (`temp`, `removed`: watched, not
saved). Films only: a series' watched state is per episode, in its episode
list. On a television it is the stop between the bookmark and the faces.
Tests: `test/features/details_watched_test.dart`.

## Local videos

The device's own videos are the Drive arrangement without an account: a
record of files, matched by name, merged into the library and the details
page, played in place.

**Finding them** is a `LocalMediaSource` per platform
(`lib/features/local/`). `AndroidLocalMediaSource` works over the
`xtremio/local_media` channel (`LocalMediaChannel.kt`). It queries
MediaStore's external video collection on every volume, a USB drive's
included, and leaves out `DCIM/` and `Pictures/`.
`DesktopLocalMediaSource` walks the folders in the `localFolders`
preference (Settings → Local, `LocalFoldersSection`, a `file_selector`
dialog) to a bounded depth and count, skipping hidden names and links.
Android's permission is `READ_MEDIA_VIDEO` (with the partial-access grant on
14, the storage read before 13), asked only when the Library's Local pill
opens. Start-up scans only what is already allowed.

**The record** (`LocalMediaFiles`, `lib/core/local_media_files.dart`) is
the `localMedia` preference: address, name, size, duration, height, and
the match. A scan reconciles it: a file found again keeps its match, a
renamed one is asked about again, one not found is dropped. `LocalMedia`
(`lib/features/local/local_media.dart`) owns it. It scans, then asks
`matchDriveFile` about each file not yet answered, writing each answer as
it lands. A catalogue that cannot be reached leaves the file for the next
refresh. Refreshes run one at a time, and one asked for during another is
a pass after it. The app refreshes at start-up and on every return to the
foreground, never asking. It sits above every screen in `LocalMediaScope`.
Android 14's partial grant ("Select photos and videos") is its own state,
`LocalMediaAccess.partial`: its videos skip the camera filter, and
`chooseMore` asks again, which is the system's picker.

**Thumbnails.** An unmatched video's card is drawn from `LocalThumbnail`
(`lib/features/local/local_thumbnail.dart`), an `ImageProvider` over
`LocalMediaSource.thumbnail`. On Android that is
`ContentResolver.loadThumbnail`, the frame the system keeps for every
indexed video, sent as JPEG. Nothing is stored by the app. A desktop has no
system thumbnailer to ask, so `DesktopThumbnails` (`desktop_thumbnails.dart`)
takes a frame with a hidden, muted libmpv player, one file at a time. The
player has video decoding switched back on (media_kit sets `vid=no`
without a view), starts a tenth of the way in, and scales to card size by
an mpv `vf`. The frame is kept in the cache directory under a hash of the
path, modification time and length.

**macOS folders.** A sandboxed app reads a picked folder only until it
quits, so `MacFolderAccess` (`folder_access.dart`) takes a
security-scoped bookmark when the folder is added (`localFolderBookmarks`)
and opens every bookmark before a walk, keeping the fresh one when the
system calls a bookmark stale. The native half is `FolderAccess` in
`macos/Runner/MainFlutterWindow.swift`, with the
`files.bookmarks.app-scope` entitlement.

**Up next.** The player hands over to the next episode's local file after a
download of it and before a linked Drive file
(`player_screen_next.dart`): the engine cannot find it, because the Local
Files addon answers every stream query empty.

**Playing.** `localStreamJson` hands the player the file's own address,
which it plays by media id like any stream. A `file://` path is registered
as it is (`media_register_local_path`). A `content://` document is opened
by the `xtremio/local_media` channel (`openFd`, which detaches the
descriptor) and handed to the server (`media_register_local_fd`). The
server reads it where it is, positionally, so it seeks. It refuses a pipe
a cloud provider may hand out rather than read it forward. Nothing is copied
or cached, and the download controls refuse both. A
matched play carries `localStreamRequest`, naming the profile's Local Files
addon (`http://127.0.0.1:11470/local-addon/manifest.json`), for the reason
Drive's carries `driveStreamRequest`. That address is not this app's
server, which binds a port the OS picks and has no such route. The addon's
URL is not rewritten, because the addon list syncs to the account.
Instead `XtremioEnv::fetch` answers it itself (`local_addon_answer` in
`rust/src/env.rs`) with an empty catalog, which Discover drops without
comment, and no streams. Tests: `test/core/local_media_files_test.dart`,
`test/features/local_media_test.dart`,
`test/features/details_local_source_test.dart`, and the env tests.

## Addons

The Addons screen (Settings → Addons, or "Browse addons" on an empty board)
reads `installed_addons` (`InstalledAddonsWithFilters`) and `remote_addons`
(`CatalogWithFilters<Descriptor>` over an `addon_catalog` resource). Whether
a community entry is installed is computed from `ctx.profile.addons` by
manifest URL. "Add addon" and every tile open `AddonDetailsScreen`, which
loads `addon_details` for one manifest URL and offers Install, Update
(`UpgradeAddon` when versions differ), Uninstall (never for a protected
addon) and Configure (the manifest URL with `manifest.json` → `configure`,
opened through `url_launcher` behind `ExternalLinkScope`). A
`configurationRequired` manifest cannot be installed, so Configure is its
primary action. `profile.addonsLocked` disables every mutation behind a
banner. [docs/ADDONS.md](ADDONS.md) covers how each addon has been
answering and the verdict drawn from it.
[docs/DEEP_LINKS.md](DEEP_LINKS.md) covers installing from a web page.

### The last stream, when its addon fails

stremio-core remembers the stream each video was last played with, on this
device only (`ctx.streams`, never synced). It offers it again only through
the current answer of the addon that gave it (`last_used_stream_update`).
So a rate-limited Torrentio hid a torrent that needs nothing from it to
play. `XtremioModel::remembered_stream` fills that gap. When the engine's
`lastUsedStream` is an error or `Ready(None)`, and this exact video has a
record, `meta_details` carries the record's stream as `rememberedStream`.
It has the shape of `lastUsedStream` and the request of the addon that gave
the stream. `MetaDetailsState.lastUsedStream` falls back to it, so
"Continue with last stream" shows and the empty notice does not. A play
credits the original addon, which keeps the record and the binge match
pointing at it. Only the exact video is answered for: the next episode's
file is something only the addon knows. Subtitles are unaffected, since
their memories key on the stream's own name and the show, never on the
addon that answered. Tests: `meta_details_remembers_the_stream_the_addon_cannot_offer`
in `rust/src/model.rs`, and "offers the stream last played here" in
`test/features/meta_details_screen_test.dart`.

## Recommendations

"More like this" is a row of posters on a title (`similar_row.dart`),
filled from the xtremio-xervice function at `GET
https://xtremio-xervice.web.app/similar/{type}/{id}`
(`lib/features/similar/xtremio_similar_titles.dart`). The function holds the
owner's Gemini key, builds the question from Cinemeta's name and year for
the id, and keeps the first answer for a title for everybody. The app holds
no key and sends nothing but a type and an id. Only `movie` and `series` are
asked. `more_like_this.dart` is the order: the answer this install already
has (`SimilarMemory`, the `similarSuggestions` preference, kept for the
life of the install per question version), else the server, then the guard.
**The guard is where correctness lives** (`similar_resolver.dart`): a model
invents titles, and a catalogue search for an invented one succeeds with a
different film, so a suggestion is kept only when a catalogue answers with
the same title and a year within one. Nothing in this path throws. Every
failure is an empty row.
[tool/recommendations/README.md](../tool/recommendations/README.md) says
which model is asked and how that was measured.

### For you

A row on Discover under Continue watching (`_ForYouRowView` in
`catalog_rows.dart`), worked out on the device by `ForYouController`
(`lib/features/for_you/`) from the whole library and the faces. The whole
library is not a model field: `ctx` holds the bucket and does not
serialize it. So `core_get_state("library_items")` answers it
(`XtremioModel::library_items_json`, removed and temporary items
included), and `CoreField.libraryItems` re-pulls it whenever a `NewState`
names `ctx` (`CoreField.ridesOn`).

**Sources** (`for_you_rules.dart`). A title is a source for each of these
it is, weight one each, so a title in both counts twice:

- **watched**: a film with `timesWatched > 0`. That is the state the
  details page's check shows and moves. It is not `flaggedWatched`, which a
  playback leaves and no mark clears, so a film the account wrongly calls
  watched leaves the sources when its check is cleared. A series is
  watched once every episode of one season numbered one or more is
  watched, or every episode it has when it has no such season. The
  watched marks are stremio-core's per-video bitfield (`state.watched`),
  read by position against the show's episode list in stremio-core's own
  order (`watched_bitfield.dart`, a port held to stremio-core's own
  fields). The list is asked of Cinemeta once per show and kept
  (`showEpisodes`).
- **saved**: added by hand, `temp == false` and `removed == false`.

A happy face adds one. A sad face makes the title no source at all. Only
`movie` and `series` are sources, and only the latest 96 (`maxSources`),
which keeps a run inside the 128 answers `SimilarMemory` keeps.

**Candidates.** Each source's "More like this" answer
(`MoreLikeThis.suggestionsFor`, through the same memory, so a title already
opened costs nothing), asked as its own type. A title named by several
sources scores the sum of their weights. Ties go to its best place in an
answer, then to the latest source. They are confirmed against Cinemeta in
rank order exactly as "More like this" confirms its own: title and year,
or dropped. The row stops at 30. Anything in the library in any
sense, on Continue watching, disliked or dismissed is left out, and the
filter is applied again on every draw so a dismissal takes the tile off at
once. Each title keeps every source that named it, strongest first, with
which listings each is in and whether it is liked
(`ForYouTitle.sources`). A screen reader hears the heaviest one
("Because you liked / watched / saved X").

**When.** The result is kept (`forYou`: titles, their sources, when, and a
signature of the sources) and drawn at once on the next start. It is
worked out again when the signature changes, and otherwise at most once a
day. A source whose ask failed is not an empty answer
(`suggestionsFor` says null). Such a run replaces the row only when its row
is at least as long, so a run with nothing answering leaves the row alone.
It is kept as incomplete and worked out again after ten minutes
(`retryAfter`), when the answers that did come in are read from memory and
only the failed sources reach the server. The server's answers and the episode lists go four at a time, with
the catalogue searches four at a time beside them. A first run with
nothing kept draws the row from the first answers and fills it as the rest
arrive. A tile is the poster and the name, as every row's is, and the
heading is "For you" alone: a tile never had room for why.

Why is the long press (a held select on a television, through the same
`RemotePress` path as Continue watching). The sheet shows the title, then
every source that suggested it, one line each, strongest first, with what
it counted for in words: "Watched and saved: Heat (×2)", "Watched: Drive".
Each line is a stop that closes the sheet and opens that title's details
page. On a television those stops sit between the title and the choices,
and the remote still starts on Cancel. Then comes the total ("5 points").
All of it comes from the kept result, so nothing is fetched to draw it.
Each kept source carries its id and type for that. A row kept before they
were is worked out again once (`ForYouController.keptShape`). The sheet is
as tall as it needs (`isScrollControlled`): at the default nine-sixteenths
a television cut the last reason in half under the actions.

Under them is **Add to library**, for films and series. It is the
bookmark's own `AddToLibrary`, a saved title synced to the account. The
row hides the title at once and counts it as a saved source next time.
**Mark as watched** comes next, for a film only. It is stremio-core's own
`MetaItemMarkAsWatched` (`CoreActions.metaItemMarkAsWatched`). For a title
the library has never seen, it makes a temporary item, watched once:
`temp` and `removed`, so not one of the Library's saved titles. That is the
state a finished playback leaves a film it was never added for. The item
is synced to the account like any library item and shown watched wherever
the app shows it (`rust/tests/core.rs` holds the item's shape). The row
hides the title at once, and the next computation counts it as a watched
source. A series has no such entry, since "watched" for a show means which
episodes, and that is the details page's. Last is **Not interested**,
which is a `dismissed` face, kept and synced like the others
([Likes and dislikes](#likes-and-dislikes)). Tests:
`test/features/for_you_rules_test.dart`, `test/features/for_you_row_test.dart`,
`test/core/watched_bitfield_test.dart`.

## Ratings

The details header shows a title's scores: IMDb, TMDB, Rotten Tomatoes'
Tomatometer (`RT`) and its Popcornmeter (`Popcorn`), as words and numbers
(`title_scores.dart`), with no logos, since those are their owners' marks.
IMDb is the addon's own rating (`MetaItem.imdbRating`), drawn with the page
and still the link to the title's IMDb page on a phone. The other three
come from the xtremio-xervice function at `GET
https://xtremio-xervice.web.app/ratings/{type}/{id}`
(`lib/features/ratings/xtremio_ratings.dart`), which asks MDBList with the
owner's key at most once a week per title for everybody
([xtremio-xervice/README.md](../xtremio-xervice/README.md#ratings)).
MDBList's IMDb score is shown only for a title the addon gave none.
`RatingsService` draws what this device remembers first
(`TitleRatingsMemory`, the `titleRatings` preference) and asks again once
that is a day old. An answer with no scores, or a failure, is not written
down and changes nothing on screen. Only a `movie` or `series` with a `tt`
id is asked about. On a television the scores are one line of text under
the facts, never a focus stop.

## What xervice keeps for an account

A signed-in account can keep things on the xtremio-xervice service that
another of its devices reads back. Every such request goes through
`XerviceIdentity` (`lib/core/xervice_identity.dart`). It sends the Stremio
session key to `POST /identity` and gets back a token good for an hour
that names the account's Stremio user id. It sends that token as the
bearer of every request after. The session key is `ctx.profile.auth.key`,
read by `stremioAuthKeyOf` and by nothing else in the app. The token is
renewed when it is two minutes from expiry or the service refuses it, and
dropped on a sign-out or a sign-in as somebody else. Being signed out or
offline, or a service that will not answer, is a quiet null and a
one-line log by kind. Everything kept there is a copy of something the
device already has, so nothing is ever a dialog. Neither the key nor the
token is written to a log, and
`redactSecrets` knows both names (`authKey`, `token`) as the second lock
(`test/core/xervice_identity_test.dart`).

**The trust statement.** The Stremio auth key transits xervice once to
prove who you are and is not kept: the function asks Stremio whose key it
is, keeps the user id in the token, and forgets the key and the e-mail
([xtremio-xervice/README.md](../xtremio-xervice/README.md#your-account)).
Your likes are stored under your Stremio user id in the clear, and your
Drive grants encrypted at rest. Delete them any time from Settings.

### Likes and dislikes

The details header has a happy face and a sad one beside the bookmark
(`face_buttons.dart`). A For you tile's long press adds "Not interested".
All three are marks in `Faces` (`lib/core/faces.dart`, the `faces`
preference): a title id, the face, and when it was given. Those are ids and
times, nothing worth redacting. Taking a face off is a mark with no face
rather than an absence, so a merge cannot bring an old face back.
`clearedAt` does the same for the whole set. On a television the two faces are stops
right of the bookmark, walked by hand along the corner (`_walkCorner` in
`tv_meta_header.dart`) because Flutter's directional walk undoes its last
move when the opposite key follows.

`FacesSync` (`lib/core/faces_sync.dart`) copies the set to the account and
merges the answer back. It sends `PUT /faces` on every change, and
whenever `ctx` shows a session key the last sync did not run for (a
signed-in start, every sign-in). The service merges newest per title and
drops nothing only one side has, so a device's first sync adds its marks
to the account's rather than replacing them. The only removal that travels
is **Forget my likes everywhere** (`DELETE /faces`). It stamps the
account's `clearedAt`, and every mark at or before it is dropped wherever
it is merged next. Marks are kept on the device per account
(`FacesByAccount`): each under the Stremio user id it was made under, or
under nobody when signed out. `AppPrefs.faces` shows the signed-in
account's marks and nobody's (`setFacesOwner`, from `ctx`). A sync sends
only those two. Nobody's marks become the account's and leave nobody's
set, so they reach the first account that signs in, once. Signing out of one account
and into another hides the first one's marks without sending them
anywhere, and they come back when it signs in again. A set stored before
marks had owners is nobody's. Tests: `test/core/faces_test.dart`,
`test/core/faces_sync_test.dart`, `test/features/details_faces_test.dart`,
`test/features/xervice_section_test.dart`, `test/app_xervice_test.dart`.

## Casting

The cast button, what it hands a receiver untouched, the LAN media listener
and every rule it refuses on are in [CASTING.md](CASTING.md).

## Pinned forks

`rust/Cargo.toml` pins every git dependency to a rev, with the reason beside
it. Read the current revs there.

| Dependency | Pinned to | Why |
|---|---|---|
| `stream-server` (package `server`, and its `enginefs`) | [`zond/stream-server`](https://github.com/zond/stream-server) | The server this app embeds. It keeps no record of what is pinned and is told at start (`ServerConfig::pins`) from this app's downloads registry. Default features are on, which is RAR support (see [the README](../README.md#license)). |
| `librqbit` | [`zond/rqbit`](https://github.com/zond/rqbit) | A dev-dependency only, for the real `.torrent` fixtures in `rust/tests/downloads.rs`. Always the rev stream-server's `enginefs` uses, or two librqbits end up in the graph: bump the two together. |
| `stremio-core` | [`zond/stremio-core`](https://github.com/zond/stremio-core) | Upstream 0.64.1 (rebased 2026-10-05, 2ab0526) plus one commit that keeps a subtitle's addon-specific fields (`fpsMilli`, `subtitleFileName`, `releaseGroup`, …) in a flattened `other` map instead of letting serde drop them (upstream PR Stremio/stremio-core#1045), one that pins its `localsearch` dependency by rev, and one that relaxes `stremio-watched-bitfield`'s `flate2 = "1.0.*"` to `"1"`. stream-server's tree needs flate2 ≥ 1.1 and Cargo will not pick two 1.x versions, so without it the graph does not resolve. Built with the `derive` + `env-future-send` features. |

To bump one: change the rev, `cargo update -p <crate>`, run `cargo test`,
and re-record any fixture whose shape moved. A stremio-core bump has to
keep the fork's `flate2` relaxation. Beside those, `flutter_rust_bridge` is
exactly 2.13.0 in `pubspec.yaml`, `rust/Cargo.toml` and the codegen.
