# Android

This is the detailed reference for building, running and verifying Xtremio on
Android. The high-level architecture (`stremio-core` + embedded
`stream-server` + `media_kit`/libmpv) is described in the main
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); this file is Android-only.

## Prerequisites

- **Android SDK**: platform 36, build-tools 36.0.0, NDK 28.2.13676358 (the
  versions Flutter 3.47 pins — `android/app/build.gradle.kts` takes them from
  the Flutter Gradle plugin, `minSdk` 24).
- **JDK 21**.
- **Rust via rustup**, with the Android targets pre-added (cargokit will run
  `rustup target add` itself on first build, but pre-installing keeps that
  first Gradle run predictable and avoids a network fetch mid-build):

  ```bash
  rustup target add aarch64-linux-android x86_64-linux-android armv7-linux-androideabi
  ```

- **`cargo` on the PATH** of whoever runs Gradle — `build.gradle.kts` shells
  out to `cargo metadata` to locate the Kotlin half of
  `rustls-platform-verifier` (an AAR shipped inside the Rust crate).
- **libclang**, for **x86_64 or armv7** builds only. `aws-lc-sys` ships
  pregenerated bindings for aarch64-linux-android only, so those two targets
  enable its `bindgen` feature (see `rust/Cargo.toml`); `rust/cargokit.yaml`
  forces the `cc` builder for them and the vendored cargokit is patched to
  point bindgen at the NDK sysroot (`rust_builder/README.md`). Verified with
  Ubuntu's `libclang-18`, found without setting `LIBCLANG_PATH`; set that
  variable only if clang-sys can't locate `libclang*.so` on your host.
  arm64-only release builds don't need this.

## Building the APK

Always redirect to a log and check the real exit code — the first Rust
cross-compile per target takes several minutes.

```bash
make apk-debug                                                           # emulator only (x86_64)
make apk                                                                 # release, arm64 only, no bindgen needed
make apk-tv                                                              # release, armeabi-v7a: Chromecast with Google TV
make apk-split                                                           # release, arm + arm64 + x64 APKs
make apk-debug FLAGS="--target-platform android-arm64,android-x64"       # phone/64-bit TV + emulator
```

`make apk-tv` is not `make apk` with a different flag by accident: see
"Running on a physical device" for which box wants which ABI. It is an armv7
build, so it is one of the two that need libclang.

Those are the `flutter build apk` lines below plus the two `--dart-define`s
that put a version and a commit in the Diagnostics header (see the Makefile,
and `docs/OPERATIONS.md`, "Diagnostics off a device"); a build without them
reports `app: unknown`, which is the one line saying which build a report is
about.
The plain commands, for anything the Makefile does not cover:

```bash
flutter build apk --debug --target-platform android-x64                  # emulator only
flutter build apk --debug --target-platform android-arm64,android-x64    # phone/64-bit TV + emulator
flutter build apk --release --target-platform android-arm64              # arm64 only, no bindgen needed
flutter build apk --release --target-platform android-arm                # armeabi-v7a only
flutter build apk --release --split-per-abi                              # arm, arm64, x64 APKs
```

Debug builds always add x86_64 for the emulator regardless of
`--target-platform` (cargokit mirrors Flutter's rule here; the vendored copy
is patched to stop also adding the dropped android-x86 ABI, which Flutter
3.47 can no longer package — see `rust_builder/README.md`). Output lands at
`build/app/outputs/flutter-apk/app-debug.apk` (or `app-release.apk`).

**The APK carries only the ABI(s) actually requested.** `--target-platform`
by itself only controls what *Flutter* compiles and copies in — `libapp.so`,
`libflutter.so`, and `libxtremio_core.so` via cargokit — never the prebuilt
native libraries a plugin's AAR ships. `media_kit_libs_android_video` bundles
`libmpv.so`, `libdartjni.so` and `libmediakitandroidhelper.so` for every ABI
regardless of what was requested, and only AGP's `ndk.abiFilters` packaging
filter prunes those. The Flutter Gradle plugin does set a default
`abiFilters` itself, but always to all three ABIs it supports — that default
exists only to keep 32-bit x86 out for Google Play, not to track
`--target-platform` — so before this was fixed, a `--target-platform
android-arm64` release build still shipped `armeabi-v7a` and `x86_64` copies
of every plugin's libraries: an 83.1 MB APK for a build targeting one ABI,
about 28 MB of it libraries for ABIs never asked for (verified with
`unzip -l` — our own `libxtremio_core.so` was already correctly single-ABI).
`android/app/build.gradle.kts` now re-derives `defaultConfig.ndk.abiFilters`
from the same `-Ptarget-platform` Gradle property Flutter's own plugin reads,
so the filter always matches what was actually requested:

| Build | APK size | ABI dirs in the APK |
|---|---|---|
| `--target-platform android-arm64` (before the fix) | 83.1 MB | `arm64-v8a`, `armeabi-v7a`, `x86_64` |
| `--target-platform android-arm64` (after) | 54.7 MB | `arm64-v8a` only |
| `--target-platform android-x64` (after) | 61.6 MB | `x86_64` only |
| no `--target-platform` (after) | 157.4 MB | all three, unchanged — Flutter's own default (arm, arm64, x64) is left alone |

