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
