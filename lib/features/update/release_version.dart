import 'package:flutter/foundation.dart';

import '../diagnostics/diagnostics_report.dart' show kAppVersion, kGitCommit;

/// A semantic version, as far as a release tag and the app's own stamp use
/// one: `MAJOR.MINOR.PATCH`, an optional `-prerelease` and an optional
/// `+build`, with an optional leading `v` (the tag's spelling).
///
/// The build part is parsed and ignored, as semver says: `pubspec.yaml`'s
/// `0.1.13+1` is the version `0.1.13`, and its `+1` is Flutter's build
/// number, which is not a version at all.
@immutable
class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(
    this.major,
    this.minor,
    this.patch, [
    this.prerelease = const [],
  ]);

  final int major;
  final int minor;
  final int patch;

  /// The dot-separated identifiers after the `-`, empty for a release.
  final List<String> prerelease;

  /// No `-prerelease` part: what a tag the release workflow publishes
  /// looks like, and what an installed release says it is.
  bool get isRelease => prerelease.isEmpty;

  static final RegExp _shape = RegExp(
    r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );

  /// [text] as a version, or null when it is not one -- an empty stamp,
  /// `unknown`, a tag somebody pushed by hand.
  static ReleaseVersion? parse(String text) {
    final match = _shape.firstMatch(text.trim());
    if (match == null) return null;
    return ReleaseVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      match[4]?.split('.') ?? const [],
    );
  }

  /// Semver precedence: the three numbers, then a pre-release below the
  /// release it leads to, then the pre-release identifiers one by one
  /// (numbers numerically and below words, words in ASCII order, and the
  /// shorter list first when one is the start of the other).
  @override
  int compareTo(ReleaseVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      // A release is above every pre-release of the same three numbers.
      return (other.prerelease.isEmpty ? 0 : 1) - (prerelease.isEmpty ? 0 : 1);
    }
    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      final a = prerelease[i];
      final b = other.prerelease[i];
      final an = int.tryParse(a);
      final bn = int.tryParse(b);
      final order = switch ((an, bn)) {
        (final int x, final int y) => x.compareTo(y),
        (int(), null) => -1,
        (null, int()) => 1,
        _ => a.compareTo(b),
      };
      if (order != 0) return order;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }

  bool operator <(ReleaseVersion other) => compareTo(other) < 0;
  bool operator >(ReleaseVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is ReleaseVersion && compareTo(other) == 0;

  @override
  int get hashCode =>
      Object.hash(major, minor, patch, Object.hashAll(prerelease));

  @override
  String toString() =>
      '$major.$minor.$patch${isRelease ? '' : '-${prerelease.join('.')}'}';
}

/// What this build is, for the update check: the stamp the Makefile puts on
/// it, and whether it is the release app.
///
/// **Only a stamped, clean release build checks by itself.** Every other
/// build is somebody working on the app, and a dialog about the latest
/// release at every start is noise to them -- worse, an offer to install
/// the release over what they are testing. So [checksByItself] wants all
/// three of:
///
/// - **a release-mode build** ([isReleaseBuild]). Debug and profile builds
///   are `com.zond.xtremio.debug`, a second app signed with the debug key:
///   the release APK is a different package to them and could never update
///   one. They still answer Settings' "Check for updates", and are only
///   ever offered the release page ([canInstall] is false).
/// - **a version that is a release** (`X.Y.Z`, a `+build` allowed). An
///   empty stamp is a plain `flutter build`/`flutter run`; a pre-release
///   suffix is a build somebody named as not-a-release.
/// - **a commit that is not `-dirty`**: the Makefile marks a build made
///   from a modified tree, and its version is the last release's while its
///   code is not.
///
/// A clean `make apk` from a commit after the last tag carries the last
/// tag's version and does check: it is behind the next release exactly the
/// way that release is, and an update over it is what its owner wants.
@immutable
class BuildIdentity {
  const BuildIdentity({
    required this.version,
    required this.commit,
    required this.isReleaseBuild,
  });

  /// This build, from the `--dart-define`s and the compiler's mode.
  static const BuildIdentity current = BuildIdentity(
    version: kAppVersion,
    commit: kGitCommit,
    isReleaseBuild: kReleaseMode,
  );

  /// `XTREMIO_VERSION`: `pubspec.yaml`'s version, or empty.
  final String version;

  /// `XTREMIO_GIT_COMMIT`: a short hash, `-dirty` when the tree was not
  /// clean, or empty.
  final String commit;

  /// Compiled in release mode, so the release app (`com.zond.xtremio`).
  final bool isReleaseBuild;

  /// [version] as a version, null when it is not one.
  ReleaseVersion? get parsed => ReleaseVersion.parse(version);

  /// Whether the start-up check runs at all. See the class.
  bool get checksByItself {
    final parsed = this.parsed;
    return isReleaseBuild &&
        parsed != null &&
        parsed.isRelease &&
        !commit.endsWith('-dirty');
  }

  /// Whether an update may be installed over this build rather than only
  /// pointed at: the release app, on a platform that installs (the
  /// installer itself decides that last part).
  bool get canInstall => isReleaseBuild;

  /// Whether [release] is newer than this build: false when this build has
  /// no version to compare.
  bool isOlderThan(ReleaseVersion release) {
    final parsed = this.parsed;
    return parsed != null && parsed < release;
  }
}