`--split-per-abi` is untouched by this (AGP's own ABI splits already produce
one single-ABI APK per split), and so is `-P disable-abi-filtering=true`, the
existing Flutter escape hatch out of ABI filtering entirely.

## Manifest and network decisions, and why

- **`INTERNET` permission** is declared in the main manifest. Flutter's
  template only adds it for debug/profile builds; addon catalogs and posters
  need it in release too.
- **`android:usesCleartextTraffic="true"`** is set on the application. This
  flag only governs Android's own network stack (`dart:io` — `Image.network`
  posters from self-hosted `http://` addons; the Flutter side itself makes
  no HTTP calls to the embedded server, its control calls are FFI). It does
  **not** affect the Rust side: reqwest/rustls sockets and libmpv's own
  networking ignore Android's cleartext policy either way. It's needed
  because some addons are plain-http, and it keeps the embedded
  `stream-server`'s `http://127.0.0.1:<port>` media URLs open to anything
  on the Dart side that might load one.
- **`rustls-platform-verifier` JNI hook.** On Android, reqwest's rustls
  verifies TLS certificates through `rustls-platform-verifier`, which needs
  the Android `Context` once before any HTTPS request. `MainActivity.onCreate`
  calls `NativeInit.initTlsVerifier(applicationContext)` (JNI, implemented in
  `rust/src/android.rs`) before the Flutter engine starts, and both the
  stremio-core `Env` and the embedded stream-server share that global
  initialization. Its Kotlin component ships as an AAR inside the Rust crate;
  Gradle locates it via `cargo metadata`, and
  `android/app/proguard-rules.pro` keeps it from being stripped by R8 in
  release builds.
- **No `HOME` needed by the embedded server.** Android app processes start
  with no `HOME` environment variable, and `dirs`/`directories` have no
  passwd fallback there. Nothing on `stream-server`'s startup path fails
  without it: every effective path comes from the directories the app
  passes in `ServerConfig` (`RustCoreClient.init(support, cache)` →
  `<files>/server` for settings and logs, `<cache>/server` for the torrent
  session, its DHT routing-table dump `dht.json` and the piece cache). The
  environment is at most consulted for defaults those directories override
  (a `HOME` fallback in the settings defaults, `dirs::cache_dir` in the
  update manager), and a missing one is not an error.
- **Leanback entries** for Android TV / Google TV are already in
  `AndroidManifest.xml` (one build runs on Android TV boxes, Chromecast with
  Google TV and the Google TV Streamer alike — they're all just Android —
  as long as its ABI is one the box has; they do not agree on that, see
  "Running on a physical device").
  `android:banner` is the tile the TV home screen shows, a 320x180 xhdpi
  PNG at `res/drawable-xhdpi/banner.png` (the launcher icon is the wrong
  shape for it).
- **`stremio://` intent-filter.** A second `intent-filter` on
  `MainActivity` takes `VIEW` with `BROWSABLE` and `DEFAULT` for
  `<data android:scheme="stremio"/>`. That is how an addon site's Install
  button reaches the app: it swaps the scheme on the addon's own manifest
  URL, so `https://host/manifest.json` is opened as
  `stremio://host/manifest.json` and Xtremio shows that addon's details
  screen (nothing is installed without a press — see
  [docs/DEEP_LINKS.md](docs/DEEP_LINKS.md)). No `android:host` and no
  `android:autoVerify`: the host is the *addon's* domain, so there is no
  domain this app could claim, and App Links verification (which serves
  `assetlinks.json` from the claimed domain) is impossible by
  construction. `MainActivity` was already
  `android:launchMode="singleTop"`, which is what makes a link
  arriving while the app is up go to the running instance's `onNewIntent`
  instead of starting a second one. To try it on a device or emulator:

  ```bash
  adb shell am start -a android.intent.action.VIEW \
    -d "stremio://v3-cinemeta.strem.io/manifest.json"
  ```
