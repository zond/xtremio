# What is built today

Screen by screen, what the app does. What the app *is* is in the
[README](../README.md); how each part works is in
[ARCHITECTURE.md](ARCHITECTURE.md).

The app boots `stremio-core` and the embedded `stream-server` at start-up
and streams only from that server. Browse, details and play; account,
library, addons and settings; downloads, Google Drive, casting and the
Android TV layout are all built. What is not is in the README's
[What is next](../README.md#what-is-next) and in [WISHLIST.md](WISHLIST.md).

## Discover, Search

- **Discover** is the screen the app opens on: a continue-watching row,
  then one row per catalog that answered, and one line at the end for the
  catalogs that could not be loaded -- expanding to the addon, what it
  said, and **Check addon** / **Uninstall** -- so a dead addon is never
  mistaken for a title nobody has. The addons' types run across the top,
  starting with **All**. A type shows that type's rows (Continue
  watching too) and a catalog menu on **Any**; choosing a catalog there, or
  **See all** on a row, opens it as a grid with its genre and other
  filters. Back comes down the same way: catalog, type, All. The menu
  offers every catalog that opens without a search -- one that needs a
  genre opens on its first -- which is stremio-core's own rule for
  Discover. A Discover opened from a title's genre chip is that catalog
  alone. (It replaced a separate Board tab, whose rows were All's.) A long
  press on a Continue watching tile (a held select on a television) offers
  **Remove from Continue watching** -- beside the Library's own menu when
  the title is in the library -- and asks once more, on **Cancel**, before
  it rewinds the title and dismisses its new-episode notifications, as
  Stremio's own "Dismiss" does; the library and the watched marks are left
  alone.
- **Search** asks every addon that supports it, groups the hits per addon,
  and accounts for the addons that could not be searched the same way.

## Details

Facts and genres; for a series a season picker and episode list with
watched state (picking an episode loads its streams); a bookmark to add or
remove the title from the library; IMDb, TMDB, Rotten Tomatoes and
Popcornmeter scores ([Ratings](ARCHITECTURE.md#ratings)); a **More like
this** row of suggestions
([Recommendations](ARCHITECTURE.md#recommendations)); and the sources every
installed addon returned, plus any linked Google Drive file and any video
on this device matched to this title or episode.

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
An addon that answered with an error or with nothing is left off the list
and not mentioned (its health shows on the Addons screen); when no addon
had anything, the screen says so and offers the addons. A **Trailer** button
under the description opens the title's trailer -- the first YouTube video
the meta addon lists (Cinemeta's `trailerStreams`), no trailer addon
needed -- in the YouTube app (a browser where there is none), and so does
a YouTube source, since the embedded server has no YouTube resolver. Coming back from the player lands on the right
episode. A series opens on the season and episode it was left on last
time, unless the library has watched something since (the player moving
on to the next episode by itself), and a title in the library never opened
here starts on the episode last watched. An episode it was sent to -- from
Continue watching -- wins over both. A phone's page (and a narrow
window's; the two-pane layout is not restored) also opens scrolled as far
as it was left -- the last 200 titles are remembered across restarts,
written on leaving, on the player going over the page and on the app
going to the background -- except from Continue watching, which starts at
the top.

**On a television** the screen is laid out for a remote. A title never
visited opens at the top of the page with the remote on the header -- the
plot, else the header's first stop -- and the rung the title is for open
under it, a walk down away. A title visited before opens with the remote
on the stop it was left on (the same source, group pill, episode or
header, with its rung and group open), once that stop has arrived; the
remote waits on the header meanwhile, and a source that is gone gives way
to the card beside it, then the group pills, then the header. Opened from
Continue watching, the remote goes to the "Continue with last source" card
instead. Nothing that arrives after the remote is put down -- or after the
viewer moves it -- takes it anywhere. Coming back to it, from the player or
a screen over it, leaves the remote where it was:

- the title's backdrop fills the panel under the overscan band, darkened by
  a gradient scrim, with the logo, one line of year, runtime, genres and
  rating, and two lines of description; no poster. A missing backdrop falls
  back to the poster, and the logo's box holds its height whether the logo
  arrives or not. The bookmark in the corner is a press right of the plot
  or the trailer, and left of it is back where the remote came from;
- episodes are a **row of cards** under the season pills: still, number,
  title, air date, watched check, download badge and a resume bar; an
  unaired episode takes no focus, and the row scrolls to the selected card.
  A press down or up onto the pills lands on the season on screen, and
  onto the row on the selected episode, rather than on the first of either
  (`TvLadderHome`): landing on a card there chooses it;
- sources are the last two rows: a card per group (resolution or addon, per
  the same layout preference), and under the chosen one a row of its
  sources. The last-used source is a card above them, and its rung is the
  one open when there is one. Back closes the open row before leaving. An
  addon that failed or had nothing is not drawn at all; when no addon had
  anything, the last rung says so, with a card that opens the addons.

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
**Known issue:** casting a torrent does not play on the receiver in this
build -- the embedded server's LAN listener now serves only published cast
tokens, and the app's switch to publishing them is the next step.

## Library

The engine's library (every added title, type pills and sorts, cumulative
paging; long press to remove, mark watched, rewind, or mute notifications),
with a hint to sign in when anonymous and **Sync now** when signed in. On
top of that, never written to the Stremio library or synced:

- **downloaded titles** appear whether or not they were added, and so do
  **linked Drive files** and **videos on this device** matched to a title,
  under their type;
- **Downloaded**, **Remote** and **Local** are filter chips that combine
  with the type pills and the sort: Downloaded narrows to what is on this
  device; Remote to what is linked from Drive, including files that matched
  nothing, with a Reload button that asks Drive for the current names;
  Local to this device's own videos, matched or not (see below);
- a long press on a card that is not the library's own offers the one
  thing to do about it: an unmatched Drive file comes off Remote (it stays
  in Drive), an unmatched local video comes off Local for good (it stays on
  the device), both with an undo; a downloaded title's card deletes the
  download, after asking;
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

**Known issue, decided:** the first start of a build on the `media-cache`
storage layout deletes the previous `rqbit-downloads` directory, and every
download's bytes with it -- there is no migration. A finished download then
says **Not on this device** and can be fetched again; an unfinished one
starts over from nothing.

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

## Local videos

Videos already on the device, found without any addon. On Android they come
from the system's media index (USB drives included; the camera's `DCIM/`
and `Pictures/` are left out), asked for with the video permission the
first time the Library's **Local** pill is opened -- never at launch. With
Android 14's "Select photos and videos" only the picked videos are listed
(camera clips included, since they were chosen), and a **Choose videos**
button beside the pill picks more. On a
desktop they come from folders chosen in Settings → Local, walked six
levels deep. Each is matched to a title by name the way a Drive file is:
matched ones are sources on their titles' pages and cards in the Library,
tracked like any other play (resume, watched, Continue Watching); unmatched
ones are listed under Local, with a frame of the video as their picture
(Android's own thumbnail; on a desktop one taken with libmpv and cached),
and play as they are. The list is renewed at start-up, whenever
Local is opened and whenever the app comes back to the foreground, so a
video deleted from the device drops out. The player opens them in
place (`content://` or `file://`): nothing is copied or proxied, and there
is nothing to download. The profile's built-in Local Files addon is
answered empty inside the app, so it no longer shows as a catalog that
could not be loaded. The player's up-next plays the next episode's local
file (after a download of it, before a Drive file). A wrong or missing
match is corrected by renaming the file: the next scan drops the old match
and asks about the new name. On macOS a chosen folder stays readable after
a restart through a security-scoped bookmark. See
[ARCHITECTURE.md](ARCHITECTURE.md#local-videos).

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

Discover has no title there: the rail already says which tab is open, so
the types are the top of the screen, and the rows below them share the
board two at a time -- a heading of one line, the catalog's subtitle after
its title, a caption of one line cut short at its end, and posters as big
as two whole rows allow (94 x 141 dp, on a 1080p Google TV's 960 x 540,
against the 153 x 230 of the one row that used to fill it). Search is laid
out the same way: its field is the top of the screen and its hits are
those rows, one per catalog, the field typed on the platform's screen or
straight into with a hardware keyboard. On those two screens the status
light sits at the right end of the pills' or the field's band. That
poster and its one-line caption are a television's everywhere: the
Library's grid, a catalog's grid and **More like this** draw the same.
