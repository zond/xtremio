# What is built today

Screen by screen, what the app does. What the app *is* is in the
[README](../README.md); how each part works is in
[ARCHITECTURE.md](ARCHITECTURE.md).

The app boots `stremio-core` and the embedded `stream-server` at start-up
and streams only from that server. Browse, details and play; account,
library, addons and settings; downloads, Google Drive, casting and the
Android TV layout are all built. What is not built is in the README's
[What is next](../README.md#what-is-next) and in [WISHLIST.md](WISHLIST.md).

## Discover, Search

- **Discover** is the screen the app opens on. It shows a
  continue-watching row, then one row per catalog that answered, then one
  line for the catalogs that could not be loaded. That line expands to the
  addon, what it said, and **Check addon** / **Uninstall**, so a dead addon
  is never mistaken for a title nobody has. The addons' types run across
  the top, starting with **All**. A type shows that type's rows (Continue
  watching too) and a catalog menu on **Any**. Choosing a catalog there, or
  **See all** on a row, opens it as a grid with its genre and other
  filters. Back comes down the same way: catalog, type, All. The menu
  offers every catalog that opens without a search, which is
  stremio-core's own rule for Discover; one that needs a genre opens on
  its first. A Discover opened from a title's genre chip is that catalog
  alone. (It replaced a separate Board tab, whose rows were All's.)
  A long press on a Continue watching tile (a held select on a television)
  offers **Remove from Continue watching**, beside the Library's own menu
  when the title is in the library. It asks once more, on **Cancel**,
  before it rewinds the title and dismisses its new-episode notifications,
  as Stremio's own "Dismiss" does. The library and the watched marks are
  left alone.
- **For you** is a row under Continue watching, above the catalogs, on
  every device. It holds titles like the ones the viewer watched through,
  added by hand or liked, from the same "More like this" answers a details
  page shows. A tile is the poster and the name, like every other row's.
  The row leaves out anything in the library in any sense, on Continue
  watching, disliked or dismissed. A long press (a held select) shows why.
  It lists every title that suggested it, strongest first, with what it
  counted for in words ("Watched and saved: Heat (×2)") and the points that
  ranked it; each title links to its details page. Then come **Add to
  library**, **Mark as watched** for a film, **Not interested** and
  **Cancel**. Add to library works as the bookmark does: the title leaves
  the row and becomes a saved source. Mark as watched is for a film seen
  elsewhere. The film becomes watched in Stremio's own library state, as
  one finished in the player does, without being added to the library,
  and it becomes a source of the row. A series has no Mark as watched
  there. The details page says which of its episodes were watched. The row
  is worked out on the device and kept. It is worked out again when the
  sources or the faces change, and otherwise once a day. With nothing
  kept, it appears as the first answers arrive. It is hidden when it has
  nothing to show ([For you](ARCHITECTURE.md#for-you)).
- **Search** asks every addon that supports it, groups the hits per addon,
  and accounts for the addons that could not be searched the same way.

## Details

The details screen shows facts and genres. A series has a season picker
and an episode list with watched state; picking an episode loads its
streams. A bookmark adds the title to the library or removes it. A film
has a check beside it that says whether it is watched. The check marks or
clears it as a finished playback would, in Stremio's own library state,
added to the library or not. A series' watched state belongs to its
episode list. Beside those are a happy face and a sad one, both at rest.
Pressing one marks the title, draws that face filled in the accent colour
and takes the other away. Pressing it again clears the mark and brings
both back. On a television both are stops right of the bookmark, and the
remote stays on the pressed face. The For you row reads these marks
([Likes and dislikes](ARCHITECTURE.md#likes-and-dislikes)). The screen
also shows IMDb, TMDB, Rotten Tomatoes and Popcornmeter scores
([Ratings](ARCHITECTURE.md#ratings)), a **More like this** row of
suggestions ([Recommendations](ARCHITECTURE.md#recommendations)), and the
sources. The sources are what every installed addon returned, plus any
linked Google Drive file and any video on this device matched to this
title or episode.

**The sources list** has two layouts. A toggle in its header says which
is on and what tapping switches to:

- **Sectioned** (the default): every addon's answers together, cut into one
  collapsible section per resolution, highest first. Streams nothing could
  be read from come last, in an "unknown" section rather than a guessed
  rung.
- **Grouped**: a collapsible section per addon, in profile order, each
  addon's own ranking intact.

Every section starts collapsed until the viewer opens one. A closed header
still says how many streams it holds and the best swarm among them. The
open sections and groups, the layout and the order are global and survive
a restart (the preferences in
[ARCHITECTURE.md](ARCHITECTURE.md#the-apps-own-preferences)). A
remembered section this title lacks opens nothing else.

Inside a section the order is **peers per megabyte** (every stream is the
same film, so size is bitrate and peers are supply). Chips offer largest
first or most peers. A stream missing either number sits after the ranked
ones, in the addons' order. A swarm known to be empty is ranked last. Each
row names its addon and is badged only with what could actually be read.
**One release is one row**: sources that are the same torrent (info hash
and file index) or the same URL collapse into one. The best-ranked
instance is kept and says "Also from ...". The grouped layout keeps a copy
per addon, marked the same way. The surviving row carries the union of
every listing's trackers, which is what playback, downloads and the stats
poll are given. An addon that answered with an error or with nothing is
left off the list and not mentioned; its health shows on the Addons
screen. When no addon had anything, the screen says so and offers the
addons. A **Trailer** button under the description opens the title's
trailer in the YouTube app, or in a browser where there is none. The
trailer is the first YouTube video the meta addon lists (Cinemeta's
`trailerStreams`), so no trailer addon is needed. A YouTube source opens
the same way, since the embedded server has no YouTube resolver.

Coming back from the player lands on the right episode. A series opens on
the season and episode it was left on last time, unless the library has
watched something since (the player moving on to the next episode by
itself). A title in the library never opened here starts on the episode
last watched. An episode it was sent to from Continue watching wins over
both. A phone's page also opens scrolled as far as it was left, and so
does a narrow window's (the two-pane layout is not restored). A page
opened from Continue watching is the exception and starts at the top. The
last 200 titles are remembered across restarts. The position is written
on leaving, on the player going over the page and on the app going to the
background.

**On a television** the screen is laid out for a remote. A title never
visited opens at the top of the page with the remote on the header (the
plot, else the header's first stop). The rung the title is for is open
under it, a walk down away. A title visited before opens with the remote
on the stop it was left on, once that stop has arrived: the same source,
group pill, episode or header, with its rung and group open. Meanwhile
the remote waits on the header. A source that is gone gives way to the
card beside it, then the group pills, then the header. The remote goes to
the "Continue with last stream" card instead when the title is opened from
Continue watching. Nothing that arrives after the remote is put down, or
after the viewer moves it, takes it anywhere. Coming back to the screen,
from the player or a screen over it, leaves the remote where it was. What
is on it:

- The title's backdrop fills the panel under the overscan band, darkened
  by a gradient scrim. On it are the logo, one line of year, runtime,
  genres and rating, and two lines of description; there is no poster. A
  missing backdrop falls back to the poster, and the logo's box holds its
  height whether the logo arrives or not. The bookmark in the corner is a
  press right of the plot or the trailer. A press left from it goes back
  where the remote came from.
- Episodes are a **row of cards** under the season pills: still, number,
  title, air date, watched check, download badge and a resume bar. An
  unaired episode takes no focus, and the row scrolls to the selected
  card. A press down or up lands on the season on screen when it reaches
  the pills, and on the selected episode when it reaches the row, rather
  than on the first of either (`TvLadderHome`). Landing on a card there
  chooses it.
- Sources are the last two rows: a card per group (resolution or addon,
  per the same layout preference), and under the chosen one a row of its
  sources. The last-used source is a card above them, and its rung is the
  one open when there is one. Back closes the open row before leaving. An
  addon that failed or had nothing is not drawn at all. When no addon had
  anything, the last rung says so, with a card that opens the addons.

## Player

The player plays every stream through the embedded server: torrents
directly, and anything on another host through its caching `/proxy`. It
has its own controls: seek bar with the buffered range, play/pause, seek
buttons, volume, fullscreen, keyboard shortcuts, playback speed. It has
embedded and addon subtitles styled from the profile settings, with
timing adjusted by hand or measured and then remembered
([Subtitles](ARCHITECTURE.md#subtitles)). It also has audio track
selection, a stats OSD ([OPERATIONS.md](OPERATIONS.md#the-stats-osd)), an
up-next countdown that hands over to the next episode, and a **buffer
ahead** choice, including "Download the whole file".

A torrent starts behind a card saying what the server is doing (fetching
metadata, checking data, finding peers, the piece it is waiting for) instead
of a spinner. A stall mid-playback shows the same card. It also says
"Buffering from the torrent…" while mpv sits blocked in a read the server
has not answered for a second, which is what a resumed film on a weak
swarm looks like. An open that fails while the torrent is still starting
is retried behind the card. A resumed torrent tells the server where it
resumes, so the resume point is asked for beside the file's head rather
than after it. A stream that turns out to be an archive or a disc image is
played from inside the container, or refused in a sentence when the film
is compressed. A cast button appears once a receiver answers. Whether a
film can be cast is judged by what mpv reports of it and the receiver's
announced name. A plain link the receiver can fetch goes to it straight.
Anything else is published on the LAN listener, repackaged with its sound
converted to AAC where the receiver needs it. While casting, the stats
button shows a panel of the cast's own (`CastStatsOverlay`). See
[CASTING.md](CASTING.md).

## Library

The engine's library: every added title, type pills and sorts, cumulative
paging, and a long press to remove, mark watched, rewind, or mute
notifications. It shows a hint to sign in when anonymous and **Sync now**
when signed in. The app adds these on top, never written to the Stremio
library or synced:

- **downloaded titles** appear whether or not they were added, and so do
  **linked Drive files** and **videos on this device** matched to a title,
  under their type;
- **Downloaded**, **Remote** and **Local** are filter chips that combine
  with the type pills and the sort. Downloaded narrows to what is on this
  device. Remote narrows to what is linked from Drive, including files
  that matched nothing, with a Reload button that asks Drive for the
  current names. Local narrows to this device's own videos, matched or not
  (see below);
- a long press on a card that is not the library's own offers the one
  thing to do about it. An unmatched Drive file comes off Remote (it stays
  in Drive), and an unmatched local video comes off Local for good (it
  stays on the device), both with an undo. A downloaded title's card
  deletes the download, after asking;
- the app bar has the way to the Downloads screen and the button that links
  remote files (Google Drive today).

## Downloads

The download button on a source pins it through the embedded server: a
torrent in the piece store, a web link or a Drive file in the proxy cache.
The button becomes a delete button once the file is whole. Replacing a
kept release with another asks first. On a television the tile's long press does
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
→ Server storage. A download on its way says under its bar what it is
doing, in the words of the player's buffering card: `Downloading 32% ·
1.2 MB/s · connected 14 · seeds 137 · swarm 539 · 612 MB of 1.9 GB`,
`Finding peers · No peers found yet · 0 B of 1.9 GB`, or the piece a
player is waiting for. On Android a foreground service keeps downloads
going after the app is left, for as long as one is on its way. Its
notification names the title, the percentage and the speed, and pulled
open shows the same lines per download, with **Cancel all**.

**Known issue, decided:** the first start of a build on the `media-cache`
storage layout deletes the previous `rqbit-downloads` directory, and every
download's bytes with it. There is no migration. A finished download then
says **Not on this device** and can be fetched again. An unfinished one
starts over from nothing.

## Google Drive

Linking starts from the library's remote-files button. A television shows a
QR code for a phone. A phone or desktop opens the page itself, and a phone
with this app installed picks with Android's own picker, several files at
once. The pairing is collected even if the viewer leaves the screen or the
app is killed. Linked files are matched to titles by name. They appear as
sources on those titles and in the library, and play through the embedded
server, which renews the access itself. They are tracked like any other
play (resume point, watched, Continue Watching, the next episode's linked
file), and download like any other source. When Google refuses the grant,
every screen asks for a new pairing. A pairing is shared with the
account's other devices while signed in to Stremio. A device with no grant
takes it at start or sign-in, with every file the Google account picked,
matched to titles. **Reload** also adds files picked on another device. See
[ARCHITECTURE.md](ARCHITECTURE.md#google-drive).

## Local videos

Videos already on the device, found without any addon. On Android they come
from the system's media index (USB drives included; the camera's `DCIM/`
and `Pictures/` are left out). The app asks for the video permission the
first time the Library's **Local** pill is opened, never at launch. Under
Android 14's "Select photos and videos", only the picked videos are listed
(camera clips included, since they were chosen), and a **Choose videos**
button beside the pill picks more. On a desktop they come from folders
chosen in Settings → Local, walked six levels deep. Each is matched to a
title by name the way a Drive file is. Matched ones are sources on their
titles' pages and cards in the Library, tracked like any other play
(resume, watched, Continue Watching). Unmatched ones are listed under
Local with a frame of the video as their picture (Android's own
thumbnail; on a desktop one taken with libmpv and cached), and play as
they are. The list is renewed at start-up, whenever Local is opened and
whenever the app comes back to the foreground, so a video deleted from
the device drops out. The player opens them in place (`content://` or `file://`): nothing is copied or proxied, and there
is nothing to download. The profile's built-in Local Files addon is
answered empty inside the app, so it no longer shows as a catalog that
could not be loaded. The player's up-next plays the next episode's local
file (after a download of it, before a Drive file). A wrong or missing
match is corrected by renaming the file: the next scan drops the old match
and asks about the new name. On macOS a chosen folder stays readable after
a restart through a security-scoped bookmark. See
[ARCHITECTURE.md](ARCHITECTURE.md#local-videos).

## Addons

Settings lists the installed and community addons. An addon can be
installed, updated, uninstalled or configured by manifest URL. Settings
also has a link out to [stremio-addons.net](https://stremio-addons.net)
and **Refresh addons from account**, which is also how a television gets
an addon installed from a website on another device. An addon site's Install button opens the addon's
details screen through a `stremio://` link ([DEEP_LINKS.md](DEEP_LINKS.md)).
Each installed addon carries a verdict on how it has been answering
([ADDONS.md](ADDONS.md)).

## Settings

Every row shows its title. What the row means opens from its icon (the
tooltip says "What is this?"), or from a held OK on a television. A row
whose second line is state keeps it: the account, the server's status,
peer discovery, incoming connections, the internet readout, the core schema version, the
installed version, the local folders' scan and a paused Share while idle.

- **Account**: sign in, create an account, sync, log out; signed in,
  **Change password** (opens Stremio's reset page for the account's address
  in the browser; the address is never logged),
  **Forget my likes everywhere** (asks first, then empties the faces on
  xtremio-xervice and on this device, and says if the service could not be
  reached) and **Forget my Drive access everywhere** (the copy kept for the
  account's other devices; afterwards it points at Google's own permissions
  page, where the grant itself is revoked).
- **Addons** and **Downloads**: the screens above.
- **Player**, **Subtitles**, **Interface**: the engine's own settings
  (seek steps, binge watching and the up-next countdown, pause on minimize,
  hardware decoding, languages, subtitle size and colours), plus the app's
  **Buffer ahead** and, on a television, **Bold focus**.
- **Streaming server**: **Share while idle** (keeps sharing the downloads
  and the last thing watched, until something else plays), the embedded
  server's status
  (there is no choice of server), **Server storage** (where torrent data
  lives, what it costs, "Clean cache now" and "Clear the cache"), **Clear
  the cache** (after a confirmation, stops what is streaming and deletes
  everything cached that a kept download does not hold, and says what it
  freed and how many torrents it stopped), peer discovery (DHT) health and
  **Incoming connections**. That row sits beside peer discovery and says
  whether other people can connect to this device. The app asks the router
  to open a port for that on every device, and downloads work either way.
- **Core**: the stremio-core storage schema version.
- **About**: **Check for updates**, and open source licences, including
  unrar-rs's. The app also looks for updates once a day by itself. An
  Android release build installs a newer release over itself. It first
  measures that the install has room. When it has not, it cleans the
  cache, then clears it, before it says there is not enough space. Every
  other build points at the release page.
- **Developer**, in release builds: **Verbose logging**, **Diagnostics** (the
  core's and the server's recent log, copied redacted unless verbose
  logging is on) and entries that play a public Big Buck Bunny torrent or
  HTTP stream, or download the torrent, without any addon.

A **status light** on the main screens is lit while the server moves bytes
to or from peers with nothing playing, and offers a stop for what it shows.

## Android TV and Google TV

A layout of its own, chosen by `DeviceProfile.detect()` asking Android
whether this is a television. The shell keeps the rail at every width, with
a focus memory per tab. Tiles mark focus with a two-stroke ring, a 5 % zoom
and a shadow ("Bold focus" thickens it and dims the rest). The D-pad walks
rows and columns. A held centre key or the menu key is a long press, and
the rest of that hold presses nothing after it. The player takes the
remote's centre and media keys, stays immersive, and asks the panel for
the film's own frame rate. Text grows 1.15x with 48 dp targets. Every
screen but the video and the Details backdrop keeps 5 % of each edge clear
of overscan. Controls a remote cannot work (the volume slider, the
fullscreen toggle) are not drawn, and neither is any scrollbar: the remote
scrolls by moving focus. Text is typed on a screen of its own
([ANDROID.md](ANDROID.md#typing-with-a-remote)).

Discover has no title there, since the rail already says which tab is
open. The types are the top of the screen. A type's catalog menu and an
open catalog's filters sit beside them on the same band as icons, with
their choice in the tooltip and checked in the menu. The rows below share
the board two at a time. Each row has a heading of one line (the catalog's
subtitle after its title), a caption of one line cut short at its end,
and posters as big as two whole rows allow: 94 x 141 dp on a 1080p Google
TV's 960 x 540, against the 153 x 230 of the one row that used to fill
it. Search is laid out the same way. Its field is the top of the screen
and its hits are those rows, one per catalog. The field is typed on the
platform's screen, typed straight into with a hardware keyboard, or
spoken through the microphone at its right end (Android's
`SpeechRecognizer`, in the app, its words showing as they are said). The
Library has no title there either. Its types, its sort (an icon, its
order in the tooltip and checked in its menu) and the bar's buttons are
one band across the top, with the Remote / Local / Downloaded row under
it. On those three screens the status light sits at the right end of the
top band. That poster and its one-line caption are a television's
everywhere. The Library's grid and a catalog's grid draw the same, and
**More like this** draws the same poster with the year on a second line
under the name. A
series' episode (`S1E2`) is a badge on its poster there, above the
progress bar, so the caption is the name alone.
