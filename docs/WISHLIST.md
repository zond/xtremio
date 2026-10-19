# The long list

Things wanted but deliberately not built, each with what it would take and
why it is not being done now. Not a backlog of chores: what is broken goes
on the known-issues list in stream-server (`docs/known-issues.md`), and
what is merely unfinished goes in the commit that leaves it unfinished.
This is for work that is a *choice* to defer.

Ordered by how likely it is to be picked up, not by size.

## Subtitles on a cast

A viewer picks a subtitle and casts, and the subtitle is silently not there.

The sending half is ready: the Cast plugin takes `tracks` on the media
information, `activeTrackIds` on the load, and has `setActiveTrackIDs` for
a change made mid-cast. What is missing is the subtitle itself, for two
reasons that both mean it has to come from our server rather than from the
addon:

* the Default Media Receiver takes **WebVTT**, and addons serve SubRip,
  often gzipped;
* Google requires **CORS headers** on a side-loaded track, which no
  third-party subtitle host sends.

So the server needs a subtitle route on the LAN media listener. It fetches
the addon's URL (through the machinery that already carries a stream's
credentials), gunzips it, converts SubRip to WebVTT and serves it with the
CORS the listener already has. Then the app builds a track for whatever
the viewer chose and hands it over with the film. That is about a day,
both sides, with tests, and the server half is testable without a device.

Until then the player should *say* that subtitles are not sent, rather
than dropping them without a word.

## Subtitles that are inside the file

About casting only: on the device mpv shows an embedded text track as it
shows any other. A receiver does not render a text track embedded in an
MKV or an MP4 at all, so on a cast it would have to be read out of the
container and served as WebVTT, beside the step above. This is nearer than
it looks. The rendition producer (`rust/src/rendition.rs`) already demuxes
the film on the phone through libavformat. It reads every packet of every
stream, a subtitle track's included, and throws away all but the picture
and the sound. The missing half is keeping the text track's packets as
well, turning them into WebVTT cues and serving those beside the
rendition. A film that goes to the receiver as it is (an MP4, a WebM)
would need the same demuxer run for its subtitles alone.

## Transcoding for a cast

What a cast does today ([CASTING.md](CASTING.md)): H.264 and HEVC in
Matroska or MP4 are repackaged with the picture copied, and any sound the
receiver may not get is converted to stereo AAC. A plain link the receiver
can fetch goes to it straight. What is still refused is a **picture** the
cast cannot carry as it is. That is video a receiver cannot decode at all:
AV1 on most, MPEG-4 Part 2, and H.264 that is not 8-bit 4:2:0 ("Hi10P",
common in anime releases) or HEVC beyond Main 10, which no receiver
decodes. It is also VP9 in a Matroska file that is not a WebM (a copy does
not carry it), a 4K film for a 1080p receiver, and Dolby Vision profile 5. Re-encoding the picture is what would cast those. It
would also give a film with no index exact seek positions on a cast: a
re-encode puts its key frames where it chooses, so each slot's real start
is known before the slot is made, which an estimated layout cannot know
(stream-server `docs/design/renditions.md` §2.8). Wanted,
and deferred because the copy covers what is actually watched.

## Speak to search

Typing a title with a D-pad is the worst part of the television.

