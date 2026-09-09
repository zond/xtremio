# How the Rust core is wired in

Where the Dart side and the Rust core meet: the bridge, what crosses it, and
what every model field means. The shape of the thing is in the
[README](../README.md#how-it-works); this is the wiring.

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
  from the profile's manifests, aligned with `catalogs`).
  Those two fields do not follow the library (`GridCatalogs` in `model.rs`),
  since nothing they carry reads it: stremio-core marks them changed on every
  library change because stremio-web merges library flags into the board it
  serializes, and here that was the whole board re-serialized and re-decoded
  on the UI isolate per pause and per progress push. The one field that *is*
  reshaped is those two: a board or search item crosses as what a poster tile
  draws -- `id`, `type`, `name`, `poster`, `posterShape`, `releaseInfo`
  (`GridItem`) -- and not the whole `MetaItemPreview`, whose `links` alone
  were three fifths of a 1.4 MB board re-serialized every time a row landed.
  `core_get_state` takes an owned snapshot under the model's read lock and
  serializes after letting it go (`FieldSnapshot`), so a board pull no longer
  parks every dispatch behind it. The model
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
  HTTP, trusting Mozilla's compiled-in roots rather than the device store
  (`http_client_builder` says why: on Android the platform verifier has Java
  download and parse CRLs on every handshake), one JSON file per bucket
  under the app-support directory with
  temp-then-fsync-then-rename writes, and two lib-owned tokio runtimes
  (concurrent + a single-worker sequential one for ordered persistence).
  Every HTTP body is read under a cap (`MOST_JSON_BYTES`, 32 MiB, ten times
  the largest real answer measured; 4 MiB for a subtitle file) chunk by
  chunk, so a compressed answer that inflates past it is abandoned rather
  than buffered, and no error out of `fetch` or `fetch_text` carries the URL
  (`without_url`), since an addon's can hold a debrid key. A bucket that
  will not parse at boot is moved aside as `<key>.json.corrupt-<seconds>`
  and read as empty; one the disk will not read refuses the boot
  (`core_init` fails and the Dart boot screen shows why) instead of
  starting an anonymous profile the first persist would write over the
  real one.
- **The app's own preferences are a file beside those buckets**
  (`rust/src/prefs.rs`, `<storage_dir>/xtremio_prefs.json`): a flat JSON
  object of client-side choices -- how a list is laid out, which view a
  screen comes up in -- written with the same atomic write. A file that
  will not parse is moved aside (`xtremio_prefs.json.corrupt-<seconds>`)
  and reads as empty; one the disk will not read is an error to
  `prefs_get_all` and refuses `prefs_set`, since a read-modify-write of one
  key over a file that could not be read is the whole file gone. They are
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
  Interface -> "Bold focus", a switch offered on a television only:
  `standard` is the two-stroke ring with its zoom and shadow, `bold`
  thickens the ring and dims everything the remote is not on, for a bright
  room a display cannot fight; an unreadable or absent value is `standard`.
  It reaches the app twice over: `FocusHighlight` reads it for what the app
  draws itself, and `FocusTheme.apply` derives it into the `ThemeData` the
  app runs under, so every Material control is marked without opting in --
  see AGENTS.md, *Eleven rules a real device taught us*) and
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
  addon's own host knows nothing about it, and a kept download's URL is
  this server's own media route with every piece already here. It
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
  server's storage costs"), `server_background_traffic()` (below) and
  `server_stream_numbers(url)` (what the server holds of one playing
  stream, asked with the URL the *engine* was handed — the address the
  bytes are cached under, which for anything but a torrent is this
  server's own `/proxy` route: the cache either side of the playhead and,
  for a torrent, the set committed for sharing and what it has moved since
  it went live — the stats panel's cache and sharing rows)
  —
  wrapped by `ServerClient` in
  `lib/core/server_client.dart`. Nothing logs the token; the header value
  is marked sensitive. `media_kit`'s `Media.httpHeaders` could carry it to
  mpv should a media route ever need it; none does.
- **Whether the server shares between sessions is the app's decision, and
  it is one settings key.** The server keeps a torrent in the swarm after
  playback ends when its `seedingEnabled` setting is true (its own default);
  when it is false a torrent nothing is streaming is paused once its idle
  grace is up (15 s) — paused in both directions, so it stops uploading to
  peers and stops fetching the rest of its own file alike — and a pinned
  download is exempt either way: it keeps downloading, and stops being
  shared when it is unpinned. **What it buys is minutes, not sessions**: an
  unpinned engine nothing is streaming is removed 300 s after it went idle
  whatever the setting says, and nothing stops sharing when the next stream
  begins, so the setting's real effect is whether those five minutes are
  spent in the swarm (both constants are `enginefs/src/lib.rs` at the
  pinned rev). The setting's subtitle says that and says nothing else; a
  longer lifecycle is the server's keep/share policy, being built there.
  The app decides
  the value and writes it through `ServerClient.updateSettings`
  (`server_update_settings`, the same function `POST /settings` runs), which
  is the only way it changes anything about the server.
  `IdleSharingPolicy` (`lib/features/sharing/idle_sharing.dart`) is what
  decides, and the viewer's `shareWhileIdle` preference is the whole of the
  decision — **on by default on every device**. Nothing asks what the
  connection costs: the term that did (a `ConnectivityManager` watcher
  behind an event channel, refusing to seed on a metered link) could only be
  answered on Android, and answered "unmetered" unconditionally on the
  desktops, so a tethered laptop seeded over mobile data under a tile
  promising it never would. What replaced that guess is showing the truth —
  see the status light below. The policy pushes only changes, serialises its
  writes, and pushes the first as soon as the preferences have loaded; a
  "Not now" (`pauseUntilRestart`) holds its answer at false for the rest of
  the run without writing anything down. A pause is a state of a switch that
  is on, and that is held from both ends: either press of the switch lifts
  one, and `pauseUntilRestart` refuses one while the switch is off. So the
  settings tile's "Paused until you next start Xtremio." is never drawn
  under a switch that is off, where the resumption it promises would never
  come. The policy notifies when that pause goes on or off, which is how the
  tile sees a "Not now" granted by a popup drawn over it.
- **The status light says what is happening, and it is the only thing that
  says it.** `SharingLight` (`lib/features/sharing/sharing_light.dart`)
  means "Xtremio is using your connection while you are not watching" —
  serving other people, a download filling in, both. It is drawn in the
  shell's top right corner while the server's reading says bytes moved,
  and never because a setting is on. The reading is
  `ServerClient.backgroundTraffic` (`server_background_traffic`,
  `ServerHandle::background_traffic`), read by `SharingActivityMonitor`
  through `RustSharingActivityClient` every five seconds while the shell's
  own route is the current one: per direction, whether librqbit's own peer
  counters grew over the last five-second window with no player reading
  over it or since, judged on the Rust side over one sample so the two
  halves cannot disagree — a peek over the engines that exist, so it creates
  nothing and touches no idle clock (the per-torrent stats calls create the
  engine they are asked about and must never stand in for it). The monitor
  repeats the halves unchanged: `uploading`, `downloading`, `active` as
  either, and `BackgroundTraffic.none` before the first reading and after a
  failed one, since a failed reading is darkness and not the last answer.
  One slot, three glyphs — an up arrow while bytes go out, a down arrow
  while they come in, `swap_vert` while both — never two lights; the glyph
  and the popup's title are `SharingLight.glyphFor` and `labelFor`. The
  shell's on-top rule is no longer what keeps the light off during a film
  (the server folds "nothing playing" in itself); it is what stops the
  polling while nobody could see the light. Semi-transparent, a 1.6 s pulse,
  inside the overscan inset and a toolbar's height below the top; the
  placement is measured on all five shell screens at TV and phone widths by
  `test/features/sharing_light_placement_test.dart`. On a television the
  remote reaches it from the top of the rail with a press of up, and the
  node is skipped by traversal so it cannot swallow a press meant for a
  poster. **Pressing it offers a stop for the arrow that is lit, and only
  rows that do something.** While bytes go out, the sharing rows: "Not
  now" (`pauseUntilRestart`) and "Stop sharing" (the setting) — but things
  upload that neither governs, a torrent serving out its idle grace or a
  title kept offline, so with the switch off the popup says that and offers
  neither, and under a pause it says so and offers only the switch, since
  the policy takes no second pause. The pause is read from `pausedForRun`,
  not from the light, which cannot tell. While bytes come in, the offline
  downloads: the light lists them before opening the popup and draws one
  "Cancel <name>" row per download still on its way, each dropping that
  download and its part-file through `DownloadsClient.remove` — what the
  downloads notification's "Cancel all" does, and the only stop there is,
  the server having no pause for a pinned file. With no offline download in
  flight the bytes are a watched title finishing its own file, which the
  sharing setting governs (above), so the popup says no download is in
  flight and draws the sharing rows. While both, both groups under a
  heading each. The way out is "Close" in every state. Widget tests count
  the pressable rows in each state; a "Cancel" is checked to remove with
  `deleteFiles: true`, and a refused removal is said in a snackbar rather
  than swallowed.
- **Offline downloads are a pin plus a registry.** The server keeps the
  chosen file of a torrent wanted and un-evictable
  (`ServerHandle::pin_download`, `pinned`/`complete` per file in
  `stats.json`) -- a *retention* property, not a location: the bytes are
  pieces in the one torrent-data root either way; `rust/src/downloads.rs`
  keeps everything it has no idea about in `<storage_dir>/downloads.json` —
  keyed `"{metaId}:{videoId}"`, holding the raw stream JSON `Load Player`
  takes back, a `MetaItem` snapshot so Details renders offline, and
  `createdAt`/`completedAt`/`lastPlayedAt`. The FFI is
  `rust/src/api/downloads.rs`: `downloads_add(request_json)`,
  `downloads_remove(key, delete_files)`, `downloads_list()`,
  `downloads_open(key)` and a `downloads_events()` stream that
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
  on it. The row leads the server on the way in and follows it out: `add`
  writes the row (naming, under `replaces`, the file it stops naming)
  before `pin_download`, `remove` marks the row `pendingRemoval` before
  `unpin_download` and drops it after, and the boot finishes whatever a
  kill left half done -- so no pin exists that no row names, and no row
  outlives its pin to be re-pinned. The file is parsed once and then
  answered from memory while its mtime and length are what the last read or
  write left; a tick is a `stat`, not a parse of every meta snapshot. The UI
  reaches all of that through one `DownloadsClient`
  (`lib/core/downloads_client.dart`), which `XtremioApp` builds and
  disposes and a `DownloadsScope` hands down the tree -- one client,
  because the progress sink is one -- with `DownloadView`
  (`lib/core/state/download.dart`) reading the registry it answers with.
- **There is one place torrent data can be, and it is not a downloads
  folder.** Everything a torrent puts on this device is under the server's
  `cacheRoot`: the piece store the streaming cache and the kept downloads
  share (`<cacheRoot>/rqbit-downloads/.pieces/<infoHash>/<bucket>/<piece>`,
  one file per whole piece), the session's own records beside it, and what
  `/proxy` cached. It is the only tree the cleaner walks. A pin decides
  that bytes are *kept*, never where they go, so a `downloadsDir` distinct
  from the cache had nothing left to hold and is gone -- an unknown key the
  server ignores on write and does not answer with. So is the app's whole
  destination model: the `Destination` enum, the `destinationSettled` /
  `destinationChoice` pair in `downloads.json`, `downloads_set_dir`,
  `downloads_apply_default_dir` and the start-up that settled the question.
  A file a previous build left with those keys keeps its entries and loses
  them at the next write; nothing adopts the folder it names, because that
  folder holds neither the piece store nor the session's records, and
  making it the root would orphan both.

  The root is named twice. Its **default** is the directory the app hands
  `server_start` (`XtremioBootstrap.dataDirectory`, `lib/main.dart`): the
  app cache directory everywhere but Android, and on Android the
  app-specific external files directory
  (`/storage/emulated/0/Android/data/com.zond.xtremio/files`), because
  `getCacheDir()` is the system's to reclaim whenever it wants room and
  with one root there is nowhere else for a kept download to be. Its
  **setting** is `cacheRoot`, written like any other settings key through
  `server_update_settings` from Settings → Server storage
  (`lib/features/diagnostics/server_storage_screen.dart`, which offers
  `getExternalStorageDirectories()` on Android so an SD card is reachable
  without a permission, and a typed path elsewhere). It is the server's
  one validated setting -- absolute, created if missing, writable, stored
  resolved -- so a root it cannot use fails the whole update and nothing in
  Dart checks a path itself. A persisted `cacheRoot` outranks the app's
  default for ever after, and a change takes effect at the **next start**:
  the running librqbit session was opened on the old root and cannot be
  moved, and what is already there is not moved either. **On Android a
  download keeps going while the app is away**: `DownloadsForegroundService`
  (`lib/features/downloads/downloads_service.dart`) puts a `dataSync`
  foreground service up over the `xtremio/downloads` channel as soon as one
  entry is unfinished and takes it down when none is (ANDROID.md,
  "Downloads while the app is away", for what Android still reserves the
  right to do to it). The registry and the server's own pin set survive the
  process dying either way, and the boot reconciliation picks the
  unfinished ones up again.

  **An install that has run before does not get that default, and one
  Android case is corrected.** stream-server fills its own default in only
  when `cacheRoot` is *empty*, and every earlier build persisted one at
  first start -- on Android the app cache directory, with the kept
  downloads then in a `downloadsDir` of their own. With one root those
  downloads would land in `getCacheDir()` on exactly the devices that had
  been safe from it, so `XtremioBootstrap.moveOffPurgeableRoot`
  (`lib/main.dart`) writes `cacheRoot` once at boot when the persisted root
  is inside the app cache directory and there is a directory the system
  does not reclaim to move it to. It compares the paths *resolved*, because
  the server stores a canonical root and `/data/user/0/<pkg>` is a symlink
  to `/data/data/<pkg>`. Everywhere else -- a desktop, an Android device
  with no external storage, and any root somebody chose on the storage
  screen -- it reads the setting and writes nothing.
- **A finished download is played off this device, and there is no file to
  open.** Torrent data is one file per piece, so no whole file is ever
  produced and the `path` the server reports is a *name* for the file
  rather than something to open. `downloads_open(key)` answers the
  embedded server's own media route for the entry's torrent and file
  (`{base}/{infoHash}/{fileIdx}`), which is served off the pieces already
  here -- no peer, no tracker, no network -- and stamps the entry's
  `lastPlayedAt` as it does. **Two things have to be true for that, and the
  row is only one of them**: the entry says `complete`, *and* the server
  answers that it is holding that file whole right now. The rows are a
  record, and the pieces are under a root that can be moved (Settings →
  Server storage) or reclaimed (an Android cache directory) without any row
  being rewritten, so a row alone is not evidence. It refuses with
  `unknown` (no such entry), `incomplete` (the bytes are not all here),
  `unavailable` (the server that reads the pieces is not running) or
  `notHeld` (it is running and does not hold these pieces: no pin, a
  dormant one, or a torrent still being checked). `notHeld` is a refusal
  and not a 404 waiting to happen: on loopback the media route *creates*
  the torrent it is asked for, so a URL handed out for a hash the session
  does not have starts a magnet add from a bare info hash with no trackers
  and blocks to its metadata timeout -- a kept download starting a
  download, behind a screen that says the film is on the device.

  The row is corrected at the next boot rather than left saying `complete`
  for ever: `reconcile_pins` marks a finished entry the server does not
  hold as `gone` -- no bytes, no completion date, a reason on the row and
  "Not on this device" in the list -- and deliberately does **not** re-pin
  it, because that would fetch a whole film again over whatever connection
  the device is on, asked for by nobody. Pressing Download on the title
  pins it again, which is what a `gone` row's own button does. Details and the
  Downloads screen hand the player that URL as a plain `url` stream
  (`lib/features/downloads/offline_play.dart`) together with the
  *original* `streamRequest` and `metaRequest`, which is what keeps
  continue-watching moving: stremio-core's `TimeChanged` writes progress
  only with a stream request and a library item, and offline the library
  item comes out of the `ctx` bucket the download put the title into.
  It is a `url` stream and not the torrent it came from even though the
  URL names the same server, because a torrent stream sends the player
  through the engine's start-up and the overlay keys on `infoHash`: a
  download with every byte here would sit behind a "connecting to peers"
  panel it has no need of. The kept copy wins over the addon's stream
  even with a connection -- but only for the release that was
  downloaded; picking another stream is a request for that source. A
  download with nowhere to play from streams the addon's own stream
  instead, rather than opening a player on a URL with nothing behind it.
  Binge-advancing asks the same question about the next episode before it
  hands over, so a downloaded season plays through off the device -- and
  offline that is the only way it advances at all, since the next
  episode's streams never load and the engine finds nothing to move on
  to.
  *Known consequence:* the synthesized `url` stream is what
  stremio-core records as that video's last stream, and it is persisted.
  `MetaDetails` resolves the last stream against the addon's current
  responses by `Stream::is_source_match` (which compares the source, so a
  `Url` never matches the `Torrent` the addon offers) and then by
  `Stream::is_binge_match`. The binge match is why `offlineStream` keeps
  `behaviorHints.bingeGroup` -- but an addon that sets none leaves neither
  match to make, so after one play off the device that title's "Continue
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
- **Every stream reaches the player as a URL on our own server.** A torrent
  already is one; a stream on anybody else's host -- a debrid link, an
  addon's own HTTP URL -- is wrapped in the embedded server's `/proxy`
  route before it is handed to mpv (`lib/core/stream_proxy.dart`). The
  shape is the one stremio-core builds and the server parses: the target's
  origin percent-encoded into a `d=` path segment, its own path and query
  after it, so a signed link keeps its signature and the file name stays
  where ffmpeg's probing and a log reader can see it. The address comes
  from `CoreInitInfo`, which is settled before the first `open`, rather
  than from `profile.settings.streamingServerUrl`, which arrives with a
  `ctx` pull that can land later. Left alone: a loopback URL (already the
  server, whatever port it bound -- which is what a kept download's own
  URL is), and everything
  when this build runs no embedded server -- which is not what configuring
  a streaming server elsewhere does. That rewrites
  `profile.settings.streamingServerUrl` only: the embedded server keeps
  running and keeps being named by `CoreInitInfo`, so a remote host's
  stream is proxied through it on such a build like any other, and the
  bytes still cross the network once. The torrent such a server is
  actually for is the opposite case -- it has an info hash, so it goes
  straight there with `buffer=` and never near the proxy. `force-seekable`
  excludes
  `/proxy` for the same reason it always excluded a remote host: the
  promise that a seek will wait rather than be refused is about the
  *server's own* torrent reader, and the route relays a host we know
  nothing about.
- **There is one cache on the device and it is the server's.** The player
  is started with `cache-on-disk=no`, once per player, for every stream,
  and nothing ever writes that property again. media_kit's own default is
  `yes`, and what that buys is a file mpv unlinks the moment it creates
  it: no name in the directory, so no `du`, no `dumpsys diskstats` and no
  walk the server's cleaner performs can find it, and the blocks come back
  only when the fd closes. On the owner's Chromecast one 90-second title
  held 928 MB that way while three separate instruments reported the app
  was using 46 MB. The server's cache is everything that is not -- named
  files, a configured limit (`min(cacheSize, occupied + available -
  512 MiB)`, the `CACHE_FREE_SPACE_FLOOR` below which
  `ensure_download_disk_ready` has already given up on the disk), a
  cleaner that evicts, and survival across a crash -- and now that every
  stream goes through it, it is the only local copy there is. There is no
  shared budget to keep any more, because there is nothing to share it
  with.
- **What the player still holds is memory, and it is deliberately small.**
  `MediaKitEngine.memoryCacheBytes` is 32 MiB, written out rather than
  inherited from media_kit's `bufferSize`. media_kit sets that on both
  `demuxer-max-bytes` and `demuxer-max-back-bytes`, and the app then sets
  the back side apart (`MediaKitEngine.backCacheBytes`, 16 MiB, through
  `mpvOverrides`) -- so the ceiling is 48 MiB: about two minutes ahead of
  a 2.3 Mbps film and 16 MiB behind the play head, which is one ten-second
  press back at anything up to about 13 Mbps; a seek that misses the
  window is a range request answered from the server's cache. Measured,
  mpv fills the forward side and then reads at what playback
  consumes (2 MB/s down to 18 KB/s within a second of the cache filling),
  so a player with no disk is not a player downloading without bound. It
  was reconsidered when the disk cache went and left where it is: the
  television has 2 GB of RAM for the whole system and the app measured
  245 MB PSS with a player up, the embedded server and its torrent engine
  share that process, and the cushion this design wants is the server's
  rather than a bigger heap here.
- **What the proxy does not do yet.** `/proxy` relays: it opens the target
  with reqwest and streams the answer back, caching nothing and fetching
  twice what is asked for twice (pinned in `server/tests/proxy.rs` in the
  stream-server tree). `Range` is forwarded and the origin's `206`,
  `Content-Range` and `Accept-Ranges` come back untouched, so a backward
  seek past the memory cache works -- by asking the origin again. For a
  torrent the file is on disk anyway and that seek is local. Making the
  proxied half local too is the next stage, and it belongs on the server's
  side of the hop rather than in the player's heap.
- **A player that is left ends its own reads first.** Each player screen
  mints a token (`player-1`, `player-2`, ...), writes it into the `/proxy`
  URLs it hands the engine as `p=`, and on the way out calls
  `server_close_proxy_streams` with it (`ProxyStreamControl`, over FFI like
  every other control call): the server ends every stream carrying that
  token, the read fails at once, and the teardown below is not left waiting
  on `network-timeout` -- five minutes, and deliberately so, since a thin
  swarm is not a dead connection. The token is a name and not a credential:
  the route is on the loopback control API behind the bearer token, never
  on the LAN media listener, and the token is stripped before the origin is
  asked for anything. **It ends the read and the token** -- breaking the
  read alone would only be a stutter, since ffmpeg runs with `reconnect=1`
  and re-fetches through the URL it already has, so the server retires the
  token too and answers `410 Gone` to anything that comes back with it.
  The order the server documents is quit-then-close, since a cancelled
  demuxer never reaches its reconnect, and that is the order the teardown
  below runs in; the token's refusal covers the case where mpv had not
  reached the quit yet. It ends a read and nothing else besides -- a
  demuxer wedged on the Flutter texture or the audio device is not polling
  that stream, which is why the bound below still exists. The call sits
  between the quit and the release with its throw caught, because it
  reaches FFI and an exception crossing it would take the release with it.
  A torrent is never proxied, so its teardown has nothing to close.
- **A player is stopped before its screen leaves, not after.** Every way
  out of the player funnels through `PlayerScreen._leave`, and it goes in
  one order: send `quit`, close the proxied streams, `await` the teardown
  with the video still in the tree and the audio device still open, then
  pop. The `quit` goes first because it is the kill and because it is what
  makes the `stop()` inside media_kit's `Player.dispose` come back
  promptly; the wait comes before the pop because media_kit releases the
  video texture and the audio device from *inside* that teardown, after
  the stop, so waiting with the screen up is what keeps the sinks
  attached and consuming until mpv has no more use for them. It used to be
  the reverse -- leave at once, release the engine two frames later
  through a future nobody held, and send the `quit` only if a ten-second
  deadline expired -- which withheld the one fast fix until the slow path
  had failed. Measured against real libmpv: the quit returns in
  microseconds, a teardown behind one comes back in 92-230 ms even against
  a socket wedged for good, and mpv's core thread goes on answering
  commands throughout, because `quit` starts the shutdown rather than
  ending the core.
- **The screen lets go of the player before it waits for it.** Waiting with
  the picture up leaves the screen built and subscribed while its engine is
  being released, which is a state it was never in before: a `completed`
  during the wait re-opened the stream, the app going to the background
  paused a released player, a cast session ending elsewhere seeked and
  played one, the open-retry and the torrent poll ran on, and media_kit's
  own `stop` -- `notify: true` by default -- pushed `position:
  Duration.zero` with the duration still the film's, which reached the core
  as a `TimeChanged` of zero and reset continue-watching for every film
  that was not finished. `PlayerScreen._detach` is the one act that ends
  all of it: the engine subscriptions, the cast subscriptions, the `player`
  and `ctx` listeners and every timer go there, before the first `await` in
  `_leave`. It is not a guard per handler, because the next handler would
  have to remember one; a screen with nothing subscribed cannot be reached
  by anything, including what has not been written yet. `State.dispose`
  still calls it (idempotently) for the screens that go without a leave --
  the hand-over's `pushReplacement`, a route dismantled from above -- but
  it is no longer where this belongs, since it now runs after the wait
  rather than instead of it. What is left after the detach is input, which
  stands down the same way the remote does: a key press is swallowed
  (`_onKeyEvent`), a hover is refused (`_onPointerMoved`, since the
  `MouseRegion` sits above the `IgnorePointer` that covers everything
  else), and the fade timer refuses to re-arm -- otherwise the focus change
  `_leave` makes on its way out arms a timer nothing cancels, and it
  outlives the screen.
- **A suspended continuation is not a subscription, and `mounted` no longer
  answers for one.** The detach above ends everything that could *arrive*
  during the wait; it cannot reach an `await` that was already in flight
  when the press landed, and that one resumes into the middle of the wait.
  It resumes into a screen that is *more* alive than the one its guard was
  written against: the player used to pop at the press and release its
  engine two frames later, so `mounted` was false by the time anything late
  came back, and now it is true for exactly the stretch it used to be false
  for. Every `mounted` guard on a continuation therefore passes precisely
  when it used to fail. Two of them cost the viewer something, both
  measured: a cast start whose `connect` answered during the wait paused
  the engine, opened the LAN listener and handed the receiver the film at
  0:37:00 -- Back was pressed and the film started on the television -- and
  a hand-over whose registry answer came back during the wait
  `pushReplacement`ed a second player, a second engine and a fresh open over
  the screen still waiting for its own teardown. So `PlayerScreen` has one
  question with one name, `_stillOurs` (`mounted && !_leaving`), and every
  continuation in the class that can reach the engine, the core, the cast
  client or the navigator asks it; `mounted` says only that there is a
  widget to call `setState` on. A continuation that had already *started*
  something -- `_startCast`, once the session exists -- unwinds it rather
  than merely returning, because a session and a socket are what must not
  outlive the screen. `test/features/player/player_leaving_awaits_test.dart`
  is the list, one row per such await.
- **`quit` is the kill, and there is nothing stronger to escalate to.**
  `PlaybackEngine.quit` sends it asynchronously on media_kit's own handle,
  never `mpv_terminate_destroy`: destroying a handle whose event loop is
  still attached deadlocks or crashes, which is why media_kit schedules its
  own five seconds after the teardown. Sending it *first* is what makes
  mpv's dispatch queue work in our favour -- the `stop` media_kit issues is
  on that same queue, so a core thread that reaches the queue at all
  reaches the quit ahead of it. A core thread already stuck elsewhere
  swallows both, and nothing in the process can reach it; what bounds that
  case is that a player keeping no disk cache costs memory, a socket and
  the server engine that socket keeps live, rather than a gigabyte of a
  4 GB television. `mpv_command_async`'s refusal is thrown rather than
  discarded, so a report never says a player was killed when the command
  was never enqueued.
- **`PlayerScreen.teardownBound` bounds the viewer's wait, and is the only
  instrument for a failure still unexplained.** Nothing is escalated to
  when it expires -- the quit went out at the press -- so the screen simply
  stops waiting after two seconds, the teardown carries on in the
  background, and a line says a player which should have stopped in a
  fraction of a second has not (with a second line when a late one lands,
  since "slow" and "never stopped" want different things looked at next).
  It is kept because on the owner's Chromecast a player once kept
  downloading at 32 Mbps for at least ninety seconds after its screen was
  left and only a force-stop ended it, and every mechanism since measured
  resolves in a fraction of a second: something happened there that is
  still not accounted for.
- **A scan is a different question from a seek, and mpv is asked
  differently.** mpv's seek is exact -- it lands on the keyframe before
  the target and decodes forward, invisibly, to the moment asked for --
  and media_kit makes that certain by starting libmpv with `hr-seek=yes`.
  On a 32-bit Amlogic box decoding through `mediacodec-copy` that decode
  is the beat every press of a seek key costs, which is how the owner
  came to notice that "when the cache goes to 0s, the seeking becomes
  smooth": with nothing to seek within, mpv fell back to a keyframe seek.
  So every press that says *further on* -- the seek keys, a remote's
  transport keys, the buttons either side of play, a double tap, and the
  seek bar's left and right while it holds focus -- goes to
  `PlaybackEngine.scanBy`, which is `seek <n> relative+keyframes`.
  Relative is the point rather than a detail: a keyframe seek to an
  absolute target lands on the keyframe *before* it, so a forward step
  shorter than the gap between keyframes goes backwards, and x264's
  default keyint is 10.4 s at 23.976 fps against a 10 s step. A press
  that names a moment instead -- a tap or a drag on the bar -- is seeked
  to exactly, and so is Shift + arrow, the *short* step, which at three
  seconds is shorter than a keyframe gap. A held key accelerates rather
  than the step growing (`SeekHold`): ten presses at the viewer's own
  `seekTimeDuration`, fifteen at twice it, five times it thereafter, and
  a fresh press always starts again at one.
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
  Space/K play-pause, ←/→ or J/L ± the seek step (10 s by default, and
  further with each repeat of a held key),
  Shift+←/→ ± the short seek step (3 s, and exact), ↑/↓ volume, M mute, F
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
  ones from a release group the viewer has already adjusted for this
  series (the correction goes back on when the file is applied, so it
  arrives fixed, and the rank asks the memory exactly what applying it
  will ask), then everything else in the order the addons answered.
  The language rows themselves are sorted on the name the menu prints,
  alphabetically, and `subtitlesByRelease` pins nothing above that: Off
  is the menu's own row above every language, and the language that is
  playing is not lifted, since the list is ordered before anything is
  selected and a row that jumps to the top once it is picked is no longer
  where the alphabet left it. The menu itself then lifts at most two
  rows, under a heading of their own -- the languages picked most often
  (`SubtitlePickMemory.pinned`), which is a fact about the viewer rather
  than about these files, and whose reason for being first cannot change
  under a finger because a count changes only on a pick and every pick
  closes the sheet. An addon answering late still moves the rows of an
  open menu, as it did before there were pins. They are
  lifted rather than copied, only ever languages this episode offers, and
  not drawn at all when they would be every language there is. Inside a rank the addon that answered first still wins --
  which matters, because the head of a language is the file its row
  applies and the file the auto-pick plays. The row order reaches the
  auto-pick in exactly one case: a session preference that is enabled and
  names no language matches every file and so takes the head of the whole
  list, which is now the alphabetically first language rather than the
  first one answered. Nothing is dropped or hidden. The video is named by the same
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
  upload, never a rate and never a verdict about its timing. **The
  video's declared frame rate now decides nothing at all**, and nothing
  in the player reads it: it pointed one button, and that button is
  gone. What replaced it measures the drift rather than naming the
  family it probably came from -- the owner's own Swedish Gilmore Girls
  file wants 1.0440 where the PAL constant is 1.0427, three seconds
  across an episode that the constant does not reach. libmpv's
  `container-fps` survives only in the stats OSD's own poll, which is
  where it was always a number to look at rather than to act on. Every
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
  the direction keys and closes it with Back. It holds one control and
  one reading. The **shift** is a stepper in 0.1 s steps on libmpv's
  `sub-delay` (positive delays the lines, which is mpv's own sign),
  counted in whole presses (`SubtitleTiming` in
  `lib/features/player/subtitle_timing.dart`) so that ten forward and ten
  back land exactly where they started. It repeats while it is held, by
  pointer or by the remote's centre key, and **the hold accelerates
  through three strides** -- ten steps of a tenth, fifteen of a whole
  second, then five-second strides
  (`SubtitleTimingOverlay.shiftStrideAt`). The offsets it has to reach
  are three orders of magnitude apart: a tenth is the smallest
  difference visible against speech, a mis-cut release is out by
  seconds, and an uncorrected PAL file is a hundred and fifteen seconds
  out by the end of an episode -- eleven hundred presses at a tenth
  each. Three strides put it about six seconds of holding away. Only the hold
  accelerates: the count belongs to the button and a release ends it, so
  every tap is a tenth however large the correction before it was. The
  **speed** is shown and cannot be pressed. A multiplier is measured
  now, never judged -- the panel says what is in force because a
  subtitle that is right at this moment and wrong in ten minutes looks
  exactly like one that is right, and the number is the only thing that
  says which. Above them the
  panel offers the two measurements, which find the drift instead of
  asking the viewer to press until it is gone: **This is right**, which
  marks the line on screen where it belongs (below), and **Match to
  another subtitle**, whose own measurement is this: two subtitle
  files for one video are two clocks, so their disagreement is a line:
  the viewer picks a file they have seen keep time, and Rust fetches
  both, turns each into a bitmap of **when it has text on screen** and
  searches for the ratio and shift that make the two bitmaps overlap
  most (`rust/src/subtitles.rs`, over FFI as `subtitles_match`, because
  two HTTP fetches and a search over two bitmaps do not belong on the UI
  thread of a Chromecast). **Both timestamps of every cue, and no text
  at all.** Comparing cue *starts* was the measurement this replaced,
  and it refused the owner's own Swedish Gilmore Girls file against an
  English one: the Swedish file has 690 cues where the English has 1024,
  because the translator merges lines and gives each merged line its own
  beat, so only 54 % of its starts land within a third of a second of an
  English start -- 89 % within a second, 97 % within a second and a
  half. A bitmap does not mind: a merged line overlaps both the lines it
  covers, and a line one file does not have costs its own bins rather
  than a whole match. **One damaged cue does not decide how long a file
  is.** Everything downstream reads the last moment a file has text on
  screen -- it is the length of the bitmap and the timeline both files'
  densities, and so the chance term below, are measured over -- so a
  stamp that parses and is wrong costs the whole measurement rather than
  its own cue, in both directions: an appended `01:00:00,000` on a
  twenty-minute file triples the timeline and decays the score into the
  raw Dice coefficient of two talkative files, and one mistyped hour
  digit on a cue's end (`02:10:18,160 --> 52:10:24,240`, from a real
  file) lights fifty hours of invented timeline and refuses a pairing
  that is perfect. So `cue_spans` drops a cue reaching further past the
  body of the file than a tenth of it or ten minutes, and stops at six
  hours for a file with no body to read at all -- four billion seconds
  of timeline is a 34 GB allocation, which aborts rather than unwinding
  and so never reaches the FFI guard. A healthy file loses nothing.
  **What two cues share is on screen once**: the bitmap takes the union
  of the cues over a bin, not their sum, because an SDH speaker label
  beside its line and a sign captioned over dialogue are one lit
  interval -- summing them counted a moment as many times as the file
  wrote it and read a density of 0.81 where the file's is 0.66. **What
  is scored is the overlap above chance,
  never the overlap.** Subtitles are on screen something like two thirds
  of an episode, so two files with nothing to do with each other already
  overlap heavily, and the number reported is
  `(dice - chance) / (1 - chance)` from `dice = 2|A∩B| / (|A|+|B|)` and
  `chance = 2·da·db / (da+db)`. `CONVINCING` sits at 0.45 and is
  **measured**: 39,000 pairings of 717 files the OpenSubtitles addon
  offered for forty titles in thirty-seven languages, split into the
  pairings whose transform is right -- judged by where it puts the lines,
  not by the score -- and the deliberate mismatches. The first have a
  fifth percentile of 0.54 and a median of 0.81; the best of the 30,918
  mismatches reaches 0.376, and a different episode of the same season
  0.222. **The two overlap**, so 0.45 is not a midpoint but a line drawn
  above the mismatches: it clears the best of them by 0.074 and costs one
  pairing in fifty that really does align -- pairs whose files keep text
  on screen for very different shares of the episode, which Dice's
  ceiling holds down however well the lines land. The measurement,
  including what each neighbouring threshold would have cost, is
  `rust/tests/subtitle_threshold.rs` and its fixture; re-run it with
  `cargo test --release --test subtitle_threshold -- --ignored`. **The search goes coarse to
  fine.** The rate window is 0.90 to 1.10 and stays there, because PAL
  against film is 4.27 % away and finding it unaided is the whole point;
  that is far too wide to sweep against every offset at a tenth of a
  second, so the first pass bins at a second -- where an episode is a
  few tens of machine words -- and two passes after it look only near
  its winner, at 100 ms and then 20 ms. A bin is lit when text covers at
  least *half* of it rather than any of it: lighting from any overlap
  makes a file of two-second lines nearly all lit at a second per bin,
  and two files that are both nearly all lit have no headroom above
  chance left to tell them apart, which measured out as the right ratio
  scoring 0.14 where a wrong one scored 0.34. How finely the ratio is
  stepped comes from how long the file is, not from a constant: a ratio
  out by `d` throws a cue `d * t` seconds, so the step nearest the right
  answer has to keep the whole file inside a bin. **Refusing is the
  point**, and a refusal says what was found -- the score and the
  transform, not a fraction of cues. "Only 303 of 690 cues matched, so
  nothing was changed" is what sent the owner looking for a different
  reference when the reference was fine, and a count of cues was never
  comparable between a file that merges lines and one that does not. A file
  with fewer than fifty cues is not evidence either way, whichever side
  of the pairing it is on, and the pairing is not measured at all; that answer carries no score and names how many
  cues each file turned out to have, because a file that could not be
  read as a subtitle is a different problem from two files that disagree
  with each
  other. The reference is always the viewer's to pick, since the answer
  is only as good as that file's own sync and nothing in the metadata
  knows which file that is; with no other file on offer the option is not
  drawn at all, and the sheet that asks is one row per language with the
  rest of a language behind a row of their own, because reaching a
  *second* language is what opening it is usually for. **The other way of
  measuring is the marks**, which is what a language that answers with
  one file -- or with several sharing the same bad timing -- has instead,
  since a match needs a second file to be right about. "This is right" on
  the panel records where the line on screen belongs: the cue's own time
  in the file, which is libmpv's `sub-start` and is its raw time there
  (measured against a running player, not read out of the manual, and
  written down at `MediaKitEngine.subtitleCueStart`), paired with the
  video position that cue is *drawn* at -- the transform in force
  applied, which is the picture the viewer has just approved, and not
  the instant the button was pressed, which is a reaction time. So one
  mark on its own changes nothing, deliberately: the viewer shifted the
  line into place themselves and the mark writes down where they put it.
  Two of them at least two minutes apart give the line through both, so
  the rate comes with it -- which is what the second mark is for, made
  out at the far end after the strides have put the picture right there
  too; a mark within half a minute of an existing one
  corrects that one rather than joining it, and the pair used is always
  the two furthest apart (`SubtitleCalibration` in
  `lib/features/player/subtitle_calibration.dart`). Which of the two
  happened is on the panel, because the picture cannot say: an offset and
  a rate both land the line in front of the viewer, and only one of them
  still holds ten minutes later. The marks belong to the file that was
  playing and go with it, since a point on one file's timeline pairing
  with the next file's would be a lever arm across two of them; only what
  they derive is kept. Reset goes back to untouched, 1.0 and 0.0, and
  throws the marks away with them, because with nothing else writing
  either property that is what "undo what I did" means -- and what those
  two numbers hold is the line through the marks, so keeping the points
  would let the next press pair with a judgement just discarded and put
  the whole answer back. What the viewer fixes is **remembered, keyed on what caused
  it** (`SubtitleSyncMemory`, `lib/core/subtitle_sync.dart`, under the
  one `subtitleSync` preference), so the same correction is not made
  again on the next episode, and `_resetSubtitleTiming` puts it back
  whenever that file goes on screen. The two keys are deliberately
  different because the causes are. A *speed* is remembered against the
  series and the group that cut the release the file was made for
  (`releaseGroup`, lower-cased), since what a file was timed against is a
  property of where it came from and video releases of one show share a
  frame rate, so a speed carries from one episode to the next. It is
  `releaseGroup` and not the addon's own bucket (`g`), which is what this
  used to key on: `g` is a per-answer cluster index, re-assigned every
  answer, so one Swedish upload batch reads `g=6, 5, 4, 1` across four
  Gilmore Girls episodes and Breaking Bad's BluRay family reads `2, 2,
  1`, and a bucket can even hold files from another episode. Keyed on it,
  a measured multiplier usually missed next episode and now and then
  landed on a family nobody had measured. `releaseGroup` is on about four
  entries in ten and is the same word every episode -- spelled with
  whatever capitals the uploader used, which is why the key is
  lower-cased -- and rows an older build wrote under `g` lapse rather
  than migrate, since the group's name is not in them. A *shift* is remembered against the
  video release as well, because an offset is the video's pre-roll less
  whatever the subtitle's source assumed and changing either side
  changes the answer; the release is the whole filename the player knows
  (the file the server says it opened, else the addon's claim), not a
  release group parsed out of it, because a parse is a guess and two
  encodes by one group can still start in different places. Any part of
  a key nobody can name -- an addon that names no release group, a
  torrent nothing has named the file of -- means that adjustment is simply not
  remembered: a narrower key is forgotten more often, and that is the
  price of never being wrong. Both values stored are real numbers, a
  multiplier and an offset in seconds, because both are measured: no
  menu of values contains 1.0440. The preferences file is forgiving by
  design, so the one place a stored multiplier becomes `sub-speed` is
  where it is checked against mpv's `<0.1-10.0>`
  (`PlayerScreen._rememberedSpeed`) -- media_kit throws the property
  write's return code away, and a value outside that range is refused in
  silence while the previous file's multiplier keeps running. Rows the
  build before this one wrote name a toggle direction and a count of
  presses, and are dropped rather than reinterpreted. Reset *forgets* rather than storing a
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
  the bar has gone. It scrolls inside whatever height the screen leaves
  it, because a 360 dp-tall phone held sideways leaves under 300 and a
  refusal's three lines do not fit in that -- overflowing there pushed
  Reset off the bottom of the screen, which is the way back from the
  state the viewer had just landed in. The speed row has no buttons and draws the space two
  would have taken, so its number stays in the column the shift row put
  its own in.

  What was *picked* is remembered too, and separately
  (`SubtitlePickMemory`, `lib/core/subtitle_picks.dart`, the
  `subtitlePicks` preference): one row per show holding the language as
  the label the menu prints, the release group of the file that was
  picked where the addon named one, or that subtitles were turned off on
  purpose, plus a count per language with no show attached. The engine's
  own `subtitle_preference` is session state -- `Unload` clears it and the
  player dispatches `Unload` on dispose -- so on a fresh start the row is
  the only thing that knows what this programme is watched in, and the
  auto-pick falls back to it. Among the files of the remembered language
  one from the remembered group is preferred, and where there is none the
  head of the language is taken as always: the group is a preference
  among files, never a condition on the language, since a show can change
  release family between seasons and six OpenSubtitles entries in ten
  name no group. A language the episode does not answer with means
  nothing is applied at all, and a show never watched is left alone --
  putting the viewer's commonest language onto an unknown programme would
  put subtitles on one that needs none. Only a pick made by hand writes
  to the store, and a preference synthesized from it is never dispatched
  back to the core. The counts decay on picks rather than on days: they
  halve when their total passes a ceiling and the zeroes drop out, which
  follows a taste that really changes without a language going stale
  while the app is closed. Then
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
  features, `zond/stream-server` at a fixed rev (`78d91cb`: generated
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
  sitting on,
  `ServerHandle::dht_status` for the diagnostics screen, a cache cap that
  is the smaller of `cacheSize` and what `statvfs` says the volume can
  give above a 512 MiB free-space floor -- so a television with no
  `cacheSize` set is capped by its own disk rather than by `u64::MAX` --
  and an ENOSPC that stops a torrent being classified as a full disk and
  answered with an eviction pass and a restart instead of a dead playback
  -- with that pass allowed to evict a file larger than the whole cap when
  the device rather than `cacheSize` is what set it, counting what the
  30-day rule freed as room made, reporting a cap of 0 as a cap rather than
  as no cap at all, and saying a disk with nothing left to evict is stuck
  once instead of every fifteen seconds for the life of the process, a LAN
  media listener that ranks its interfaces rather than naming whichever
  non-loopback one `getifaddrs` happened to list first -- a phone's
  cellular address as readily as its Wi-Fi one, and a container or VM
  bridge as readily as either, since what the ranking demotes is every
  interface a receiver on a home network cannot be behind, and an
  interface whose netmask the kernel never reported is not subnet-matched
  at all -- that says in the log which address it gave a receiver and when
  a request arrives, and that counts what it has been asked for, so a
  receiver which never fetched can be told from one which reached this
  device -- which is all the count knows about it -- the count belonging to
  the session that asks about it:
  start and stop both reset it, so a second receiver picked mid-cast does
  not inherit the first one's). To
  bump: change the rev, `cargo update -p <crate>`, run
  `cargo test`, re-record any fixture whose shape moved, move the
  `[patch]` key along if the source URL changed (it names the URL being
  patched, and a stale key silently patches nothing), and re-copy
  `rust/vendor/stremio-watched-bitfield` from the new stremio-core rev
  when that crate changed (it carries a one-line `flate2` relaxation the
  combined graph needs; see `rust/vendor/README.md`).
