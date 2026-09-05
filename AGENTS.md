# Working on Xtremio

Conventions for people and agents changing this repository. `README.md`
explains what the code does; this is about how changes are made.

## Read first

- `docs/ARCHITECTURE.md`, "How the Rust core is wired in" (state crosses as
  JSON, what each model field is, what the app reads from the settings).
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
  recorded by the `#[ignore]` network tests in `rust/tests/`
  (`docs/OPERATIONS.md` lists the `cargo test --test <name> -- --ignored`
  commands) and loaded
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
it, and the platform registrations are listed in `docs/DEEP_LINKS.md`. A
widget test drives links through `FakeDeepLinks` (`test/support/`);
nothing in the tests touches `app_links`.

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
`lib/features/player/subtitle_timing.dart`). **A declared rate now
decides nothing**: it ordered the list once and pointed one button once,
and neither is true any more. Each rule below has a test; see
`docs/ARCHITECTURE.md`, *Subtitles*.

- **A multiplier is measured, never judged.** The toggle that offered
  25/23.976 and its reciprocal is gone, and so are
  `SubtitleSpeedDirection`, `subtitleSpeedDirection` and the
  frame-rate-family reduction that pointed it. It was both too blunt and
  too narrow for the case it existed for: the owner's Swedish Gilmore
  Girls file needs 1.0440 where the PAL constant is 1.0427, PAL-ish plus
  0.12 %, three seconds across an episode that no toggle reaches and no
  offset cancels. **A rate is only ever derived from evidence about
  these two files -- a scored alignment, or two marks far enough apart
  to have a lever arm -- and never from a declared frame rate.** Do not
  re-derive a multiplier from a rate an addon or a container claims;
  that is the premise this whole section exists to refuse.
- **One of the two mechanisms is built and one is not, and the
  difference is not cosmetic.** What the viewer has is the match
  (`subtitles_match`, below). `SubtitleCalibration`
  (`lib/features/player/subtitle_calibration.dart`) solves the same line
  from marks the viewer makes -- "this line belongs at this moment" --
  and it is **not reachable from the sofa**: nothing in `lib/`
  constructs a `SubtitleMark`, there is no "This is right" on the panel,
  and nothing reads `sub-start`. It is a solver with its tests and no
  consumer. So a language that answers with one file, or with several
  that share the same bad timing, has no rate fix at all today, and no
  document here or in README may say otherwise. Wiring it up means
  answering the question its own header leaves open first: whether
  mpv's `sub-start` reports a cue already moved by `sub-delay` and
  `sub-speed` or its raw time in the file, **verified against the
  running player** rather than against the manual -- the sign of
  `sub-speed` was assumed from documentation once and had to be
  confirmed on the owner's television.
- **The panel shows the multiplier and cannot press it.** A subtitle
  that is right at this moment and wrong in ten minutes looks exactly
  like one that is right, so the number is the only thing on screen that
  says which -- and the panel is the surface operated *after* the OSD
  bar has faded. The row draws the space two buttons would have taken so
  the number stays in the shift row's column.
