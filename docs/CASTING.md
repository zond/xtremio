# Casting to a Chromecast

What the cast button does, and what it refuses and why (the honest
half). The player it hangs off is in [ARCHITECTURE.md](ARCHITECTURE.md#the-player).

A cast button sits on the player's top bar once a receiver has answered.
It hands the stream to the receiver **untouched**: the bytes the embedded
server already serves, with no processing anywhere. Or it hands it over
**repackaged**, for an H.264 or HEVC film in a Matroska file, or an MP4
whose sound the receiver will not take or carries in more than two
channels. A repackaged film is the same picture as one fragmented MP4, made
as the receiver reads it. Its sound is copied when it is AAC and
**converted to stereo AAC** otherwise
([Renditions](#renditions-the-picture-repackaged-the-sound-converted)).
While the television plays, the player screen is a remote. The
picture is never decoded or encoded for a receiver yet, so the honest part
of this is still the refusal. The button is never built on Android TV: a TV
is a receiver, not a sender.

Receivers are looked for with the platform's passive search while a
player is open. An active scan runs too while the receiver list is on
screen (`startDiscovery(activeScan: true)`, Android's MediaRouter
`CALLBACK_FLAG_PERFORM_ACTIVE_SCAN`). The passive search can miss a
receiver that is there. The active one costs power for as long as it runs,
so it runs only while someone is choosing. A receiver the passive search
misses altogether still leaves the button off the bar.

## What can be cast

**The compatibility rule** (`lib/features/cast/cast_compatibility.dart`):
MP4 or WebM, video the receiver decodes at the film's size and rate, and
audio the container may carry (AAC or MP3 in an MP4, Opus or Vorbis in a
WebM). The audio half is keyed on the container because that is where a
receiver draws the line. The video half is keyed on the model name the
receiver announces ([The receiver table](#the-receiver-table)).

**mpv is the only authority on what the file is.** A cast starts from the
player, where mpv is reading the file. The check believes only mpv's
report: `file-format` (the reader that opened the file), `video-codec`,
`audio-codec-name` and `video-params/pixelformat`, sampled while the
receiver list is open (`PlaybackStats`). No file name, URL extension,
server-resolved name or release claim (`x265`, `DDP5.1`) is read. Those are
often absent (a debrid link names no file at all) and sometimes wrong, and
mpv is reading the bytes.

- **The container** is the family of the reader mpv names. libavformat's one
  reader for MP4, M4V and QuickTime (`mov,mp4,m4a,3gp,3g2,mj2`) is the **MP4
  family**: handed over as `video/mp4` when its codecs are ones the receiver
  takes. mpv's own Matroska reader (`mkv`) and libavformat's
  (`matroska,webm`) are the **Matroska family**. A file of it is a WebM,
  handed over as `video/webm`, when it carries VP8 or VP9 with Opus, Vorbis
  or no sound. Otherwise it is a Matroska file, which a receiver does not
  take as it is. Any
  other reader (AVI, a transport stream, Ogg, ...) is refused by name.
- **The codecs** are mpv's, for the same reason, and decide within a
  family: a receiver's video list, and the audio the container may carry.
- **A picture no receiver decodes is refused up front**, for every
  receiver, whether the film would go as it is or repackaged (a rendition
  copies the picture). That is H.264 that is not 8-bit 4:2:0 (High 10,
  "Hi10P", common in anime releases; High 4:2:2; High 4:4:4), and HEVC
  beyond Main 10 (12 bits, 4:2:2, 4:4:4). Google lists H.264 as High
  Profile only and HEVC as Main and Main 10 on every receiver that has it
  (`ReceiverTable.deepestPicture`, all 4:2:0). The sentence names it:
  "This film's video is 10-bit H.264, which no Chromecast can play, and
  xtremio can't convert it for casting yet." (`CastRefusal.pictureFormat`).
  **mpv says which by its pixels**, not a profile. The libmpv this app
  ships (v0.36.0-549) names no profile anywhere. Its `video-codec` is the
  decoder and its description, `h264 (H.264 / AVC / MPEG-4 AVC / MPEG-4
  part 10)`, and its track list has no `codec-profile` (mpv 0.37). So the
  check reads `video-params/pixelformat` (`yuv420p10`, `yuv422p`,
  `yuv444p`, ...; measured with libmpv on a file ffmpeg made in each
  profile). When that is a hardware surface (`mediacodec`), it reads what
  the surface holds (`video-params/hw-pixelformat`, `p010`). A surface
  that does not say is not held against the film
  ([Known limits](#known-limits)).
- **The answer is "not yet"** (`CastRefusal.pending`, below) until mpv has
  reported the reader and the video codec. It is never a guess.
- **QuickTime is MP4 here**: one reader opens both, so a `.mov` of H.264 or
  HEVC with AAC is handed over as `video/mp4` as it is
  ([Known limits](#known-limits)).
- **A stream read through a `/proxy` or `/ftp` route is refused** before
  any of that, whatever host the route is on. Another Stremio server's
  proxy is no more castable than ours. Such a stream is an origin that will
  not serve ranges, read forward, or a route the server names no id for. The LAN
  listener serves published ids and nothing else, and nothing here can
  seek such a stream for a receiver.

**What is judged is the film, not its container.** The server resolves an
id that turns out to be an archive or disc image to the member inside it
(`Resolved.member`). mpv plays the member, and the cast follows: mpv's
report is about the member, and what is published is the same id. So a
`.rar` holding an MP4 casts as one, and a Matroska inside a `.rar` is judged
as a Matroska, whatever either is called. A link-borne container's
credentials never cross the LAN. The receiver is handed a token, and the
session the server made for the container stays on this device.

A refusal is a dialog saying what is wrong and that the conversion that
would fix it does not exist yet. `CastRefusal` names the rule, and is the
seam the rest of the renditions fill. **One refusal is not a verdict.** A
press before mpv has reported what the file is, in the first moments of a
stream or the first instant the receiver list is open, gets a dialog
headed *Still working out what this file is*. It says "The player has not
said yet what kind of file this is, and that is what decides whether a
Chromecast can play it. Try again once it has started playing."
(`CastRefusal.pending`). Nothing is connected, published or loaded, and
the same button works once mpv has reported. A report is about the file mpv
was reading. It is dropped when the screen moves to another stream, and the
next cast waits for mpv to report on the new one.

## The receiver table

What a receiver decodes depends on its model, so the video half of the
rule is a row per model (`lib/features/cast/receiver_table.dart`, step F5
of stream-server's `docs/design/renditions.md`). Each row comes from
Google's table (developers.google.com/cast/docs/media) and gives the
codecs and, per codec, the biggest picture at the fastest rate.

| Model | H.264 | HEVC | VP8 | VP9 | AV1 |
| --- | --- | --- | --- | --- | --- |
| Chromecast 1st/2nd gen | 720p60 or 1080p30 | -- | 720p60 or 1080p30 | -- | -- |
| Chromecast 3rd gen | 1080p60 | -- | 720p60 or 1080p30 | -- | -- |
| Chromecast Ultra | 1080p60 | 4K60 | 4K30 | 4K60 | -- |
| Chromecast with Google TV 4K | 4K30 or 1080p60 | 4K60 | -- | 4K60 | -- |
| Chromecast with Google TV HD | 1080p60 | 1080p60 | -- | 1080p60 | -- |
| Google TV Streamer | 4K60 | 4K60 | -- | 4K60 | 4K60 |
| Nest Hub | 720p60 | -- | -- | 720p60 | -- |
| Nest Hub Max | 720p30 | -- | -- | 720p30 | -- |

**A receiver is judged by the model name it announces**
(`ReceiverTable.of`), the one thing the Cast SDK says about its hardware
(`CastDevice` in play-services-cast 21.5.0 has that name, a protocol
version and capability bits every video receiver shares). A name's row
holds what is **common to every model announcing it**, and what the best
of them decodes (`ReceiverRow.atBest`). "Chromecast" is announced by the
three dongle generations and both Chromecasts with Google TV. zond's 4K one
says "Chromecast" like a 2015 dongle. So by name it is H.264 at 720p60 or
1080p30 for certain (Google lists no VP8 for the Google TV models). At best
it is H.264 at 4K30 or 1080p60, VP8, and HEVC and VP9 at 4K60. "Chromecast
Ultra", "Google TV Streamer", "(Google) Nest Hub" / "Google Home Hub" and
"Google Nest Hub Max" name one model each, so their rows are that model's
and have nothing better to try. A name the table does not know, such as a
television with Cast built in, gets H.264 at 720p30 for certain (what
every row decodes) and, at best, everything any row decodes.

The picture of a film decides one of three things, for a file handed over
as it is and for a rendition alike (a rendition copies the picture):

- **Within what every model with the name decodes: sent.**
- **Beyond that, but within what the best of them decodes: tried** (zond:
  "we could e.g. try HEVC if we are uncertain"). The cast is sent as a
  trial (`CastReady.tentative`, `CastRendition.tentative`; the log says
  "trying HEVC on a receiver ...") and the receiver's own report of its
  picture decides ([A receiver that shows no picture](#a-receiver-that-shows-no-picture)).
  An HEVC film on zond's television is such a trial.
- **Beyond what any model with the name decodes: refused up front**, with
  a sentence that says what the best of them plays (`CastRefusal.videoCodec`,
  `CastRefusal.pictureSize`): 'The best of the receivers that call
  themselves "Chromecast" plays H.264, VP8, HEVC or VP9 video; this film's
  video is AV1. ...'. For a name of one model, that is anything beyond
  its row: 'Every receiver that calls itself "Google Nest Hub" plays
  H.264 up to 1280x720 at 60 frames a second; this film's picture is
  1920x1080 at 24 frames a second. ...'.

A size or rate mpv has not reported is not held against a film.

**There is no lookup of the exact model.** The receiver's own setup
endpoint would name it (`https://<receiver>:8443/setup/eureka_info`), but
only through a self-signed certificate the app keeps no exception for. It
would also save little. An uncertain receiver is tried and ended when it
shows no picture, so an unable one costs three seconds of black screen.

## A receiver that shows no picture

A receiver that cannot decode a film's picture does not say so. An AV1
MP4 went BUFFERING to PLAYING on zond's Chromecast with Google TV 4K
(measured 2026-10-05), with its position advancing, no error and no idle
reason: sound over a black screen. What it does is leave out `videoInfo`
(width, height, HDR type). For a picture it decodes, its media status
carries that from BUFFERING on (H.264 and HEVC MP4s:
`{"width":1280,"height":720,"hdrType":"sdr"}`). One receiver measured;
other models are taken to be the same, not proven.

flutter_chrome_cast drops that field, so the app's own Kotlin listens
beside it (`CastPictureChannel.kt`). It adds a second callback on the
`RemoteMediaClient` of the plugin's session, reached through the shared
`CastContext` (never created there). On every status it sends
`{width, height, hdr}` or null over the `xtremio/cast_picture` event
channel. `GoogleCastClient` carries it on every `CastStatus` (`picture`).
This is Android only (`CastClient.reportsPicture`). iOS is not carried.

The player (`_watchCastPicture`) stops the cast **once the receiver says
PLAYING and its position has moved `PlayerScreen.castNoPictureAfter` (3 s)
from where it first did, with no picture reported this load**. The film
resumes here at the receiver's position, and the dialog *No picture on
<receiver>* says "<receiver> played the sound but showed no picture: it
cannot show this film's picture (HEVC, 3840x2160). It was sent the film
repackaged, its sound converted. The film is playing here again." The
receiver is not sent that codec again this session
(`ReceiverPictureMemory`, refused up front). It is a check on a state the
receiver reported, not a timer. A cast that is buffering or waiting on a
swarm is never ended by it. A file of sound alone (mpv reads no video
track: `current-tracks/video/codec`) has no picture to miss, and is judged
by its container and sound. The first picture of each load is logged
("the receiver shows a 1280x720 sdr picture"), never a URL.

## Renditions: the picture repackaged, the sound converted

A Chromecast will not open a Matroska file, and most films are one.
`CastCompatibility.of` answers `CastRendition` instead of the container
refusal when mpv reports the film inside as H.264 or HEVC. That needs the
stream played by id and a device that can make one
(`media_renditions_available`). The same goes for a file of the MP4 family
whose picture the receiver takes but whose sound it should not get as it
is. That is sound its container does not allow (Dolby Digital in an MP4,
the common case), which would otherwise be refused. Or it is sound in more
than two channels (AAC 5.1), which would otherwise be a gamble on the
receiver's sound.

**The sound is copied when it is AAC in one or two channels, and converted
to stereo AAC otherwise** (`CastRendition.convertsSound`,
`RenditionSpec.convertSound`: `{"aacStereo": {"bitrate": 192000}}`).
Converted means Dolby Digital, Dolby Digital Plus, DTS, TrueHD, Opus, FLAC,
MP3, PCM, AAC 5.1: whatever mpv names, since the producer decodes with the
same FFmpeg mpv played it with. **Surround is converted whatever the receiver says it
plays**: zond's television sends its sound over Bluetooth, and Dolby cast
to it plays silent. The channel count is mpv's
`current-tracks/audio/demux-channel-count`: the track's own, as the
container declares it. It is not `audio-params/channel-count`, which is
what mpv's decoder hands on for this device's output. AAC whose count mpv
has not reported is copied, as it was before the count was asked for. An
MP4 with AAC 5.1 that cannot be a rendition goes as it is. A copy carries
H.264 and HEVC (Main and Main 10, so HDR10 and HLG too). The receiver's row
says whether it decodes the picture at its size and rate
([The receiver table](#the-receiver-table)).

**When it would be repackaged and its picture cannot be**, the refusal
names it and why (the sound is never the reason: it converts):

- video the receiver decodes but a copy does not carry (VP8, VP9):
  "This film's video is VP9, which xtremio can't repackage for casting
  yet.";
- video the receiver cannot decode (AV1, MPEG-4 Part 2, MPEG-2, VC-1):
  "This film's video is AV1, which this receiver can't play, and xtremio
  can't convert it for casting yet." (step F4).

The producer catches one thing mpv cannot see while the cast is prepared:
**Dolby Vision**. mpv reports it as HEVC, and the libmpv this app ships
(v0.36.0-549) has no `dolby-vision-profile` track property to ask. The
producer reads the container's Dolby Vision record
(`StreamInfo::dolby_vision`, from the stream's side data). It copies
profiles 7 and 8 as the HDR10, SDR or HLG base layer they carry, dropping
the RPU and enhancement-layer NAL units (types 62 and 63) and signalling no
Dolby Vision. **Profile 5**, a base layer only a Dolby Vision decoder shows
right, fails the rendition with "This film's picture is Dolby Vision
profile 5, which has no ordinary HDR or SDR picture underneath: the
television would show it in the wrong colours." The preparation below
meets it before the receiver is told anything. `media_rendition_readiness`
answers `failed` with that sentence, and the phone shows it in the refusal
dialog (`rust/tests/rendition.rs` and
`player_cast_test.dart` quote it on both sides). A receiver that asks
anyway is answered `503` with it. A profile 5 film that needs no rendition
is not read by the producer at all ([Known limits](#known-limits)).

Otherwise the player publishes a **rendition** (`media_publish_rendition`,
stream-server's `ServerHandle::publish_rendition`) with this player's
duration, position and audio track (`RenditionSpec`,
`lib/core/media_ids.dart`). It hands the receiver
`<lan base>/cast/<token>/stream.mp4` as `video/mp4`, with the film's
length. That is **one progressive fragmented MP4**, starting at this
player's position, which the receiver plays as a file (`<video src>`). It
is not HLS. zond's Chromecast with Google TV plays nobody's HLS above 720p
through its Media Source path (measured). It plays the same 1080p film as
a fragmented MP4 file (stream-server `docs/design/renditions.md`, F2). The
file has a length and ranges, and its timestamps are the film's, so the
receiver reports the film's position. Same token rules, same listener,
same watchdog: each read of the file counts as a body.

**The receiver is told to load only once the rendition's start is made.**
A rendition's first answer waits for the film's index (a Matroska file's
Cues, usually at its end) and the slot the receiver starts in. Behind a
thin swarm that took a minute on zond's phone, and the Chromecast default
receiver gave up on a load that silent. So after publishing, the player
asks the server to prepare it (`media_prepare_rendition`,
`ServerHandle::prepare_rendition`) and polls `media_rendition_readiness`
every half second (`PlayerScreen.castPreparePoll`). Meanwhile a card over
the video shows "Preparing for <receiver>…", then "Reading the film's
index…" or "Fetching the start…", and the torrent's download speed when
there is one. Its **Cancel** unpublishes, ends the session and leaves the
film here. A `failed` readiness is shown as a refusal with the server's
sentence. The server makes only what is asked for, for the receiver as for
the phone's own player. So the preparation is a simulated receiver that
asks for the header, slot 0 (Chrome's demuxer reads it before it seeks)
and the slot for the start. **Local playback pauses at publish**, at the
start the rendition is made for, and the receiver is told exactly that
start. Cancel or a refusal resumes it. No timer gives up: the viewer
is the one who cancels. A direct (as-is) cast is loaded at once,
as before.

**The torrent stays up for as long as anything uses it, because the app
says so.** The server keeps a player screen's torrent running from its
first read until the screen is left (`server_release_player` in the
player's teardown, `ServerHandle::release_player`). It keeps a cast's
running from publish to unpublish. The cast takes it while the screen
still holds it, so the hand-over has no gap (stream-server
`docs/storage.md`, *Who keeps a torrent running*). A cast is published
with the screen's play token. So once it is unpublished, the film keeps
sharing as the viewer's idle share, as after leaving the player, until the
viewer plays something else. That share runs only while idle sharing is
allowed. Before, the server
guessed from the last stream opened and the reads in flight, and stopped
the torrent a television was waiting on once anything else opened.

The server cuts the film into segments at its own keyframes. With the
source's index, that is one per keyframe a second or more apart (its
`docs/design/renditions.md`, "A slot per sync sample"). It muxes them,
keeps a few in memory and answers the receiver's ranges from them, with
nothing on disk (its `docs/design/renditions.md`). The server asks one
thing of the app: the **producer**, `rust/src/rendition.rs`, installed at
every server start. Each run gets a thread of its own, which reads the
media id's `MediaReader` through **libavformat from the libmpv media_kit
ships** (`rust/src/libav.rs`). The vendored libmpv exports FFmpeg 6.0's
whole API. Android's `MediaExtractor` drops Dolby and DTS tracks and opens
no AVI (measured on zond's phone). The run picks the film's video and the
audio track playing here, and seeks to the run's segment. It hands the
server every packet's presentation time on mpv's clock (less the
container's start). It hands over the H.264 or HEVC parameter sets and
samples in Annex-B, with an HEVC `hvcC`'s SEI messages too (an HDR10
encode's mastering display and light levels are often only there). And it
hands over the AAC frames, as they are or, when converting, the ones it
made (below). The server writes HEVC as `hvc1` + `hvcC`, its samples
length-prefixed, with a `colr` from the SPS's colour description. The key
flags are the container's. For Matroska those are HEVC's IRAP pictures,
the same ones its cues index (x265's open GOPs make every key after the
first a CRA). Stop and every other way out unpublish, which ends the run
wherever it is blocked. There is no timer: a stalled torrent
is waited for.

**The receiver seeks in it by bytes**, as in any file, so seeks are the
receiver's again: the television's remote, and this screen's (a `SEEK`, as
for a stream cast as it is). Measured on zond's TV (stream-server
`docs/design/renditions.md` §2.8): a remote seek is one `Range` straight
at the segment that holds the target, given a length, exact ranges and a
`sidx`. A `sidx` is an index of the file's segments by time and size,
right after the `moov`. So the server lays the file out before it makes
any of it: the header, then one slot per segment. Each slot is as long as
that segment's share of the source, **mirrored from the source's index**
when it has one and estimated when it has none. A slot is padded to its
end, and every byte is the same however often it is asked for. The
producer hands the server the index. The first run of a rendition
(`Job::wants_index`) reports the video's sync samples, each with its byte
position, from **libavformat's index** (`Demuxer::index_entries`). That is
an MP4's sample tables, an AVI's `idx1` or Matroska's cues. libavformat
reads cues at a first seek, so the run seeks to the start. A Matroska
cue's position is moved from its cluster to its block by the cue's
`CueRelativePosition`, which libavformat does not keep
(`rust/src/matroska.rs` reads the cues for it). A transport stream, or a
Matroska file with no cues, has no index and is estimated. A transport
stream's AAC comes as ADTS, whose configuration is the first frame's
header (`adts_config`).

To try a rendition without the app, run `cargo test --test rendition
serve -- --ignored --nocapture` with `XTREMIO_RENDITION_FILE` and
`XTREMIO_RENDITION_OUT`. It serves one on loopback, and a television
reaches it through `adb reverse`. `tool/rendition-video` plays it in
headless Chrome as a `<video src>`, the way the receiver plays a file. It
checks that it is seekable end to end and that a seek to 5:00 is one far
`Range`.

**Bound to one FFmpeg.** `rust/src/libav.rs` reads FFmpeg's structs by
layout. The layout is asserted at compile time for 64- and 32-bit targets
against what `tool/libav_offsets.sh` measures. At load it refuses a
library whose FFmpeg majors are not 6.x's (libavformat 60, libavcodec 60,
libavutil 58). A bump of the vendored libs package to another FFmpeg
re-runs the tool. On a desktop the system libmpv's FFmpeg is found through
it. Casting is not offered there anyway (`CastClient.isSupported`), but
`rust/tests/rendition.rs` runs the whole path against it. It publishes
`ffmpeg`-made films (H.264, and HEVC Main 10 HDR10 with open GOPs, as
Matroska with Dolby Vision records patched in), fetches them off the LAN
listener, checks them with `ffprobe` and decodes them with `ffmpeg`.

### Converting the sound

`rust/src/sound.rs` (step F3). The run's thread decodes the chosen track
with **libavcodec from the same libmpv** (`libav::SoundDecoder`), which has
every decoder, Dolby, DTS and TrueHD included. zond's phone has Dolby
`MediaCodec` decoders but none for DTS or TrueHD, and `MediaExtractor`
hands none of them out anyway, so FFmpeg decodes everything. The thread
mixes the sound down to stereo at 48 kHz with **libswresample**. It uses
the default matrix (centre and surrounds at -3 dB into each side, LFE left
out), normalised so the sum never clips. It encodes **AAC-LC stereo,
48 kHz, 192 kbit/s**. On a phone the encoder is **Android's `MediaCodec`**
(`rust/src/mediacodec.rs`: the NDK's `AMediaCodec` from a `dlopen`ed
`libmediandk.so`, `c2.android.aac.encoder` by name, AOSP's FDK; no Kotlin,
no JNI). Elsewhere it is **FFmpeg's own AAC encoder** where the library
has one (a desktop's system FFmpeg). With neither there, the producer
refuses: "This device cannot convert the film's sound
for the television: it has no AAC encoder this app can use."

**The same bytes, whichever run makes them.** A slot must be identical
however it is reached (the receiver seeks by bytes), and a codec's output
depends on everything it saw before. So the sound is made in **chunks of
48 AAC frames** (1.024 s) on a fixed grid of the film's clock. Frame `i`
is the sound at `i x 1024` samples, stamped `i x 64000/3` us, which the
server's 90 kHz clock reads as exactly `i x 1920`. **Each chunk comes from
a fresh decoder, resampler and encoder.** The decoder is fed from the first
packet 0.4 s before the encoder's input. An AC3 frame's overlap, TrueHD's
wait for a major sync and Opus's prediction all settle within that lead.
The encoder is fed from two frames before the chunk to two after, and
flushed. Its priming is discarded by count (FFmpeg's encoder: 1024
samples; FDK: 1600, its transform plus block-switching look-ahead), so its
kept frames land on the grid. Where the run began decides nothing. A chunk
is made only from packets that are a function of the chunk, and only when
the run read from before its pre-roll. A run starts two seconds before its
first cut, and a chunk with its pre-rolls spans about 1.5 s. The conversion lags the
picture by about 1.5 s of film, which the server's cut rule already waits
for.

`rust/tests/rendition_sound.rs` makes H.264 films with Dolby Digital Plus
5.1, Dolby Digital 5.1, DTS 5.1, TrueHD 5.1 and AAC 5.1 in Matroska, and
Dolby Digital and AAC 5.1 in MP4. Each flashes white and clicks on every
channel at each whole second. The test checks what comes back: AAC-LC stereo 48 kHz, decoding clean,
every click within 3 ms of where the source's is against its flash (whole,
and in every slot read alone after the header), every slot byte-identical
when a fresh rendition's run is started at it, and a seek one jump.
`cargo test --test rendition_sound serve -- --ignored --nocapture` serves a
converted rendition for a television.

Video that is neither H.264 nor HEVC, and readers other than the MP4 and
Matroska families, are still refused. Converting the picture is step F4
of the renditions design.

## The URL and the address the receiver is given

**A cast is a published media id.** A Chromecast cannot fetch from
`127.0.0.1`, so the stream mpv reads by id is **published**
(`media_publish`, stream-server's `ServerHandle::publish`) on the server's
**LAN media listener** (`server_set_lan_media`). The receiver is handed
`<lan base>/cast/<token>`. The token is 128 random bits naming that one
stream, never derived from the id. It is served with the play the screen's
own player had, so a torrent shares as it does here. The listener serves
published tokens and nothing else: no control route, no `/proxy`, no
torrent or archive route. So nothing on the network can make this device
fetch, add or open anything. `rust/tests/lan_media.rs` pins that contract. Every kind casts
this way: a torrent, a link through the server's cache (one the receiver
can fetch itself goes to it directly, below), a Drive file, a download, a
file on this device, the film inside an archive. **The token is
withdrawn** (`media_unpublish`, which also cuts a body being served) when
the session ends from any side, when another receiver is picked (which is
handed a token of its own), when a start fails, when the screen moves to
another stream and when the player is left. Stopping the listener
withdraws every token besides. A token is never logged. A stream played by URL rather
than by id, on a host other than this device, is handed over as that URL,
and no listener is started for it (`_castUrl`).

**A plain link the receiver can play as it is goes to it as it is**
(`directCastUrl`, `lib/features/cast/direct_cast.dart`). Relaying it would
send every byte across the Wi-Fi twice and keep the phone awake for the
length of the film, and nothing is shared for a link either way. The
receiver is handed the link itself when all of these hold. It is an
addon's `url` stream (no torrent, archive, Drive file, file on this device
or server route). It is `http` or `https` with no credentials in it, on a
public host (not loopback, private, link-local, CGNAT, unique-local,
`.local`, `.lan`, `.localhost`, `.home.arpa` or a single-label name). It
has no `behaviorHints.proxyHeaders` and is not `notWebReady`. The server
resolved it to a file it reads in process, not to the member of an
archive. And it is `CastReady` by mpv's report like any cast. A film that
needs a rendition is repackaged here, so it is relayed. No listener is started,
nothing is published, the watchdog has nothing to count, seeks are the
receiver's, and Stop brings the film back at the receiver's position as
for any cast. The remote says *Playing directly from the source* under the
receiver's name, so a report about a cast says which kind it was. The log
says "casting the stream straight from its source" and never the link or
its host.

**A receiver that refuses the link is handed the relay instead, once.**
That covers a debrid link bound to the phone's address, an expired one,
or a 403. The receiver reports idle with `ERROR` (`CastStatus.failed`)
before it has played or paused, or the platform refuses the load. The player then
publishes the same id on the LAN listener and loads that on the same
session at the position it handed over (`_fallBackFromDirect`), logging why
and not the link. The stream is relayed from then on, to any receiver,
until the screen moves to another stream. A refusal of the relay is
handled as any cast's. An error after the receiver has played is the
film's and changes nothing. This is a refusal handler, not a timer: a
receiver slow to start a link is waited for like any other.

**Which address of this device** to hand over depends on where the
receiver is, so Android is asked. `MainActivity.castDeviceAddress` reads
the receiver's address off the MediaRouter route (`flutter_chrome_cast`
drops it), and `GoogleCastClient` asks once per cast as the session starts. The server then
names the interface on that receiver's subnet. With no address (a stale
route, a platform with none) it ranks its own interfaces, demoting every
kind a receiver cannot be behind -- tunnels, cellular, Android tethers,
container and VM bridges. That ranking is a guess, and a wrong guess
leaves a Chromecast on its splash screen forever. The app says so, rather
than casting an unfetchable URL, when no interface can reach the receiver.
If that receiver was picked while another had the stream, the film comes
back to this device.

**What was handed over is written down**: the player logs the listener's
address (never the token) and the receiver address it was chosen for, or
the refusal. The receiver reports nothing useful, so this is the only
account.

**The watchdog reads two counts** (stream-server `docs/lan-media.md`)
`PlayerScreen.castFetchTimeout` (20 s) after a load: the listener's
requests (`server_lan_media_requests_served`) and bodies
(`server_lan_media_bodies_served`, a `/cast` `GET` that began sending
bytes). Every start and stop resets both. They give three readings:

- **No requests**: the receiver could not route to the address. The session
  ends as Stop ends it, the film comes back, and the dialog says why.
- **Requests and no body**: the receiver reached this device and has been
  sent nothing yet: a refusal the server logged, or a stream whose bytes
  are not here (a dead swarm). The remote says so under the title. The
  check runs again every 20 s until a body has begun, and then the note
  goes. **It never ends the cast**: a stream that is slow to come is waited
  for, and the viewer is the one who stops it.
- **A body**: the network and the server did their part. The rest is the
  media's, and nothing is said.

What the receiver reports about itself never cancels the wait, because
the receiver this exists to catch reports a healthy session. Only the ways
out of a session (`_cancelCastFetch`) cancel it, and picking a second
receiver is one of them.

**The listener lives exactly as long as a session**: closed when the session
ends, from any side, when a start fails and on `dispose`. Nothing binds it
at boot. Turning it on grants the server's persisted `lanMediaEnabled`,
and turning it off takes it back. `start_in` takes back a grant a crashed
cast left behind, so what is on disk while nothing casts is "no".

## While casting

The player screen shows the title, the position, play/pause, seek and stop,
all from the receiver's status. A pause from the receiver's own remote
shows here too, and the phone's transport keys are the receiver's. Local
playback is stopped and its reports ignored. Ending the session resumes it
where the receiver had got to (a status with no media keeps the last position rather
than reading as the start of the film). The core hears the same
`TimeChanged`, `PausedChanged` and `Ended` local playback sends, so the
library and continue-watching do not notice.

**On Android all of that rests on `flutter_chrome_cast` 1.5.0**, which
`pubspec.yaml` requires. Once a Default Media Receiver plays, its status
lists the video track it found in the file, with no `trackContentType`
(`"tracks": [{"trackId": 1, "type": "VIDEO"}]`, measured on zond's
Chromecast with Google TV; the BUFFERING before it lists none). Up to
1.4.8 the plugin's Dart parser required that field, and the method-call
handler swallowed the error. So no status carrying the track reached the
app: not PLAYING, PAUSED, a rebuffer, or any idle that still carries the
media. The log said "the receiver says buffering" and never "playing". The
play/pause button stayed on pause, so it could not resume. The core never
heard a pause, the direct-cast trial never closed, and the no-picture check
never ran. The widget tests could not see it, since their fake reports
statuses directly. `google_cast_client_test.dart` sends the measured shape
through the plugin's own channel.

### The stats panel while casting

The stats button and **Shift+I** work while casting as they do for local
play, and show a panel of their own on the phone's casting view
(`CastStatsOverlay`, `lib/features/player/cast_stats_overlay.dart`). The
panel is never on the television and never over the remote. On a narrow
phone the remote keeps the height it needs and the panel scrolls in the
rest. Its
look is the local panel's, and so is the rule: a row with nothing measured
is absent. It asks the server once a second
(`ServerHandle::cast_numbers` through `media_cast_numbers`; stream-server
`docs/lan-media.md`) while it is on screen and a cast is live, and not
while the app is hidden. Every rate is two answers over the time between
them, on the screen's clock (`PlayerScreen.now`).

```
receiver Living Room TV · Chromecast · HEVC sent · playing · 1920x1040 sdr
sending  rendition (video/mp4) · video hevc copied · audio eac3 5.1 → aac 2.0 192 kbps
position 2:10 / 2:00:00
buffered 2 times · 6.0 s
requests 6 · 5 bodies · 1 open
re-req.  1 in the last 30 s
sent     3.0 MB · 8.0 Mbps
made     36 s ahead · 1.5x
runs     at 2:06, 67 slots · 2 started
layout   3363 slots, exact
source   torrent · 16.0 Mbps · 2 opens · 14 seeks
```

- `receiver`: its name and the model it announced; the picture's codec as
  [the receiver table](#the-receiver-table) judged it, `sent` when every
  model with that name decodes it and `tried` when only some do; what it
  says it is doing; and the picture it reports, or `no picture reported`
  where the platform would report one.
- `sending`: `from its source, not through this device` for a link handed
  straight over, `as it is` with the type the receiver is answered with, or
  `rendition (video/mp4)`; the picture and the sound, mpv's word on the
  source's sound (taken when the cast was handed over) beside what the
  server makes of it.
- `position`: the receiver's, of its length.
- `buffered`: how often the receiver stopped to buffer since the cast
  began, and for how long in all, a stop still going included. The load
  is not a stop.
- `requests`: every request under the token, the bodies begun, and those
  being read now. `re-req.` is the requests of the last thirty seconds
  (or of as long as the panel has watched): **a healthy receiver asks once
  per seek**, so several a minute with nobody seeking is a receiver that
  keeps losing its stream.
- `sent`: bytes sent to the receiver, and the rate now.
- For a rendition: `made`, how much film past the receiver's position is
  made, unbroken, from where it last asked, and the production speed as a
  multiple of real time (absent while the run waits at its lookahead and
  makes nothing); `runs`, each live run's start and the slots it has made,
  and how many runs were started (one more for each seek); `layout`, the
  slots, their length when they are all one, and whether they mirror the
  film's index (`exact`) or are estimated.
- `source`: what was read for the receiver (the kind of source, the read
  rate, the opens and the seeks), and for a torrent the swarm rows the
  local panel shows.

The panel never shows the LAN URL or the token. One INFO line says how a
cast went once it ends (Stop, the session ending elsewhere, another
receiver picked, leaving the player), for a pasted diagnostics log:

```
the cast ended after 12 min: the receiver buffered 1 time, 41 s in all; 14 requests, 1.2 GB sent
```

(`_logCastEnd`: "never buffered" for a receiver that did not stop, and "it
read the stream from its source" in place of the counts for a link handed
straight over.)

**Casts do not binge**, by decision: `Ended` from the receiver shows no
up-next card and never starts the next episode, whatever `bingeWatching`
says. The viewer is at the television, not at the phone to cancel a
countdown.

## Known limits

What a cast still gets wrong, knowingly:

- **A seek can land up to half a second late.** A rendition's decode times
  run half a second ahead of its presentation times, so that no
  composition offset is negative. A slot is labelled at its first decode
  time. So a seek to a time in the last half second before a key frame
  lands on that key frame, after the time asked for (stream-server
  `docs/design/renditions.md`, "Every sample at its own time").
- **A film with no index seeks backwards slowly.** A Matroska file without
  cues gets an estimated layout, whose slots are labelled late and open
  with a `styp`. A seek back to a slot not read before walks forward a slot
  per request (7 to 17 in headless Chrome; the television may not recover).
  A transport stream would be the same, but the app refuses one before a
  rendition is considered.
- **Dolby Vision profile 5 in an MP4 with AAC sound shows in the wrong
  colours.** It goes to the receiver as it is: mpv reports it as HEVC, the
  shipped libmpv has no property for the profile, and no producer reads
  the container's record for a film that needs no rendition. In Matroska
  it is a rendition, and refused while the cast is prepared. Closing it
  needs a libmpv that reports the profile or a server-side sniff of the
  record before the hand-over.
- **A QuickTime (`.mov`) file of H.264 or HEVC with AAC is handed over as
  `video/mp4`**, as mpv cannot tell it from an MP4. Untested on a
  receiver; one that will not play it shows as a cast that does not start.
- **10-bit H.264 decoded in hardware may not be caught up front.** The
  pixel format is the check's only word on it, and a hardware decoder
  hands mpv a `mediacodec` surface that may not say what it holds. Most
  phones' decoders do not take High 10, and mpv decodes it in software,
  which names `yuv420p10`. A phone whose decoder does take it leaves the
  film to the receiver's report of its picture
  ([A receiver that shows no picture](#a-receiver-that-shows-no-picture)).
  Unmeasured on a phone.
- **Subtitles are not sent** to the receiver ([WISHLIST.md](WISHLIST.md#subtitles-on-a-cast)).

## The pieces, and what is verified

`lib/features/cast/`: `cast_client.dart` (the interface, `CastScope`,
`ReceiverPictureMemory`, the types), `google_cast_client.dart` (over
[`flutter_chrome_cast`](https://pub.dev/packages/flutter_chrome_cast)),
`cast_compatibility.dart`, `receiver_table.dart`, `direct_cast.dart`,
`cast_widgets.dart` (the receiver sheet, the remote, the preparing card).
The session is in `PlayerScreen` (`player_screen_casting.dart`), its panel
in `lib/features/player/cast_stats_overlay.dart`. `RenditionSpec` and the
publishing calls are in `lib/core/media_ids.dart`, and `LanMediaControl`
is on `ServerClient`. On Android there are `CastPictureChannel.kt` and
`MainActivity.castDeviceAddress`. Widget tests use `FakeCastClient` /
`FakeLanMediaControl` (`test/support/`), in `test/features/cast/`
(`cast_compatibility_test.dart`, `direct_cast_test.dart`,
`google_cast_client_test.dart`, `player_cast_test.dart`,
`player_direct_cast_test.dart`, `player_cast_stats_test.dart`).
`CastPictureTest.kt` is the JVM test of the picture report's parsing.
`rust/tests/lan_media.rs` drives the listener, and `rust/tests/rendition.rs`
and `rendition_sound.rs` the renditions. The manifest entries are in
[ANDROID.md](ANDROID.md#manifest-and-platform-channels).

**One real receiver**: zond's Chromecast with Google TV 4K, on which
renditions play and seek (stream-server `docs/design/renditions.md` §2.8)
and the missing picture report above was measured. Every other model is
Google's table, not seen. Verified here without one: the LAN listener over
real HTTP (it serves media routes, answers `/proxy` and `/settings` with
404, counts requests, and is gone after a stop and a shutdown), the
Android manifest merge, every decision the app makes around a fake sender,
and a rendition fetched over that listener and decoded by `ffmpeg` on a
desktop (`rust/tests/rendition.rs`).