**The field half is built.** On a television, Search's field has a
microphone at its right end. It recognizes speech in the app with
Android's `SpeechRecognizer`, shows the words as they are said and
confirms the transcript as a typed entry
([ANDROID.md](ANDROID.md#typing-with-a-remote)). The first build handed
off to `RecognizerIntent`, which a Chromecast with Google TV answers with
its own search and never gives the words back. A phone needs nothing of
ours: its keyboard has a microphone.

What is left is the remote's own search/mic key (`KEYCODE_SEARCH`, or the
Assistant handing over a query through a searchable activity) going
straight into the search screen. Nothing takes it today. Check what a
Google TV remote's mic button actually sends to a foreground app before
building on it, because the Assistant may keep it for itself.

## Continue watching on the Google TV home screen -- measured, closed

The Google TV home screen has a "Continue watching" row that other apps put
their half-watched titles in. xtremio's Continue watching lives only inside
the app, and will stay there.

**Measured 2026-10-07 on zond's Chromecast with Google TV.** A Watch Next
entry published by the app itself (`androidx.tvprovider`,
`TvContractCompat.WatchNextPrograms`, a movie with a poster, a position and
an intent back into the app, the row id answered) never appeared on the home
screen. That is what Google documents. Google TV shows Watch Next rows only
from apps it has certified, the ones under Settings → Accounts & sign-in →
the account → Your services. The certification is for Play-distributed
partners, now moving to the allow-listed Engage SDK, and nothing offers a
path to a sideloaded app. Plex and the others do exactly what the probe
did, and their package is on the list. The probe, its permission and its channel were
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
not built yet). So this works the day an addon lists every volume of a
set as its own stream. The app would gather the siblings from the stream list it already has, by infohash and by the
volume numbering in the names, and hand the server all of them. No URL
guessing: an addon that offers three streams is offering three URLs.

What is missing is an addon that does it. The debrid services unpack RAR
sets themselves, so what they expose is usually the film rather than the
volumes. That is why a good addon answers such a torrent with "not
available" rather than with a list of `.partNN.rar` files, and why the one
that *did* list them was the one misbehaving. **Send one real stream list
that names every volume and this becomes an afternoon.**

## HDR on the device