- **Google Cast entries.** Three, all in the `<application>` block, and no
  Gradle changes at all — everything else the Cast SDK needs (mediarouter,
  `play-services-cast-framework`, its own `MediaIntentReceiver` and
  `ReconnectionService`, the plain `FOREGROUND_SERVICE` permission) merges in
  from `flutter_chrome_cast`'s own manifest:
  - `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, without which the SDK's media
    notification cannot run as a foreground service on API 34+.
  - the `com.google.android.gms.cast.framework.OPTIONS_PROVIDER_CLASS_NAME`
    meta-data naming `com.felnanuke.google_cast.GoogleCastOptionsProvider`.
    The SDK instantiates that class by name before any app code runs, so it
    has to be in the manifest and cannot be passed in; the plugin fills its
    options in from what Dart hands
    `GoogleCastContext.setSharedInstanceWithOptions`.
  - `com.google.android.gms.cast.framework.media.MediaNotificationService`,
    which lives in Play services; declaring it is what lets the SDK start it.

  `MainActivity` is **unchanged**: the app drives sessions through the
  session manager rather than the SDK's own `MediaRouteButton` dialog, so
  there is no AppCompat host requirement. (`flutter_chrome_cast`'s own
  example uses a plain `FlutterActivity` too.) The merge was verified with
  `./gradlew :app:processReleaseManifest`; casting itself was not — there is
  no Chromecast on this machine.
- **`xtremio/device` channel.** `DeviceProfile.detect()`
  (`lib/shell/device_profile.dart`) runs once in `main()` before `runApp`
  and asks `MainActivity` for `{isTv, hasTouch}`: `isTv` is
  `UiModeManager.currentModeType == UI_MODE_TYPE_TELEVISION` or the
  `android.software.leanback` feature, `hasTouch` is `FEATURE_TOUCHSCREEN`.
  The answer goes down the widget tree as `DeviceScope`, which is what the
  remote-driven layout keys on. Any error on the channel means "a phone";
  no other platform calls it (desktop is never a TV).

## Typing with a remote

On Android TV the app window keeps input focus while the on-screen keyboard is
up, so every D-pad press is delivered to Flutter and moves Flutter's focus:
the keyboard can never move its own selection, which makes it decorative and
sign-in impossible. The cause is `IME_FLAG_NO_FULLSCREEN`, which Flutter sets
on every field it creates and which Dart cannot unset -- fullscreen
("extract") mode is precisely the mode in which the keyboard takes window
focus and owns the remote. So on a television the app hosts no text field at
all. `TvTextField` (`lib/widgets/tv_text_field.dart`) draws the field's
decoration around its current value and, on select, asks `MainActivity` over
the `xtremio/device` channel for `TextEntryActivity` -- one plain `EditText`
on a screen of its own, carrying none of those flags -- then takes back the
string. Back cancels and nothing moves; Done returns the text, which is
delivered to the field's `onChanged` and `onSubmitted` because confirming
there is the remote's way of pressing Done. A password is masked, asks the
keyboard to learn nothing from it (`IME_FLAG_NO_PERSONALIZED_LEARNING`), is
kept out of autofill and runs behind `FLAG_SECURE`. Off a television
`TvTextField` is the ordinary Flutter `TextField` every one of those places
always had.

A field that can be emptied takes an `onClear`, and the button that does it
is the field's own, never part of the decoration: off a television it is the
`suffixIcon` inside the box, as it has always been, and on one it sits
*beside* the box. Inside, a remote could neither reach it (the field takes
focus as a whole, so there is nothing to the right of the text to step to)
nor press it (`RemotePress` is above every descendant and takes select for
the typing screen), which is a button drawn where the remote cannot go.

## Telling the television what rate the film is

A 23.98 fps film presented on a 59.94 Hz output lands on a 3:2 cadence:
some frames shown twice and some three times, which is what the owner sees
as the picture "jumping really strangely", and the frames that miss their
vsync are dropped. On his Chromecast with Google TV driving an Acer 1080p
projector that read `dropped 560 vo / 0 decoder` — every drop at the video
output, none at the decoder, on a stream with 125 seconds buffered. The
panel was on `mActiveModeId=1074` (59.94 Hz) while its own list offered
1920x1080 at 23.976 (1082) and at 24.0 (1083), because nothing here had
ever asked for a rate.

So while a film is playing the player asks for one, and gives it back when
it stops. `DisplayFrameRate` (`lib/shell/display_frame_rate.dart`) is the
Dart half, on the `xtremio/device` channel; the rate is the container's,
observed off libmpv (`PlaybackEngine.videoFrameRate`), and it is asked for
only on a television — a phone's panel has no business switching, and no
other platform has the API. `MainActivity` answers with one of two paths:

- **Android 12 (API 31) and up**: `Surface.setFrameRate` on Flutter's own
  surface, with `FRAME_RATE_COMPATIBILITY_FIXED_SOURCE` (what the content
  *is*, leaving the mode to the platform) and `CHANGE_FRAME_RATE_ALWAYS`
  (a change the panel cannot make invisibly is allowed — 59.94 Hz to
  23.976 Hz retrains the HDMI link and blanks the picture for about a
  second, and every useful switch on a television is of that kind). The
  device's own **Match content frame rate** setting can still refuse a
  non-seamless switch; that is the viewer's call, and if a box is set to
  "Seamless only" nothing here can or should override it.
- **Android 11 (API 30) and below**: the window's `preferredDisplayModeId`,
  naming a mode outright. `FrameRateMode.matching` picks which — the mode
  of the current resolution whose refresh rate is the evenest whole
  multiple of the content's. API 30 does have a two-argument
  `setFrameRate`, but it predates `CHANGE_FRAME_RATE_ALWAYS` and so only
  ever switches seamlessly, which is the switch a television cannot do, so
  it takes the mode path with everything older.

**The ask is made again whenever it can have lapsed.** It is not once per
file: on API 31+ it is a vote on the surface Flutter draws into, and that
surface is destroyed when the app goes to the background and rebuilt on
the way back, taking the vote with it — so the player asks again on
resume. It also asks again when playback runs after the rate was given
back, which is the viewer rewinding into a film that had ended. libmpv
reports `container-fps` once per value and never repeats it, so a rate
kept only in that event is a rate lost for the rest of the playback;
`PlayerScreen` writes it down instead. Repeating an ask the panel is
already honouring costs nothing — there is no mode to change and no
picture to blank.

**Giving it back matters more than asking.** A display left at 24 Hz makes
the whole system UI judder, which is a worse fault than the one being
fixed. It is cleared when playback ends, when playback fails (the failure
card keeps this screen up, so nothing else would), when the player is
left, and in `PlayerScreen.dispose` — which is the one that covers every
other way out, since no route leaves this screen without disposing it. Both platform
paths are cleared whichever of them set one. What is *not* handled here is
the app being killed outright: a surface vote dies with the surface and a
window attribute with the window, so there is nothing left behind.

**Verifying it on a device.** `FrameRateMode` is the piece with no Android
in it and has a JVM test (`./gradlew :app:testDebugUnitTest`); the surface,
the window and the display need a real panel:

```bash
adb shell dumpsys display | grep -E 'mActiveModeId|mBaseDisplayInfo'  # while playing
adb shell settings get secure match_content_frame_rate                # null = the box's default
```

The proof is a reading rather than a test: the stats OSD's dropped count
should barely move on the file that dropped 560, and `dumpsys display`
should name the 23.976 mode while that film is on screen and the 59.94 one
again once it is not.

## Where offline downloads go, and when they run

- **The destination is set by the app, once.** The embedded server's own
  default keeps a pinned torrent in its cache root — on Android that is
  `getApplicationCacheDirectory()` (`/data/data/com.zond.xtremio/cache`),
  which the system is free to reclaim whenever it wants space. Half a film
  reclaimed mid-download is not a download, so start-up points the server
  at the app-specific external files directory instead
  (`applyDefaultDestination`, `lib/features/downloads/destination.dart`,
  called from `XtremioApp.initState`) through the `downloads_set_dir` FFI
  call — `POST /settings`'s `downloadsDir`, with its validation.

  ```
  /storage/emulated/0/Android/data/com.zond.xtremio/files/downloads/<infoHash>/<file>
  ```

  `adb shell run-as com.zond.xtremio ls …` is not needed for it: the
  external files directory is world-readable over adb
  (`adb shell ls /sdcard/Android/data/com.zond.xtremio/files/downloads`).

  *Once* means once ever, not once per launch: the registry records both
  that the question was answered and which answer it was
  (`destinationSettled` and `destinationChoice` in
  `<files>/core/downloads.json`, written by `downloads_set_dir`), and
  start-up reads those rather than "is `downloadsDir` null?". Null is an
  answer too — it is what the Downloads screen writes for "Default (with
  the cache)" — and it is not quietly replaced on the next launch.

  The two are not the same null, which is why the path is recorded and not
  just the flag. The server clears a `downloadsDir` it cannot prepare at
  boot (an SD card that is not in the device) and persists the null, and
  on Android the fallback that leaves is `getApplicationCacheDirectory()`
  — the purgeable directory this whole section exists to stay out of. So
  a recorded path that the settings no longer have is read as the server
  having dropped it: start-up asks for that path again, and if the volume
  is really gone it applies the external files directory instead. Never
  the cache. An install upgraded from a build before `destinationChoice`
  has no path on record; if its destination was cleared it reads as
  "Default (with the cache)" and has to be re-picked on the Downloads
  screen.
- **No permission is involved.** An app's own external files directory
  needs none on `minSdk` 24 (`getExternalFilesDir`, which is what
  path_provider's `getExternalStorageDirectory()` returns), and it must
  stay that way: the manifest declares no storage permission, and
  `MANAGE_EXTERNAL_STORAGE` is never the answer. The Downloads screen's
  picker offers `getExternalStorageDirectories()`, which is the same
  directory on every removable volume — an SD card among them — so a
  chosen destination is still permission-free.
- **Uninstall takes the downloads with it**, as it does for anything in the
  app's own directories, and the system does *not* purge them the way it
  may purge `getCacheDir()`. "Clear storage" in the app info screen does
  delete them; the registry (`<files>/core/downloads.json`) goes at the
  same time, so the two stay consistent.
- **A download keeps going after the user leaves the app**, held up by a
  foreground service; see "Downloads while the app is away" below for what
  that does and does not promise. Nothing is lost when the process does go:
  librqbit persists the torrent and its verified pieces, the server
  persists its pin set, and start-up re-pins every unfinished registry
  entry, so reopening the app continues where it stopped. A *finished*
  download needs nothing running at all — it is played straight off the
  file.
- **Moving the destination moves nothing that is already there.** The
  server relocates a torrent only when it is pinned again, which for an
  unfinished download happens at the next start-up. Files a finished
  download left behind stay where they were downloaded; the registry keeps
  naming that path.

## Downloads while the app is away

Android freezes the process of an app the user has left, and the whole
download stack — the embedded `stream-server` and librqbit — lives in the
Flutter process. A `dataSync` foreground service is how an app asks to keep
running; it hosts nothing, and nothing moved process for it.

**What is on the device side.** `DownloadsService.kt` is the service,
`DownloadsChannel.kt` the `xtremio/downloads` method channel `MainActivity`
installs beside `xtremio/device` (a separate concern: that one is asked
once, at start-up, what kind of device this is). Dart calls `start`,
`update`, `stop`, `requestNotificationPermission` and `takePendingOpen`;
the platform calls back `open` (the notification was tapped) and
`cancelAll` (its action was pressed), because the registry is behind the
FFI and only Dart can act on either.

**What decides when it runs.** `DownloadsForegroundService`
(`lib/features/downloads/downloads_service.dart`), from the one
`DownloadsClient` the app holds: the service goes up as soon as one entry
is unfinished (neither complete nor paused, the same test
`Entry::unfinished` makes in `rust/src/downloads.rs`) and comes down the
moment none is. Playing or seeding is not a reason to hold it. The progress
feed only carries rows that *moved*, so a row for a key no listing has
mentioned is read as "something was added" and answered with a fresh
listing, and a removal — which has no event at all — is caught by
re-reading the listing every 5 s while the service is up. At rest neither
costs anything.

**The notification.** One ongoing notification on a low-importance channel
(`xtremio.downloads`, `IMPORTANCE_LOW`, no sound, no vibration, no badge),
so it never buzzes: `Downloading 3 titles` over `1.2 GB of 4.0 GB · 30%`,
with a progress bar — indeterminate while any one of the downloads still
has no length (a magnet resolving), since a percentage of only the entries
that know theirs would be a percentage of the wrong number. Tapping the
body opens the app on the Downloads screen. Its one action is **Cancel
all**, which drops every unfinished entry with its part-file: there is no
pause for a pinned file in the registry today, and inventing one on a
notification would be a promise the server cannot keep.

**The permissions.** `FOREGROUND_SERVICE` and
`FOREGROUND_SERVICE_DATA_SYNC` in the manifest, the service declared with
`android:foregroundServiceType="dataSync"`, and `POST_NOTIFICATIONS` asked
for at runtime on API 33+ — the first time a download actually starts,
never at launch, and once a run so it cannot nag. A download found
unfinished when the app opens is not a download starting: it puts the
service up silently and the question waits for one that really begins. A refusal costs the
notification and nothing else: the service still runs and the download
still finishes. There is no storage permission and there still must not
be.

**What Android still reserves the right to do.** A foreground service is
not a guarantee of life. The system may kill the process under memory
pressure; Doze and the per-app battery optimisation may throttle or park
the sockets, so an idle screen-off device can slow a download right down;
and Android 15 (API 35) puts a running-time budget on `dataSync` services
(about 6 hours in 24), after which the system stops it. Swiping the app
out of recents stops it outright, on purpose: `android:stopWithTask="true"`
on the service, because the Flutter engine goes at the same moment and a
notification nobody can move on or take down is worse than none. All of
those end the same way — the pin set and the registry are on disk, and the
next launch re-pins every unfinished entry and picks up where the bytes
stopped.

**Verifying it on a device.** None of this can be seen from a unit test.
The Kotlin that has no Android in it (`DownloadsProgressBar`) has a JVM
test (`./gradlew :app:testDebugUnitTest`); the service, the notification
and the permission dialog need a device or an emulator:

```bash
adb shell dumpsys activity services com.zond.xtremio   # the service and its type
adb shell dumpsys notification --noredact | grep -A5 xtremio.downloads
adb shell am start -n com.zond.xtremio/.MainActivity   # start a download, then:
adb shell input keyevent KEYCODE_HOME                  # leave the app
adb shell dumpsys deviceidle force-idle                # and watch what Doze does
```

## Running on an emulator (headless, KVM)

The x86_64 `google_apis` image is the one that runs on an x86_64 Linux host
(which is also why the bindgen path above matters — the AVD itself isn't
arm64). Requires the user to be in the `kvm` group and `/dev/kvm` to be
accessible.

```bash
export ANDROID_HOME=~/Android/Sdk
export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH

yes | sdkmanager --install "emulator" "system-images;android-36;google_apis;x86_64"
echo no | avdmanager create avd -n xtremio_api36 -k "system-images;android-36;google_apis;x86_64" -d pixel_7

emulator -avd xtremio_api36 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -memory 4096 &
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 5; done

adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.zond.xtremio/.MainActivity
```

## Running on an Android TV emulator

Same flow, a different image and device profile. The TV AVD is what the
D-pad work is verified against.

```bash
yes | sdkmanager --install "system-images;android-36;android-tv;x86_64"
echo no | avdmanager create avd -n xtremio_tv36 \
  -k "system-images;android-36;android-tv;x86_64" -d tv_1080p

emulator -avd xtremio_tv36 -no-window -no-audio -no-boot-anim -no-snapshot \
  -gpu swiftshader_indirect -memory 4096 &
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 5; done

adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.zond.xtremio/.MainActivity
```

**Use the x86_64 TV image, not the 32-bit `x86` one.** API 36 publishes
both `system-images;android-36;android-tv;x86` and
`…;android-tv;x86_64` (below API 36 the Intel TV images are 32-bit only),
but Flutter 3.47 cannot package a 32-bit x86 APK at all:
`flutter build apk --debug --target-platform android-x86` is rejected
outright (`"android-x86" is not an allowed value for option
"--target-platform"`, exit 64), and the Gradle plugin's `PLATFORM_ARCH_MAP`
lists arm, arm64 and x64 only. cargokit *does* know the target
(`i686-linux-android`, `rust_builder/cargokit/build_tool/lib/src/target.dart`),
but nothing downstream would put the resulting `.so` in an APK — which is
why the vendored copy is patched to stop adding that ABI (see
`rust_builder/README.md`). So on a 32-bit-only TV image the app cannot be
installed at all; use the x86_64 image on an x86_64 host, `arm64-v8a` on an
arm64 host, or a physical box with the APK for the ABI that box reports.

The ordinary emulator debug APK is what installs here — no separate build:

```bash
flutter build apk --debug --target-platform android-x64
```

**Checking the device answers "television".** The app's layout keys on
`DeviceProfile.detect()`, so it is worth confirming what the image reports:

```bash
adb shell dumpsys uimode | grep mCurUiMode   # 0x24 → & 0x0f = 4 = UI_MODE_TYPE_TELEVISION
adb shell pm list features | grep leanback   # android.software.leanback (+ _only)
```

(The TV AVD also claims `android.hardware.touchscreen`, which a real TV box
does not; nothing in the layout depends on `hasTouch`, only on `isTv`.)

### Driving it with the remote

Every keycode the app listens for, as `adb shell input keyevent <name>`:

| Key | Keycode | What the app does with it |
|---|---|---|
| D-pad up/down/left/right | `KEYCODE_DPAD_UP` `_DOWN` `_LEFT` `_RIGHT` (19-22) | Moves focus (rows, columns, rail ↔ body); in the player: seek left/right, controls up/down |
| Centre | `KEYCODE_DPAD_CENTER` (23) | Activates the focused tile/button; on the player's video, play/pause and wake the controls |
| Centre, held | `input keyevent --longpress 23` | The long press: mark watched (episode), the library item's action menu |
| Context menu | `KEYCODE_MENU` (82) | The same menu as the long press |
| Back | `KEYCODE_BACK` (4) | Pops the route; leaves the player |
| Play/pause | `KEYCODE_MEDIA_PLAY_PAUSE` (85), `KEYCODE_MEDIA_PLAY` (126), `KEYCODE_MEDIA_PAUSE` (127) | Play/pause |
| Rewind / fast-forward | `KEYCODE_MEDIA_REWIND` (89), `KEYCODE_MEDIA_FAST_FORWARD` (90) | Seek by the profile's seek step |
| Next / previous | `KEYCODE_MEDIA_NEXT` (87), `KEYCODE_MEDIA_PREVIOUS` (88) | Next episode; previous restarts the current one |

**Text fields on a television are not text fields.** Flutter hosts none of
them there: select on a field opens `TextEntryActivity`, a screen of its own
with one plain `EditText` the system keyboard can actually own (see ["Typing
with a remote"](#typing-with-a-remote) above, for why --
`IME_FLAG_NO_FULLSCREEN` makes an in-app field undrivable by a remote). So a
field is driven in two steps, and `input text` only reaches the second one:

```bash
adb shell input keyevent KEYCODE_DPAD_CENTER  # opens the typing screen
adb shell input text "the%squery"             # %s is a space; it has the caret
adb shell input keyevent KEYCODE_ENTER        # Done: the string goes back to
# the field, which submits with it (a search runs, an addon URL is saved).
# A hardware Enter reaches the screen as IME_NULL and confirms; BACK instead
# cancels, and neither the value nor the focus in the app moves.
```

The Clear button of a search field sits *beside* the box on a television,
not inside it, so it is `KEYCODE_DPAD_RIGHT` from the field and then
`KEYCODE_DPAD_CENTER` -- a press of its own, not another trip to the typing
screen.

A walk from the Board to playback, headless:

```bash
K() { adb shell input keyevent "$@"; sleep 1; }
K KEYCODE_DPAD_RIGHT   # rail → first poster
K KEYCODE_DPAD_CENTER  # open Details
K KEYCODE_DPAD_DOWN; K KEYCODE_DPAD_CENTER   # pick a stream → player
K KEYCODE_MEDIA_PLAY_PAUSE
adb shell screencap -p /sdcard/tv.png && adb pull /sdcard/tv.png
adb logcat -d | grep -iE "flutter|xtremio|FATAL"
```

**Verify:**

```bash
adb logcat -d | grep -E "flutter|xtremio|stream_server|rustls"
# should show the embedded server starting, and no
# "Expect rustls-platform-verifier to be initialized"

