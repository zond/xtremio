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

## Nothing re-times a subtitle but the viewer

A declared frame rate says where an upload came from, not how it is
timed. Ten English subtitles for one film declaring six different rates
all end within 1 % of the same runtime; five Gilmore Girls files at
25 fps really do run 4.27 % short against the five at 23.976. Nothing in
the metadata separates those two populations, so anything applied
automatically fixes one and breaks the other in equal measure -- and
breaks it silently, on a file that was in sync when it arrived. So
`sub-speed` and `sub-delay` are the viewer's alone, through the panel
behind "Adjust timing" (`SubtitleTiming` in
`lib/features/player/subtitle_timing.dart`). What a rate still decides
is the *direction* of one button, and nothing else -- the list is
ordered by the release an upload was cut for. Each rule below has a
test; see README, *Subtitles*.

- **The ratio is `fps_sub / fps_video`, and the reciprocal is the bug.**
  A film of N frames sits at `N / fps_sub` in the subtitle and at
  `N / fps_video` in the picture, so 25 against 23.976 is 1.0427
  (`SubtitleTiming.speedStep`). Reversed it does not half-fix the drift,
  it doubles it -- the cue lands further from where it belongs than
  leaving the file alone. That is why the speed control is pointed by
  the video rather than offered both ways, and
  `subtitleSpeedDirection` is what points it.
- **The video picks the direction, and only the container may say so.**
  Frame rates are two lineages -- film (23.976, 24, and the 29.97, 30,
  47.952, 48, 59.94, 60 telecined or doubled off them, all the same
  seconds) and PAL (25, 50, 4.27 % faster) -- and drift appears only
  between them. So a film-family video is facing a PAL-sourced file and
  needs it stretched, a PAL-family video the reverse, and the two
  families are disjoint under `subtitleFrameRateRatios`. **Two buttons
  exist for exactly one case**: a container that declares no rate, or a
  rate in neither family, where no direction can be chosen and a stream
  would otherwise be unfixable. A measurement must never reach this: a
  stall rendering 12 frames a second reads as film (12 is 24 halved) and
  points the button confidently the wrong way.
- **A correction in force always has its own button.** That is not a
  second case for the pair above but the rule below kept reachable: the
  gap where a ruled-out direction would be cannot be pressed, so a
  correction in force in it could only be swapped for its reciprocal by
  the button that *is* drawn, and never taken back to 1.0 at all. It is
  reachable without anything remembering anything, because the rate is
  observed rather than read -- mpv reports `container-fps` when it has
  probed the container, which on a torrent is well after playback began
  -- and a press made while it still says nothing can land in the
  direction the answer then rules out.
- **The speed is a toggle, so a second press is exactly 1.0.**
  `SubtitleTiming.speedDirection` is a direction and not a count of
  presses, which is what makes that structural rather than arithmetic --
  a stepper's two presses were the ratio squared, nine per cent out and
  a state nobody means to reach. It follows that the multiplier is three
  values, all far inside `sub-speed`'s `<0.1-10.0>`, so no press can
  reach a write mpv would refuse in silence. The shift is still counted
  in integer presses (ten forward and ten back must land on zero) and is
  still the only hold-to-repeat in the app; a *toggle* must never repeat,
  since held at the stepper's rate it flips eight times a second and
  lands wherever the release falls.
- **Every path that changes what is shown recomputes both from
  scratch.** Another file, an embedded track, subtitles off, the next
  video, and the auto-pick restoring the tracks after the engine refused
  a file: all of them go through `PlayerScreen._resetSubtitleTiming`,
  which is why they are one call, and which is why it replaces the whole
  `SubtitleTiming` rather than one number of it. Both belong to the
  player, not to the file, so one left over from the last pick silently
  ruins a subtitle that was correct, which is worse than the problem
  being solved. A path that *undoes* a change is one of these -- the
  refused pick was the hole -- so add a path, add its reset and its
  test. What it resets *to* is what the viewer is remembered to have
  fixed about the file going on screen (below), and untouched whenever
  nothing is: an embedded track, subtitles off, an addon that names no
  group. Nothing else writes either property, so the value after this
  call is always the whole of what mpv is playing.
