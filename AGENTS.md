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

## The subtitle menu re-times files, and the multiplier is the risk

`subtitleSpeed` (`lib/features/player/subtitle_groups.dart`) says what
libmpv's `sub-speed` has to be for an upload cut at one frame rate to
keep time with a video running at another, and
`PlaybackEngine.setSubtitleSpeed` is what writes it. It replaces a filter
that dropped those files: a 25 fps subtitle against a 23.976 fps film
drifts four seconds a minute, but the drift is linear, so one multiplier
removes it and nothing has to be hidden. Each rule below has a test; see
README, *Subtitles*.

- **The ratio is `fps_sub / fps_video`, and the reciprocal is the bug.**
  A film of N frames sits at `N / fps_sub` in the subtitle and at
  `N / fps_video` in the picture, so 25 against 23.976 is 1.0427.
  Reversed it does not half-fix the drift, it doubles it -- the cue lands
  further from where it belongs than leaving the file alone.
- **Every path that changes what is shown puts it back to 1.0.** Another
  file, an embedded track, subtitles off, the next video, and the
  auto-pick restoring the tracks after the engine refused a file: all of
  them go through `PlayerScreen._retimeSubtitles`, which is why they are
  one call. The multiplier belongs to the player, not to the file, so one
  left over from the last pick silently ruins a subtitle that was
  correct, which is worse than the problem being solved. A path that
  *undoes* a change is one of these -- the refused pick was the hole --
  so add a path, add its reset and its test.
- **Only what the container declares is a rate.** `videoFrameRate` reads
  `container-fps` and nothing else. `estimated-vf-fps` is the obvious
  second choice and is a *measurement* -- ten frame durations averaged,
  read the moment the media loads, which mpv's own manual calls unstable
  for the imprecise timestamps a torrent stream is full of. Fed to a
  comparison with a hundredth-of-a-frame tolerance it re-times the files
  that were right. Do not add a fallback.
- **An unknown rate corrects nothing.** Cast, offline, a fake, a
  container that says nothing, a read that threw: all of it is null, and
  null means every file is played exactly as it was written. Never
  substitute a default, a guess or a last-known rate -- a guess here
  breaks a subtitle that was in sync.
- **Nothing is hidden; what the rate decides is the order.**
  `subtitlesByFrameRateFit` puts a language's files that need no
  correction first, then the ones that declared no rate, then the ones a
  multiplier has to fix -- an addon's `fpsMilli` is a claim about the
  release the upload was made for, and a claim can be wrong, so a file
  that needs nothing is worth more than one we fix. Between languages
  nothing moves and inside a rank the addon that answered first still
  wins, because that is the file a language row applies.

Three more things that are easy to undo by accident:

- **Everything that consumes the subtitle list orders it.** There are two
  consumers, the menu and the session preference's auto-pick, and the
  auto-pick is the one that applies a file without the viewer looking. It
  waits for the engine to have answered about the rate
  (`_frameRateSampled`) before it runs, because the sample resolves a
  microtask after it is started, and a pick made before it would play the
  addons' first answer uncorrected. A third consumer must do both.
- **The tolerance is 0.01 fps at the content's own rate, and the ratios
  that reach it are the ones that preserve *seconds*.** A subtitle is
  timed in wall-clock seconds, so telecine and frame doubling (5/4, 2,
  5/2) are the same cut and need no correction -- 23.976 film in a 29.97
  container is identical seconds -- while 25 against 23.976 is a 4.3 %
  speed-up and does. The same reduction is what keeps the multiplier
  honest, and it runs on *both* numbers: a 50 fps PAL encode is 25 fps
  material and a 29.97 fps container is 23.976 fps film, so the ratio is
  the one nearest 1 over both families and not a single step off the
  video's declared rate -- reducing the file alone answers 0.834 there,
  which is worse than doing nothing. Widening the tolerance instead of
  adding a ratio is the wrong repair: 0.01 is what separates a rounded
  `23980` from a real 24 fps cut. And a ratio outside `sub-speed`'s own
  `<0.1-10.0>` is not a frame rate but a mis-scaled `fpsMilli`; it has to
  answer 1.0, because media_kit discards the property write's return code
  and mpv refuses such a value in silence, leaving the last file's
  multiplier in force.
