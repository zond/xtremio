import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/update/release_version.dart';
import 'package:xtremio/features/update/releases.dart';

/// The fields of `GET /repos/zond/xtremio/releases/latest` this app reads,
/// in GitHub's shape.
Map<String, dynamic> latestJson({
  String tag = 'v0.1.14',
  bool draft = false,
  bool prerelease = false,
}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/zond/xtremio/releases/tag/$tag',
  'draft': draft,
  'prerelease': prerelease,
  'body': '## Fixes\r\n\r\n* one',
  'assets': [
    for (final name in [
      'xtremio-arm64-v8a.apk',
      'xtremio-armeabi-v7a.apk',
      'xtremio-linux-x64.tar.gz',
    ])
      {
        'name': name,
        'size': 1234,
        'digest': 'sha256:${'ab' * 32}',
        'browser_download_url':
            'https://github.com/zond/xtremio/releases/download/$tag/$name',
      },
  ],
};

void main() {
  group('ReleaseInfo.fromGitHub', () {
    test('reads the tag, the notes, the page and every asset', () {
      final release = ReleaseInfo.fromGitHub(latestJson());
      expect(release.tag, 'v0.1.14');
      expect(release.version, ReleaseVersion.parse('0.1.14'));
      expect(release.notes, '## Fixes\r\n\r\n* one');
      expect(
        release.page,
        Uri.parse('https://github.com/zond/xtremio/releases/tag/v0.1.14'),
      );
      final apk = release.asset('xtremio-armeabi-v7a.apk')!;
      expect(apk.size, 1234);
      expect(apk.digest, 'sha256:${'ab' * 32}');
      expect(
        apk.url.toString(),
        'https://github.com/zond/xtremio/releases/download/v0.1.14/'
        'xtremio-armeabi-v7a.apk',
      );
      expect(release.asset('xtremio-x86_64.apk'), isNull);
    });

    test('refuses what is not a published release with a version', () {
      for (final json in [
        latestJson(tag: 'nightly'),
        latestJson(tag: 'v0.2.0-rc.1'),
        latestJson(draft: true),
        latestJson(prerelease: true),
        <String, dynamic>{},
      ]) {
        expect(
          () => ReleaseInfo.fromGitHub(json),
          throwsFormatException,
          reason: '$json',
        );
      }
      expect(() => ReleaseInfo.fromGitHub([]), throwsFormatException);
    });
  });

  test('the APK is chosen by the device\'s first ABI', () {
    expect(apkAssetNameForAbi('arm64-v8a'), 'xtremio-arm64-v8a.apk');
    // A Chromecast with Google TV: 64-bit chip, 32-bit userspace.
    expect(apkAssetNameForAbi('armeabi-v7a'), 'xtremio-armeabi-v7a.apk');
    // The emulator: the release builds nothing for it.
    expect(apkAssetNameForAbi('x86_64'), isNull);
    expect(apkAssetNameForAbi('armeabi'), isNull);
  });

  test('release notes read as text, not as Markdown source', () {
    const markdown =
        '<!-- written by the release procedure -->\r\n'
        '## What changed\r\n'
        '\r\n'
        '\r\n'
        '* **Faster** start, see [the docs](https://example.com/d)\r\n'
        '- `make apk` stamps the _version_\r\n'
        '![logo](logo.png)\r\n'
        '\r\n';
    expect(
      releaseNotesText(markdown),
      'What changed\n'
      '\n'
      '• Faster start, see the docs\n'
      '• make apk stamps the version',
    );
  });

  test('an underscore inside a word is left alone', () {
    expect(releaseNotesText('set XTREMIO_VERSION'), 'set XTREMIO_VERSION');
  });
}