adb forward tcp:11470 tcp:11470
curl -si http://127.0.0.1:11470/heartbeat
# HTTP/1.1 401 Unauthorized — the control API wants the per-launch bearer
# token only the Rust side holds; the 401 itself proves the server is up.
# If 11470 was taken the app fell back to an ephemeral port; read the real
# one from logcat instead. The BitTorrent listener (librqbit) is always on
# an ephemeral UDP/TCP port for the embedded server, so nothing needs
# forwarding or a fixed firewall rule for it.

# Discover showing Cinemeta posters proves HTTPS end to end
```

## Running on a physical device

**Ask the device which ABI it wants; do not infer it from the chip.** With USB
debugging enabled (`adb devices` shows `device`, not `unauthorized`):

```bash
adb shell getprop ro.product.cpu.abilist
```

The first entry is the one to build for. Measured on the box this project
targets, a **Chromecast with Google TV** (`sabrina`, Android 14 / API 34):

```
armeabi-v7a,armeabi
```

That is a 64-bit chip running a 32-bit userspace, and there is no `arm64-v8a`
in the list, so an arm64 APK is not merely slower there — it is refused, with
`INSTALL_FAILED_NO_MATCHING_ABIS`. It wants **`make apk-tv`** (armeabi-v7a),
which needs no source change at all: rustls and aws-lc-rs cross-compile for
`armv7-linux-androideabi` unchanged, and the release APK came out at 44.6 MB
against arm64's 55.2 MB. A phone or a 64-bit TV box (whose list starts
`arm64-v8a`) takes `make apk` instead.

Then, for either:

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n com.zond.xtremio/.MainActivity
```

