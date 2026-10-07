# The long list

Things wanted but deliberately not built, each with what it would take and
why it is not being done now. Not a backlog of chores: what is broken goes
on the known-issues list in stream-server (`docs/known-issues.md`), and
what is merely unfinished goes in the commit that leaves it unfinished.
This is for work that is a *choice* to defer.

Ordered by how likely it is to be picked up, not by size.

## Subtitles on a cast

A viewer picks a subtitle, casts, and it is simply not there -- silently.

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

About casting only: on the device mpv shows an embedded text track as it
shows any other. A receiver does not render a text track embedded in an
MKV or an MP4 at all, so on a cast it would have to be read out of the
container and served as WebVTT, beside the step above. Nearer than it
looks: the rendition producer (`rust/src/rendition.rs`) already demuxes
the film on the phone through libavformat, reading every packet of every
stream -- a subtitle track's included -- and throwing away all but the
picture and the sound. Keeping the text track's packets as well, turning
them into WebVTT cues and serving those beside the rendition is the
missing half; a film that goes to the receiver as it is (an MP4, a WebM)
would need the same demuxer run for its subtitles alone.

## Transcoding for a cast

What a cast does today ([CASTING.md](CASTING.md)): H.264 and HEVC in
Matroska or MP4 are repackaged with the picture copied and any sound the
receiver may not get converted to stereo AAC; a plain link the receiver
can fetch goes to it straight. What is still refused is a **picture** the
cast cannot carry as it is: video a receiver cannot decode at all (AV1 on
most, MPEG-4 Part 2, and H.264 that is not 8-bit 4:2:0 -- "Hi10P", common
in anime releases -- or HEVC beyond Main 10, which no receiver decodes),
VP9 in a Matroska file that is not a
WebM (a copy does not carry it), a 4K film for a 1080p receiver, Dolby
Vision profile 5. Re-encoding the picture is what would cast those. It
would also give a film with no index exact seek positions on a cast: a
re-encode puts its key frames where it chooses, so each slot's real start
is known before the slot is made, which an estimated layout cannot know
(stream-server `docs/design/renditions.md` §2.8). Wanted,
and deferred because the copy covers what is actually watched.

## Speak to search

Typing a title with a D-pad is the worst part of the television.

**The field half is built**: on a television Search's field has a
microphone at its right end that recognizes speech in the app with
Android's `SpeechRecognizer`, shows the words as they are said and
confirms the transcript as a typed entry
([ANDROID.md](ANDROID.md#typing-with-a-remote)). The first build handed
off to `RecognizerIntent`, which a Chromecast with Google TV answers with
its own search and never gives the words back. A phone needs nothing of
ours: its keyboard has a microphone.

What is left is the remote's own search/mic key (`KEYCODE_SEARCH`, or the
Assistant handing over a query through a searchable activity) going
straight into the search screen; nothing takes it today. Check what a
Google TV remote's mic button actually sends to a foreground app before
building on it -- the Assistant may keep it for itself.

## Continue watching on the Google TV home screen -- measured, closed

The Google TV home screen has a "Continue watching" row that other apps put
their half-watched titles in; xtremio's Continue watching lives only inside
the app, and will stay there.

**Measured 2026-10-07 on zond's Chromecast with Google TV.** A Watch Next
entry published by the app itself (`androidx.tvprovider`,
`TvContractCompat.WatchNextPrograms`, a movie with a poster, a position and
an intent back into the app, the row id answered) never appeared on the home
screen. That is what Google documents: Google TV shows Watch Next rows only
from apps it has certified -- the ones under Settings → Accounts & sign-in
→ the account → Your services -- and the certification is for Play-distributed
partners, now moving to the allow-listed Engage SDK; nothing offers a path
to a sideloaded app. Plex and the others do exactly what the probe did; their
package is on the list. The probe, its permission and its channel were
removed again the same day (`git log` for "home-screen probe"). What would
show the rows: the classic Android TV launcher on older boxes, and
third-party launchers such as Projectivy, which read the table unfiltered.
Not worth building for a home screen zond does not use.

## Shrinking the stremio-core fork to nothing

Four small patches would let us drop the fork and follow upstream: the
subtitle properties (upstream PR Stremio/stremio-core#1045), the
localsearch rev pin, the flate2 widening, and the gh-pages guard
(`rust/Cargo.toml` says what each is for). Three
more version-range widenings would do the same for stremio-core-web. Each
is upstreamable on its own. The fork policy says minimal divergence, and
this is how that becomes zero.

## Block-compressed archives

A compressed member cannot be seeked, so those are refused. Formats with
independently-compressed blocks (bgzip, seekable zstd) could be, with a
block index. **Decided against**: the releases that show up in practice
are stored RAR and ZIP, so this would be machinery for a case that does
not arrive. Here so the decision is findable, not to be done.

## Multi-volume RAR behind a debrid link

Works from a torrent: the server finds the sibling volumes in the
torrent's own file list. Behind a debrid link the app is handed one URL,
and a set needs all of them, each separately signed.

**But the server half is mostly built for it**: `/rar/create` takes
`urls`, a list of volumes in order, while a link the server sniffs as a RAR
is one volume (stream-server `docs/design/media-pipeline.md` §2.9: an
explicit volume list is a `MediaSpec` field when something supplies one,
not built yet). So this works the day an addon lists
every volume of a set as its own stream -- the app would gather the
siblings from the stream list it already has, by infohash and by the
volume numbering in the names, and hand the server all of them. No URL
guessing: an addon that offers three streams is offering three URLs.

What is missing is an addon that does it. The debrid services unpack RAR
sets themselves, so what they expose is usually the film rather than the
volumes -- which is why a good addon answers such a torrent with "not
available" rather than with a list of `.partNN.rar` files, and why the one
that *did* list them was the one misbehaving. **Send one real stream list
that names every volume and this becomes an afternoon.**

## Audio a receiver cannot have

About playing on the device into an AV receiver (an amplifier), not about
casting. Dolby Atmos objects fold to the channel bed on every build there is,
ffmpeg having no renderer for them; nothing to do until it does. TrueHD
*passthrough* is a different matter: the shipped libmpv has `ad_spdif`
and `spdif-truehd` compiled in, so `--audio-spdif=truehd` could bitstream
to a capable receiver. Worth one experiment on the device; it helps only
viewers with an AVR that takes it.

## Closed, and staying closed

* **iOS.** No forks are carried for it.
  [OPERATIONS.md](OPERATIONS.md#building-for-ios) has the two proven
  changes, and the CI job is red by design.
* **Browser clients.** Closed by zond.
* **Drive as an addon.** Closed by zond (2026-10-05): the app's own Drive
  support -- remote files read by range, linked once, offline downloads --
  is better than anything an addon seam would give it.
* **A discover-only torrent state** (finding peers and metadata for a
  source before it is picked). Closed by zond (2026-10-05): people scroll
  around among sources before selecting one, and starting and stopping
  torrents for that pollutes the swarm and our own compute and memory. A
  torrent is on because something explicit holds it -- a player screen, a
  cast, a download -- and for no other reason.
