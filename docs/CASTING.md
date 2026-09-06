# Casting to a Chromecast

What the cast button does, and -- the honest half -- what it refuses and
why. The player it hangs off is described in
[docs/ARCHITECTURE.md](ARCHITECTURE.md).

A cast button on the player's top bar, once a receiver has answered. It hands
the stream to the receiver **untouched** — the bytes the embedded server
already serves, with no processing anywhere — and turns the player screen into
a remote while the television plays. Media3 remuxing, which is what would let
the other three quarters of the streams out there be cast, is not built.

Because nothing is converted, the honest part of this is the refusal.

**The compatibility rule, as implemented**
(`lib/features/cast/cast_compatibility.dart`): MP4 or WebM, H.264, HEVC, VP8
or VP9 video, and audio the container is allowed to carry — AAC or MP3 in an
MP4, Opus or Vorbis in a WebM. The audio half is keyed on the container
because that is where a receiver draws the line; the video half is one list
for every device, which is a known approximation in both directions — HEVC
and VP9 want a Chromecast Ultra or newer, and a WebM claiming H.264 would be
called ready — and the comment on the table says why fixing it means asking
the session what the receiver in the room supports.

- The **container** comes from the name of the file the embedded server says
  it opened (`streamName` in the `stats.json` the player already polls), then
  the converted stream's filename, then `behaviorHints.filename`, then a URL
  path that ends in a real file name. The server comes first because a
  torrent's streaming URL is `/{infoHash}/{fileIdx}` and says nothing, and the
  addon is often silent or guessing: it says what it believes it linked to,
  the server says what it opened. (For a torrent the converted stream is the
  same claim — `Stream::to_converted` clones `behavior_hints` verbatim — while
  an offline play, where it really is the file on disk, has no server behind
  it at all.) A container nothing identifies is a **refusal**, not a maybe. A
  guess here is a guess about whether the evening works.
- The **codecs** come from mpv while the stream is playing locally
  (`video-codec` and `audio-codec-name`, sampled while the receiver list is
  open), and otherwise from what the release claims about itself — the
  `StreamFacts` tags and the filename. A claim is believed when it says
  something is *wrong* and never taken as proof that something is right, so a
  codec nothing mentions passes on the container's strength alone, and mpv
  overrules a release name that disagrees with the decoder.
- A `/proxy` or `/ftp` URL is refused before any of that. Those routes are
  each an open proxy and are deliberately not mounted on the LAN listener, so
  a stream stremio-core plays through the proxy cannot be cast at all.

A refusal is a dialog that says what is wrong and that the conversion which
would fix it does not exist yet; `CastRefusal` names which rule refused, which
is the seam Media3 fills.

One refusal is not a verdict. In the first seconds of a torrent the server has
not opened a file yet, so nothing anywhere names it; that is
`CastRefusal.containerPending`, headed "Still working out what this file is"
rather than "This stream cannot be cast", and it answers itself — the poll that
names the file makes the same button work, with nothing reopened. The name is
kept for as long as the player is on that stream, because the polling stops
once playback is under way while which file this is does not go stale, and it
is only ever taken from an answer about the file being streamed: the
torrent-level fallback's `streamName` is the file the server *guessed*.

**The URL the receiver is given.** A Chromecast cannot fetch from
`127.0.0.1`, so a loopback URL is rebuilt on the server's **LAN media
listener** — a second HTTP listener with no control routes on it at all, and
deliberately without `/proxy` and `/ftp` (`rust/src/server.rs`,
`server_set_lan_media`). A stream served from somewhere else on the internet is
handed over as it is; the receiver has a connection of its own, and no listener
is started for it. If no local interface can reach the receiver, the app says
the device is unreachable rather than casting a URL that could never be
fetched.