About playing on the Android TV box or a phone, not about casting. A cast
already keeps HDR10 and HLG ([CASTING.md](CASTING.md#converting-the-picture)).
The receiver decodes the film and switches the television itself.

**Every HDR film is shown as SDR today.** media_kit's Android controller has
mpv draw each frame with `vo=gpu` (OpenGL ES, `gpu-context=android`) into a
Flutter texture. Flutter composites that texture as an 8-bit SDR image.
Android never sees an HDR video layer, so the box never switches HDMI into
HDR and the television shows no badge. mpv tone-maps PQ and HLG down to SDR
first. xtremio sets no HDR property and never asks the display what it
takes.

| Variant | Today | What could support it |
|---|---|---|
| HDR10 | Tone-mapped to SDR | Any of the three paths below |
| HLG | Tone-mapped to SDR | Any of the three paths below |
| HDR10+ | Tone-mapped to SDR, its dynamic metadata ignored | Only a hardware decoder writing to the surface (paths 1 and 3) |
| Dolby Vision 8 | Its base layer, tone-mapped | Dolby Vision on a box with a Dolby Vision decoder (paths 1 and 3). Otherwise its HDR10 or HLG base layer as HDR |
| Dolby Vision 7 | Its HDR10 base layer, tone-mapped | The base layer as HDR10. The full enhancement layer is hard for any Android player |
| Dolby Vision 5 | Wrong colours (green or purple) | Dolby Vision on a box with a decoder. Correct colours in SDR with libplacebo |
| Dolby Vision IQ | Nothing | Nothing for the app to do. The television adapts a Dolby Vision signal to the room |

No variant is allow-listed. Any app may play them through the platform's
decoder. Dolby Vision needs a Dolby Vision decoder on the box
(`video/dolby-vision`), which the manufacturer licenses. Many Google TV
boxes have one.

**The picture has to leave Flutter's texture.** Every variant needs this
one change. Android switches the output to HDR only when its compositor gets
a video layer marked as HDR. A texture drawn into Flutter's own frame can
never be one. The video has to be its own `SurfaceView`, shown under
Flutter's UI as a platform view. The controls and the subtitles are Flutter
widgets already, so they are drawn over it as they are today. mpv decodes
and times the subtitles, and media_kit's `SubtitleView` draws their text
(`PlaybackEngine.buildVideo`). There are three ways to fill that surface:

1. **mpv's `mediacodec_embed`.** It is compiled into the shipped libmpv.
   MediaCodec decodes straight into the surface and carries HDR10's static
   metadata, HDR10+'s dynamic metadata and Dolby Vision on a box that
   decodes it. mpv then draws nothing, so its scaling and colour handling
   are gone, and the box's hardware scaler does that work instead. The
   subtitles are unaffected, since mpv still hands their text to Flutter.
   A codec the box cannot decode in hardware has no picture on this path,
   so such a film keeps today's path.
2. **mpv's own drawing into an HDR surface.** Keep `vo=gpu`, hand it a
   `SurfaceView` whose EGL surface is 10-bit BT.2020 PQ or HLG, and point
   mpv at that target (`target-trc`, `target-prim`). It keeps mpv's
   scaling and colour handling, and software-decoded films keep a picture.
   It covers HDR10 and HLG only:
   HDR10's static metadata has to be set on the surface by hand, and
   neither HDR10+ nor Dolby Vision survives mpv's renderer. Nobody has
   tried whether mpv 0.36's OpenGL ES path does this on Android.
3. **A second player for HDR films** (Media3 ExoPlayer). This is the
   standard Android path. It does every variant, and audio passthrough too.
   But it is a whole second player beside mpv. It has no `xtremio://`
   protocol, so it would read the server's media route. Its subtitle cues
   would have to reach Flutter's `SubtitleView` another way, and it reports
   its own stats. Everything the player screen asks
   of `PlaybackEngine` would be answered twice.

**Only hybrid composition keeps the surface real.** Flutter shows an
Android view in one of three ways
([Flutter's platform views](https://docs.flutter.dev/platform-integration/android/platform-views)):

- Hybrid composition (`PlatformViewsService.initExpensiveAndroidView`)
  leaves the view in the real view hierarchy, with "SurfaceView support".
  Android composites the `SurfaceView` itself, so HDR can reach the
  display.
- Texture layer hybrid composition and virtual display copy the view into
  a texture. That loses HDR as any texture does. A `SurfaceView` in a
  virtual display also renders too dark on some Samsung phones
  ([flutter#141207](https://github.com/flutter/flutter/issues/141207)).
- Hybrid Composition++ hands both to Android's compositor and avoids the
  costs below. It is experimental and needs Android 14 and Impeller on
  Vulkan, which most Google TV boxes do not have.

Hybrid composition has a cost. Flutter merges its raster thread into the
platform thread while such a view is up, which lowers the frame rate of
the Flutter UI drawn over it. Before Android 10 it also copies every
Flutter frame through main memory. On a weak box that cost lands on the
player's controls. So the view should exist only while a film plays.
A hybrid `SurfaceView` has also been drawn above the app bar inside a list
([flutter#113601](https://github.com/flutter/flutter/issues/113601)). A
full-screen player avoids that case, but the controls must be checked to
stay on top.

**media_kit has no platform-view mode.** Its Android controller always
makes a texture surface and hands it to mpv (`wid`). Paths 1 and 2 need
that surface to be a `SurfaceView`'s instead. That means our own platform
view, as a fork of media_kit_video's Android controller or a small plugin
of our own. The rest of media_kit stays: the player, the properties and
`xtremio://`.

**Flutter itself stays SDR, and that is fine.** Flutter has no HDR and no
wide gamut on Android. Impeller's wide gamut exists only on iOS, and
nobody is working on it for Vulkan
([flutter#127852](https://github.com/flutter/flutter/issues/127852)). The
controls and subtitles are SDR graphics over an HDR video layer, which is
how Android expects it.

**Others have done this.** The evidence that a hybrid `SurfaceView` under
Flutter delivers HDR comes from apps, not from Flutter's own docs:

- [m3u-tv](https://github.com/m3ue/m3u-tv/issues/221), a Flutter Android TV
  app, moved full-screen playback from a Flutter texture to a Media3
  `SurfaceView` in hybrid composition (October 2026). HDR output works
  there, and it matches the frame rate as this app does.
- [DreamPlayer](https://github.com/mangeshghodke/DreamPlayer), a Flutter
  player for Android TV, does the same with Media3 for HDR10+ and Dolby
  Vision. It also runs libmpv in its own `SurfaceView` through hybrid
  composition, never a texture. That shows mpv renders into such a surface.
  It does not show that mpv's own drawing gets HDR to the display.
- [`video_player_hdr`](https://pub.dev/packages/video_player_hdr), a fork
  of Flutter's `video_player`, offers a platform view instead of a texture
  for HDR, and asks the display what it supports.
- media_kit's own tracker agrees from the other side. A contributor wrote:
  "Flutter textures don't have HDR capability on any platform"
  ([media-kit#615](https://github.com/media-kit/media-kit/issues/615)).
  One reporter with no HDR on an NVIDIA Shield switched to Media3 in a
  platform view
  ([media-kit#1243](https://github.com/media-kit/media-kit/issues/1243)).
  Another saw HDR10 distorted with hardware decoding and fine without it
  ([media-kit#1207](https://github.com/media-kit/media-kit/issues/1207)).
  That one is worth checking here, since this app asks for
  `mediacodec,mediacodec-copy`.

Any of the three also needs these:

- Ask the display what it takes (`Display.getHdrCapabilities()`, and per
  mode from API 34). Send HDR only to a television that takes it, and
  tone-map as today otherwise.
- Make the frame-rate switch (`FrameRateMode`) follow onto the new surface.
- Look at Flutter's controls over an HDR layer on a real panel. Android
  dims graphics to SDR white there.

**libplacebo (`vo=gpu-next`) is the other half, and gives no HDR by itself.**
It is mpv's newer renderer. It would improve what is shown in SDR:

- Tone mapping gets better curves and per-scene peak detection.
- Dolby Vision's per-scene data (the RPU, which FFmpeg 6 exposes) is
  applied. Profile 5 gets correct colours, and profiles 7 and 8 use their
  scene data.
- HDR10+'s dynamic metadata steers the tone mapping.

It still draws into the same texture, so the television still does not
switch. Its `--target-colorspace-hint` tells the window system that the
output is HDR, and mpv 0.41 turns it on by default. The release notes name
HDR output on DRM, Wayland and macOS, never on Android. Together with path 2
it would be the best path that stays inside mpv.

**libplacebo comes with any newer mpv, so it costs a libmpv build of our
own.** Every libmpv media_kit ships is mpv 0.36 with libplacebo off
(`-Dlibplacebo=disabled`). That holds for Android's
libmpv-android-video-build (the `full` flavour vendored in
`third_party/media_kit_libs_android_video`) and for macOS's
libmpv-darwin-build, whose newest release (September 2026) still locks
0.36.0. Windows's libmpv-win32-video-build has been archived since 2024.
So `vo=gpu-next` exists in none of them.

mpv itself has moved on: 0.41.0 came out in December 2025, and `gpu-next`
is its default renderer. Since 0.37, mpv does not build without
libplacebo, and since 0.39 it needs FFmpeg 6.1. The bundled builds have
6.0. So libplacebo is not a separate choice for HDR. It is the price of any
newer mpv, including what a newer mpv would bring besides HDR: the
`dolby-vision-profile` track property (0.39), `ao_audiotrack`'s passthrough
fixes (0.38) and AAudio output on Android (0.41).

A media_kit bump will not bring that mpv, because media_kit's builds are
not moving. The cost is owning a libmpv build for each platform for as long
as the app exists: mpv, libplacebo and FFmpeg 6.1 or newer, for four
Android ABIs and the desktops. Today an update is checking four URLs and
MD5 sums ([ANDROID.md](ANDROID.md#the-libmpv-the-apk-carries)). After it,
it is a build pipeline we own. media_kit's Dart side stays written against
mpv 0.36, so every mpv upgrade also means checking mpv's client API changes
(`DOCS/client-api-changes.rst`) against media_kit and the patch in
`third_party/media_kit`.

**libplacebo also costs GPU work.** Its renderer is heavier than `vo=gpu`,
most of all with per-scene peak detection, which runs a compute pass on
every frame. The boxes this app targets are where that bites. A Chromecast
with Google TV has a low-end Mali GPU, and 4K60 with tone mapping may drop
frames there. Measure on the weakest box before choosing it, with peak
detection off as the fallback. Once the library has it, the switch on
Android is one line: `VideoControllerConfiguration.vo`, which media_kit
defaults to `gpu` there. The desktops are not that simple. media_kit draws
there through mpv's render API (`vo=libmpv`), where the renderer is not a
`vo` setting. Nobody has checked whether that API can use libplacebo, so the
same picture on every platform may not be reachable through media_kit.

**Not built because each path costs a part of the player that works
today.** Path 1 costs mpv's own drawing of the picture, path 3 costs having
one player, and libplacebo costs the prebuilt libmpv. Nobody has measured a box to choose
between them. The first experiment is cheap: play an HDR10 film through
`mediacodec_embed` on a `SurfaceView` and see whether the television
switches.

## Audio a receiver cannot have

About playing on the device into an AV receiver (an amplifier), not about
casting. Dolby Atmos objects fold to the channel bed on every build there
is, because ffmpeg has no renderer for them. There is nothing to do until
it has one. TrueHD *passthrough* is a different matter: the shipped libmpv
has `ad_spdif` and `spdif-truehd` compiled in, so `--audio-spdif=truehd`
could bitstream to a capable receiver. It is worth one experiment on the
device. It helps only viewers with an AVR that takes it.

## Recommendations for the viewer -- chosen, built, one path deferred

What was wanted: a row that knows what this viewer likes, not only what one
title is like. What was built is the For you row
([ARCHITECTURE.md](ARCHITECTURE.md#for-you)). Its sources are the viewer's
own library: what they watched through, what they added, what they liked.
Each source's "More like this" answer gives the candidates, a weighted
vote runs across them, and the catalogue check every suggestion already
goes through applies. It was chosen because every part of it already
existed and was already paid for. The answers are the ones the server
keeps per title for everybody, so the row costs no new model calls and no
key on the device. It is worked out on the device from data the device
already holds. The only thing the viewer's taste adds to the service is a
set of title ids under their account (the faces), which they can delete.

**Considered and deferred: collaborative filtering over MovieLens.** The
MovieLens ratings (tens of millions of ratings by real people) would give
"people who liked these also liked". That is a different and in places
better signal than a model's "feels like". But it is a model to train and
host, a dataset licence that is research-only for the large sets, a
mapping from MovieLens ids to IMDb ids that loses titles, and nothing
newer than the last dump. The vote over per-title answers gives most of
the row for none of that. It is worth picking up if the row turns out to
narrow too fast onto a few titles. A per-title answer cannot correct that,
and a co-rating model can. The faces it would need as input are already
collected.

## Closed, and staying closed

* **iOS.** No forks are carried for it.
  [OPERATIONS.md](OPERATIONS.md#building-for-ios) has the two proven
  changes, and the CI job is red by design.
* **Browser clients.** Closed by zond.
* **Drive as an addon.** Closed by zond (2026-10-05): the app's own Drive
  support (remote files read by range, linked once, offline downloads) is
  better than anything an addon seam would give it.
* **A discover-only torrent state** (finding peers and metadata for a
  source before it is picked). Closed by zond (2026-10-05): people scroll
  around among sources before selecting one, and starting and stopping
  torrents for that pollutes the swarm and our own compute and memory. A
  torrent is on only because something explicit holds it: a player screen,
  a cast, a download.
