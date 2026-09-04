# Working on Xtremio

Conventions for people and agents changing this repository. `README.md`
explains what the code does; this is about how changes are made.

## Read first

- `README.md` → "How the Rust core is wired in" (state crosses as JSON,
  what each model field is, what the app reads from the settings).
- `docs/phase3-design.md` when touching account, library, addons or
  settings: it lists the exact action JSON, state shapes and the engine's
  surprises. Its line offsets were read at the rev it names, which is
  older than the current pin, so check a shape against the pinned source
  rather than trusting an offset.
- The pinned stremio-core source (`rust/Cargo.toml` names the rev) is the
  authority on wire shapes. Do not guess a field name; read the `serde`
  attributes.

## Commits

- Small, single-concept commits with a message that says what changed and
  why in prose. Do not push unless asked.
- Every commit an agent wrote ends with a `Co-Authored-By` trailer naming
  the model that wrote it (`Co-Authored-By: <model name>
  <noreply@anthropic.com>`), so the name follows the model rather than
  this document.
- Latest dependency versions; `flutter_rust_bridge` must stay the same
  exact version in `pubspec.yaml`, `rust/Cargo.toml` and the codegen.
  Nothing under `rust/src/api` changes without regenerating the bindings
  and committing them (CI checks for drift).

## Verification, with real exit codes

Run these before every commit and look at the exit codes, not at the tail
of the output. Never pipe a test command into `tail`/`head`/`grep` before
an `&&`-gated commit (the pipe's exit code is the filter's, not the
tests'); redirect to a log file and `echo EXIT=$?` instead.

```bash
dart format --set-exit-if-changed lib test; echo EXIT=$?
flutter analyze; echo EXIT=$?
flutter test > /tmp/flutter-test.log 2>&1; echo EXIT=$?
# Rust changes:
(cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test); echo EXIT=$?
# FFI-backed Dart tests load rust/target/debug/libxtremio_core.*: rebuild
# it after touching rust/src, or they run against a stale library.
cargo build --manifest-path rust/Cargo.toml; echo EXIT=$?
```

New behaviour needs tests that fail without it. Check at least one by
stashing the `lib/` (or `rust/src`) change and running the new test
(`git stash push -- lib && flutter test <file>; git stash pop`).

## Tests and fixtures

- Widget tests run against `FakeCoreClient` (`test/support/`), a
  `FakePlaybackEngine` and the other fakes there; nothing in `test/features`
  touches FFI or libmpv. `test/core/core_client_test.dart` and
  `rust/tests/core.rs` are the FFI/engine tests.
- Model-field states come from fixtures under `rust/tests/fixtures/`,
  recorded by the `#[ignore]` network tests in `rust/tests/` (the README
  lists the `cargo test --test <name> -- --ignored` commands) and loaded
  through `test/support/fixtures.dart`. Refresh a fixture by re-running its
  recorder, never by hand-editing recorded JSON; trim large catalogs.
- `ctx_logged_in.json` is hand-authored with a fake account. Never commit a
  recorded session, and redact `auth.key`, `_id` and `email` from anything
  captured against a real account.

## Never log auth material

`Authenticate` actions and the `UserAuthenticated` / `Error{source}` events
carry the password; `ctx.profile.auth.key` is the session key. Do not log
or print `RuntimeCoreEvent.args`, action args of `Ctx` actions, or the
`ctx` JSON — log event names and `source.event` only. The same goes for
test output and bug reports.

The embedded server's bearer token (`ServerHandle::auth_token`, read
through `server::token_for` in `rust/src/env.rs`) is in the same class:
never log it, never return it over FFI, never put it in a URL. It exists
only inside the Rust crate.

## The app never speaks HTTP to the embedded server

Only libmpv fetches from it (the open media routes). Everything else the
server can answer — settings, a torrent's `stats.json`, creating an
engine — is a control route that wants the token, and the app reaches it
in one of two ways: stremio-core's `StreamingServer` model through
`Env::fetch` (which adds the header), or an FFI function over
`ServerHandle`'s library API — `rust/src/api/server.rs`
(`server_torrent_stats`, `server_settings`, `server_update_settings`,
`server_storage_report`, `server_cache_usage`, `server_clean_cache_now`) and
`rust/src/api/downloads.rs` (`downloads_add`, `downloads_remove`,
`downloads_list`, `downloads_open`, `downloads_set_dir`,
`downloads_apply_default_dir`, `downloads_events`). A new need goes in one of those, as a Rust function
returning JSON, not as a `dart:io` `HttpClient` call.