- **What the viewer fixed is remembered under what caused it, and the
  two keys are deliberately different.** `SubtitleSyncMemory`
  (`lib/core/subtitle_sync.dart`, one preferences key, `subtitleSync`)
  keys a *speed* on the series and the addon's `g`, because what a file
  was timed against is a property of where it came from and video
  releases of one show share a frame rate; it keys a *shift* on the
  video release as well, because an offset is the video's pre-roll less
  whatever the subtitle's source assumed and so depends on both sides.
  The release is the whole filename from `castFilename` -- the file the
  server says it opened, else the addon's claim -- lower-cased, and not
  a release group parsed out of it: a parse is a guess, and two encodes
  by one group can still start in different places. Any part of a key
  nobody can name means that adjustment is not remembered at all, and
  back to untouched is *forgotten* rather than stored as a zero, since
  nothing remembered is what nothing applied looks like next time. A
  narrower key is forgotten more often, which is the price of never
  being wrong. **A remembered speed the video's own family contradicts
  is not applied.** A speed carries across releases because releases of
  one show almost always share a rate; where one does not, putting it
  back is the reciprocal mistake the first rule above is about. It is
  dropped rather than reversed -- a remembered stretch says the group's
  files are PAL-timed, and a PAL-timed file on a PAL video needs
  nothing -- and it stays in the file, because the next release is
  likely to be the family it was learned on. **The rule runs again when
  a late rate arrives**, because the rate is observed and on a torrent
  that is normally after the file went on: enforcing it only where the
  answer was already in makes it dead code for exactly the population it
  was written for, and leaves 4.27 % on a subtitle that was in sync when
  it arrived, with nothing that resets it. Only the machine's speed is
  withdrawn -- `PlayerScreen._restoredSpeed` is what tells the two
  apart -- because a press is a judgement about the drift on screen, and
  a press keeps its own button, so the toggle back to exactly 1.0 stays
  reachable.
- **Only a press on the panel is a judgement, and a press does not
  write.** `_adjustTiming` is the one path that remembers; every other
  call on the timing is the machine putting a file back the way it found
  it, and writing that down would overwrite what an earlier evening
  decided. The write itself waits (`_pendingSync`) until the adjusting
  is over -- the panel closing, something changing what is on screen, or
  the player going away -- because the shift repeats eight times a
  second under a held key and two overlapping `prefsSet` calls land on
  FRB's worker pool in no particular order, so twenty of them could
  leave the file holding a number the panel is not showing. What waits
  is a closure over the file the press was made on, and
  `_resetSubtitleTiming` flushes it *before* it moves, or the next press
  on the file that replaced it drops the one before. The flush in
  `dispose` runs *after* the preferences listener is removed, and that
  order is load-bearing: writing a preference notifies synchronously,
  and a notification answered from inside `dispose` is a `setState` on
  an element the framework has already marked defunct. `mounted` does
  not catch it -- `StatefulElement.unmount` marks the element defunct
  before it calls `dispose` and clears `state._element` only after -- so
  a debug build throws on `markNeedsBuild`'s assert. Both paths that
  reach it, the up-next hand-over and the stop key, leave the panel
  open, so this is the ordinary way out and not an edge.
- **Both values are re-applied after a re-open, and the file goes back
  first.** A network error, a false end of file and a buffer change all
  re-open the stream keeping the position; the values belong to the
  playback, not to the file the demuxer just re-read. An `open` is a
  fresh `loadfile`: nothing `sub-add` put in survives one
  (`MediaKitEngine.open` clears its own record of them for the same
  reason) and nothing re-adds it, since the auto-pick has counted itself
  done and a re-open does not re-arm it. Writing the timing onto
  whatever mpv then selects by its own rules puts a gone file's
  multiplier on a track that was in step, four seconds a minute out with
  no path that resets it, so `_restoreExternalSubtitle` runs before
  `_applySubtitleTiming` -- which is why the applied file is remembered
  next to the timing at all.
