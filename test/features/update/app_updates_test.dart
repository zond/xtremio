import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/update/app_updates.dart';
import 'package:xtremio/features/update/release_version.dart';

import '../../support/fake_prefs_client.dart';
import '../../support/fake_server_cache.dart';
import '../../support/fake_updates.dart';

void main() {
  final noon = DateTime.utc(2026, 10, 3, 12);

  group('the daily look', () {
    test('is due once a day, and when the clock went backwards', () {
      expect(AppUpdates.isDue(null, noon), isTrue);
      expect(
        AppUpdates.isDue(
          noon,
          noon.add(const Duration(hours: 23, minutes: 59)),
        ),
        isFalse,
      );
      expect(AppUpdates.isDue(noon, noon.add(const Duration(days: 1))), isTrue);
      // A clock set back must not leave the look stuck in its future.
      expect(
        AppUpdates.isDue(noon, noon.subtract(const Duration(minutes: 1))),
        isTrue,
      );
    });

    test('never reclaims the cache, even when it finds an update', () async {
      final cache = FakeServerCache(cleanResult: cleanedNothing);
      final updates = fakeUpdates(cache: cache);
      expect(await updates.checkIfDue(), isA<UpdateAvailable>());
      expect(await updates.check(), isA<UpdateAvailable>());
      expect(cache.cleans, 0);
    });

    test('asks GitHub once a day, and remembers it asked', () async {
      final client = FakePrefsClient();
      final prefs = AppPrefs(client: client);
      final source = FakeReleaseSource(release: sampleRelease());
      var now = noon;
      final updates = fakeUpdates(
        prefs: prefs,
        source: source,
        clock: () => now,
      );

      expect(await updates.checkIfDue(), isA<UpdateAvailable>());
      expect(source.asked, 1);
      expect(
        client.stored[AppPrefs.updateCheckedAtKey],
        noon.millisecondsSinceEpoch,
      );

      now = noon.add(const Duration(hours: 20));
      expect(await updates.checkIfDue(), isA<UpdateNotChecked>());
      expect(source.asked, 1);

      // And across a restart: a new start reads the time back.
      final restarted = AppPrefs(client: client);
      await restarted.load();
      final again = fakeUpdates(
        prefs: restarted,
        source: source,
        clock: () => now,
      );
      expect(await again.checkIfDue(), isA<UpdateNotChecked>());
      expect(source.asked, 1);

      now = noon.add(const Duration(days: 1));
      expect(await again.checkIfDue(), isA<UpdateAvailable>());
      expect(source.asked, 2);
    });

    test('a failed look counts too: the rate limit counts it', () async {
      final source = FakeReleaseSource(
        error: const HttpException('GitHub answered 500'),
      );
      final updates = fakeUpdates(source: source);
      final result = await updates.checkIfDue();
      expect(
        result,
        isA<UpdateCheckFailed>().having(
          (r) => r.message,
          'message',
          'GitHub answered 500',
        ),
      );
      expect(await updates.checkIfDue(), isA<UpdateNotChecked>());
      expect(source.asked, 1);
    });

    test(
      'a build that is not a stamped release never looks by itself',
      () async {
        for (final identity in [
          debugBuild,
          const BuildIdentity(version: '', commit: '', isReleaseBuild: true),
          const BuildIdentity(
            version: '0.1.13+1',
            commit: 'cda9225-dirty',
            isReleaseBuild: true,
          ),
        ]) {
          final source = FakeReleaseSource(release: sampleRelease());
          final updates = fakeUpdates(identity: identity, source: source);
          expect(await updates.checkIfDue(), isA<UpdateNotChecked>());
          expect(
            source.asked,
            0,
            reason: '${identity.version} ${identity.commit}',
          );
        }
      },
    );

    test('a skipped release is not offered again; a newer one is', () async {
      final prefs = AppPrefs.inMemory();
      final source = FakeReleaseSource(release: sampleRelease());
      var now = noon;
      final updates = fakeUpdates(
        prefs: prefs,
        source: source,
        clock: () => now,
      );
      await updates.skip(sampleRelease());
      expect(prefs.updateSkippedTag, 'v0.1.14');

      expect(await updates.checkIfDue(), isA<UpdateUpToDate>());

      now = now.add(const Duration(days: 1));
      source.release = sampleRelease(tag: 'v0.1.15');
      expect(
        await updates.checkIfDue(),
        isA<UpdateAvailable>().having((r) => r.release.tag, 'tag', 'v0.1.15'),
      );
    });
  });

  test('a skip survives a restart', () async {
    final client = FakePrefsClient();
    await fakeUpdates(prefs: AppPrefs(client: client)).skip(sampleRelease());
    final restarted = AppPrefs(client: client);
    await restarted.load();
    expect(restarted.updateSkippedTag, 'v0.1.14');
    final source = FakeReleaseSource(release: sampleRelease());
    expect(
      await fakeUpdates(prefs: restarted, source: source).checkIfDue(),
      isA<UpdateUpToDate>(),
    );
  });

  group('Check for updates', () {
    test('asks whenever it is pressed, the skipped release included', () async {
      final prefs = AppPrefs.inMemory();
      final source = FakeReleaseSource(release: sampleRelease());
      final updates = fakeUpdates(prefs: prefs, source: source);
      await updates.skip(sampleRelease());
      expect(await updates.check(), isA<UpdateAvailable>());
      expect(await updates.check(), isA<UpdateAvailable>());
      expect(source.asked, 2);
    });

    test('says up to date, and unversioned, too', () async {
      final source = FakeReleaseSource(release: sampleRelease(tag: 'v0.1.13'));
      expect(await fakeUpdates(source: source).check(), isA<UpdateUpToDate>());
      expect(
        await fakeUpdates(
          source: source,
          identity: const BuildIdentity(
            version: '',
            commit: '',
            isReleaseBuild: false,
          ),
        ).check(),
        isA<UpdateUnversioned>(),
      );
    });

    test('works in a debug build, which installs nothing', () async {
      final updates = fakeUpdates(identity: debugBuild);
      expect(await updates.check(), isA<UpdateAvailable>());
      expect(updates.canInstall, isFalse);
      // A desktop release build points at the page as well.
      expect(fakeUpdates(installsHere: false).canInstall, isFalse);
      expect(fakeUpdates().canInstall, isTrue);
    });
  });

  test('a look sweeps away downloads but the offered release\'s', () async {
    final dir = await Directory.systemTemp.createTemp('xtremio-sweep-');
    addTearDown(() => dir.delete(recursive: true));
    final old = File('${dir.path}/xtremio-v0.1.13-arm64-v8a.apk')
      ..writeAsStringSync('installed already');
    final part = File('${dir.path}/xtremio-v0.1.14-arm64-v8a.apk.part')
      ..writeAsStringSync('half');
    final updates = AppUpdates(
      prefs: AppPrefs.inMemory(),
      identity: releaseBuild,
      source: FakeReleaseSource(release: sampleRelease()),
      downloadsDirectory: () async => dir,
      clock: () => noon,
      installsHere: true,
    );
    await updates.check();
    await pumpEventQueueUntil(() => !old.existsSync());
    expect(old.existsSync(), isFalse);
    expect(part.existsSync(), isTrue);
  });
}

/// Lets the sweep [AppUpdates.check] starts and does not wait for finish,
/// with a deadline rather than a sleep.
Future<void> pumpEventQueueUntil(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(Duration.zero);
  }
}