- **The shift accelerates under a hold, and only under a hold.** Ten
  steps of a tenth, fifteen of a whole second, then five-second strides
  (`SubtitleTimingOverlay.shiftStrideAt`). The offsets are three orders
  of magnitude apart -- a tenth is what is visible against speech, a
  mis-cut release is out by seconds, an uncorrected PAL file is a
  hundred and fifteen seconds out by the end of an episode -- eleven
  hundred presses at a tenth each, which is where the strides come
  from. They are what a second mark would need too, if the marks were
  ever wired up; nothing makes one today and the strides do not wait on
  that. The stride count belongs to the button and a
  release, a cancel or a lost focus ends it, so **every tap is a tenth**
  however large the correction before it was; and every stride is a
  whole number of presses, so ten forward and ten back still land on
  zero. This is still the only hold-to-repeat in the app.
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
  stores a multiplier and an offset in seconds, both real numbers
  because both are measured, and keys a *speed* on the series and the
  addon's `g`, because what a file
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
  being wrong. **The file is forgiving, so the player is where a stored
  multiplier is refused.** `PlayerScreen._rememberedSpeed` checks it
  against mpv's `<0.1-10.0>` (`minSubtitleSpeed`/`maxSubtitleSpeed`):
  media_kit writes `sub-speed` with `mpv_set_property_string` and throws
  the return code away, so a value outside it is refused in silence
  while the *previous* file's multiplier keeps running under a panel
  claiming this one. A row the toggle's build wrote -- a direction
  string, a count of presses under `shift` -- is dropped rather than
  reinterpreted, which is what the rename to `shiftSeconds` is for:
  three presses read as three seconds is thirty times the adjustment
  that was made. **What is not guarded any more** is a remembered
  multiplier carried onto a release of the other frame-rate family. The
  rule that dropped one read a stored `stretch` as "this group's files
  are PAL-timed", which is an inference about a toggle's two values and
  not about a measurement. If it bites, key the speed on the release as
  the shift already is; do not reason from a declared rate again.
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
  A press with nowhere to go along a row -- left at the first stepper --
  has to stay in the panel rather than fall through to the seek bar.
  **It scrolls inside whatever height it is given**, because what it is
  tall enough for is not its own to decide: a 360 dp-tall phone held
  sideways leaves it under 300, and with the match button and a
  refusal's three lines on it the panel that overflowed pushed Reset off
  the bottom of the screen -- Reset being the way back from the state
  the viewer had just landed in. Anything added to it is added to a
  column that already does not fit somewhere.