On a TV device the way in is usually ADB over the network — turn on ADB
debugging in its developer options, then `adb connect <ip>:5555` — rather than
a cable.

## What was verified

Verified 2026-09-02 on an x86_64 Linux host (KVM available, user in the `kvm`
group) against commit `a4b9327` (10 commits ahead of `origin/main`; at that
commit the app still set `HOME` itself for librqbit, which the current
`stream-server` no longer needs -- see above).

**CI replication** (`.github/workflows/ci.yml`, run locally):

| Job | Steps | Result |
|---|---|---|
| Rust | `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test` | pass — 15 tests passed, 2 ignored (network-only fixtures), 0 failed |
| Flutter | `flutter pub get`, `dart format --set-exit-if-changed .`, `flutter analyze`, `cargo build --manifest-path rust/Cargo.toml`, `flutter test` | pass — 0 analyzer issues, 46 tests passed |
| codegen | `flutter_rust_bridge_codegen generate` (2.13.0, matching the pinned Dart package version), `git diff --exit-code -- lib/src/rust rust/src/frb_generated.rs` | pass — no drift |

(`dart format` was run against a clean tree with no stale `build/` directory
present — a `build/` left over from a previous local build otherwise gets
swept into the scan and reformatted too, since it's outside the CI checkout
but not excluded by the bare `.` path; that's local-tree noise, not a real
failure, since `build/` is gitignored.)