## The downloads registry

`rust/src/downloads.rs` owns what is kept offline; the server owns the pin
and the bytes. Keep it that way:

- **Progress has one source of truth, and the registry is not it.**
  `downloaded`/`size`/`path`/`state` come from the server's `downloads()`,
  which `refresh` merges into the entries and writes back: the file keeps
  the last-known copy so the list and `downloads_open` still work with no
  server, and that is all it is. Never compute or advance progress
  locally, and do not add a field the server could answer that is not a
  cached echo of it — that is two truths, and one of them stale. Because
  it is a cache, a tick that moved nothing but `downloaded` does not
  rewrite the file (a state, a path, an error or a finished file still
  does, at once), and what a tick *pushes* is the narrow `progress` row,
  never the whole entry — `downloads_list` is what carries an entry.
- **The file is forgiving and additive.** Entries are camelCase, unknown
  keys survive a round trip, and an entry this build cannot parse is
  written back verbatim. A new field is optional with a default; nothing
  in the app hand-edits `downloads.json` (or a recorded
  `downloads_registry.json` fixture — re-record it with
  `cargo test --test downloads -- --ignored`, which is idempotent: the
  recorder fixes the tmp path and the timestamps because the Dart tests
  quote them, so keep it that way).
- **One client, one sink.** The Rust side keeps a single progress sink, so
  the app builds one `DownloadsClient` in `XtremioApp` and hands it down
  through `DownloadsScope`. A screen takes the client from the scope;
  widget tests put `FakeDownloadsClient` (`test/support/`) there and never
  reach FFI.
- **Where the files go is asked, not assumed.** The destination is the
  server's `downloadsDir` setting: read it with `DownloadsClient.directory`
  and write it with `setDirectory`, which is `downloads_set_dir` and its
  validation. The registry records *what was answered and by whom*
  (`Registry::destination`, on the wire the `destinationSettled` and
  `destinationChoice` pair): nothing asked, the platform default the app
  applied, the cache on purpose, or a folder chosen. A default the app
  applies goes through `applyDefaultDirectory`
  (`downloads_apply_default_dir`), never `setDirectory`, so standing in
  for a folder the server dropped at boot does not erase which folder that
  was. Start-up reads the record
  (`lib/features/downloads/destination.dart`) and no screen invents a
  path.
- Downloads are control calls like any other: over FFI, never HTTP (see
  above).

## Deep links open an addon; they never install one

A `stremio://host/manifest.json` link (what every addon site's Install
button produces) opens that addon's details screen and stops there. Three
rules hold it in place, and each has a test:

- **Nothing is dispatched but the `Load`.** A link must never reach
  `InstallAddon`. Landing on the screen with the Install button waiting is
  the whole of it — a page the user merely visited cannot change their
  profile.
- **The URL is passed on unmodified.** `AddonDetails` in stremio-core
  rewrites `stremio://` to `https://` itself, on the whole string
  (`src/models/addon_details.rs`), so a port, a configuration in the path
  and a query survive. Do not parse and rebuild it in Dart; stremio-web
  does, and loses both.
- **A link never logs the URL.** A manifest URL can carry a debrid API key,
  which puts it in the same class as the auth material above. Log the
  scheme, not the link.

`lib/shell/deep_link.dart` decides what a link means, `XtremioApp` acts on
it, and the platform registrations are listed in README, "Installing an
addon from the web". A widget test drives links through `FakeDeepLinks`
(`test/support/`); nothing in the tests touches `app_links`.

## The subtitle menu hides files, so four rules hold it back

`subtitlesMatchingFrameRate` (`lib/features/player/subtitle_groups.dart`)
drops the uploads cut for a video of another speed -- a 25 fps subtitle
against a 23.976 fps film drifts four seconds a minute, so it is the
wrong file, not a worse one. Hiding is a strong move on numbers two
strangers claimed (the addon about its upload, the container about
itself), and each of these keeps it from taking the list away. Each has a
test; see README, *Subtitles*.

- **Only what the container declares is a rate.** `videoFrameRate` reads
  `container-fps` and nothing else. `estimated-vf-fps` is the obvious
  second choice and is a *measurement* -- ten frame durations averaged,
  read the moment the media loads, which mpv's own manual calls unstable
  for the imprecise timestamps a torrent stream is full of. Fed to a
  comparison with a hundredth-of-a-frame tolerance it hides the correct
  files and leaves the ones that declared nothing. Do not add a fallback.
