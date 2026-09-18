# Builds that say what they are.
#
# The Diagnostics screen's header reads its version and commit from two
# `--dart-define`s (`XTREMIO_VERSION`, `XTREMIO_GIT_COMMIT`, read by
# `lib/features/diagnostics/diagnostics_report.dart`). A plain
# `flutter build` passes neither, and every report copied off such a build
# says `app: unknown` -- which is the one line that says which build the rest
# of the report is about. So the build a person actually types is this one.
#
#   make apk            release APK for a phone or a 64-bit TV box (arm64)
#   make apk-tv         release APK for a Chromecast with Google TV (armeabi-v7a)
#   make apk-split      release APKs per ABI (arm, arm64, x64)
#   make apk-debug      debug APK for the x86_64 emulator
#   make linux          release Linux desktop bundle
#   make macos          release macOS .app
#   make ios            release iOS build, unsigned -- does it compile at all
#   make run            flutter run, stamped the same way
#   make version        show what would be stamped
#
# Any of them takes the usual extra flags through FLAGS=, e.g.
#   make apk FLAGS="--target-platform android-arm64,android-x64"

VERSION := $(shell sed -n 's/^version: //p' pubspec.yaml)
# The commit, marked when the tree it was built from was not clean: a report
# from a modified build must not name a commit as if it were that commit.
COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)$(shell test -z "$$(git status --porcelain 2>/dev/null)" || echo -dirty)
DEFINES := --dart-define=XTREMIO_VERSION=$(VERSION) \
           --dart-define=XTREMIO_GIT_COMMIT=$(COMMIT)

FLAGS ?=
DEVICE ?=

.PHONY: apk apk-tv apk-split apk-debug linux macos ios run version

# Version codes follow `apk-split`, which is what goes to Drive: Flutter's
# per-ABI build adds 1000 for armeabi-v7a and 2000 for arm64-v8a to the build
# number, so its APKs carry 1001 and 2001. A single-ABI build stamps 1 unless
# told otherwise, and Android then refuses it as a downgrade over the Drive
# build -- `adb install -d` does not lift that for a release app, and
# uninstalling loses the login and settings. So these targets stamp the same
# codes and the two kinds of build install over each other.
apk:
	flutter build apk --release --target-platform android-arm64 --build-number=2001 $(DEFINES) $(FLAGS)

# A Chromecast with Google TV has a 64-bit chip and a 32-bit userspace
# (`ro.product.cpu.abilist` is `armeabi-v7a,armeabi` on Android 14), so it
# refuses the arm64 APK above with INSTALL_FAILED_NO_MATCHING_ABIS. Needs
# libclang, which armv7 uses to generate the aws-lc-sys bindings -- ANDROID.md,
# "Prerequisites".
apk-tv:
	flutter build apk --release --target-platform android-arm --build-number=1001 $(DEFINES) $(FLAGS)

apk-split:
	flutter build apk --release --split-per-abi $(DEFINES) $(FLAGS)

apk-debug:
	flutter build apk --debug --target-platform android-x64 $(DEFINES) $(FLAGS)

linux:
	flutter build linux --release $(DEFINES) $(FLAGS)

macos:
	flutter build macos --release $(DEFINES) $(FLAGS)

# There is no signing identity to build against, so this answers whether the
# iOS half compiles and nothing else -- the .app it leaves cannot be installed.
ios:
	flutter build ios --release --no-codesign $(DEFINES) $(FLAGS)

run:
	flutter run $(if $(DEVICE),-d $(DEVICE),) $(DEFINES) $(FLAGS)

version:
	@echo "XTREMIO_VERSION=$(VERSION)"
	@echo "XTREMIO_GIT_COMMIT=$(COMMIT)"