**Which address of this device it is given** depends on where the receiver
is, and Android is asked: `MainActivity.castDeviceAddress` reads the address
off the MediaRouter route the Cast SDK discovered -- `flutter_chrome_cast`
drops it on the way to Dart -- and `GoogleCastClient` asks for it as the
session starts, once per cast rather than once per receiver on every route
change. The server then names the interface on that receiver's subnet. With
no address to go on (iOS, a route gone stale) it ranks its own interfaces
instead: a private address on an ordinary interface ahead of anything on one
a receiver cannot be behind at all -- a tunnel, a cellular link, an Android
tether, a container or VM bridge, each of which carries a private address on
an ordinary-looking name and would otherwise tie with the real LAN
interface. That ranking is a guess, and losing the guess is a
Chromecast that sits on its splash screen forever -- which is what made the
address worth asking Android for.

**What was handed over is written down.** The player logs the URL and the
address it was chosen for, and logs the refusal when there was no address to
give; both land in Diagnostics with everything else the player records. It is
the only account there is: the receiver reports nothing useful, and the
server's own log says only that its listener started and stopped.

**A receiver that never fetches** is not left looking like one that is merely
slow. `PlayerScreen.castFetchTimeout` after a load -- twenty seconds -- one
question is asked, and the listener's count of what it has been asked for is
the whole of the answer (`server_lan_media_requests_served`, reset by every
start and every stop, so it is the session's own even when a second receiver
is picked while the first still has the stream). Nothing at all: the address
was one the receiver could not route to, and nothing will happen, because a
connect to an unroutable host hangs instead of failing. The session ends the
way Stop ends it, the film comes back to this device, and the dialog says
why. Something: it reached this device, the viewer is told nothing, and the
count goes in the log. Whether such a receiver is filling a buffer or cannot
decode what it fetched is not something twenty seconds can tell -- a cold
torrent has made requests by then and is still warming up -- so a dialog
blaming the file would be wrong as often as it was right, and Stop is where
it always was.

**What the receiver says about itself is never consulted here**, and that is
the point rather than an omission. The receiver this check exists for reports
a healthy session and `media_control_handler.cc(59) Unknown player state:`,
which the client folds into `CastPlayerState.idle`; a check that disarmed on
anything but buffering therefore disarmed on the one case it was written for,
and the tests only passed because the fake emitted no status at all. So
nothing incoming cancels the wait -- only the ways out of a session do
(`_cancelCastFetch`). A stream fetched from the internet arms none of this:
our listener is not the one it would be asking.

**The listener lives exactly as long as a session**, and that is made hard to
get wrong rather than merely intended: it is closed when the session ends, when
the session ends from the television or another phone, when a start fails, on
`dispose`, and defensively right after the server starts — stream-server binds
a configured `lan_media_addr` at boot, so `start_in` shuts it again as the
first thing it does. Turning it on also grants the server's `lanMediaEnabled`
veto and turning it off takes it back, so what is on disk while nothing is
casting is "no".

**While casting** the player screen shows the title, the position, play/pause,
seek and stop, all from the receiver's own status — a pause from its remote
shows up here too. Local playback is stopped and its own reports ignored, and
ending the session resumes it where the receiver had got to. The core hears the
same three actions local playback dispatches — `TimeChanged`, `PausedChanged`,
`Ended` — so the library and continue-watching do not notice which device the
pixels were on.

The button is never built on Android TV: a TV is a receiver, not a sender.

The pieces: `lib/features/cast/` (`cast_client.dart` — the interface,
`CastScope` and the types; `google_cast_client.dart` — the implementation over
[`flutter_chrome_cast`](https://pub.dev/packages/flutter_chrome_cast);
`cast_compatibility.dart`; `cast_widgets.dart`), the session in
`PlayerScreen`, and `LanMediaControl` on `ServerClient`. Widget tests drive it
through `FakeCastClient`/`FakeLanMediaControl` (`test/support/`) and never
touch the plugin; `rust/tests/lan_media.rs` drives the listener itself.

**Not verified against a real Chromecast** — there is no receiver on this
machine. What is verified: the LAN listener over real HTTP (it serves media
routes, answers `/proxy` and `/heartbeat` with 404, counts every request that
reaches it, and is gone after a stop and after a shutdown), the Android
manifest merge, and every decision the app makes around a fake sender --
including which address the server is asked for and what is said about a
receiver that never comes back for the stream.