- **A match is measured in Rust, chosen by the viewer, and refused out
  loud.** "Match to another subtitle" solves for the ratio and offset
  mapping the playing file onto one the viewer says is in sync
  (`rust/src/subtitles.rs`, `subtitles_match` over FFI;
  `SubtitleMatchClient` in `lib/features/player/subtitle_match.dart`).
  Each thing that holds it up has a test. **Both timestamps of every
  cue are read**, and each file becomes a bitmap of when it has text on
  screen. Comparing cue *starts* is what this replaced, and it refused
  the owner's own Swedish Gilmore Girls file against an English one: a
  translator merges lines and gives the merged line its own beat, so
  that file has 690 cues where the English has 1024 and only 54 % of its
  starts land within a third of a second of an English start. Overlap
  does not mind -- a merged line covers both the lines it replaced --
  and the same representation is what a future version would correlate
  against the audio's own speech detection, which is the only real
  ground truth. **One damaged cue does not decide how long a file
  is.** Everything downstream reads the *last* moment a file has text on
  screen: it is the length of the bitmap, and it is the timeline both
  files' densities and so the chance term are measured over. So a stamp
  that parses and is wrong is not one cue's worth of damage -- an
  appended `01:00:00,000` on a twenty-minute file triples the timeline,
  divides chance by three and decays the score into the raw Dice
  coefficient this module exists to *not* threshold (measured, an
  unrelated pair went from refused to convincing), and one mistyped hour
  digit on a cue's *end* lights fifty hours of invented timeline and
  refuses a pairing that is perfect. `cue_spans` therefore answers what
  the file describes: a cue reaching further past the body of the file
  than a tenth of it or ten minutes is dropped like one that ends before
  it starts, with a six-hour stop under that for a file with no body to
  read at all -- four billion seconds of timeline is a 34 GB allocation,
  and Rust aborts rather than unwinding, so `guarded` never sees it. A
  healthy file loses nothing. **What two cues share is on screen once.**
  `Bitmap::of` takes the union of the cues over a bin and not their sum:
  an SDH speaker label beside its line, a sign captioned over dialogue
  and a song under both are one lit interval, and adding their shares up
  counts a moment as many times as the file happens to write it -- the
  tests' own file with every cue doubled read a density of 0.81 where it
  is 0.66, and two cues covering three tenths of a bin between them
  summed to six tenths and lit it, which is the opposite of the "at
  least half" rule below. This is why nothing deduplicates and why the
  parse sorts. **The score is the overlap *above chance*, never the
  overlap.** Subtitles are on screen two thirds of the time, so two
  unrelated files already overlap heavily; what is reported and
  thresholded is `(dice - chance) / (1 - chance)`, `chance` coming from
  the two files' own densities. Do not threshold Dice, a count of cues,
  or anything else that a talkative programme moves. **`CONVINCING` is
  measured, at 0.45, and the populations it separates overlap.** 39,000
  pairings of 717 real files from the OpenSubtitles addon -- forty films
  and episodes, thirty-seven languages -- put the pairings whose
  transform is right (median cue start within a third of a second of the
  reference's nearest, half of them that close: a statistic the score
  does not use) at a fifth percentile of 0.54 and a median of 0.81, and
  the deliberate mismatches at a best of **0.376** over 30,918 of them,
  0.222 for a different episode of the same season. The worst pairing
  that should be applied scores below the best mismatch, **so there is no
  gap and the number is set above the mismatches rather than between the
  two**: 0.45 clears the best of them by 0.074 and refuses one in fifty
  of the pairings that really align. Do not lower it to catch those --
  0.40 leaves 0.024 of margin and 0.35 lets nine mismatches through --
  and do not move it on an argument that has not been measured:
  `rust/tests/subtitle_threshold.rs` records the corpus, the populations
  and the cost of each neighbouring threshold, its guard tests pin the
  constant into the window the numbers allow, and
  `cargo test --release --test subtitle_threshold -- --ignored` takes the
  measurement again. **What the threshold costs is a scoring problem, not
  a threshold one**: the pairings it refuses are those whose two files
  keep text on screen for very different shares of the episode, where
  Dice's own ceiling holds the score down however well the lines land --
  a partial track that recovers the ratio exactly and lands four fifths
  of its starts within a third of a second scored 0.33, under the
  mismatches' own best. Taking those means a different score, not a lower
  number. The fixture's four worst pairings to apply are *not* that and
  are older than the horizon above: all four name one file, all four
  found the right transform and all four scored about zero, which is a
  stretched timeline rather than a ceiling, so re-recording should lose
  them. **The score is the
  answer either way, and a refusal says what was found**: the score
  *and* the transform. A fraction of cues is what sent the owner looking
  for a different reference when the reference was fine, and it is not
  comparable between a file that merges lines and one that does not.
  **Nothing to measure is a different answer and says so**, naming both
  files' cue counts and carrying no score at all: a file that could not
  be read as a subtitle is a different problem from two files that
  disagree, and a percentage would describe the file the viewer is
  trying to fix instead of the one they picked badly. **Fifty cues is
  the floor on both sides** (`FEWEST_CUES`), inherited and now generous:
  scoring against chance moved the count at which an unrelated pair
  stops being alignable by accident down to about eight a side. It stays
  because a file with fewer cues is a signs track rather than a
  translation, and because the mismatches that come closest to convincing
  are the shortest files in the calibration corpus. **The rate window stays
  0.90 to 1.10**, because PAL is 4.27 % away and finding it *unaided* is
  the point; that is too wide to sweep against every offset at a tenth
  of a second, so the search is coarse to fine -- a second per bin over
  the whole window, then 100 ms and 20 ms near the winner -- and the
  ratio step comes from the file's length rather than a constant, so the
  step nearest the right answer keeps the whole file inside a bin. A bin
  is lit when text covers at least *half* of it: lighting it from any
  overlap leaves an episode ninety per cent lit at a second per bin,
  with no headroom above chance to measure in, and the right ratio then
  scored 0.14 where a wrong one scored 0.34. **The reference is never
  guessed**, since the measurement is only as good as that file's own
  sync with the video and no metadata knows which file that is -- which
  is also why the option is not drawn at all with nothing else on offer,
  and why the sheet that asks is one row per language with the rest
  behind a row of their own, the subtitle menu's shape and for its
  reason: a language answers with sixty-nine files, and the *other*
  language is what a viewer opening this sheet is reaching for. **A
  subtitle URL is never quoted back**: it can carry a debrid API key, so
  `crate::env::fetch_text` strips it out of every failure and the panel
  says one fixed sentence. What is measured belongs to the file it was
  measured for, so `_resetSubtitleTiming` drops the note and an answer
  that lands after the subtitle changed is thrown away.
