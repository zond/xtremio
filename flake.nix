{
  # A development environment, not a package: `nix develop` gives the tools
  # docs/OPERATIONS.md and docs/ANDROID.md list, at the versions they name.
  # Nothing here builds the app; `make` does that, inside the shell, as it
  # does outside one.
  #
  #   nix develop               Flutter, Rust (via rustup), codegen, the
  #                             desktop libraries, libmpv and ffmpeg for the
  #                             FFmpeg tests
  #   nix develop .#android     the same plus JDK 21, the Android SDK and NDK
  #                             Flutter 3.47 pins, an emulator and an image
  #   nix develop .#xervice     Node 22 and firebase-tools for xtremio-xervice/
  #
  # Not provided, because Nix cannot: Xcode (a macOS build, `make macos`, uses
  # the one installed from the App Store, and `xcode-select` must point at it).
  description = "Xtremio development shells";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # flutter347 is built for these three only.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              # The Android SDK is unfree, and androidenv refuses to compose
              # one until its licence is accepted. Only the `android` shell
              # instantiates it; entering that shell is accepting it.
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };
          inherit (pkgs) lib stdenv;

          # CI's FLUTTER_VERSION is 3.47.1; nixpkgs carries the newest 3.47.x.
          flutter = pkgs.flutter347;

          # rust/src/libav.rs reads FFmpeg's structs by layout and refuses any
          # FFmpeg major but 6 -- the one the vendored Android libmpv carries.
          # nixpkgs' mpv links the current FFmpeg, so the FFmpeg tests
          # (rust/tests/libav.rs, rendition.rs, mpv_stream.rs) would print
          # SKIPPED against it, and on Linux the app's own renditions would be
          # refused. Rebuild libmpv against FFmpeg 6, and give the tests an
          # `ffmpeg` of the same release (it needs libx264, which this has).
          ffmpeg = pkgs.ffmpeg_6;
          mpv = pkgs.mpv-unwrapped.override { inherit ffmpeg; };
          libmpv = "${mpv}/lib/libmpv${if stdenv.hostPlatform.isDarwin then ".2.dylib" else ".so.2"}";

          # On macOS the build is Xcode's: a Nix C compiler in the shell sets
          # DEVELOPER_DIR, SDKROOT and NIX_CFLAGS_* that xcodebuild and
          # CocoaPods then trip over. Use the system's clang there.
          mkShell = if stdenv.hostPlatform.isDarwin then pkgs.mkShellNoCC else pkgs.mkShell;

          common = {
            packages = [
              flutter
              # cargokit (rust_builder/cargokit) drives cargo through
              # `rustup run stable cargo build` and adds targets with
              # `rustup target add`, so the Rust toolchain has to be rustup's
              # and not a Nix-built one. It uses ~/.rustup as usual.
              pkgs.rustup
              # Codegen, Dart package and crate must all be 2.13.0, and
              # `generate` shells out to `cargo expand`.
              pkgs.flutter_rust_bridge_codegen
              pkgs.cargo-expand
              pkgs.gnumake
              pkgs.git
              ffmpeg
              mpv
            ]
            ++ lib.optionals stdenv.hostPlatform.isLinux [
              # What `flutter build linux` and media_kit / flutter_secure_storage
              # link against (docs/OPERATIONS.md, "Setting up a dev machine").
              pkgs.clang
              pkgs.cmake
              pkgs.ninja
              pkgs.pkg-config
              pkgs.gtk3
              pkgs.libsecret
              mpv.dev
            ]
            ++ lib.optionals stdenv.hostPlatform.isDarwin [
              # Flutter's macOS plugins come in as pods.
              pkgs.cocoapods
            ];

            # The libmpv the FFmpeg tests load (rust/tests/support/film.rs).
            XTREMIO_LIBMPV = libmpv;

            shellHook = ''
              ${lib.optionalString stdenv.hostPlatform.isDarwin ''
                unset DEVELOPER_DIR SDKROOT
                # Even mkShellNoCC puts the stdenv's GNU userland first on
                # PATH, and what Xcode runs assumes BSD's: the podspec of
                # media_kit_libs_macos_video runs a Makefile with `sed -i '''`
                # and `cut -f 1 -f 3`, both errors to GNU, which leaves
                # Frameworks/.symlinks/mpv empty and the link failing on
                # "framework 'Mpv' not found". Let /usr/bin answer instead.
                PATH=$(printf %s "$PATH" | tr : '\n' \
                  | grep -vE '^/nix/store/[a-z0-9]{32}-(coreutils|findutils|diffutils|gnused|gnugrep|gawk|gnutar)-[^/]*/bin$' \
                  | paste -sd: -)
              ''}
              # cargokit builds with rustup's `stable`, so that is the one that
              # has to meet rust/Cargo.toml's rust-version.
              want=$(sed -n 's/^rust-version = "\(.*\)"/\1/p' rust/Cargo.toml 2>/dev/null)
              have=$(rustup run stable rustc --version 2>/dev/null | cut -d' ' -f2)
              if [ -z "$have" ]; then
                echo "xtremio: no stable Rust toolchain yet; run:"
                echo "  rustup toolchain install stable --component rustfmt,clippy"
              elif [ -n "$want" ] && [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -1)" != "$want" ]; then
                echo "xtremio: rustup's stable is $have, rust/Cargo.toml needs $want; run:"
                echo "  rustup update stable"
              fi
            '';
          };

          # Android: platform 36, build-tools 36.0.0 and NDK 28.2.13676358,
          # the versions Flutter 3.47's Gradle plugin asks for
          # (docs/ANDROID.md, "Prerequisites"), plus an emulator image for
          # this host's architecture: x86_64 on an x86_64 host, arm64-v8a on
          # Apple silicon and arm64 Linux.
          #
          # Gradle installs what a build asks for and is missing, which it
          # cannot do into a read-only SDK in the store, so every platform a
          # module compiles against is named here: 37 for the app
          # (`compileSdk = 37`, android/app/build.gradle.kts, forced by
          # permission_handler_android 14.1, which pins 37); 36, Flutter's
          # default, which app_links, media_kit_video,
          # media_kit_libs_android_video and rust_builder pin too; and 35,
          # which flutter_chrome_cast, jni and jni_flutter pin. The SDK
          # repository names API 37 "37.0" (platforms/android-37.0) and
          # androidenv looks it up by that key, so "37" would not evaluate.
          # Each platform also brings the system images below that exist for
          # it. CMake 3.22.1 is AGP's default, which jni's native build uses.
          android = pkgs.androidenv.composeAndroidPackages {
            platformVersions = [
              "35"
              "36"
              "37.0"
            ];
            includeCmake = true;
            cmakeVersions = [ "3.22.1" ];
            buildToolsVersions = [ "36.0.0" ];
            platformToolsVersion = "latest";
            includeNDK = true;
            ndkVersions = [ "28.2.13676358" ];
            includeEmulator = true;
            includeSystemImages = true;
            systemImageTypes = [
              "google_apis"
              "android-tv"
            ];
            abiVersions = [ (if stdenv.hostPlatform.isAarch64 then "arm64-v8a" else "x86_64") ];
          };
          androidHome = "${android.androidsdk}/libexec/android-sdk";
        in
        {
          default = mkShell common;

          android = mkShell (
            common
            // {
              packages = common.packages ++ [
                android.androidsdk
                pkgs.jdk21
                # bindgen, for aws-lc-sys on the x86_64 (emulator) and armv7
                # (Chromecast with Google TV) Android targets.
                pkgs.llvmPackages.libclang
              ];

              ANDROID_HOME = androidHome;
              ANDROID_SDK_ROOT = androidHome;
              ANDROID_NDK_HOME = "${androidHome}/ndk/28.2.13676358";
              JAVA_HOME = pkgs.jdk21.home;
              LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            }
            // lib.optionalAttrs stdenv.hostPlatform.isLinux {
              # The aapt2 Gradle fetches from Maven is a dynamically linked
              # ELF that does not run on NixOS; use the SDK's own.
              GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidHome}/build-tools/36.0.0/aapt2";
            }
          );

          xervice = pkgs.mkShellNoCC {
            # xtremio-xervice/functions/package.json: "engines": { "node": "22" }
            packages = [
              pkgs.nodejs_22
              pkgs.firebase-tools
            ];
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
