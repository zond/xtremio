# Android and Android TV

Building, running and checking Xtremio on Android, and the Android-only
decisions behind it. How the app works is in
[ARCHITECTURE.md](ARCHITECTURE.md); running it anywhere else is in
[OPERATIONS.md](OPERATIONS.md).

## Prerequisites

`nix develop .#android` provides all of these but rustup's targets
([OPERATIONS.md](OPERATIONS.md#with-nix)).

- **Android SDK**: platform 36, build-tools 36.0.0, NDK 28.2.13676358 (the
  versions Flutter 3.47 pins; `android/app/build.gradle.kts` takes them from
  the Flutter Gradle plugin, `minSdk` 24).
- **JDK 21**.
- **Rust via rustup**, with the Android targets added (cargokit adds them on
  first build, but pre-installing keeps that build predictable):

  ```bash
  rustup target add aarch64-linux-android x86_64-linux-android armv7-linux-androideabi
  ```

- **libclang**, for **x86_64 or armv7** builds only. `aws-lc-sys` ships
  pregenerated bindings for aarch64-linux-android only, so the other two
  enable its `bindgen` feature (`rust/Cargo.toml`); `rust/cargokit.yaml`
  forces the `cc` builder for them and the vendored cargokit points bindgen
  at the NDK sysroot (`rust_builder/README.md`). Ubuntu's `libclang-18` is
  found without setting `LIBCLANG_PATH`. arm64-only builds do not need it.

## Building the APK

Redirect to a log and check the real exit code: the first Rust
cross-compile per target takes several minutes. The `make` targets
([OPERATIONS.md](OPERATIONS.md#building-and-running)) stamp the version and
commit the Diagnostics header reads; the plain commands work too.

```bash
make apk-debug                                                     # emulator only (x86_64)
make apk                                                           # release, arm64 only, no bindgen needed
make apk-tv                                                        # release, armeabi-v7a: Chromecast with Google TV
make apk-split                                                     # release, arm + arm64 + x64 APKs
make apk-debug FLAGS="--target-platform android-arm64,android-x64" # phone/64-bit TV + emulator
```

Debug and profile builds are the package `com.zond.xtremio.debug`
("Xtremio debug"), installed beside a release build rather than over it
([DRIVING.md](DRIVING.md#the-second-app)). Debug builds always add x86_64 for the emulator (cargokit mirrors Flutter
here; the vendored copy is patched to stop also adding android-x86, which
Flutter 3.47 cannot package). Output lands in
`build/app/outputs/flutter-apk/`.

**The APK carries only the ABIs requested.** `--target-platform` controls
only what Flutter compiles (`libapp.so`, `libflutter.so`,
`libxtremio_core.so`), never the prebuilt libraries a plugin's AAR ships
(`libmpv.so` and friends, for every ABI). Only AGP's `ndk.abiFilters`
prunes those, and the Flutter plugin's default filter is always all three
ABIs, so `android/app/build.gradle.kts` re-derives `abiFilters` from the
same `-Ptarget-platform` property Flutter reads. An arm64 release is about
55 MB instead of 83. `--split-per-abi` and `-P disable-abi-filtering=true`
are untouched.

### The libmpv the APK carries

`pubspec.yaml` overrides `media_kit_libs_android_video` with the vendored
copy in `third_party/media_kit_libs_android_video`, whose
`android/build.gradle` fetches the **`full`** flavour of the prebuilt libmpv
rather than the `default` media_kit pins. The default's ffmpeg has no
`truehd` or `mlp` decoder while still demuxing TrueHD, so a UHD Blu-ray
remux (TrueHD often its only audio) played silent, saying so only in the
log. `full` is the same libmpv, ffmpeg and NDK revision built with
`--enable-decoders`, 3.4 MiB more per ABI, same licence.

**On any media_kit bump, check the four URLs and MD5 sums in that file**:
upstream goes on pinning the default flavour, and re-vendoring without
looking loses TrueHD with nothing failing. DTS-HD MA was never affected;
Atmos objects fold to the channel bed on every build, since ffmpeg has no
renderer for them.

## Manifest and platform channels

- **`INTERNET`** is declared in the main manifest (Flutter's template adds it
  only for debug and profile).
- **`ACCESS_NETWORK_STATE` is not declared here**, and is in the APK anyway:
  `play-services-cast-framework` and the `datatransport` libraries under it
  add it. Check the merge report
  (`build/app/outputs/logs/manifest-merger-*-report.txt`) rather than
  re-adding the line on seeing the permission on an install.
- **`android:usesCleartextTraffic="true"`** governs only Android's own
  network stack (`dart:io`: posters from plain-http addons). reqwest/rustls
  and libmpv ignore it.
- **No platform certificate verifier.** Every HTTPS client in the process
  (the app's, stream-server's, rqbit's) brings its own roots, so reqwest
  never constructs `rustls-platform-verifier`, and the app ships neither its
  Kotlin half nor the JNI init it needs. That verifier parsed CRLs in Java on
  every handshake, measured at 400 MB of heap per tracker announce on a
  Chromecast. `clippy.toml` in each repo refuses the reqwest constructors
  that would reach it; uninitialised, it would panic.
- **No `HOME` is needed**: every path the server uses comes from the
  directories the app passes it.
- **Leanback.** One build runs on Android TV, Chromecast with Google TV and
  Google TV Streamer, given the right ABI (see
  [Running on a physical device](#running-on-a-physical-device)).
  `android:banner` is a 320x180 PNG at `res/drawable-xhdpi/banner.png`.
- **`stremio://` intent-filter**: `VIEW` + `BROWSABLE` + `DEFAULT` for
  `scheme="stremio"`, no host and no `autoVerify` (the host is the addon's
  domain). `MainActivity` is `singleTop`, so a link arriving while the app
  is up goes to `onNewIntent`. See [DEEP_LINKS.md](DEEP_LINKS.md). To try
  one: `adb shell am start -a android.intent.action.VIEW -d
  "stremio://v3-cinemeta.strem.io/manifest.json"`.
- **Drive pairing app link**: a second, `autoVerify` filter for
  `https://xtremio-xervice.web.app/link`, verified against the service's
  `/.well-known/assetlinks.json`, so a phone with the app opens a
  television's pairing link natively (see
  [ARCHITECTURE.md](ARCHITECTURE.md#google-drive)). Verification is per
  signing certificate: a differently signed build falls back to the browser.
- **Google Cast**: `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, the
  `OPTIONS_PROVIDER_CLASS_NAME` meta-data naming
  `com.felnanuke.google_cast.GoogleCastOptionsProvider`, and Play services'
  `MediaNotificationService`; everything else merges in from
  `flutter_chrome_cast`. `play-services-cast` is named in Gradle so
  `CastDevice` is on the compile classpath for `castDeviceAddress` (below).
- **Channels.**
  - `xtremio/device`: `DeviceProfile.detect()` (`lib/shell/device_profile.dart`)
    asks once, before `runApp`, for `{isTv, hasTouch}` -- `isTv` is
    `UiModeManager` in television mode or the `android.software.leanback`
    feature; any error means "a phone", and no other platform calls it. The
    answer goes down the tree as `DeviceScope`, the only thing the TV layout
    keys on. The channel also carries `os` (the Diagnostics device line),
    `editText`, the frame-rate calls, and `castDeviceAddress` -- the
    receiver's IPv4 address off the MediaRouter route, which
    `flutter_chrome_cast` drops and the server needs to pick an interface
    (see [CASTING.md](CASTING.md)).
  - `xtremio/display`: an event channel pushing the display's refresh rate
    (below).
  - `xtremio/downloads`: the foreground service (below).
  - `xtremio/drive_picker`: `DrivePicker.kt`, Android's own Drive picker.
  - `xtremio/update`: `AppUpdateChannel.kt`, installing a downloaded
    release (below).
- **`REQUEST_INSTALL_PACKAGES`** and the unexported `InstallStatusReceiver`
  are the in-app update's: see
  [Updating from inside the app](#updating-from-inside-the-app).

## Updating from inside the app

The app looks for a newer release on GitHub by itself and offers it in a
dialog: Update, Skip this version, Later. Settings > About > "Check for
updates" asks at any time and says "up to date" too. The code is in
`lib/features/update/`; the Android half is `AppUpdateChannel.kt`.

- **When it looks.** Once a day at most, 20 seconds after start-up, and
  never while a player is on the stack: both the look and the dialog wait
  for the player to close. The time of the last look is written before
  GitHub is asked (`updateCheckedAt` in the preferences), so a failed look
  counts too: the unauthenticated API allows 60 requests an hour per IP,
  shared with everything else on the network. "Check for updates" ignores
  the day.
- **What it compares.** The release tag (`vX.Y.Z`, from
  `releases/latest`, which leaves drafts and pre-releases out) against the
  `XTREMIO_VERSION` the Makefile stamps -- never the version code, which is
  2001 on a phone and 1001 on a television for every release.
- **Which builds look by themselves.** Only a release-mode build with a
  release version stamped and a commit that is not `-dirty`
  (`BuildIdentity.checksByItself`). A `flutter run`, a build from a
  modified tree and every debug or profile build stay quiet. A debug or
  profile build is `com.zond.xtremio.debug`, signed with the debug key, so
  the release APK could never update it: "Check for updates" works there,
  and offers only the release page.
- **Installing.** Update downloads the APK for `Build.SUPPORTED_ABIS[0]`
  (`arm64-v8a` or `armeabi-v7a`; a Chromecast with Google TV reports the
  latter) into the app's own storage, picks up a stopped download where it
  left off, and checks it against the SHA-256 GitHub lists for the asset;
  a mismatch, or no checksum at all, deletes it and installs nothing. The
  install is a `PackageInstaller` session that asks for user action
  outright, so Android's own confirmation is always shown. When it
  succeeds Android closes xtremio; open it again.
- **"Install unknown apps".** Android lets an app install packages only
  with that per-app switch. The dialog explains it and opens the switch
  (`ACTION_MANAGE_UNKNOWN_APP_SOURCES`); where nothing answers that screen
  it says where the setting lives, and Install goes ahead anyway, which
  makes Android ask in place.
- **A different key.** Installs from before v0.1.8 are signed with another
  key; Android refuses the update, and the dialog says to uninstall first
  (which loses the login, settings and downloads). Every release since is
  signed with the same key, and CI checks it.
- **Desktops** get the same look and dialog, with "Open release page"
  instead of Update: nothing replaces itself there.

## Typing with a remote

On Android TV the app window keeps input focus while the on-screen keyboard
is up, because Flutter sets `IME_FLAG_NO_FULLSCREEN` on every field and Dart
cannot unset it -- so the D-pad moves Flutter's focus and the keyboard can
never be driven. So on a television the app hosts no text field at all.
`TvTextField` (`lib/widgets/tv_text_field.dart`) draws the field and, on
select, asks `MainActivity` (`editText`) for `TextEntryActivity`: one plain
`EditText` on a screen of its own. Back cancels; Done returns the text to
`onChanged` and `onSubmitted`. A password is masked, kept out of
personalized learning and autofill, and runs behind `FLAG_SECURE`. A
field's clear button sits *beside* the box on a television, never inside
it. Off a television `TvTextField` is an ordinary `TextField`.

## Telling the television what rate the film is

A 23.976 fps film on a 59.94 Hz output lands on a 3:2 cadence, which is the
picture jumping. So while a film plays the player asks the display for the
film's rate and gives it back when it stops. `DisplayFrameRate`
(`lib/shell/display_frame_rate.dart`) is the Dart half, asked only on a
television, with the container's rate (`PlaybackEngine.videoFrameRate`).
`MainActivity` answers on one of two paths:

- **Android 12 (API 31) and up**: `Surface.setFrameRate` on Flutter's
  surface, `FRAME_RATE_COMPATIBILITY_FIXED_SOURCE` and
  `CHANGE_FRAME_RATE_ALWAYS` (a switch that retrains HDMI and blanks the
  picture for a second is allowed, since every useful one is of that kind).
- **Android 11 and below**: the window's `preferredDisplayModeId`, the mode
  of the current resolution whose rate is the evenest whole multiple of the
  film's (`FrameRateMode.matching`).

On API 31+ the vote can be dropped in silence, so the user's
match-content setting is read first
(`DisplayManager.getMatchContentFrameRateUserPreference`, mapped by
`FrameRateMode.askFor`): **seamless only, or unknown** -- vote, and name the
mode as well (an unset setting is seamless-only, and 59.94 to 23.976 is
never seamless); **always** -- the vote alone; **never** -- nothing at all.

A rate outside 20-120 fps (`FrameRateMode.plausible`) is never asked for:
`container-fps` is computed from track timing, and a broken file can claim
1000 fps. The ask is repeated on resume (the surface, and its vote, is
rebuilt) and when playback runs again after the rate was given back; the
player keeps the rate rather than relying on libmpv's one event.

**Giving it back matters more than asking**, since a system UI left at
24 Hz judders. It is cleared when playback ends or fails, when the player is
left, and in `PlayerScreen.dispose`, on both paths.

## Telling mpv when the screen refreshes

Matching the panel fixes the cadence but not the drops, which are the
decoder's doing: media_kit's `hwdec=auto-safe` can only pick `mediacodec-copy`
in the libmpv it ships, which copies every frame into CPU memory -- on a
Chromecast with Google TV thousands of `vo` drops, frames decoded on time
and presented late. `MediaKitEngine.configurationFor` names
`hwdec=mediacodec,mediacodec-copy` (mpv-android's list): direct first, the
copy as fallback (224 % of a core down to 45 %, and `1 vo / 0 decoder`
drops). The OSD's `hwdec` row is the only reliable check of which one took:
the logcat line does not distinguish them, since the direct decoder logs
the same line the copy mode does.

**No display sync**: `video-sync=display-resample` does not engage on this
VO, and forcing it draws the audio audibly ahead of the picture over
minutes, so `video-sync` stays mpv's default (`audio`). What remains is
**`override-display-fps`** (`MediaKitEngine.displayRateProperties`), because
Android's `gpu-context` answers `VO_NOTIMPL` to every display-rate request
and this is the only way mpv learns the rate at all. It is:

- **measured, not assumed**: `MainActivity` reports `Display.getRefreshRate()`
  on the `xtremio/display` event channel, once on subscription and on every
  `onDisplayChanged`, since a requested rate may not be the one delivered;
- **Android only**: every other VO measures the rate itself, so the gate in
  `displayRateProperties` answers an empty map elsewhere;
- **taken back** (`displayRateOff`, the property set to `0`) on every path
  that gives the rate back.

The stats OSD draws `display 23.976 Hz` between the drop counts and
`hwdec`. The fixed state is `hwdec mediacodec` with a `vo` count that has
stopped climbing. Not in scope unless the drops return: rendering into a
real `Surface` rather than a Flutter texture, which is what the libVLC and
Media3 players of the official app do.

## Where torrent data goes

The root and its rules are in
[ARCHITECTURE.md](ARCHITECTURE.md#where-torrent-data-lives). On Android:

- **The default root** is the app-specific external files directory,
  `/storage/emulated/0/Android/data/com.zond.xtremio/files`, not
  `getCacheDir()`, which the system may reclaim mid-download. It is readable
  over adb without `run-as` (`adb shell ls
  /sdcard/Android/data/com.zond.xtremio/files/media-cache/.pieces`);
  the internal directories (`files/core`, `files/server`) need `run-as`.
- **No permission is involved, and none may be added.** An app's own
  external files directory needs none on `minSdk` 24, and the Server storage
  picker offers `getExternalStorageDirectories()`, the same directory on
  every removable volume. `MANAGE_EXTERNAL_STORAGE` is never the answer.
- **Uninstall and "Clear storage" take the torrent data**, along with the
  registry (`files/core/downloads.json`), so the two stay consistent.

## Downloads while the app is away

Android freezes the process of an app the user has left, and the whole
download stack lives in it. A `dataSync` foreground service keeps it
running; it hosts nothing.

- **The pieces**: `DownloadsService.kt` is the service; `DownloadsChannel.kt`
  is the `xtremio/downloads` channel. Dart calls `start`, `update`, `stop`,
  `requestNotificationPermission` and `takePendingOpen`; the platform calls
  back `open` (notification tapped), `cancelAll` and `timedOut`.
- **When it runs**: `DownloadsForegroundService`
  (`lib/features/downloads/downloads_service.dart`) puts it up while any
  entry is on its way -- not complete, paused, gone or errored (an errored
  entry has no engine behind it) -- and takes it down when none is. It reacts
  to the progress feed and to the client's own removal events; nothing is
  re-read on a timer.
- **The notification**: one ongoing, low-importance notification
  (`xtremio.downloads`, no sound or vibration): `Downloading 3 titles` over
  `1.2 GB of 4.0 GB · 30%`, indeterminate while any download has no length
  yet. Tapping opens the Downloads screen; its one action is **Cancel all**,
  since a pinned file has no pause.
- **Permissions**: `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_DATA_SYNC`,
  and `POST_NOTIFICATIONS` asked at runtime on API 33+ the first time a
  download actually starts, once a run. A refusal costs only the
  notification.
- **What Android still reserves.** The process may be killed under memory
  pressure; Doze may throttle an idle screen-off device; Android 15 gives
  `dataSync` about 6 hours in 24 in the background, then calls `onTimeout`,
  and a service that does not stop within seconds crashes the process. So
  `DownloadsService.onTimeout` tells Dart and stops; the download waits for
  the app to open. Swiping the app from recents stops the service
  (`android:stopWithTask="true"`), since the Flutter engine goes too. In
  every case the pin set and the registry are on disk, and the next launch
  re-pins every unfinished entry.

Checking it on a device (`DownloadsProgressBar` has a JVM test; the rest
needs a device):

```bash
adb shell dumpsys activity services com.zond.xtremio   # the service and its type
adb shell dumpsys notification --noredact | grep -A5 xtremio.downloads
adb shell input keyevent KEYCODE_HOME                  # leave the app mid-download
adb shell dumpsys deviceidle force-idle                # and watch what Doze does
```

## Running on an emulator

The x86_64 `google_apis` image runs on an x86_64 Linux host (the user in the
`kvm` group, `/dev/kvm` accessible):

```bash
export ANDROID_HOME=~/Android/Sdk
export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH

yes | sdkmanager --install "emulator" "system-images;android-36;google_apis;x86_64"
echo no | avdmanager create avd -n xtremio_api36 -k "system-images;android-36;google_apis;x86_64" -d pixel_7

emulator -avd xtremio_api36 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -memory 4096 &
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 5; done

adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.zond.xtremio.debug/com.zond.xtremio.MainActivity
```

For **Android TV**, the same flow with `system-images;android-36;android-tv;x86_64`
and `-d tv_1080p` (AVD `xtremio_tv36`); the same x86_64 debug APK installs.
Use the x86_64 TV image, not the 32-bit `x86` one: Flutter 3.47 cannot
package an x86 APK at all. Check the image answers "television":

```bash
adb shell dumpsys uimode | grep mCurUiMode   # 0x24 → & 0x0f = 4 = UI_MODE_TYPE_TELEVISION
adb shell pm list features | grep leanback   # android.software.leanback
```

The TV AVD also claims a touchscreen, which a real box does not; nothing
keys on `hasTouch`. Under `swiftshader_indirect` libmpv draws no video, so
decoding cannot be checked on an emulator: the position advancing is what
can.

### Driving it with the remote

| Key | Keycode | What the app does with it |
|---|---|---|
| D-pad | `KEYCODE_DPAD_UP` `_DOWN` `_LEFT` `_RIGHT` (19-22) | Moves focus; in the player, seek left/right, controls up/down |
| Centre | `KEYCODE_DPAD_CENTER` (23) | Activates the focused control; on the video, play/pause and wake the controls |
| Centre, held | `input keyevent --longpress 23` | The long press: mark watched, an item's action menu |
| Context menu | `KEYCODE_MENU` (82) | The same menu as the long press |
| Back | `KEYCODE_BACK` (4) | Comes down the ladder; leaves the player |
| Play/pause | `KEYCODE_MEDIA_PLAY_PAUSE` (85), `_PLAY` (126), `_PAUSE` (127) | Play/pause |
| Rewind / fast-forward | `KEYCODE_MEDIA_REWIND` (89), `_FAST_FORWARD` (90) | Seek by the profile's seek step |
| Next / previous | `KEYCODE_MEDIA_NEXT` (87), `_PREVIOUS` (88) | Next episode; previous restarts the current one |

A text field is two steps, and `input text` reaches only the second:

```bash
adb shell input keyevent KEYCODE_DPAD_CENTER  # opens the typing screen
adb shell input text "the%squery"             # %s is a space
adb shell input keyevent KEYCODE_ENTER        # Done: the field submits with it
```

A walk from Discover to playback:

```bash
K() { adb shell input keyevent "$@"; sleep 1; }
K KEYCODE_DPAD_RIGHT   # rail → the types above the rows
K KEYCODE_DPAD_DOWN    # → first poster
K KEYCODE_DPAD_CENTER  # open Details
K KEYCODE_DPAD_DOWN; K KEYCODE_DPAD_CENTER   # pick a stream → player
K KEYCODE_MEDIA_PLAY_PAUSE
adb shell screencap -p /sdcard/tv.png && adb pull /sdcard/tv.png
```

### Checking a run

Every line the app keeps goes to logcat under the tag `xtremio`; crates
logging through `log` keep their own module tags.

```bash
adb logcat -s xtremio
adb logcat -d | grep -E "flutter|xtremio|stream_server|rustls|FATAL"
# The embedded server starting.

# The port is the OS's; read it from logcat:
#   adb logcat -d | grep "embedded stream-server started"   ... url=http://127.0.0.1:<port>/
PORT=<the port from that line>
adb forward tcp:$PORT tcp:$PORT
curl -si http://127.0.0.1:$PORT/heartbeat
# 401 Unauthorized: the control API wants the bearer token only Rust holds,
# and the 401 proves the server is up.
```

Discover showing Cinemeta posters proves HTTPS end to end.

## Running on a physical device

To drive the app from a terminal or an agent rather than by hand, see
[DRIVING.md](DRIVING.md): debug and profile builds are a separate
`com.zond.xtremio.debug` app that installs beside the release one.

**Ask the device which ABI it wants**; do not infer it from the chip:

```bash
adb shell getprop ro.product.cpu.abilist
```

The first entry is the one to build for. A **Chromecast with Google TV**
(`sabrina`, Android 14) answers `armeabi-v7a,armeabi` -- a 64-bit chip with
a 32-bit userspace, which refuses an arm64 APK with
`INSTALL_FAILED_NO_MATCHING_ABIS` -- so it takes **`make apk-tv`**. A phone
or a 64-bit TV box (a list starting `arm64-v8a`) takes `make apk`.

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n com.zond.xtremio/.MainActivity
```

On a TV device the way in is usually ADB over the network: enable ADB
debugging in its developer options, then `adb connect <ip>:5555`.

The frame-rate work is read on a real panel:

```bash
adb shell dumpsys display | grep -E 'mActiveModeId|mBaseDisplayInfo'  # while playing
adb shell settings get secure match_content_frame_rate                # null = the box's default
```

`dumpsys display` should name the film's mode while it plays and the
previous one once it stops; `FrameRateMode` itself has a JVM test
(`./gradlew :app:testDebugUnitTest`).