**Native Android build and run** (not yet gated in CI — see the note at the
bottom of `ci.yml` — verified manually instead):

- `flutter build apk --debug --target-platform android-arm64,android-x64`
  succeeded (cross-compiled `xtremio_core` for both
  `aarch64-linux-android` and `x86_64-linux-android` via cargokit, then
  `assembleDebug`), producing a 315 MB debug APK.
- Installed and launched on a freshly created `xtremio_api36` AVD
  (`android-36;google_apis;x86_64`, headless, `-gpu swiftshader_indirect`).
- `adb logcat` showed: `NativeInit.initTlsVerifier` running before Flutter
  starts (no "Expect rustls-platform-verifier to be initialized" warning
  anywhere in the log), the embedded `stream-server` starting and listening on
  `127.0.0.1:11470`, the stremio-core runtime starting against that URL, and
  no `FATAL` or uncaught-exception lines for the run.
- `adb forward tcp:11470 tcp:11470 && curl http://127.0.0.1:11470/heartbeat`
  returned `{"success":true}` (HTTP 200). (That was before the server's
  control API took a bearer token; today the same probe answers 401.)
- The app booted straight into **Board**; navigating to **Discover** loaded
  and rendered the Cinemeta catalog with poster images over HTTPS (confirmed
  visually via `adb shell screencap`), proving the TLS-verifier hook,
  cleartext-loopback-only manifest flag, and addon HTTP client all work
  together on-device.
- BitTorrent DHT bootstrapping was visible in the log
  (`librqbit_dht::dht: finished, successes=59, errors=13, ...` — the error
  count there is normal UDP-over-DHT timeout noise, not a failure) but full
  torrent playback (Settings → Developer → "Play test torrent") was not
  exercised in this session.
- Some outbound IPv6 connect attempts failed with `Network is unreachable`
  and transparently fell back to IPv4 — expected on this emulator network
  configuration, not an app issue.

