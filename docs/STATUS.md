# What is built today

Screen by screen, what the app does and why it does it that way. What the
app *is* is in the [README](../README.md).

**Status:** phase 3 (account, library, addons, settings) is complete
on top of phase 2 (browse → details → play); what the README calls next is
not started. The app boots `stremio-core` and the
embedded `stream-server` at start-up, and nothing in the app talks HTTP
to that server except libmpv fetching media: the server's control API
takes a per-launch bearer token that only the Rust side holds
(stremio-core's requests get it in `Env::fetch`; the app's own control
calls are FFI). **Board** shows a continue-watching
row and one row per catalog that answered, with one line at the end for
the catalogs that could not be loaded (expanding to the addon, what it
said, and Check addon / Uninstall); **Discover** browses any catalog
through the engine's type/catalog/genre filters; **Search** asks every
addon that supports it, groups the hits per addon, and accounts for the
addons that could not be searched the same way, so a dead addon is never
mistaken for a title nobody has.
**Details** shows facts and genres, a season picker and episode list with
watched state for series (picking an episode loads its streams), and the
streams every installed addon returns with quality hints parsed into
chips. The sources list has two layouts and a toggle in its header, worded
to say which layout is on screen and what tapping switches to, to pick
one: **sectioned** -- every addon's answers put together and cut into
**one collapsible section per resolution**, highest first, with the
streams nothing could be read from last in a section that says it does
not know rather than guessing a rung -- is the default. The other is
grouped: a section per addon, in profile order, each addon's own ranking
intact, which is what the engine hands over and what the sources list
looked like before the sectioned layout existed. Every resolution section
starts *collapsed*, on every title, until the viewer opens one, so the
first thing shown is a compact list of what is available rather than a
guess at what they want; a *closed* header still says how many streams it
holds and the best swarm among them -- an empty-looking 2160p and a
healthy one are different answers. Which sections are open is a global
preference too, not a per-title one: a section opened on one title stays
open on the next and survives a restart, and a resolution the current
title does not offer is simply not shown open, never swapped for some
other section the viewer did not ask for. Inside a section the
order is **peers per megabyte** -- ascending size over peers -- because
every stream in the list is the same film: duration is constant, so size
is bitrate, bitrate is the demand and peers are the supply, which makes
the smallest size per peer the best first guess at a stream that arrives
faster than it is watched. Chips in the header offer largest first or
most peers instead. A stream missing either number cannot be ranked by
the ratio and sits after every ranked one in the addons' own order --
never as a zero and never as a best guess -- while a swarm known to be
empty is ranked, and ranked last of the ranked. Each row names the addon
it came from and is badged with what could actually be read off the
stream, size and peers included -- nothing is badged that is not known.
The layout, the order and which sections are open are all global and
persisted (`streamsSectioned`, `streamsOrder` and `openStreamSections` in
the preferences file), so they follow the user to the next title and
survive a restart -- an install from before the layout was renamed keeps
its choice too, read from the older `streamsFlat` key it was stored
under. **One release is one
row**: two addons offering the same torrent (or one addon offering it
twice) collapse on what they *are* -- info hash plus file index, or the
direct URL, the identity a download pin already uses -- never on what
they look like, so two different releases with the same resolution and
size both stay. The sectioned list collapses after sorting and across
the whole list, so the best-ranked instance is the one kept and a source
two addons described differently cannot appear in two sections; it says
"Also from ..." when
another addon had it too (silently when one addon simply repeated
itself); the grouped list keeps a copy in each addon's group, marked the
same way, since the groups are what that layout is for. The row that
survives carries the **union of every listing's `announce` list**,
deduplicated and in first-seen order, and that merged stream is what
playback, a download and the stats poll are handed -- so the server adds
the torrent with every tracker any addon knew about. An addon that answered
with an error is named from the profile
rather than by its host and offers to be checked or uninstalled on the
spot; details routes are video-aware, so coming back from the player
lands on the right episode. **On a television** the top of that screen is
a different shape: the title's own artwork fills the panel -- *under* the
overscan band, since the artwork is the one thing here meant to be
cropped -- and over it sit the logo, one line of year, runtime, genres and
rating, and two lines of description, with no poster, because at three
metres the poster was a third of the layout of a picture already on
screen. What darkens the artwork is a gradient scrim over it: never
opacity on the text (dimmed text over a busy frame is unreadable in a way
a dimmed picture behind solid text is not) and never a blur, which the
Chromecast's Mali GPU cannot afford full-screen. No backdrop falls back to
the poster, one that will not load falls back the same way, and neither
leaves the brand ground. metahub names an image's size in its URL, so what
is asked for is the `medium` one rather than Cinemeta's small poster
stretched across the panel, and the decode is bounded to the panel's own
pixels. The logo's box is the same height whether the logo arrives, never
arrives or answers 404 a few seconds later: an image given only a height
holds that height from its first frame, and the name that stands in for
one that failed has to hold it too, or the header and every row under it
jump up under a focus ring somebody is using. A series' episodes are a
**row of cards** there rather than the vertical list, under the season
pills that were already a row: a remote
walks a row with two keys and a list with a hundred. A card carries what
its list row carried -- the still with the episode number on it, the
title, the air date, a check when it has been watched, a badge when it is
kept on the device -- plus a bar saying how far into that episode the
viewer got, which is the library item's own resume point and so appears
on at most one card of a series. Every card is built at once, because
directional focus only considers widgets that have been built and a lazy
row hands the D-pad back halfway through the season; each still is
decoded no larger than the card it is drawn in, which is what that costs
instead. The row scrolls to the selected card, so resuming at episode
nineteen does not start the remote at episode one, and an episode that
has not aired is drawn saying so and takes no press and no focus. The
**sources** are the last two rows rather than a pane down the right: a card
per group -- a resolution rung or an addon, whichever the same
`streamsSectioned` preference already says, never a second setting --
carrying the line a collapsed section header carries on a phone, and under
whichever card is chosen a row of that group's sources. The group row stays
put with the chosen card marked, so another group is a sideways press away
rather than a press back and a press down; the order chips still order
inside one; a press past either end of a row stays in the row, since the
nearest node to the right of the last card is not in the row at all but in
the header three rows up; the last-used shortcut is a card of its own above
them and the place the remote starts, and it appears the first time a title
is played without moving the remote off the card the viewer chose from; and
Back puts the open row away before it leaves the screen, a rung on the same
ladder the player comes down -- while there is a row to put away, which is
a group still carrying the open label rather than the label on its own.
Which group is open is deliberately *not* the phone's
`openStreamSections`: that is a
global set of resolutions kept across restarts, and this is one row at a
time that Back closes -- the same word for two different things. What the
addons did other than answer -- the ones that failed, the ones that had
nothing, and nobody having anything at all -- is the last card of that row,
counting on its own line so a viewer who never chooses it is still told,
and naming them in the row it opens -- a card each, since a joined line
clips at the fourth name and a remote has no press that unfolds one, and
each card takes a press to that addon's own details. The
**player** plays torrents through the
embedded server and HTTP streams directly, with its own controls (seek
bar with the buffered range, play/pause, seek buttons, volume,
fullscreen, keyboard shortcuts, playback speed), embedded and addon
subtitles styled from the profile settings, audio track selection, a
stats OSD, an up-next countdown
that hands off to the next episode, and a pre-playback progress overlay
for torrents that shows the server's start-up phase (checking existing
data, finding peers, buffering the start) with percentages and download
speed instead of a bare spinner, and an open that fails while the torrent
is still resolving, checking or buffering is retried a few times behind
that card rather than failing outright. **Settings → Developer** ships in
release builds: entries that play or download a public Big Buck Bunny
torrent to prove the torrent path without any addon, and **Diagnostics**,
which shows the core's recent log (its own and the embedded server's) and
copies it, redacted, to the clipboard. **Library** lists every added title over the engine's
`LibraryWithFilters` model (type and sort filters, cumulative paging,
long-press to remove, mark watched, rewind or mute notifications), and
the details header has a bookmark to add or remove a title, wearing on a
television the same focus ring everything else there wears rather than
Material's tint. **Downloads**
keeps a torrent stream on the device: the download button on a stream tile
pins the file through the embedded server and becomes a delete button once
the file is whole, so the tile that took a download is the tile that undoes
it -- asking, as the list does, whether the bytes go with the entry. On a
television that button cannot be focused (directional traversal skips a
node inside the focused one's rect, and it is inside the stream tile), so
the tile's long press -- hold select, or the remote's menu key -- does
whatever the button would.
Badges on the episode list and
the details header say what is kept and how far along -- an episode's
badge is the same delete button once its file is whole, while the header's
counts several downloads and stays a count. The Downloads
screen -- from the details app bar, the running player's menu, the
"Downloaded" chip in the Library or Settings, so the list is one tap from
whatever the downloads are of -- lists
everything with its progress, plays a finished one, retries a stopped one,
deletes one with or without its bytes, and says where the files go --
a folder to pick on Android, a path to type elsewhere. Opened from the
player it offers no play of its own: a second player over the running one
would load the same shared `player` field and start an engine beside it. On Android the
app picks that folder itself on a first run: its own external files
directory, which the system leaves alone, rather than the cache it may
reclaim mid-download. On Android a download goes on
after the user leaves the app: a `dataSync` foreground service holds the
process up with an ongoing notification -- how many titles, how far
along, tappable to the Downloads screen, with a Cancel all on it -- for
exactly as long as something is unfinished. A stream whose
video is already kept from another release is offered as a replacement,
and a *finished* one is named in a confirmation first, because taking the
new pin deletes the old file. Downloading a
title also adds it to the library, which is what makes the player record
progress with no network. **Addons**
(from Settings) lists the installed and community addons and installs,
updates, uninstalls or configures one by manifest URL, links out to
[stremio-addons.net](https://stremio-addons.net) and pulls the account's
addons down again on demand. An addon found on the web installs from
inside the app: its site's Install button hands the platform a
`stremio://` link, which Xtremio registers and opens as that addon's
details screen (see [Installing an addon from the
web](DEEP_LINKS.md)).
**Settings** holds
the Stremio account (sign in, create an account, sync, log out), the
engine's own settings (player, subtitles, interface, streaming server)
and the state of the embedded server. The design notes behind phase 3
are in [docs/phase3-design.md](phase3-design.md).

**Android TV / Google TV** is supported as a first-class layout, not as a
phone app on a big screen. At start-up `DeviceProfile.detect()` asks the
`xtremio/device` platform channel what kind of device this is:
`MainActivity` answers `isTv` (`UiModeManager.currentModeType ==
UI_MODE_TYPE_TELEVISION`, or the `android.software.leanback` feature) and
`hasTouch` (`FEATURE_TOUCHSCREEN`); every other platform answers locally
without a channel call, and any error means "a phone". The answer goes
down the tree as a `DeviceScope`, and that is the only thing the TV
layout keys on — which is also how the widget tests put a screen on a
television. When it says television: the shell keeps the rail at every
width and gives each tab its own focus memory, tiles mark focus with a
two-stroke ring (near-black outside, near-white inside, four logical
pixels: one colour cannot read over unknown poster art in a room that is
not dark), a 5 % zoom and a shadow, lift their own caption to full
strength and scroll themselves into view — Settings → Interface →
"Focus highlight" offers Bold, which thickens that ring and dims
everything the remote is not on, for a projector in a bright room — the
D-pad walks rows and columns (a held centre key is a long press, the
context-menu key opens the same menu a long press does), the player takes
the remote's centre and media keys and is immersive-fullscreen the whole
time it is up, posters and text grow (1.15x text, a roomier density,
48 dp targets), every screen holds 5% of every edge clear of overscan
except the video itself and the Details backdrop, and the controls a
remote cannot work (the volume slider, the fullscreen toggle, scrollbar
thumbs) are not drawn.
