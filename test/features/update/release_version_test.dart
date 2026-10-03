import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/update/release_version.dart';

ReleaseVersion v(String text) => ReleaseVersion.parse(text)!;

void main() {
  group('ReleaseVersion', () {
    test('reads a tag and a pubspec stamp the same way', () {
      expect(v('v0.1.14'), v('0.1.14'));
      // Flutter's build number is semver build metadata: not a version.
      expect(v('0.1.13+1'), v('0.1.13'));
      expect(v('0.1.13+1').toString(), '0.1.13');
    });

    test('is not anything else', () {
      for (final text in ['', 'unknown', '0.1', 'v0.1.x', '01.2.3', 'x1.2.3']) {
        expect(ReleaseVersion.parse(text), isNull, reason: text);
      }
    });

    test('compares numbers as numbers', () {
      expect(v('0.1.10') > v('0.1.9'), isTrue);
      expect(v('0.2.0') > v('0.1.99'), isTrue);
      expect(v('1.0.0') > v('0.99.99'), isTrue);
      expect(v('0.1.13') < v('0.1.13'), isFalse);
    });

    test('puts a pre-release below its release, in semver order', () {
      final ordered = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ].map(v).toList();
      for (var i = 0; i + 1 < ordered.length; i++) {
        expect(ordered[i] < ordered[i + 1], isTrue, reason: '${ordered[i]}');
        expect(ordered[i + 1] > ordered[i], isTrue, reason: '${ordered[i]}');
      }
    });
  });

  group('BuildIdentity', () {
    BuildIdentity build(
      String version, {
      String commit = 'cda9225',
      bool release = true,
    }) => BuildIdentity(
      version: version,
      commit: commit,
      isReleaseBuild: release,
    );

    test('a stamped, clean release build checks by itself', () {
      expect(build('0.1.13+1').checksByItself, isTrue);
    });

    test('nothing else does', () {
      // `flutter run` / a plain `flutter build`: no stamp at all.
      expect(build('').checksByItself, isFalse);
      // Built from a modified tree: the version is the last release's,
      // the code is not.
      expect(
        build('0.1.13+1', commit: 'cda9225-dirty').checksByItself,
        isFalse,
      );
      // A version somebody named as not a release.
      expect(build('0.1.14-dev').checksByItself, isFalse);
      // Debug and profile: a second app the release cannot update.
      expect(build('0.1.13+1', release: false).checksByItself, isFalse);
    });

    test('only a release-mode build may install', () {
      expect(build('0.1.13').canInstall, isTrue);
      expect(build('0.1.13', release: false).canInstall, isFalse);
    });

    test('is older than a newer release only', () {
      expect(build('0.1.13+1').isOlderThan(v('0.1.14')), isTrue);
      expect(build('0.1.13+1').isOlderThan(v('0.1.13')), isFalse);
      expect(build('0.1.14').isOlderThan(v('0.1.13')), isFalse);
      // No version is older than nothing: nothing to compare.
      expect(build('').isOlderThan(v('9.9.9')), isFalse);
    });
  });
}
