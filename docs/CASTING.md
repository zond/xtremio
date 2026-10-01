# Casting to a Chromecast

What the cast button does, and -- the honest half -- what it refuses and
why. The player it hangs off is in [ARCHITECTURE.md](ARCHITECTURE.md#the-player).

A cast button on the player's top bar, once a receiver has answered. It hands
the stream to the receiver **untouched** -- the bytes the embedded server
already serves, with no processing anywhere -- and turns the player screen
into a remote while the television plays. Media3 remuxing, which would let
most other streams be cast, is not built. Because nothing is converted, the
honest part of this is the refusal. The button is never built on Android TV:
a TV is a receiver, not a sender.

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
`.rar` holding an MP4 casts, and a Matroska inside a `.rar` is refused as a
Matroska. A link-borne container's credentials never cross the LAN: the
receiver is handed a token, and the session the server made for the
container stays on this device.

A refusal is a dialog saying what is wrong and that the conversion that
would fix it does not exist yet; `CastRefusal` names the rule, which is the
seam Media3 would fill. **One refusal is not a verdict**: in the first
seconds of a torrent the server has not opened a file yet, which is
`CastRefusal.containerPending` ("Still working out what this file is"), and
the poll that names the file makes the same button work. The name is kept
while the player is on that stream, and taken only from an answer about the
file being streamed, never the torrent-level fallback's guess. A member is
never pending: a member whose name says nothing is an unknown file.

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
after a stop and a shutdown), the Android manifest merge, and every decision
the app makes around a fake sender.
