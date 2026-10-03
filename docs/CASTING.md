# Casting to a Chromecast

What the cast button does, and -- the honest half -- what it refuses and
why. The player it hangs off is in [ARCHITECTURE.md](ARCHITECTURE.md#the-player).

A cast button on the player's top bar, once a receiver has answered. It hands
the stream to the receiver **untouched** -- the bytes the embedded server
already serves, with no processing anywhere -- or, for an H.264 or HEVC
film with AAC sound in a Matroska file, **repackaged**: the same samples as one fragmented MP4,
made as the receiver reads it ([Renditions](#renditions-a-matroska-film-repackaged)). It
turns the player screen into a remote while the television plays. Nothing
is decoded or encoded for a receiver yet, so the honest part of this is
still the refusal. The button is never built on Android TV: a TV is a
receiver, not a sender.

## What can be cast

**The compatibility rule** (`lib/features/cast/cast_compatibility.dart`):
MP4 or WebM, H.264, HEVC, VP8 or VP9 video, and audio the container may
carry -- AAC or MP3 in an MP4, Opus or Vorbis in a WebM. The audio half is
keyed on the container because that is where a receiver draws the line; the
video half is one list for every device, a known approximation (HEVC and
VP9 want a Chromecast Ultra or newer), and the comment on the table says why
fixing it means asking the session what the receiver supports.

- **The container** comes from the name of the file the embedded server says
  it opened (`streamName` in the `stats.json` the player polls), then the
  converted stream's filename, then `behaviorHints.filename`, then a URL
  path ending in a real file name, then the name the server resolved the
  media id to. The server comes first because a
  torrent's URL says nothing and the addon may be guessing. A container
  nothing identifies is a **refusal**, not a maybe.
- **The codecs** come from mpv while the stream plays locally (`video-codec`
  and `audio-codec-name`, sampled while the receiver list is open), and
  otherwise from what the release claims (`StreamFacts` tags, the filename).
  A claim is believed when it says something is *wrong* and never taken as
  proof that something is right; mpv overrules a release name that
  disagrees.
- **A stream this device reads only by URL is refused** before any of
  that when it is on this device: an origin that will not serve ranges
  (read forward through `/proxy`) or a route the server names no id for
  (`/ftp`). The LAN listener serves published ids and nothing else, and
  nothing here can seek such a stream for a receiver.

**What is judged is the film, not its container.** The server resolves an
id that turns out to be an archive or disc image to the member inside it
(`Resolved.member`), mpv plays the member, and the cast follows:
`PlayerScreen._castFilename` is the member's own name
(`MediaResolution.memberName`), and what is published is the same id. So a
`.rar` holding an MP4 casts, and a Matroska inside a `.rar` is judged as a
Matroska. A link-borne container's credentials never cross the LAN: the
receiver is handed a token, and the session the server made for the
container stays on this device.

A refusal is a dialog saying what is wrong and that the conversion that
would fix it does not exist yet; `CastRefusal` names the rule, which is the
seam the rest of the renditions fill. **One refusal is not a verdict**: in the first
seconds of a torrent the server has not opened a file yet, which is
`CastRefusal.containerPending` ("Still working out what this file is"), and
the poll that names the file makes the same button work. The name is kept
while the player is on that stream, and taken only from an answer about the
file being streamed, never the torrent-level fallback's guess. A member is
never pending: a member whose name says nothing is an unknown file.

## Renditions: a Matroska film, repackaged

A Chromecast will not open a Matroska file, and most films are one. When
the film inside is H.264 or HEVC with AAC sound -- **as mpv reports it**,
since a copy is only as right as the codecs it copies, and a release's claim
is not enough -- `CastCompatibility.of` answers `CastRendition` instead of
the container refusal, provided the stream is played by id and this device
can make one (`media_renditions_available`). HEVC (Main and Main 10, so
HDR10 and HLG too) is allowed because zond's receiver, a Chromecast with
Google TV 4K (`sabrina`), decodes it up to 4K: `_repackagedVideo` is a
constant for that receiver until the receiver table (step F5) makes it a
row per model, and until then an HEVC film cast to a receiver without HEVC
is a black screen.

**When it would be repackaged and a track cannot be**, the refusal names
the track and why, in one sentence each, the picture first:

- sound that is not AAC -- "This film's sound is Dolby Digital Plus
  (E-AC3), which xtremio can't convert for casting yet." (converting it is
  step F3);
- video the receiver decodes but a copy does not carry (VP8, VP9) --
  "This film's video is VP9, which xtremio can't repackage for casting
  yet.";
- video the receiver cannot decode (AV1, MPEG-4 Part 2, MPEG-2, VC-1) --
  "This film's video is AV1, which this receiver can't play, and xtremio
  can't convert it for casting yet." (step F4);
- codecs mpv has not reported yet -- a "not yet", headed *Still working out
  what this file is*: "...which xtremio repackages for casting once the
  player has said what is in it. Try again once it has started playing."

What mpv cannot see, the producer refuses when the receiver first asks:
**Dolby Vision**. mpv reports it as HEVC; the producer reads the container's
Dolby Vision record (`StreamInfo::dolby_vision`, from the stream's side
data) and copies profiles 7 and 8 as the HDR10, SDR or HLG base layer they
carry, dropping the RPU and enhancement-layer NAL units (types 62 and 63)
and signalling no Dolby Vision; **profile 5** -- a base layer only a Dolby
Vision decoder shows right -- fails the rendition with "This film's
picture is Dolby Vision profile 5, which has no ordinary HDR or SDR picture
underneath: the television would show it in the wrong colours." The
server answers the receiver `503` with that sentence; the app does not yet
read a rendition's state (`rendition_state`, step F5), so on the phone it
shows as a receiver that did not play. The player then publishes a
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
light levels are often only there), and the AAC frames as they are. The
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

Sound that is not AAC, video that is neither H.264 nor HEVC and every other
container are still refused; converting them is the rest of step F of the
renditions design.

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
this way: a torrent, a link through the server's cache, a Drive file, a
download, a file on this device, the film inside an archive. **The token is
withdrawn** (`media_unpublish`, which also cuts a body being served) when
the session ends from any side, when another receiver is picked (which is
handed a token of its own), when a start fails, when the screen moves to
another stream and when the player is left; stopping the listener withdraws
every token besides. A token is never logged. A link the server reads only
forward is handed over as it is when it is on another internet host, and
no listener is started for it.

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