- **Nothing in the player reads the video's frame rate.** There is no
  `videoFrameRate` on the engine and no observation of `container-fps`
  for subtitles: the one thing that used it was the toggle's direction.
  `PlaybackStats` still polls the property, but only while the stats OSD
  is on screen and only to print it. Adding the observation back means
  adding a consumer that reasons from a declared rate, which is what
  this section refuses.
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
labelled. See `docs/ADDONS.md`.

## Eleven rules a real device taught us

Most of these were bugs on a real Chromecast with Google TV; one was a red
box on a 400 dp phone, one has been written twice already, and the last
four came out of living with the details screen on one. Every one of them
is easy to write again. Each has a test behind it, except where the rule
itself says a test cannot reach it.

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
  nothing. **So a rung asks what is on screen, never a field that says
  what should be.** The details screen draws its open row of sources for a
  group that is still in the list, and keyed its rung to the label being
  set instead: a label naming a rung the streams had stopped offering lost
  the row and kept the rung, and the press that should have left the
  screen did nothing at all.
- **A button drawn inside a focusable thing is not a button.** On a
  television a tile, a row or a text field takes focus as a whole, and the
  `RemotePress` above it takes select before any descendant's own
  activation runs. Anything that must be pressed on its own goes *beside*
  the thing, outside that `RemotePress` -- see `TvTextField.onClear` and
  the addon health verdict, which is drawn under its tile rather than in
  it. Drawn and dead is worse than absent. `FocusableTile` now enforces
  the rule rather than stating it: on a television it wraps its child in
  an `ExcludeFocus`, so **directional traversal really does have nothing
  inside a tile to move to**. It used to, and the failure was invisible --
  the installed list's ⋮ menus took focus one per row, the ring lit up on
  the whole tile as if the tile had it, select still opened the addon, and
  the walk went menu to menu past everything drawn under a row.
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
  cards, both rows of source cards), and its test walks to the *last* item
  of a row with more items than fit. What that costs is paid down by bounding each image's decode
  to the box it is drawn in, not by building fewer widgets -- which is
  affordable because each such row has a natural bound: a season, a
  catalog page, the sources of one group. A list with no bound needs one
  before it becomes a row.
- **A sideways press at the end of a row stays in the row.** Directional
  traversal takes the nearest node in the direction pressed and nothing
  confines that to the row: right at the last source card landed on the
  layout toggle in the header three rows up, off a press that reads as
  "the next card", and the way back is a press down and a guess at which
  row it lands in. So a row the remote walks swallows left at its first
  focus stop and right at its last (`_Strip` in `tv_source_row.dart`;
  `RootShell._onRailKey` does the same for the rail's up and down). Every
  other key passes -- up and down are the way out and have to keep
  working.
- **Anything the remote can land on wears the app's own focus
  indicator.** Material marks a focused button with a tint of about a
  tenth, which over poster art or a darkened backdrop, on a panel in a
  room this app knows nothing about, is exactly the cue that disappears --
  the reason `FocusHighlight` draws three of them. A control with a focus
  node and no ring is one the remote can reach and nobody can find, which
  is the same class of fault as a button that is drawn and dead.
  `FocusHighlighted` puts the ring on a control that owns its own node (a
  chip, an `IconButton`) without touching traversal.
- **An image holds its box before it has arrived, and a late failure is
  the case that matters.** An `Image.network` given only a height occupies
  exactly that from its first frame, so a shorter fallback moves
  everything below it -- seconds after the screen settled, under a ring
  the viewer is already using. The rule is not "handle the error": the
  pending, the failed and the loaded image are all one size, whether by
  `StackFit.expand` inside a fixed box (`TvBackdrop`, `EpisodeThumbnail`)
  or by a floor under whatever stands in (`TvMetaHeader`).
- **A sliver that comes and goes is keyed.** Focus lives in elements, and
  an unkeyed list of slivers is matched by position and type: one
  appearing above its neighbours re-parents them, tears their subtrees
  down and disposes the node the remote was on, whereupon whatever
  autofocuses answers the D-pad instead. The details screen's last-used
  shortcut appears the first time a title is played, which is exactly when
  the viewer is coming back from the player expecting the card they
  left.
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
