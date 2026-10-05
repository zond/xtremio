# Casting to a Chromecast

What the cast button does, and -- the honest half -- what it refuses and
why. The player it hangs off is in [ARCHITECTURE.md](ARCHITECTURE.md#the-player).

A cast button on the player's top bar, once a receiver has answered. It hands
the stream to the receiver **untouched** -- the bytes the embedded server
already serves, with no processing anywhere -- or, for an H.264 or HEVC
film in a Matroska file, or an MP4 whose sound the receiver will not take,
**repackaged**: the same picture as one fragmented MP4, its
sound copied when it is AAC and **converted to stereo AAC** otherwise, made
as the receiver reads it ([Renditions](#renditions-the-picture-repackaged-the-sound-converted)).
It turns the player screen into a remote while the television plays. The
picture is never decoded or encoded for a receiver yet, so the honest part
of this is still the refusal. The button is never built on Android TV: a TV
is a receiver, not a sender.

## What can be cast

**The compatibility rule** (`lib/features/cast/cast_compatibility.dart`):
MP4 or WebM, H.264, HEVC, VP8 or VP9 video, and audio the container may
carry -- AAC or MP3 in an MP4, Opus or Vorbis in a WebM. The audio half is
keyed on the container because that is where a receiver draws the line; the
video half is one list for every device, a known approximation (HEVC and
VP9 want a Chromecast Ultra or newer), and the comment on the table says why
fixing it means asking the session what the receiver supports.

**mpv is the only authority on what the file is.** A cast starts from the
player, where mpv is reading the file, and its report -- `file-format` (the
reader that opened the file), `video-codec` and `audio-codec-name`, sampled
while the receiver list is open (`PlaybackStats`) -- is all the check
believes. No file name, URL extension, server-resolved name or release claim
(`x265`, `DDP5.1`) is read: they are often absent (a debrid link names no
file at all) and sometimes wrong, and mpv is reading the bytes.

- **The container** is the family of the reader mpv names. libavformat's one
  reader for MP4, M4V and QuickTime (`mov,mp4,m4a,3gp,3g2,mj2`) is the **MP4
  family**: handed over as `video/mp4` when its codecs are ones the receiver
  takes. mpv's own Matroska reader (`mkv`) and libavformat's
  (`matroska,webm`) are the **Matroska family**: a WebM, handed over as
  `video/webm`, when it carries VP8 or VP9 with Opus, Vorbis or no sound;
  otherwise a Matroska file, which a receiver does not take as it is. Any
  other reader (AVI, a transport stream, Ogg, ...) is refused by name.
- **The codecs** are mpv's, for the same reason, and decide within a
  family: a receiver's video list, and the audio the container may carry.
- **Before mpv has reported** the reader and the video codec, the answer is
  `CastRefusal.pending`, a "not yet" (below), never a guess.
- **One wrinkle, untested on a receiver:** mpv cannot tell QuickTime (`.mov`)
  from MP4 -- one reader opens both -- so a `.mov` of H.264 or HEVC with AAC
  is now handed over as `video/mp4` as it is, where a file name used to send
  it to a rendition. A receiver that will not play one would show as a cast
  that does not start.
- **A stream this device reads only by URL is refused** before any of
  that when it is on this device: an origin that will not serve ranges
  (read forward through `/proxy`) or a route the server names no id for
  (`/ftp`). The LAN listener serves published ids and nothing else, and
  nothing here can seek such a stream for a receiver.

**What is judged is the film, not its container.** The server resolves an
id that turns out to be an archive or disc image to the member inside it
(`Resolved.member`), mpv plays the member, and the cast follows: mpv's
report is about the member, and what is published is the same id. So a
`.rar` holding an MP4 casts as one, and a Matroska inside a `.rar` is judged
as a Matroska, whatever either is called. A link-borne container's credentials never cross the LAN: the
receiver is handed a token, and the session the server made for the
container stays on this device.

A refusal is a dialog saying what is wrong and that the conversion that
would fix it does not exist yet; `CastRefusal` names the rule, which is the
seam the rest of the renditions fill. **One refusal is not a verdict**:
pressed before mpv has reported what the file is -- the first moments of a
stream, or the first instant the receiver list is open -- the dialog is
headed *Still working out what this file is* and says "The player has not
said yet what kind of file this is, and that is what decides whether a
Chromecast can play it. Try again once it has started playing."
(`CastRefusal.pending`). Nothing is connected, published or loaded, and
the same button works once mpv has reported. A report is about the file mpv
was reading: when the screen moves to another stream it is dropped, and the
next cast waits for mpv to report on the new one.

## Renditions: the picture repackaged, the sound converted

A Chromecast will not open a Matroska file, and most films are one. When
the film inside is H.264 or HEVC, as mpv reports it, `CastCompatibility.of`
answers `CastRendition` instead of the container refusal, provided the
stream is played by id and this device can make one
(`media_renditions_available`). The same goes for a file of the MP4 family
whose picture the receiver takes but whose sound its container does not
allow (Dolby Digital in an MP4, the common case), which would otherwise be
refused, or allows in more than two channels (AAC 5.1), which would
otherwise be a gamble on the receiver's sound.

**The sound is copied when it is AAC in one or two channels, and converted
to stereo AAC otherwise** (`CastRendition.convertsSound`,
`RenditionSpec.convertSound`: `{"aacStereo": {"bitrate": 192000}}`) --
Dolby Digital, Dolby Digital Plus, DTS, TrueHD, Opus, FLAC, MP3, PCM, AAC
5.1: whatever mpv names, since the producer decodes with the same FFmpeg mpv
played it with. **Surround is converted whatever the receiver says it
plays**: zond's television sends its sound over Bluetooth, and Dolby cast
to it plays silent. The channel count is mpv's
`current-tracks/audio/demux-channel-count` -- the track's own, as the
container declares it, not `audio-params/channel-count`, which is what
mpv's decoder hands on for this device's output -- and AAC whose count mpv
has not reported is copied, as it was before the count was asked for (an
MP4 with AAC 5.1 that cannot be a rendition goes as it is). HEVC (Main and
Main 10, so HDR10 and HLG too) is allowed because zond's receiver, a Chromecast with
Google TV 4K (`sabrina`), decodes it up to 4K: `_repackagedVideo` is a
constant for that receiver until the receiver table (step F5) makes it a
row per model, and until then an HEVC film cast to a receiver without HEVC
is a black screen.

**When it would be repackaged and its picture cannot be**, the refusal
names it and why (the sound is never the reason: it converts):

- video the receiver decodes but a copy does not carry (VP8, VP9) --
  "This film's video is VP9, which xtremio can't repackage for casting
  yet.";
- video the receiver cannot decode (AV1, MPEG-4 Part 2, MPEG-2, VC-1) --
  "This film's video is AV1, which this receiver can't play, and xtremio
  can't convert it for casting yet." (step F4).

What mpv cannot see, the producer refuses while the cast is prepared:
**Dolby Vision**. mpv reports it as HEVC, and the libmpv this app ships
(v0.36.0-549) has no `dolby-vision-profile` track property to ask; the
producer reads the container's Dolby Vision record (`StreamInfo::dolby_vision`, from the stream's side
data) and copies profiles 7 and 8 as the HDR10, SDR or HLG base layer they
carry, dropping the RPU and enhancement-layer NAL units (types 62 and 63)
and signalling no Dolby Vision; **profile 5** -- a base layer only a Dolby
Vision decoder shows right -- fails the rendition with "This film's
picture is Dolby Vision profile 5, which has no ordinary HDR or SDR picture
underneath: the television would show it in the wrong colours." The
preparation below meets it before the receiver is told anything:
`media_rendition_readiness` answers `failed` with that sentence, and the
phone shows it in the refusal dialog (`rust/tests/rendition.rs` and
`player_cast_test.dart` quote it on both sides). A receiver that asks
anyway is answered `503` with it. **The gap**: a profile 5 film in an MP4
with AAC sound is not a rendition, so no producer reads its record; it is
handed over as it is and shows in the wrong colours. Closing it needs a
libmpv that reports the profile (a newer mpv's track property), or a
server-side sniff of the record before the hand-over. The player then publishes a
**rendition** (`media_publish_rendition`, stream-server's
`ServerHandle::publish_rendition`) with this player's duration, position and
audio track (`RenditionSpec`, `lib/core/media_ids.dart`), and hands the
receiver `<lan base>/cast/<token>/stream.mp4` as `video/mp4`, with the
film's length: **one progressive fragmented MP4**, starting at this
player's position, which the receiver plays as a file (`<video src>`). Not
HLS: zond's Chromecast with Google TV plays no HLS above 720p through its
Media Source path -- anyone's, measured -- and plays the same 1080p film as
a fragmented MP4 file (stream-server `docs/design/renditions.md`, F2). The
file has a length and ranges, and its timestamps are the film's, so the
receiver reports the film's position. Same token rules, same listener,
same watchdog: each read of the file counts as a body.

**The receiver is told to load only once the rendition's start is made.**
A rendition's first answer waits for the film's index (a Matroska file's
Cues, usually at its end) and the slot the receiver starts in; behind a
thin swarm that took a minute on zond's phone, and the Chromecast default
receiver gave up on a load that silent. So after publishing, the player
asks the server to prepare it (`media_prepare_rendition`,
`ServerHandle::prepare_rendition`) and polls `media_rendition_readiness`
every half second (`PlayerScreen.castPreparePoll`), showing a card over the
video -- "Preparing for <receiver>…", then "Reading the film's index…" or
"Fetching the start…", and the torrent's download speed when there is one
-- with a **Cancel** that unpublishes, ends the session and leaves the film
here. A `failed` readiness is shown as a refusal with the server's
sentence. The server makes only what is asked for -- the receiver is given
what it requests, as the phone's own player is -- so the preparation is a
simulated receiver: the header, slot 0 (Chrome's demuxer reads it before it
seeks) and the slot for the start. **Local playback pauses at publish**,
at the start the rendition is made for, and the receiver is told exactly
that start; Cancel or a refusal resumes it. No timer gives up: the viewer
is the one who cancels. A direct (as-is) cast is loaded at once,
as before.

**The torrent stays up for as long as anything uses it, because the app
says so.** The server keeps a player screen's torrent running from its
first read until the screen is left (`server_release_player` in the
player's teardown, `ServerHandle::release_player`), and a cast's from
publish to unpublish (stream-server `docs/storage.md`, *Who keeps a torrent
running*). Before, it guessed from the last stream opened and the reads in
flight, and stopped the torrent a television was waiting on once anything
else opened.

The server cuts six-second segments at the film's own keyframes, muxes
them, keeps a few in memory and answers the receiver's ranges from them --
nothing on disk (its `docs/design/renditions.md`). What it asks of the app is the **producer**,
`rust/src/rendition.rs`, installed at every server start: per run a thread
of its own, reading the media id's `MediaReader` through **libavformat from
the libmpv media_kit ships** (`rust/src/libav.rs` -- the vendored libmpv
exports FFmpeg 6.0's whole API; Android's `MediaExtractor` drops Dolby and
DTS tracks and opens no AVI, measured on zond's phone). It picks the film's
video and the audio track playing here, seeks to the run's segment, and
hands the server every packet's presentation time on mpv's clock (less the
container's start), the H.264 or HEVC parameter sets and samples in Annex-B
(an HEVC `hvcC`'s SEI messages too: an HDR10 encode's mastering display and
light levels are often only there), and the AAC frames as they are -- or,
converting, the AAC frames it made (below). The
server writes HEVC as `hvc1` + `hvcC`, its samples length-prefixed, with a
`colr` from the SPS's colour description; the key flags are the
container's, which for Matroska are HEVC's IRAP pictures, the same ones its
cues index (x265's open GOPs make every key after the first a CRA). Stop and every other way out unpublish, which
ends the run wherever it is blocked. There is no timer: a stalled torrent
is waited for.

**The receiver seeks in it by bytes**, as in any file, so seeks are the
receiver's again: the television's remote, and this screen's (a `SEEK`, as
for a stream cast as it is). Measured on zond's TV (stream-server
`docs/design/renditions.md` §2.8): with a length, exact ranges and a
`sidx` -- an index of the file's segments by time and size, right after
the `moov` -- a remote seek is one `Range` straight at the segment that
holds the target. So the server lays the file out before it makes any of
it: the header, then one slot per segment, each as long as that segment's
share of the source -- **mirrored from the source's index** when it has
one, estimated when it has none -- padded to the slot's end, every byte the
same however often it is asked for. The producer hands it the index: the
first run of a rendition (`Job::wants_index`) reports the video's sync
samples, each with its byte position, from **libavformat's index**
(`Demuxer::index_entries`: an MP4's sample tables, an AVI's `idx1`,
Matroska's cues -- which libavformat reads at a first seek, so the run
seeks to the start), with a Matroska cue's position moved from its
cluster to its block by the cue's `CueRelativePosition`, which
libavformat does not keep (`rust/src/matroska.rs` reads the cues for it).
A transport stream, or a Matroska file with no cues, has no index and is
estimated; a transport stream's AAC comes as ADTS, whose configuration is
the first frame's header (`adts_config`).

To try a rendition without the app: `cargo test --test rendition serve --
--ignored --nocapture` with `XTREMIO_RENDITION_FILE` and
`XTREMIO_RENDITION_OUT` serves one on loopback (a television reaches it
through `adb reverse`), and `tool/rendition-video` plays it in headless
Chrome as a `<video src>`, the way the receiver plays a file, and checks
that it is seekable end to end and that a seek to 5:00 is one far
`Range`.

**Bound to one FFmpeg**: `rust/src/libav.rs` reads FFmpeg's structs by
layout, asserted at compile time for 64- and 32-bit targets against what
`tool/libav_offsets.sh` measures, and refuses at load a library whose
FFmpeg majors are not 6.x's (libavformat 60, libavcodec 60, libavutil 58).
A bump of the vendored libs package to another FFmpeg re-runs the tool.
On a desktop the system libmpv's FFmpeg is found through it; casting is not
offered there anyway (`CastClient.isSupported`), but `rust/tests/rendition.rs`
runs the whole path against it: `ffmpeg`-made films -- H.264, and HEVC
Main 10 HDR10 with open GOPs, as Matroska with Dolby Vision records patched
in -- published, fetched off the LAN listener, checked by `ffprobe` and
decoded by `ffmpeg`.

### Converting the sound

`rust/src/sound.rs` (step F3). The run's thread decodes the chosen track
with **libavcodec from the same libmpv** (`libav::SoundDecoder`: it has
every decoder, Dolby, DTS and TrueHD included; zond's phone has Dolby
`MediaCodec` decoders but none for DTS or TrueHD, and `MediaExtractor` hands
none of them out anyway, so FFmpeg decodes everything), mixes it down to
stereo at 48 kHz with **libswresample** (the default matrix -- centre and
surrounds at -3 dB into each side, LFE left out -- normalised so the sum
never clips), and encodes **AAC-LC stereo, 48 kHz, 192 kbit/s**: with
**Android's `MediaCodec`** on a phone (`rust/src/mediacodec.rs`, the NDK's
`AMediaCodec` from a `dlopen`ed `libmediandk.so` -- `c2.android.aac.encoder`,
AOSP's FDK, by name; no Kotlin, no JNI), and with **FFmpeg's own AAC
encoder** where the library has one (a desktop's system FFmpeg). Neither
there, the producer refuses: "This device cannot convert the film's sound
for the television: it has no AAC encoder this app can use."

**The same bytes, whichever run makes them.** A slot must be identical
however it is reached (the receiver seeks by bytes), and a codec's output
depends on everything it saw before. So the sound is made in **chunks of
48 AAC frames** (1.024 s) on a fixed grid of the film's clock -- frame `i`
is the sound at `i x 1024` samples, stamped `i x 64000/3` us, which the
server's 90 kHz clock reads as exactly `i x 1920` -- **each chunk from a
fresh decoder, resampler and encoder**: the decoder fed from the first
packet 0.4 s before the encoder's input (an AC3 frame's overlap, TrueHD's
wait for a major sync and Opus's prediction all settle in that), the encoder
fed from two frames before the chunk to two after and flushed, its priming
discarded by count (FFmpeg's encoder: 1024 samples; FDK: 1600, its
transform plus block-switching look-ahead), so its kept frames land on the
grid. Where the run began decides nothing: a chunk is made only from
packets that are a function of the chunk, and only when the run read from
before its pre-roll (a run starts two seconds before its first cut, and a
chunk with its pre-rolls spans about 1.5 s). The conversion lags the
picture by about 1.5 s of film, which the server's cut rule already waits
for.

`rust/tests/rendition_sound.rs` makes H.264 films with Dolby Digital Plus
5.1, Dolby Digital 5.1, DTS 5.1, TrueHD 5.1 and AAC 5.1 in Matroska and
Dolby Digital and AAC 5.1 in MP4, flashing white and clicking on every channel at each whole
second, and checks what comes back: AAC-LC stereo 48 kHz, decoding clean,
every click within 3 ms of where the source's is against its flash (whole,
and in every slot read alone after the header), every slot byte-identical
when a fresh rendition's run is started at it, and a seek one jump.
`cargo test --test rendition_sound serve -- --ignored --nocapture` serves a
converted rendition for a television.

Video that is neither H.264 nor HEVC, and readers other than the MP4 and
Matroska families, are still refused; converting
the picture is step F4 of the renditions design.

## The URL and the address the receiver is given

**A cast is a published media id.** A Chromecast cannot fetch from
`127.0.0.1`, so the stream mpv reads by id is **published**
(`media_publish`, stream-server's `ServerHandle::publish`) on the server's
**LAN media listener** (`server_set_lan_media`), and the receiver is
handed `<lan base>/cast/<token>`: 128 random bits naming that one stream,
never derived from the id, served with the play the screen's own player had
(so a torrent shares as it does here). The listener serves published tokens
and nothing else -- no control route, no `/proxy`, no torrent or archive
route -- so nothing on the network can make this device fetch, add or open
anything; `rust/tests/lan_media.rs` pins that contract. Every kind casts
this way: a torrent, a link through the server's cache (one the receiver
can fetch itself goes to it directly, below), a Drive file, a download, a
file on this device, the film inside an archive. **The token is
withdrawn** (`media_unpublish`, which also cuts a body being served) when
the session ends from any side, when another receiver is picked (which is
handed a token of its own), when a start fails, when the screen moves to
another stream and when the player is left; stopping the listener withdraws
every token besides. A token is never logged. A link the server reads only
forward is handed over as it is when it is on another internet host, and
no listener is started for it.

**A plain link the receiver can play as it is goes to it as it is**
(`directCastUrl`, `lib/features/cast/direct_cast.dart`): relaying it would
send every byte across the Wi-Fi twice and keep the phone awake for the
length of the film, and nothing is shared for a link either way. The
receiver is handed the link itself when all of these hold: an addon's
`url` stream (no torrent, archive, Drive file, file on this device or
server route), `http` or `https` with no credentials in it, on a public
host (not loopback, private, link-local, CGNAT, `.local`, `.lan` or a
single-label name), with no `behaviorHints.proxyHeaders` and not
`notWebReady`, resolved by the server to a file it reads in process and
not to the member of an archive, and `CastReady` by mpv's report like any
cast -- a film that needs a rendition is repackaged here, so it is
relayed. No listener is started,
nothing is published, the watchdog has nothing to count, seeks are the
receiver's, and Stop brings the film back at the receiver's position as
for any cast. The remote says *Playing directly from the source* under the
receiver's name, so a report about a cast says which kind it was. The log
says "casting the stream straight from its source" and never the link or
its host.

**A receiver that refuses the link is handed the relay instead, once.**
A debrid link bound to the phone's address, an expired one, a 403: the
receiver reports idle with `ERROR` (`CastStatus.failed`) before it has
played or paused, or the platform refuses the load. The player then
publishes the same id on the LAN listener and loads that on the same
session at the position it handed over (`_fallBackFromDirect`), logging why
and not the link. The stream is relayed from then on, to any receiver,
until the screen moves to another stream; a refusal of the relay is
handled as any cast's. An error after the receiver has played is the
film's and changes nothing. This is a refusal handler, not a timer: a
receiver slow to start a link is waited for like any other.

**Which address of this device** depends on where the receiver is, and
Android is asked: `MainActivity.castDeviceAddress` reads the receiver's
address off the MediaRouter route (`flutter_chrome_cast` drops it), and
`GoogleCastClient` asks once per cast as the session starts. The server then
names the interface on that receiver's subnet. With no address (a stale
route, a platform with none) it ranks its own interfaces, demoting every
kind a receiver cannot be behind -- tunnels, cellular, Android tethers,
container and VM bridges. That ranking is a guess, and losing it is a
Chromecast on its splash screen forever. If no interface can reach the
receiver, the app says so rather than casting an unfetchable URL, and a
receiver picked while another had the stream gives the film back to this
device.

**What was handed over is written down**: the player logs the listener's
address (never the token) and the receiver address it was chosen for, or
the refusal; the receiver reports nothing useful, so this is the only
account.

**The watchdog reads two counts** (stream-server `docs/lan-media.md`):
`PlayerScreen.castFetchTimeout` (20 s) after a load, the listener's
requests (`server_lan_media_requests_served`) and bodies
(`server_lan_media_bodies_served`, a `/cast` `GET` that began sending
bytes), both reset by every start and stop, give three readings:

- **No requests**: the receiver could not route to the address. The session
  ends as Stop ends it, the film comes back, and the dialog says why.
- **Requests and no body**: the receiver reached this device and has been
  sent nothing yet -- a refusal the server logged, or a stream whose bytes
  are not here (a dead swarm). The remote says so under the title, and the
  check runs again every as long until a body has begun, when the note
  goes. **It never ends the cast**: a stream that is slow to come is waited
  for, and the viewer is the one who stops it.
- **A body**: the network and the server did their part; the rest is the
  media's, and nothing is said.

What the receiver reports about itself is never consulted -- the receiver
this exists for reports a healthy session and an unknown player state -- so
only the ways out of a session (`_cancelCastFetch`) cancel the wait, and
picking a second receiver is one of them.

**The listener lives exactly as long as a session**: closed when the session
ends, from any side, when a start fails and on `dispose`. Nothing binds it
at boot. Turning it on grants the server's persisted `lanMediaEnabled` and
turning it off takes it back, and `start_in` takes back a grant a crashed
cast left behind, so what is on disk while nothing casts is "no".

## While casting

The player screen shows the title, the position, play/pause, seek and stop,
all from the receiver's status -- a pause from its own remote shows here
too, and the phone's transport keys are the receiver's. Local playback is
stopped and its reports ignored; ending the session resumes it where the
receiver had got to (a status with no media keeps the last position rather
than reading as the start of the film). The core hears the same
`TimeChanged`, `PausedChanged` and `Ended` local playback sends, so the
library and continue-watching do not notice.

**Casts do not binge**, by decision: `Ended` from the receiver shows no
up-next card and never starts the next episode, whatever `bingeWatching`
says. The viewer is at the television, not at the phone to cancel a
countdown.

## The pieces, and what is verified

`lib/features/cast/`: `cast_client.dart` (the interface, `CastScope`, the
types), `google_cast_client.dart` (over
[`flutter_chrome_cast`](https://pub.dev/packages/flutter_chrome_cast)),
`cast_compatibility.dart`, `cast_widgets.dart`; the session in
`PlayerScreen`; `LanMediaControl` on `ServerClient`. Widget tests use
`FakeCastClient` / `FakeLanMediaControl` (`test/support/`);
`rust/tests/lan_media.rs` drives the listener. The manifest entries are in
[ANDROID.md](ANDROID.md#manifest-and-platform-channels).

**Not verified against a real Chromecast**: there is no receiver here. What
is verified: the LAN listener over real HTTP (it serves media routes,
answers `/proxy` and `/settings` with 404, counts requests, and is gone
after a stop and a shutdown), the Android manifest merge, every decision
the app makes around a fake sender, and a rendition fetched over that
listener and decoded by `ffmpeg` on a desktop (`rust/tests/rendition.rs`).
Whether the default receiver plays the rendition stream is the device
proof still owed.
