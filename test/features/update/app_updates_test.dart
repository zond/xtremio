import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/update/app_updates.dart';
import 'package:xtremio/features/update/install_room.dart';
import 'package:xtremio/features/update/release_version.dart';

import '../../support/diagnostics_capture.dart';
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
      expect(cache.clears, 0, reason: 'and never clears it either');
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

  group('making room', () {
    /// A 4 GB volume with [free] bytes free: its reserve is 200 MB, so a
    /// 1 kB APK needs 200,003,000 bytes before the download.
    DataVolumeRoom fourGb(int free) =>
        DataVolumeRoom(freeBytes: free, totalBytes: 4000000000);

    test('a device with room is measured and left alone', () async {
      final lines = captureDiagnostics();
      final cache = FakeServerCache(cleanResult: cleanedNothing);
      final updates = fakeUpdates(
        cache: cache,
        installer: FakeApkInstaller(volume: fourGb(1000000000)),
      );
      final room = await updates.makeRoom(apkBytes: 1000, downloaded: false);
      expect(room!.fits, isTrue);
      expect((cache.cleans, cache.clears), (0, 0));
      expect(lines, [
        'info update room before the download: 1000000000 bytes free, '
            '200003000 needed',
      ]);
    });

    test('the gentle clean that makes room is the last step', () async {
      final lines = captureDiagnostics();
      final installer = FakeApkInstaller(volume: fourGb(150000000));
      final cache = FakeServerCache(
        cleanResult: cleanedSome(400000000),
        onClean: () => installer.volume = fourGb(550000000),
      );
      final steps = <RoomStep>[];
      final room = await fakeUpdates(
        cache: cache,
        installer: installer,
      ).makeRoom(apkBytes: 1000, downloaded: true, onStep: steps.add);
      expect(room!.fits, isTrue);
      expect((cache.cleans, cache.clears), (1, 0));
      expect(steps, [RoomStep.measuring, RoomStep.cleaning]);
      expect(lines, [
        'info update room before the install: 150000000 bytes free, '
            '200002000 needed',
        'info update after the cache clean: 150000000 bytes free before, '
            '550000000 after, 200002000 needed',
      ]);
    });

    test('a clean that frees too little is followed by the full clear, '
        'which makes room', () async {
      final lines = captureDiagnostics();
      final installer = FakeApkInstaller(volume: fourGb(150000000));
      final cache = FakeServerCache(
        cleanResult: cleanedSome(10000000),
        onClean: () => installer.volume = fourGb(160000000),
        clearResult: const CacheClearReport(
          freed: 900000000,
          stopped: 1,
          deleted: 40,
          total: 0,
        ),
        onClear: () => installer.volume = fourGb(1060000000),
      );
      final steps = <RoomStep>[];
      final room = await fakeUpdates(
        cache: cache,
        installer: installer,
      ).makeRoom(apkBytes: 1000, downloaded: false, onStep: steps.add);
      expect(room!.fits, isTrue);
      expect((cache.cleans, cache.clears), (1, 1));
      expect(steps, [RoomStep.measuring, RoomStep.cleaning, RoomStep.clearing]);
      expect(lines, [
        'info update room before the download: 150000000 bytes free, '
            '200003000 needed',
        'info update after the cache clean: 150000000 bytes free before, '
            '160000000 after, 200003000 needed',
        'info update after the cache clear: 160000000 bytes free before, '
            '1060000000 after, 200003000 needed',
      ]);
    });

    test('when both free too little the room says what was cleared', () async {
      final cache = FakeServerCache(
        cleanResult: cleanedSome(10000000),
        clearResult: const CacheClearReport(
          freed: 90000000,
          stopped: 1,
          deleted: 40,
          total: 0,
        ),
      );
      final room = await fakeUpdates(
        cache: cache,
        installer: FakeApkInstaller(volume: fourGb(150000000)),
      ).makeRoom(apkBytes: 1000, downloaded: false);
      expect(room!.fits, isFalse);
      expect(room.cleared, isTrue);
      expect(room.freedBytes, 100000000, reason: 'the clean and the clear');
      expect(
        room.shortText,
        'The update needs 200 MB free on this device and there is 150 MB. '
        'Streams were stopped and the torrent cache cleared, which freed '
        '100 MB; what it still holds is the downloads you kept, which Server '
        'storage shows.',
      );
    });

    test('a clear that does not answer is said as such', () async {
      final lines = captureDiagnostics();
      final cache = FakeServerCache(
        cleanResult: cleanedNothing,
        clearError: StateError('server not running'),
      );
      final room = await fakeUpdates(
        cache: cache,
        installer: FakeApkInstaller(volume: fourGb(150000000)),
      ).makeRoom(apkBytes: 1000, downloaded: false);
      expect(room!.freedBytes, isNull);
      expect(
        room.shortText,
        'The update needs 200 MB free on this device and there is 150 MB. '
        'The torrent cache could not be cleared; Server storage shows what '
        'it holds.',
      );
      expect(
        lines,
        contains('warn update the cache clear did not answer (StateError)'),
      );
    });
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