- **An unknown rate filters nothing.** Cast, offline, a fake, a container
  that says nothing, a read that threw: all of it is null, and null means
  every file stays. Never substitute a default, a guess or a last-known
  rate.
- **A language filtering would empty keeps every one of its files.** The
  valve is per language keyed the way the menu groups them, and it is
  decided *before* the exemption below, so a language whose files all
  mismatch keeps all of them whether or not one is playing.
- **The file that is playing is never dropped.** The menu is reachable
  before the media loads, so a pick can predate the rate. Take the active
  file out and every row is unselected -- Off included, since that row
  keys on a null active id -- with subtitles still on screen.

Two more things that are easy to undo by accident:

- **Everything that consumes the subtitle list filters it.** There are two
  consumers, the menu and the session preference's auto-pick, and the
  auto-pick is the one that applies a file without the viewer looking. It
  waits for the engine to have answered about the rate
  (`_frameRateSampled`) before it runs, because the sample resolves a
  microtask after it is started. A third consumer must do both.
- **The tolerance is 0.01 fps at the content's own rate, and the ratios
  that reach it are the ones that preserve *seconds*.** A subtitle is
  timed in wall-clock seconds, so telecine and frame doubling (5/4, 2,
  5/2) are the same cut -- 23.976 film in a 29.97 container is identical
  seconds -- while 25 against 23.976 is a 4.3 % speed-up and is not.
  Widening the tolerance instead of adding a ratio is the wrong repair:
  0.01 is what separates a rounded `23980` from a real 24 fps cut.

An upload's *name* in that menu is addon text as well, and it is subject
to the same suspicion: it goes through `wellFormedText`, it is cut to
sixty characters whichever property it came from (and the row caps at two
lines besides, because a `ListTile` grows to fit), and it gets its
position back on the end when another file of the same language derives
the same name (`1 (2)`). Addons repeat themselves -- all three Czech files
OpenSubtitles answers for The Godfather are called `1.srt` -- and the
`Option N` these names replaced was at least unique.

The rate is never shown anywhere in the UI. The request was a list that
is right, not a number to reason about.

## The addon health record keys on a hash, never the URL

`rust/src/addon_health.rs` counts how each installed addon answers, and
every record is addressed by `key_for`: `host[:port]#` plus the first 12 hex
characters of `sha256(transport URL)`. **The transport URL itself is never
stored, and neither is any query string** — the same reason a deep link
never logs one above: a manifest URL can carry a debrid API key, which puts
it in the class of things this file says are never written down. The
readable half is the host, so a preferences file stays legible to the
person whose file it is; the digest is what keeps two configurations of one
addon apart.

Nothing else about a request is kept either: not the resource id (that is a
viewing history), not per-request timestamps, and not an error string (a
`reqwest` error can carry the URL back in its own message).

`lib/features/addons/addon_health.dart` mirrors `key_for` in Dart so the URL
never crosses FFI to be hashed there. The two are pinned to each other by a
test on each side (`the_key_is_the_digest_the_app_computes` and "is the
digest the Rust side computes"); if they ever drift the record silently
reads as "not used yet", so change one only with the other.

Rust counts and Dart judges: `AddonHealth.verdict` is a pure function over
an immutable record, so the rule can change without a migration. Empty is
its own bucket, never folded into failed; a sweep in which every addon
failed is recorded against nobody; and the embedded server and the local
addon are never recorded against, on top of a protected addon never being
labelled. See README, "Which addons are worth keeping".

## Brand assets are generated, never hand-edited

Every icon, the Android TV banner, the splash mark and the README logo come out
of `tool/generate_branding.sh`, which draws one two-tone X from a handful of
coordinates and writes each platform's sizes. Change a colour or a coordinate
there and re-run it; do not touch the PNGs, the `ic_launcher_*` XML or
`values*/ic_launcher_background.xml` by hand, because the next run overwrites
them. It needs ImageMagick 7 and Cantarell Extra Bold for the wordmark.

The Android launcher icon is an adaptive icon: a flat background colour, a
vector foreground, and a monochrome layer for Android 13 themed icons. The
foreground keeps the mark inside the circle every launcher mask leaves visible,
so widening the X in the script means checking that first.

## Use cheaper models for mechanical work

When an agent delegates, mechanical subtasks (formatting, renames, moving
code, re-recording fixtures, running the verification above) go to a
smaller model; keep the larger model for design and for anything that
reads stremio-core to decide a wire shape.
