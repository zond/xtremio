# The long list

Things wanted but deliberately not built, each with what it would take and
why it is not being done now. Not a backlog of chores: what is broken goes
on the known-issues list in stream-server (`docs/known-issues.md`), and
what is merely unfinished goes in the commit that leaves it unfinished.
This is for work that is a *choice* to defer.

Ordered by how likely it is to be picked up, not by size.

## Subtitles on a cast

A viewer picks a subtitle, casts, and it is simply not there -- silently.
Asked for by zond, 2026-09-21.

The sending half is ready: the Cast plugin takes `tracks` on the media
information, `activeTrackIds` on the load, and has `setActiveTrackIDs` for
a change made mid-cast. What is missing is the subtitle itself, for two
reasons that both mean it has to come from our server rather than from the
addon:

* the Default Media Receiver takes **WebVTT**, and addons serve SubRip,
  often gzipped;
* Google requires **CORS headers** on a side-loaded track, which no
  third-party subtitle host sends.

So: a subtitle route mounted on the LAN media listener that fetches the
addon's URL (through the machinery that already carries a stream's
credentials), gunzips it, converts SubRip to WebVTT and serves it with the
CORS the listener already has; then the app builds a track for whatever
the viewer chose and hands it over with the film. About a day, both sides,
with tests -- and the server half is testable without a device.

Until then the player should *say* that subtitles are not sent, rather
than dropping them without a word.

## Subtitles that are inside the file

The step after the one above, and a much bigger one: a receiver does not
render a text track embedded in an MKV or an MP4 at all, so those would
have to be read out of the container and served as WebVTT. The translated
sources layer already reads containers by byte range, which is the half
that exists; a Matroska subtitle track reader is the half that does not.

## Transcoding for a cast

What would make casting work for the files a receiver turns down -- HEVC,
Matroska, TrueHD -- instead of refusing them with a sentence. stream-server
already advertises HLS transcoding support, so this may be wiring rather
than building; scope it before estimating. Wanted since 2026-09-08 and
deferred every time because direct play covers what is actually watched.

## A discover-only torrent state

An engine with no reader wants every file, and the want set only narrows
when a stream arrives -- so anything that creates an engine early fetches
the whole torrent until a reader shows up (measured 2026-09-19: 546 MB at
~50 MB/s). It is not hit today only because the player's stream request
follows its open by about 160 ms.

The fix needs a state where a torrent finds peers and metadata without
wanting data, and rqbit drops peers when neither side is interested, so
only addresses and metadata would survive it. That is a change in the
fork, not here. It is also what "start the engine when a source is picked"
waits on.

## Drive as an addon

Asked by zond, 2026-09-20: whether Google Drive belongs behind an addon
seam rather than in the app. The translated-sources work made the case
stronger -- a Drive file is another source of byte ranges, which is
exactly what that seam takes -- but nothing has been designed.

## Shrinking the stremio-core fork to nothing

Three small patches would let us drop the fork and follow upstream: the
localsearch rev pin, the flate2 widening, and the gh-pages guard. Three
more version-range widenings would do the same for stremio-core-web. Each
is upstreamable on its own. The fork policy says minimal divergence, and
this is how that becomes zero.

## Block-compressed archives

A compressed member cannot be seeked, so those are refused. Formats with
independently-compressed blocks (bgzip, seekable zstd) could be, with a
block index. **Decided against, 2026-09-20**: the releases that show up in
practice are stored RAR and ZIP, so this would be machinery for a case
that does not arrive. Here so the decision is findable, not to be done.

## Multi-volume RAR behind a debrid link

Works from a torrent -- the server finds the sibling volumes in the
torrent's own file list. Behind a debrid link it cannot: the app is handed
one URL and a set needs all of them, each separately signed. It would take
an addon that names every volume, which no addon does.

## Audio a receiver cannot have

Dolby Atmos objects fold to the channel bed on every build there is,
ffmpeg having no renderer for them; nothing to do until it does. TrueHD
*passthrough* is a different matter: the shipped libmpv has `ad_spdif`
and `spdif-truehd` compiled in, so `--audio-spdif=truehd` could bitstream
to a capable receiver. Worth one experiment on the device; it helps only
viewers with an AVR that takes it.

## Closed, and staying closed

* **iOS.** No forks are carried for it. `README.md` has the two proven
  changes and the CI job is red by design.
* **Browser clients.** Closed by zond, 2026-09-19.
