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
  posters from self-hosted `http://` addons, and calls the Flutter side makes
  to the embedded server's loopback URL). It does **not** affect the Rust
  side: reqwest/rustls sockets and libmpv's own networking ignore Android's
  cleartext policy either way. It's needed because the embedded
  `stream-server` always talks `http://127.0.0.1:<port>`, never https, and
  some addons are themselves plain-http.
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
  passwd fallback there. `stream-server` therefore derives every path it
  needs from the directories the app passes in `ServerConfig`
  (`RustCoreClient.init(support, cache)` → `<files>/server` for settings
  and logs, `<cache>/server` for the torrent session, its DHT routing-table
  dump `dht.json` and the piece cache) and never consults the environment
  on its startup path.
- **Leanback entries** for Android TV / Google TV are already in
  `AndroidManifest.xml` (same APK runs on Android TV boxes, Chromecast with
  Google TV, and the Google TV Streamer — they're all just Android).

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

For D-pad/leanback work, use `system-images;android-36;android-tv;x86_64`
instead — same flow.

**Verify:**

```bash
adb logcat -d | grep -E "flutter|xtremio|stream_server|rustls"
# should show the embedded server starting, and no
# "Expect rustls-platform-verifier to be initialized"

adb forward tcp:11470 tcp:11470
curl -s http://127.0.0.1:11470/heartbeat
# {"success":true} — if 11470 was taken the app fell back to an
# ephemeral port; read the real one from logcat instead

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
  returned `{"success":true}` (HTTP 200).
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

**Not verified this session:** a physical device or Android TV box (none
attached), the arm64 build's *runtime* behavior (only the x86_64 slice of the
debug APK was actually run, though the arm64 slice built cleanly), release
builds, and end-to-end torrent playback on Android.