**Not verified in that session:** a physical device or Android TV box (none
attached), the arm64 build's *runtime* behavior (only the x86_64 slice of the
debug APK was actually run, though the arm64 slice built cleanly), release
builds, and end-to-end torrent playback on Android.

### Offline downloads on the phone emulator (2026-09-03)

Verified on the headless `xtremio_api36` AVD
(`android-36;google_apis;x86_64`, `-gpu swiftshader_indirect`) with the
x86_64 debug APK at commit `7bdda0c`, driven by `adb shell input` and read
back with `adb shell screencap`, `adb shell ls`/`du` and `adb shell run-as`.

- **The destination default lands.** A fresh install wrote
  `"downloadsDir": "/storage/emulated/0/Android/data/com.zond.xtremio/files/downloads"`
  into `files/server/settings.json` at start-up, and the Downloads screen
  showed that path under "Where downloads go".
- **The download runs and the file lands there.** Settings → Developer →
  "Download test torrent" pinned the public Big Buck Bunny torrent; the
  registry (`files/core/downloads.json`) went
  `downloading 11.6 MB → 65 MB → 122 MB → 186 MB → 243 MB → complete
  276134947 / 276134947` over about 15 seconds, and the row on the
  Downloads screen showed "Downloading 17% · 47.0 MB of 276 MB" with its
  bar mid-flight and "Downloaded · 276 MB" after. The bytes are in
  `…/files/downloads/dd8255…d1c/Big Buck Bunny.mp4`, next to the torrent's
  other files.
- **Playing it needs nothing running.** The row's Play opened the player on
  the `file://` URL with no torrent start-up overlay (that keys on
  `infoHash`, and this stream has none); libmpv read the real duration and
  the position advanced (`0:18 / 10:34`). No frames are drawn — swiftshader
  renders no video on this AVD, as in every earlier session — so decoding
  itself is still unverified on an emulator.
- **Deleting takes the folder with it.** "Delete the file" emptied the
  registry and removed the whole `<infoHash>` directory.
- **Two things to know when checking on device.** `ls -l` shows the file at
  its full length from the first moment — librqbit allocates it sparsely —
  so use `du -sk` for what is really on the volume (37 MB at 3 s, 122 MB at
  7 s). And `adb shell ls /sdcard/Android/data/com.zond.xtremio/files/…`
  works from the shell user; only other apps are kept out of `Android/data`,
  so `run-as` is needed for the internal directories (`files/core`,
  `files/server`) but not for the downloads.
- No `FATAL`/`AndroidRuntime` line for the whole run.
- **Not verified:** a purge of the cache directory (the reason for the
  default), an SD-card destination (the AVD has one volume), moving the
  destination with downloads already on disk, and what happens to a running
  download when Android freezes the process.

### The TV layout on a TV emulator (2026-09-03)

Verified on a headless `xtremio_tv36` AVD
(`system-images;android-36;android-tv;x86_64`, `-d tv_1080p`, 1920x1080,
`-gpu swiftshader_indirect`) with the x86_64 debug APK, driven entirely by
`adb shell input keyevent` and read back with `adb shell screencap`.

- The image answers television: `mCurUiMode=0x24` (`& 0x0f` = 4 =
  `UI_MODE_TYPE_TELEVISION`) and `android.software.leanback`, so
  `DeviceProfile.detect()` reports `isTv`. It also claims
  `android.hardware.touchscreen`, which a real TV box does not; nothing in
  the layout depends on `hasTouch`.
- The Board came up in the TV layout: rail at every width, 5% of every edge
  held clear, the first poster autofocused with its ring, ten-foot posters
  and text. D-pad right/left/up/down walked the row and the rows, the centre
  key opened Details, and back returned to the Board with focus where it
  had been.
- Left from the body's first column landed on the rail, up/down walked the
  destinations, and the centre key switched tabs; focus moving down the
  Settings list scrolled it.
- The player (Settings → Developer → "Play test HTTP stream") opened
  immersive-fullscreen with no system bars, and drew neither the volume
  slider nor the fullscreen button — the remote's controls only. The centre
  key and `KEYCODE_MEDIA_PLAY_PAUSE` toggled play/pause, the centre key woke
  the faded controls, and back popped the player (`route pop: player`).
- The embedded server reached **Ready** at `http://127.0.0.1:11470/`; no
  `FATAL`/`AndroidRuntime` lines for the whole run.
- **Two things this run turned up.** The row header overflowed by 6 px under
  the TV's 1.15x text scale — fixed (the header now grows with the text
  scale, and the widget test reproduces the same 6 px). And on Settings the
  D-pad got **stuck in the streaming-server radio group**: `RadioGroup`
  takes the up/down keys to move the selection, so the remote could not
  walk past it to the Developer entries below, and it silently flipped the
  server choice on the way. Fixed: the two choices are plain tiles with the
  radio's icon on a television, radios everywhere else.
- **Not verified:** decoded video. Position stayed at `0:00 / 0:10` with the
  transport in its playing state — libmpv renders nothing under
  swiftshader on this AVD (playback has never been exercised on an emulator
  in any session). Torrent playback, a physical TV box and a real remote
  are all still untried.
