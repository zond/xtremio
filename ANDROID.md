# Android

This is the detailed reference for building, running and verifying Xtremio on
Android. The high-level architecture (`stremio-core` + embedded
`stream-server` + `media_kit`/libmpv) is described in the main
[README](README.md#how-the-rust-core-is-wired-in); this file is Android-only.

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
flutter build apk --debug --target-platform android-x64                  # emulator only
flutter build apk --debug --target-platform android-arm64,android-x64    # phone/TV + emulator
flutter build apk --release --target-platform android-arm64              # arm64 only, no bindgen needed
flutter build apk --release --split-per-abi                              # arm, arm64, x64 APKs
```

Debug builds always add x86_64 for the emulator regardless of
`--target-platform` (cargokit mirrors Flutter's rule here; the vendored copy
is patched to stop also adding the dropped android-x86 ABI, which Flutter
3.47 can no longer package — see `rust_builder/README.md`). Output lands at
`build/app/outputs/flutter-apk/app-debug.apk` (or `app-release.apk`).

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
  `AndroidManifest.xml` (same APK runs on Android TV boxes, Chromecast with
  Google TV, and the Google TV Streamer — they're all just Android).
  `android:banner` is the tile the TV home screen shows, a 320x180 xhdpi
  PNG at `res/drawable-xhdpi/banner.png` (the launcher icon is the wrong
  shape for it).
- **`stremio://` intent-filter.** A second `intent-filter` on
  `MainActivity` takes `VIEW` with `BROWSABLE` and `DEFAULT` for
  `<data android:scheme="stremio"/>`. That is how an addon site's Install
  button reaches the app: it swaps the scheme on the addon's own manifest
  URL, so `https://host/manifest.json` is opened as
  `stremio://host/manifest.json` and Xtremio shows that addon's details
  screen (nothing is installed without a press — README, "Installing an
  addon from the web"). No `android:host` and no `android:autoVerify`:
  the host is the *addon's* domain, so there is no domain this app could
  claim, and App Links verification (which serves `assetlinks.json` from
  the claimed domain) is impossible by construction. `MainActivity` was
  already `android:launchMode="singleTop"`, which is what makes a link
  arriving while the app is up go to the running instance's `onNewIntent`
  instead of starting a second one. To try it on a device or emulator:

  ```bash
  adb shell am start -a android.intent.action.VIEW \
    -d "stremio://v3-cinemeta.strem.io/manifest.json"
  ```
- **`xtremio/device` channel.** `DeviceProfile.detect()`
  (`lib/shell/device_profile.dart`) runs once in `main()` before `runApp`
  and asks `MainActivity` for `{isTv, hasTouch}`: `isTv` is
  `UiModeManager.currentModeType == UI_MODE_TYPE_TELEVISION` or the
  `android.software.leanback` feature, `hasTouch` is `FEATURE_TOUCHSCREEN`.
  The answer goes down the widget tree as `DeviceScope`, which is what the
  remote-driven layout keys on. Any error on the channel means "a phone";
  no other platform calls it (desktop is never a TV).

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
- **Downloads only advance while the app is running.** There is no
  foreground service yet, so once Android freezes or kills the process the
  torrent stops with it; a notification and a `FOREGROUND_SERVICE_DATA_SYNC`
  service are the follow-up. Nothing is lost when it happens: librqbit
  persists the torrent and its verified pieces, the server persists its pin
  set, and start-up re-pins every unfinished registry entry, so reopening
  the app continues where it stopped. A *finished* download needs nothing
  running at all — it is played straight off the file.
- **Moving the destination moves nothing that is already there.** The
  server relocates a torrent only when it is pinned again, which for an
  unfinished download happens at the next start-up. Files a finished
  download left behind stay where they were downloaded; the registry keeps
  naming that path.

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
arm64 host, or a physical box with the arm64 APK.

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

A phone, TV box or Chromecast with Google TV with USB debugging enabled
(`adb devices` shows `device`, not `unauthorized`) takes the arm64 APK the
same way: `adb install -r build/app/outputs/flutter-apk/app-debug.apk` (built
with `android-arm64` in `--target-platform`), then
`adb shell am start -n com.zond.xtremio/.MainActivity`. No physical device or
Android TV box was available to this session, so this path is documented but
not yet exercised — the emulator run below stands in for it.

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