- **What the viewer does ends the guessing, not just the correcting.**
  A pick from the menu and a press on the panel both stop the session
  preference's auto-pick for that media (`_subtitlesChosenByHand`).
  `_autoPickedSubtitles` records only that the engine *accepted* a pick,
  so an engine that keeps refusing one leaves the auto-pick retrying on
  every player-state and tracks event for the rest of the media -- which
  is what that retry is for -- and every retry replaces the whole
  `SubtitleTiming` and, on the way back out of the refusal, the
  selection with it. Without the stop, a shift vanished a second after
  it was made and again a second later, while the viewer was watching
  the picture for it to take effect, and a file they had chosen
  themselves was taken away. It is per media, cleared with the rest of
  the per-`open` state.
- **An undo that arrives late undoes only its own work.** `sub-add` is
  mpv fetching a URL under `network-timeout`, so the auto-pick's
  rejection can land minutes after the call and the viewer can have
  picked a file and adjusted it meanwhile. The revert checks that what
  is on screen is still the id it applied before putting anything back,
  and it moves `_timing` inside a `setState`: it is the one path that
  changes the timing outside a build, and the panel is drawn from it, so
  without one the numbers on screen are not the numbers mpv is playing.
- **The panel is not the OSD and must never join it.** Adjusting means
  pressing and then watching the picture for several seconds, so a panel
  on the bar's three-second timer would be gone before the first
  judgement. It is drawn outside the fade rather than added to
  `_canAutoHide` -- pinning the bar up over the picture being judged is
  the wrong half of the problem -- and letting the bar go while it stays
  is safe only because the ring is still on something drawn. It has its
  own focus scope so a left press walks its row instead of seeking, and
  its own rung on the Back ladder above the bar, on every device rather
  than only on a television, since on a phone Back is the only way out.
  The row a direction key walks may hold one button rather than two, so
  a press with nowhere to go has to stay in the panel rather than fall
  through to the seek bar.
- **Only what the container declares is a rate, and it is observed
  rather than asked for.** `videoFrameRate` is an `observeProperty` on
  `container-fps` and nothing else, because when mpv knows the rate is
  not ours to choose: it learns it as the demuxer probes the container,
  and a torrent's container is only there once the pieces holding it
  have arrived. A read taken at any fixed moment calls such a video's
  rate unknown for the whole film, which is what offered both speed
  buttons for a 23.976 episode. A late answer may point the button, and
  that is safe only because of the rule above -- a correction in force
  keeps its own button -- so do not weaken that one.
  `estimated-vf-fps` is the obvious second choice and is a *measurement*
  -- ten frame durations averaged, which mpv's own manual calls unstable
  for the imprecise timestamps a torrent stream is full of. It would
  point the speed button off a number the stall invented, confidently
  and the wrong way, and observed it would do so on every stall. Do not
  add a fallback: there is one property, not a list of them.
- **An unknown rate decides nothing.** Cast, offline, a fake, a
  container that says nothing, a read that threw: all of it is null, and
  null means the panel offers both directions and a remembered speed put
  back unchallenged. Never substitute a default, a guess or a last-known
  rate. Two things read the rate and both have to answer again when a
  late observation changes it -- the panel's direction, and the
  remembered speed above -- so unknown is a state to be left behind,
  never a verdict to be recorded.
- **Nothing is hidden; what orders a language is the release.**
  `subtitlesByRelease` puts a language's files that the addon says were
  cut for the release actually playing first, then the ones from a group
  the viewer has already adjusted for this series, then the addons' own
  order. The first rank is evidence about *this video*: two files cut
  for one release keep its time, where a declared rate says only where
  an upload came from. The second is worth having because the
  correction goes back on when the file is applied, so it arrives fixed
  -- which is why it asks `SubtitleSyncMemory` exactly what
  `_resetSubtitleTiming` will ask it, and why a shift measured against
  another release does not rank: a rank must not promise a fix that
  never comes. Between languages nothing moves and inside a rank the
  addon that answered first still wins, because that is the file a
  language row applies. Ordering by the rate is the thing not to put
  back: it had to be taught that a claim beats no claim, and then that a
  mis-scaled `fpsMilli` beats neither, and the premise under all of it
  was still wrong.
