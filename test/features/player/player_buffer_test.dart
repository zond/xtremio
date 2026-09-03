import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/downloads/download_labels.dart';
import 'package:xtremio/features/downloads/downloads_screen.dart';
import 'package:xtremio/features/player/track_menus.dart';

import '../../support/fake_downloads_client.dart';
import '../../support/fake_prefs_client.dart';
import '../../support/player_harness.dart';

/// "Buffer ahead": the app-wide choice, the override for one playback, and
/// the option at the top of the scale that stops buffering and keeps the
/// file instead.
///
/// The window itself lives in the streaming server; all the app does is
/// name it on the stream URL (`?buffer=`), which is why every assertion here
/// is about that URL, about the pin the last option takes, or about what the
/// viewer is told when the pin is refused.
void main() {
  /// [AppPrefs] over a file that already holds [choice].
  Future<AppPrefs> storedPrefs(BufferAhead choice) async {
    final prefs = AppPrefs(
      client: FakePrefsClient({AppPrefs.bufferAheadKey: choice.stored}),
    );
    await prefs.load();
    return prefs;
  }

  /// The `buffer=` value of the nth URL the engine was opened with.
  String? openedBuffer(PlayerHarness harness, int index) =>
      harness.engine.opened[index].$1.queryParameters['buffer'];

  /// How many `Load Player` actions have been dispatched: re-opening a
  /// stream must add none.
  int loads(PlayerHarness harness) => harness.core.dispatched
      .where((action) => action.action['action'] == 'Load')
      .length;

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Playback settings'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseBuffer(WidgetTester tester, BufferAhead choice) async {
    await tester.tap(find.byKey(PlayerSettingsSheet.bufferChipKey(choice)));
    await tester.pumpAndSettle();
  }

  group('the stored choice', () {
    testWidgets('reaches the stream URL', (tester) async {
      useWideViewport(tester);
      final harness = PlayerHarness(
        prefs: await storedPrefs(BufferAhead.large),
      );
      await harness.pump(tester);

      expect(harness.engine.opened, hasLength(1));
      expect(openedBuffer(harness, 0), 'large');
    });

    testWidgets('is normal when nothing was ever chosen', (tester) async {
      useWideViewport(tester);
      final harness = PlayerHarness(prefs: AppPrefs(client: FakePrefsClient()));
      await harness.pump(tester);

      expect(openedBuffer(harness, 0), 'normal');
    });

    testWidgets('survives a restart of the app', (tester) async {
      // The choice is the app's own preference, so a second AppPrefs over
      // the same file is what the next launch reads.
      final stored = FakePrefsClient();
      await AppPrefs(client: stored).setBufferAhead(BufferAhead.maximum);

      final restarted = AppPrefs(client: stored);
      await restarted.load();
      expect(restarted.bufferAhead, BufferAhead.maximum);

      useWideViewport(tester);
      final harness = PlayerHarness(prefs: restarted);
      await harness.pump(tester);
      expect(openedBuffer(harness, 0), 'maximum');
    });
  });

  group('the override for one playback', () {
    testWidgets('re-opens the stream where it is, without restarting it', (
      tester,
    ) async {
      useWideViewport(tester);
      final harness = PlayerHarness(
        prefs: await storedPrefs(BufferAhead.normal),
      );
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 96));
      harness.engine.emitPosition(const Duration(minutes: 12));
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);

      final loadsBefore = loads(harness);
      expect(loadsBefore, 1, reason: 'the playback was loaded once');
      await openSheet(tester);
      await chooseBuffer(tester, BufferAhead.maximum);

      // One more `open`, on the same engine, at the position it had
      // reached: the window only reaches libmpv through the URL, so the
      // stream is re-opened rather than the playback restarted. No second
      // `Load Player`, and no second engine.
      expect(harness.engine.opened, hasLength(2));
      expect(openedBuffer(harness, 1), 'maximum');
      expect(harness.engine.opened[1].$2, const Duration(minutes: 12));
      expect(harness.engines, hasLength(1));
      expect(loads(harness), loadsBefore);
    });

    testWidgets('reverts to the stored choice with the next playback', (
      tester,
    ) async {
      useWideViewport(tester);
      final prefs = await storedPrefs(BufferAhead.normal);
      final first = PlayerHarness(prefs: prefs);
      await first.pump(tester);
      await openSheet(tester);
      await chooseBuffer(tester, BufferAhead.large);
      expect(openedBuffer(first, 1), 'large');

      // A different player, over the same preferences: the override went
      // with the screen it was made on.
      final second = PlayerHarness(prefs: prefs);
      await second.pump(tester);
      expect(openedBuffer(second, 0), 'normal');
      expect(prefs.bufferAhead, BufferAhead.normal);
    });
  });

  group('keeping the whole file', () {
    testWidgets('pins a download, and it is in the Downloads list', (
      tester,
    ) async {
      useWideViewport(tester);
      final downloads = FakeDownloadsClient();
      final harness = PlayerHarness(
        prefs: await storedPrefs(BufferAhead.normal),
        downloads: downloads,
      );
      await harness.pump(tester);

      await openSheet(tester);
      await chooseBuffer(tester, BufferAhead.wholeFile);

      // The existing offline-download mechanism, not a second one: one
      // `add`, carrying the stream that is playing.
      expect(downloads.added, hasLength(1));
      expect(downloads.added.single.metaId, 'tt0063350');
      expect(
        downloads.added.single.stream.infoHash,
        '11ea02584fa6351956f35671962ab46354d99060',
      );
      // And it is stated as storage, not as buffering.
      expect(find.textContaining('Downloads'), findsWidgets);

      await tester.tap(find.text(kDownloadsScreenTooltip));
      await tester.pumpAndSettle();
      expect(find.byType(DownloadsScreen), findsOneWidget);
      expect(find.text('Night of the Living Dead'), findsOneWidget);
    });

    testWidgets('a device with no room is told, not silently filled', (
      tester,
    ) async {
      useWideViewport(tester);
      final downloads = FakeDownloadsClient()
        ..onAdd = (request) => DownloadAddResult.fromJson({
          'ok': false,
          'key': request.key,
          'error': {
            'kind': 'insufficientSpace',
            'required': 4000000000,
            'available': 1000000000,
            'margin': 524288000,
            'message': 'not enough free space for this download',
          },
        });
      final harness = PlayerHarness(
        prefs: await storedPrefs(BufferAhead.normal),
        downloads: downloads,
      );
      await harness.pump(tester);

      await openSheet(tester);
      await chooseBuffer(tester, BufferAhead.wholeFile);

      expect(
        find.textContaining(
          'not enough free space for this download '
          '(needs 4.0 GB, 1.0 GB free)',
        ),
        findsOneWidget,
      );
      // The refusal leaves the viewer on the widest window that needs no
      // room, and says so rather than pretending the choice took.
      expect(
        find.textContaining('Buffering as far ahead as possible instead.'),
        findsOneWidget,
      );
      expect(
        openedBuffer(harness, harness.engine.opened.length - 1),
        'maximum',
      );
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(
                PlayerSettingsSheet.bufferChipKey(BufferAhead.maximum),
              ),
            )
            .selected,
        isTrue,
      );
    });

    testWidgets('with no downloads client above, it says so and buffers', (
      tester,
    ) async {
      useWideViewport(tester);
      final harness = PlayerHarness(
        prefs: await storedPrefs(BufferAhead.normal),
      );
      await harness.pump(tester);

      await openSheet(tester);
      await chooseBuffer(tester, BufferAhead.wholeFile);

      expect(
        find.textContaining('This stream cannot be kept on the device.'),
        findsOneWidget,
      );
      expect(
        openedBuffer(harness, harness.engine.opened.length - 1),
        'maximum',
      );
    });
  });
}
