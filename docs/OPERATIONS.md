# Running and checking Xtremio

What to run before a commit, how to see video play, and the two screens
that answer "what is this build doing" -- server storage and Diagnostics.

## Verifying on a dev machine

```bash
# Rust crate
cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
cargo test --test cinemeta -- --ignored       # network: loads a Cinemeta catalog, refreshes the fixture
cargo test --test meta_details -- --ignored   # network: meta + streams + Player + continue watching for a public-domain torrent, plus a series (seasons, selected episode, watched), refreshes fixtures
cargo test --test board -- --ignored          # network: Board rows + a search over the default addons, refreshes fixtures
cargo test --test library_addons -- --ignored # network: ctx (logged out), installed/remote addons, addon details (Cinemeta), library fixtures
cargo test --test downloads -- --ignored      # no network: rebuilds downloads_registry.json (a finished movie, a half-done episode, an empty one) from two torrents it builds itself
cargo test --release --test subtitle_threshold -- --ignored   # network: re-measures where CONVINCING sits over ~39,000 pairings of real subtitle files (downloads ~70 MB into $XTREMIO_SUBTITLE_CORPUS or a temp dir, ~15 min); refreshes subtitle_threshold.json
cargo test --test subtitles -- --ignored      # no network: rewrites subtitle_starts.json from XTREMIO_SUBTITLE_PLAYING and XTREMIO_SUBTITLE_REFERENCE
# ctx_logged_in.json is hand-authored (a fake account); there is no recorder for it, and a real session must never be committed

# Dart (FFI-backed tests load rust/target/debug/libxtremio_core.* directly;
# rebuild after touching rust/src or they run against a stale library)
cargo build --manifest-path rust/Cargo.toml
flutter pub get && dart format --set-exit-if-changed . && flutter analyze && flutter test

# Bindings must be committed
flutter_rust_bridge_codegen generate && git diff --exit-code lib/src/rust rust/src/frb_generated.rs
```

## Seeing video play

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev
flutter run -d linux
```

Then either **Discover → a title → a stream**, or **Settings → Developer →
"Play test torrent"** (Big Buck Bunny from a public torrent through the
embedded server; "Play test HTTP stream" is the direct-play path). The
stats OSD (Shift+I) ends with the URL libmpv is playing, so a torrent
should read `http://127.0.0.1:11470/dd8255ec…/-1?tr=…`.

## What the server's storage costs

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

## Diagnostics off a device

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

## The stats OSD

To judge playback performance by numbers rather than feel, the player has a
stats OSD (like mpv's): move the mouse over the video to show it, or press
**Shift+I** (or the stats button in the top bar) to pin it on/off. It lists
output vs container FPS, dropped
frames, the **hwdec** in use (or `software` when libmpv is decoding on the
CPU), codec and resolution, video bitrate, and demuxer cache / buffering
state, sampled twice a second only while it is on screen.

Two more rows are about seeking rather than performance: mpv's `seekable`
and `partially-seekable` on one, the demuxer's own seekable ranges out of
`demuxer-cache-state` on the other. They are there because
"fast-forwarding past the downloaded part makes the position jump back" is
a demuxer refusing the seek rather than a slow one serving it: mpv
restores the position when the demuxer says it cannot seek, and nothing
else on screen tells that apart from a seek that worked and then rewound.
A `seekable no`, or a `ranges none`, is the reading that says so. `ranges`
says `none` only when mpv answered with no ranges; both rows are absent
when it did not answer at all, since a dash there would be a measurement
nobody made.

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

## Linux video is software-rendered (for now)

Which is what the panel above will say on a Linux desktop, so this is why.
`media_kit_video` 2.0.1 cannot share Flutter 3.38+'s EGL context (the
embedder only makes it current on the raster thread — see
[media-kit #1404](https://github.com/media-kit/media-kit/issues/1404)), so it
falls back to software rendering on **both X11 and Wayland**. Playback works,
but is CPU-rendered; `--profile`/`--release` builds are much smoother than
debug. The fix is the Linux renderer redesign in
[media-kit PR #1346](https://github.com/media-kit/media-kit/pull/1346), not
yet released. **No code change is needed here**: once a `media_kit_video`
release includes it, `flutter pub upgrade media_kit_video` enables hardware
rendering automatically. Android (the primary target) is unaffected.
