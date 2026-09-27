# What is built today

Screen by screen, what the app does. What the app *is* is in the
[README](../README.md); how each part works is in
[ARCHITECTURE.md](ARCHITECTURE.md).

The app boots `stremio-core` and the embedded `stream-server` at start-up
and streams only from that server. Browse, details and play; account,
library, addons and settings; downloads, Google Drive, casting and the
Android TV layout are all built. What is not is in the README's
[What is next](../README.md#what-is-next) and in [WISHLIST.md](WISHLIST.md).

## Board, Discover, Search

- **Board**: a continue-watching row, then one row per catalog that
  answered, and one line at the end for the catalogs that could not be
  loaded -- expanding to the addon, what it said, and **Check addon** /
  **Uninstall** -- so a dead addon is never mistaken for a title nobody has.
- **Discover** browses any catalog through the engine's type, catalog and
  genre filters.
- **Search** asks every addon that supports it, groups the hits per addon,
  and accounts for the addons that could not be searched the same way.

## Details

Facts and genres; for a series a season picker and episode list with
watched state (picking an episode loads its streams); a bookmark to add or
remove the title from the library; a **More like this** row of suggestions
([Recommendations](ARCHITECTURE.md#recommendations)); and the sources every
installed addon returned, plus any linked Google Drive file matched to this
title or episode.

**The sources list** has two layouts and a toggle in its header saying
which is on and what tapping switches to:

- **Sectioned** (the default): every addon's answers together, cut into one
  collapsible section per resolution, highest first, with streams nothing
  could be read from last in an "unknown" section rather than a guessed
  rung.
- **Grouped**: a collapsible section per addon, in profile order, each
  addon's own ranking intact.

Every section starts collapsed until the viewer opens one; a closed header
still says how many streams it holds and the best swarm among them. Which
sections and groups are open, the layout and the order are global and
survive a restart (the preferences in
[ARCHITECTURE.md](ARCHITECTURE.md#the-apps-own-preferences)); a remembered
section this title lacks opens nothing else.

Inside a section the order is **peers per megabyte** (every stream is the
same film, so size is bitrate and peers are supply); chips offer largest
first or most peers. A stream missing either number sits after the ranked
ones in the addons' order; a swarm known to be empty is ranked last. Each
row names its addon and is badged only with what could actually be read.
**One release is one row**: sources that are the same torrent (info hash
and file index) or the same URL collapse, keeping the best-ranked instance
and saying "Also from ..."; the grouped layout keeps a copy per addon,
marked the same way. The surviving row carries the union of every listing's
trackers, which is what playback, downloads and the stats poll are given.
An addon that answered with an error is named and can be checked or
uninstalled on the spot. Coming back from the player lands on the right
episode.

**On a television** the screen is laid out for a remote:

- the title's backdrop fills the panel under the overscan band, darkened by
  a gradient scrim, with the logo, one line of year, runtime, genres and
  rating, and two lines of description; no poster. A missing backdrop falls
  back to the poster, and the logo's box holds its height whether the logo
  arrives or not;
- episodes are a **row of cards** under the season pills: still, number,
  title, air date, watched check, download badge and a resume bar; an
  unaired episode takes no focus, and the row scrolls to the selected card;
- sources are the last two rows: a card per group (resolution or addon, per
  the same layout preference), and under the chosen one a row of its
  sources. The last-used source is a card above them and where the remote
  starts. Back closes the open row before leaving. What the addons did
  besides answer -- failed, had nothing -- is the last group card, naming
  each addon in the row it opens.

## Player

Plays every stream through the embedded server -- torrents directly, and
anything on another host through its caching `/proxy` -- with its own
controls: seek bar with the buffered range, play/pause, seek buttons,
volume, fullscreen, keyboard shortcuts, playback speed; embedded and addon
subtitles styled from the profile settings, with timing adjusted by hand or
measured and then remembered ([Subtitles](ARCHITECTURE.md#subtitles));
audio track selection; a stats OSD
([OPERATIONS.md](OPERATIONS.md#the-stats-osd)); an up-next countdown that
hands over to the next episode; and a **buffer ahead** choice, including
"Download the whole file".

A torrent starts behind a card saying what the server is doing (fetching
metadata, checking data, finding peers, the piece it is waiting for) instead
of a spinner, and a stall mid-playback shows the same card; an open that
fails while the torrent is still starting is retried behind it. A stream
that turns out to be an archive or a disc image is played from inside the
container, or refused in a sentence when the film is compressed. A cast
button appears once a receiver answers ([CASTING.md](CASTING.md)).

## Library

The engine's library (every added title, type pills and sorts, cumulative
paging; long press to remove, mark watched, rewind, or mute notifications),
with a hint to sign in when anonymous and **Sync now** when signed in. On
top of that, never written to the Stremio library or synced:

- **downloaded titles** appear whether or not they were added, and so do
  **linked Drive files** matched to a title, under their type;
- **Downloaded** and **Remote** are filter chips that combine with the type
  pills and the sort: Downloaded narrows to what is on this device; Remote
  to what is linked from Drive, including files that matched nothing, with a
  Reload button that asks Drive for the current names;
- the app bar has the way to the Downloads screen and the button that links
  remote files (Google Drive today).

## Downloads

The download button on a source pins it through the embedded server -- a
torrent in the piece store, a web link or a Drive file in the proxy cache --
and becomes a delete button once the file is whole; replacing a kept
release with another asks first. On a television the tile's long press does
what the button would. Badges on episodes and the details header say what
is kept and how far along.

The **Downloads** screen (from the details app bar, the player's menu, the
library's app bar and Settings) lists everything with its progress, plays a
finished one, retries a stopped one, deletes one (always with its bytes)
and says how much room it all takes. Opened from the player it offers no
play of its own. A download that is no longer on the device says **Not on
this device** and offers to fetch it again. A finished download plays with
no network, and offline the player still records watch progress. There is
no downloads folder to choose: torrent data has one root, named in Settings
→ Server storage. On Android a foreground service with a notification
(progress, **Cancel all**) keeps downloads going after the app is left.

## Google Drive

Linking starts from the library's remote-files button. A television shows a
QR code for a phone; a phone or desktop opens the page itself, and a phone
with this app installed picks with Android's own picker, several files at
once. The pairing is collected even if the viewer leaves the screen or the
app is killed. Linked files are matched to titles by name, appear as
sources on those titles and in the library, play through the embedded
server (which renews the access itself), are tracked like any other play
(resume point, watched, Continue Watching, the next episode's linked file),
and download like any other source. When Google refuses the grant, every
screen asks for a new pairing. See
[ARCHITECTURE.md](ARCHITECTURE.md#google-drive).

## Addons

From Settings: the installed and community addons; install, update,
uninstall or configure one by manifest URL; a link out to
[stremio-addons.net](https://stremio-addons.net); and **Refresh addons from
account**, which is also how a television gets an addon installed from a
website on another device. An addon site's Install button opens the addon's
details screen through a `stremio://` link ([DEEP_LINKS.md](DEEP_LINKS.md)).
Each installed addon carries a verdict on how it has been answering
([ADDONS.md](ADDONS.md)).

## Settings

- **Account**: sign in, create an account, sync, log out.
- **Addons** and **Downloads**: the screens above.
- **Player**, **Subtitles**, **Interface**: the engine's own settings
  (seek steps, binge watching and the up-next countdown, pause on minimize,
  hardware decoding, languages, subtitle size and colours), plus the app's
  **Buffer ahead** and, on a television, **Bold focus**.
- **Streaming server**: **Share while idle**, the embedded server's status
  (there is no choice of server), **Server storage** (where torrent data
  lives, what it costs, "Clean cache now") and peer discovery (DHT) health.
- **About**: open source licences, including unrar-rs's.
- **Developer**, in release builds: **Verbose logging**, **Diagnostics** (the
  core's and the server's recent log, copied redacted unless verbose
  logging is on) and entries that play or download a public Big Buck Bunny
  torrent without any addon.

A **status light** on the main screens is lit while the server moves bytes
to or from peers with nothing playing, and offers a stop for what it shows.

## Android TV and Google TV

A layout of its own, chosen by `DeviceProfile.detect()` asking Android
whether this is a television. The shell keeps the rail at every width with a
focus memory per tab; tiles mark focus with a two-stroke ring, a 5 % zoom
and a shadow ("Bold focus" thickens it and dims the rest); the D-pad walks
rows and columns, a held centre key or the menu key is a long press; the
player takes the remote's centre and media keys, stays immersive, and asks
the panel for the film's own frame rate; text grows 1.15x with 48 dp
targets; every screen but the video and the Details backdrop keeps 5 % of
each edge clear of overscan; and controls a remote cannot work (the volume
slider, the fullscreen toggle, scrollbar thumbs) are not drawn. Text is
typed on a screen of its own
([ANDROID.md](ANDROID.md#typing-with-a-remote)).
