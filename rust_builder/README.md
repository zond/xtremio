# rust_builder

Glue that builds the `rust/` crate with Flutter. The FFI plugin skeleton
(`android/`, `ios/`, `linux/`, `macos/`, `windows/`, `pubspec.yaml`) is what
`flutter_rust_bridge_codegen create` generates; `cargokit/` is vendored from
[cargokit](https://github.com/irondash/cargokit) through FRB.

## Local patches to the vendored cargokit

- `cargokit/gradle/plugin.gradle`: the debug variant no longer appends
  `android-x86`. Flutter 3.47 has no `android-x86` target platform (its
  `PLATFORM_ARCH_MAP` lists arm, arm64 and x64 only) and sets
  `abiFilters` accordingly, so an i686 build would be compiled and then
  dropped from the APK. `android-x64` is kept for the emulator.

- `cargokit/build_tool/lib/src/android_environment.dart`: additionally
  exports `BINDGEN_EXTRA_CLANG_ARGS_<triple>` = `--target=<triple><minSdk>
  --sysroot=<NDK sysroot>` next to `CC_<triple>`/`CFLAGS_<triple>`. Build
  scripts that run bindgen (aws-lc-sys on x86_64/armv7 Android, which have
  no pregenerated bindings) otherwise parse the host's `/usr/include` and
  fail with `'bits/libc-header-start.h' file not found`.

Re-apply these when re-copying cargokit from a newer FRB/cargokit release.