- **A corrected row says one word, and never the number.** `re-timed`
  under the addon's name (`SubtitleMenu.retimedNote`), on the file's own
  row and on the language row that applies it, because a viewer whose
  subtitles still drift has to know we touched this one before comparing
  it with another. The rate is never shown anywhere: the request was a
  list that is right, not a number to reason about.

An upload's *name* in that menu is addon text as well, and it is subject
to the same suspicion: it goes through `wellFormedText`, it is cut to
sixty characters whichever property it came from (and the row caps at two
lines besides, because a `ListTile` grows to fit), and it gets its
position back on the end when another file of the same language derives
the same name (`1 (2)`). Addons repeat themselves -- all three Czech files
OpenSubtitles answers for The Godfather are called `1.srt` -- and the
`Option N` these names replaced was at least unique.

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

## Six rules a real device taught us

Five of these were bugs on a real Chromecast with Google TV and the sixth
was a red box on a 400 dp phone; every one of them is easy to write again.
Each has a test behind it, except where the rule itself says a test cannot
reach it.

- **Nothing vetoes the OSD's fade on a focus.**
  `PlayerScreen._canAutoHide` lists what keeps the controls up -- a menu, a
  scrub, a stall, the start-up overlay, playback not running -- and a
  control *holding focus* is deliberately not on that list. On a television
  the remote has nowhere to put focus but the bar, so a veto there latches:
  the first D-pad press pinned the OSD for the rest of the session, and the
  subtitles stayed lifted clear of it for just as long. What makes that safe
  is that hiding the bar and handing the remote back to the video are one
  act (`_hideControls`), so nothing is ever left focused on something that
  is not drawn -- and that every state which flips `_canAutoHide` back to
  true re-arms the timer as it goes.
- **A direction key never leaves a layer.** Once the remote is in the
  control bar, up from the top row and down from the transport row
  dead-end, because directional traversal is confined to the enclosing
  `FocusScope` (`_controlsScope`, `_upNextScope`). The video is not a
  legitimate focus target while something visible is on screen: stepping
  out onto it puts the ring nowhere. Back is the way out, and it comes down
  a ladder, most transient first. A rung only exists while it would visibly
  do something -- a bar that cannot fade (paused, buffering, a menu, the
  end of a film) is not one, and Back leaves instead of appearing to do
  nothing.
- **A button drawn inside a focusable thing is not a button.** On a
  television a tile, a row or a text field takes focus as a whole, so
  directional traversal has nothing inside it to move to, and the
  `RemotePress` above it takes select before any descendant's own
  activation runs. Anything that must be pressed on its own goes *beside*
  the thing, outside that `RemotePress` -- see `TvTextField.onClear`. Drawn
  and dead is worse than absent.
- **A subtitle's position is pushed, not configured.** media_kit's
  `SubtitleView` reads `SubtitleViewConfiguration.padding` once, when its
  state is created, and a `GlobalKey` inside `VideoState` keeps that state
  alive for the session; the style and the scaler it does re-read, which is
  what makes the omission look like it works. Moving the subtitles means
  `VideoState.setSubtitleViewPadding`, on the frame after the build that
  computed the value (it is a `setState` below the widget being built), and
  only when it changed. Widget tests cannot catch a regression here: the
  fake engine records the argument, it does not lay out a `SubtitleView`.
- **A scrolling strip clips, so a focused tile needs room to grow.** Once a
  row holds more than fits, its viewport paints behind a clip of exactly
  its own bounds, and a tile in a horizontal list is laid out to exactly
  that height -- so the zoom and the shadow a focused tile wears are cut
  off at both edges and the cue reads as a crop. The room comes out of the
  strip's own padding (`_RowLayout.focusSlack`), and only on a television,
  which is the only place anything zooms.
- **A width shared between N things is clamped at zero.** Anything of the
  form `(width - gaps) / n` goes negative on a narrow screen with a large
  `n` -- thirty-odd season pills on a phone -- and a negative `minWidth` is
  not a cramped layout but a `NOT NORMALIZED` constraints failure that
  takes the whole sliver, and everything below it, down with it. Release
  builds clamp and debug builds throw, so this is a red box the owner sees
  and CI does not.

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