- **A release match is whole tokens, and a false one is worse than
  none.** `subtitleMatchesRelease` compares the addon's `releaseGroup`
  and `movieReleaseName` against the name the player knows the video by
  (`castFilename`, the same one a shift is keyed on), both cut into
  lower-case runs of letters and digits, and the claim has to appear as
  a contiguous run of whole tokens. A match puts a file at the head of
  its language, which is what the row applies and what the auto-pick
  plays with nobody looking -- so part of a word is not a match (`DFN`
  never claims a DFNX rip), scattered tokens are not (`BluRay` and
  `x264` from opposite ends of a name describe a kind of encode), and a
  lone bare number or two-letter tag is not, since a year and a
  resolution are what a bad parse leaves in those fields. **A release
  *name* also has to reach past the front of the filename**: a run
  starting at the first token and stopping short of the last is the
  show, the episode and its title, which every upload of that episode
  carries. Against the real OpenSubtitles answer for one Gilmore Girls
  episode, twelve files matched the playing name and eleven of them
  claimed only that -- one claiming `Gilmore Girls` matched every
  filename tried -- each marked "same release" and sent to the head of
  its language ahead of the file that did name the rip. A release
  *group* is never the show's title and still counts wherever it sits,
  which is what keeps the one genuine match in that answer. Both sides
  lose a trailing container extension first, since agreeing where a name
  ends is what "to the end" needs, and an addon writing `.mkv` where the
  server opened the `.mp4` is naming the same release. A claim matching
  *every* file of a language costs nothing, because a rank keeps the
  addons' order inside it; a generic claim on *one* file of a language
  is the harmful shape, and is what the rule above is for.

Three more things that are easy to undo by accident:

- **Everything that consumes the subtitle list orders it.** There are two
  consumers, the menu and the session preference's auto-pick, and the
  auto-pick is the one that applies a file without the viewer looking, so
  a consumer that skipped the ordering would play whichever addon
  answered first. Both go through `PlayerScreen._offeredSubtitles`, which
  is one call rather than four arguments repeated twice; a third consumer
  calls it too. Nothing waits on anything to run it -- the ordering asked
  the engine for the rate until the release replaced it, and what it asks
  now (the server's filename, the series, the memory) is either there or
  is not.
- **The tolerance is 0.01 fps, and the ratios that reach it are the ones
  that preserve *seconds*.** A subtitle is timed in wall-clock seconds,
  so telecine and frame doubling (5/4, 2, 5/2) leave a rate in the same
  family -- 23.976 film in a 29.97 container is identical seconds --
  while 25 against 23.976 is a 4.3 % speed-up and is the other family.
  That reduction is the whole of what a declared rate is used for now:
  it places the *video* in its family so the speed button can be pointed.
  Widening the tolerance instead of adding a ratio is the wrong repair:
  0.01 is what separates a rounded 23.98 from a real 24 fps cut.
- **A row says the addon and why it is first, never a rate or a
  verdict.** A file matching the release earns two words for it
  (`SubtitleMenu.releaseNote`), on the row and on the language row that
  would apply it, because a row that is first for a reason should say
  the reason. That is a fact about the upload; the declared rate is
  still shown nowhere, and neither is any judgement about a file's
  timing. The request was a list that is right and a button that presses
  the right way, not a number to reason about.

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

## Seven rules a real device taught us

Five of these were bugs on a real Chromecast with Google TV, the sixth was
a red box on a 400 dp phone and the seventh has been written twice
already; every one of them is easy to write again. Each has a test behind
it, except where the rule itself says a test cannot reach it.

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
- **A row a remote walks is built all at once.** Directional traversal
  only considers widgets that have been built, so a `ListView.builder`
  strip hands the D-pad back at the last realised tile and the rest of the
  row cannot be reached at all -- silently, and only on a row longer than
  the screen. A row the remote walks end to end is a
  `SingleChildScrollView` over a `Row` (the season pills, the episode
  cards), and its test walks to the *last* item of a row with more items
  than fit. What that costs is paid down by bounding each image's decode
  to the box it is drawn in, not by building fewer widgets.
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
