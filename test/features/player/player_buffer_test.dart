import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/dev/dev_streams.dart';
import 'package:xtremio/features/downloads/download_labels.dart';
import 'package:xtremio/features/downloads/downloads_screen.dart';
import 'package:xtremio/features/player/player_screen.dart';
import 'package:xtremio/features/player/track_menus.dart';

import '../../support/fake_downloads_client.dart';
import '../../support/fake_prefs_client.dart';
import '../../support/player_harness.dart';

/// "Buffer ahead": the app-wide choice, the override for one playback, and
/// the option at the top of the scale that stops buffering and keeps the
/// file instead.
///
/// The window itself lives in the streaming server; all the app does is
/// name it: with the play it registers for a torrent's media id
/// (`MediaIds.setPlay`), and on a change through the server
/// (`MediaIds.setBuffer`), which re-opens nothing. So every assertion here
/// is about what the server was told, about the pin the last option takes,
/// or about what the viewer is told when the pin is refused. A torrent in a
/// build with no embedded server still names it on its URL (`?buffer=`)
/// and re-opens for a change; the tests of that re-open run there.
void main() {
  /// [AppPrefs] over a file that already holds [choice].
  Future<AppPrefs> storedPrefs(BufferAhead choice) async {
    final prefs = AppPrefs(
      client: FakePrefsClient({AppPrefs.bufferAheadKey: choice.stored}),
    );
    await prefs.load();
    return prefs;
  }

  /// The buffer the nth open of a torrent played by id carried.
  String? openedBuffer(PlayerHarness harness, int index) =>
      harness.mediaIds.plays[index].buffer;

  /// The buffer the server was last told for the stream on screen: the
  /// last change, or the one its open carried.
  String? bufferNow(PlayerHarness harness) => harness.mediaIds.buffers.isEmpty
      ? harness.mediaIds.plays.last.buffer
      : harness.mediaIds.buffers.last.$2;

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
    testWidgets('goes with the torrent\'s play to the server', (tester) async {
      useWideViewport(tester);
      final harness = PlayerHarness(
        prefs: await storedPrefs(BufferAhead.large),
      );
      await harness.pump(tester);

      expect(harness.engine.opened, hasLength(1));
      expect(harness.engine.opened.single.$1, mediaIdUrl('m1'));
      expect(harness.mediaIds.plays.single.id, 'm1');
      expect(openedBuffer(harness, 0), 'large');
    });

    testWidgets('has nothing to reach where there is no embedded server', (
      tester,
    ) async {
      // The window is the server's read-ahead; a build that started no
      // server plays the stream as the core published it.
      useWideViewport(tester);
      final harness = PlayerHarness(
        prefs: await storedPrefs(BufferAhead.large),
        embeddedServer: false,
      );
      await harness.pump(tester);

      expect(harness.mediaIds.registered, isEmpty);
      expect(harness.engine.opened.single.$1.queryParameters['buffer'], isNull);
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
    testWidgets('is told to the server, and re-opens nothing', (tester) async {
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

      // The server's reader takes the window at its next seek: the film
      // is not stopped for it, and the engine is not asked again.
      expect(harness.mediaIds.buffers, [('m1', 'maximum')]);
      expect(harness.engine.opened, hasLength(1));
      expect(harness.engines, hasLength(1));
      expect(loads(harness), loadsBefore);
    });

    testWidgets('re-opens nothing where there is no embedded server', (
      tester,
    ) async {
      useWideViewport(tester);
      final harness = PlayerHarness(
        prefs: await storedPrefs(BufferAhead.normal),
        embeddedServer: false,
      );
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 96));
      harness.engine.emitPosition(const Duration(minutes: 12));
      harness.engine.emitPlaying(true);
      await pumpEvents(tester);

      await openSheet(tester);
      await chooseBuffer(tester, BufferAhead.maximum);

      expect(harness.engine.opened, hasLength(1));
      expect(harness.mediaIds.buffers, isEmpty);
    });

    testWidgets('after a failure, is told and is not an attempt', (
      tester,
    ) async {
      // A torrent read by URL re-opened for a new window, and that re-open
      // was a new attempt that took the failure card down. Played by id
      // nothing re-opens, so the card stays: it is still what happened.
      useWideViewport(tester);
      final harness = PlayerHarness(
        prefs: await storedPrefs(BufferAhead.normal),
      );
      harness.torrentStats.response = const TorrentStats(
        phase: TorrentPhase.ready,
      );
      await harness.pump(tester);
      await tester.pump(PlayerScreen.torrentStatsInterval);
      harness.engine.emitError('Failed to recognize file format.');
      await pumpEvents(tester);
      expect(find.textContaining('Playback failed'), findsOneWidget);

      final opens = harness.engine.opened.length;
      await openSheet(tester);
      await chooseBuffer(tester, BufferAhead.maximum);
      expect(harness.engine.opened, hasLength(opens));
      expect(harness.mediaIds.buffers, [('m1', 'maximum')]);
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
      expect(bufferNow(first), 'large');

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
      expect(bufferNow(harness), 'maximum');
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
      expect(bufferNow(harness), 'maximum');
      // Once: the refusal falls back to the window the pin already asked
      // for (`wholeFile` and `maximum` share a wire), and nothing re-opens.
      expect(harness.mediaIds.buffers, [('m1', 'maximum')]);
      expect(harness.engine.opened, hasLength(1));
    });

    testWidgets('a direct stream is told by id, and nothing re-opens', (
      tester,
    ) async {
      // A link is played by id like a torrent, so the change goes to the
      // server the same way (which has a read-ahead to change only for a
      // torrent) -- and a re-open would only stop the picture.
      useWideViewport(tester);
      final harness = PlayerHarness(
        prefs: await storedPrefs(BufferAhead.normal),
        player: {
          'selected': {'stream': DevStreams.bigBuckBunnyHttp},
          'stream': {
            'type': 'Ready',
            'content': [
              {'streaming_url': DevStreams.bigBuckBunnyHttp['url']},
              DevStreams.bigBuckBunnyHttp,
            ],
          },
        },
        stream: DevStreams.bigBuckBunnyHttp,
      );
      await harness.pump(tester);
      harness.engine.emitDuration(const Duration(minutes: 10));
      harness.engine.emitPosition(const Duration(minutes: 2));
      await pumpEvents(tester);
      expect(harness.engine.opened, hasLength(1));

      await openSheet(tester);
      await chooseBuffer(tester, BufferAhead.maximum);
      expect(harness.engine.opened, hasLength(1));
      expect(harness.mediaIds.buffers, [('m1', 'maximum')]);
    });
  });
}
