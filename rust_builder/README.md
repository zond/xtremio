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

Re-apply these when re-copying cargokit from a newer FRB/cargokit release.
