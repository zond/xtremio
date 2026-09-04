import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/player/playback_engine.dart';

import '../support/fake_core_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';

const String movieId = 'tt0063350';
const String addonUrl = 'https://alpha.example/manifest.json';

/// The two halves of `👤` (U+1F464). An addon that truncates a name to a
/// fixed number of code units sends one of these on its own, and a `Text`
/// handed that string throws `string is not well-formed UTF-16` out of the
/// text engine -- which takes the whole row down, not just the character.
const String highHalf = '\uD83D';
const String lowHalf = '\uDC64';

Map<String, dynamic> streams(List<Map<String, dynamic>> list) => [
  {
    'request': {
      'base': addonUrl,
      'path': {
        'resource': 'stream',
        'type': 'movie',
        'id': movieId,
        'extra': <Object>[],
      },
    },
    'content': {'type': 'Ready', 'content': list},
  },
].first;

void main() {
  /// Grouped, not the sources list's sectioned default: this file is
  /// about text rendering safety on a stream row, not resolution
  /// sections, and the fixture's one release needs no section opened to
  /// be on screen. `AppPrefs.inMemory()` persists nothing, so the
  /// setter's write below completes synchronously (nothing to await) and
  /// the value is already in place by the time this returns.
  AppPrefs groupedPrefs() {
    final prefs = AppPrefs.inMemory();
    unawaited(prefs.setStreamsSectioned(false));
    return prefs;
  }

  Widget harness(FakeCoreClient core) => CoreScope(
    client: core,
    child: PrefsScope(
      prefs: groupedPrefs(),
      child: PlaybackScope(
        createEngine: FakePlaybackEngine.new,
        torrentStats: FakeTorrentStatsClient(),
        child: const MaterialApp(
          home: MetaDetailsScreen(type: 'movie', id: movieId),
        ),
      ),
    ),
  );

  FakeCoreClient coreWith(List<Map<String, dynamic>> list) => FakeCoreClient(
    state: {
      CoreField.metaDetails: loadMetaDetailsFixture()
        ..['streams'] = [streams(list)],
      CoreField.ctx: loadCtxLoggedOutFixture(),
    },
  );

  Future<void> pump(WidgetTester tester, FakeCoreClient core) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(core));
    await tester.pumpAndSettle();
  }

  testWidgets('a name and a description with half a character in them still '
      'draw a row', (tester) async {
    await pump(
      tester,
      coreWith([
        {
          'infoHash': 'a' * 40,
          'name': 'Alpha$highHalf 1080p',
          'description': 'Alpha.1080p.mkv$lowHalf\n👤 42 💾 1.51 GB',
        },
      ]),
    );

    // The row is there, the half character is not, and nothing threw: a
    // rendered `<?>` (or an exception) is what this is about.
    expect(tester.takeException(), isNull);
    expect(find.text('Alpha 1080p'), findsOneWidget);
    expect(find.text('42 seeders'), findsOneWidget);
    expect(find.text('1.51 GB'), findsOneWidget);
  });

  testWidgets('an emoji in a title that is too long to fit survives whole', (
    tester,
  ) async {
    // Long enough that the tile has to shorten it, with the emoji where a
    // truncation by code units would land between its two halves.
    final title = 'Torrentio 👤 ${'the same very long release name ' * 4}';
    await pump(
      tester,
      coreWith([
        {'infoHash': 'b' * 40, 'name': title},
      ]),
    );

    expect(tester.takeException(), isNull);
    final drawn = tester.widget<Text>(find.text(title));
    // The string reaches the widget entire; the *painted* line is what is
    // shortened, by the widget, which cannot cut a character in half.
    expect(drawn.data, title);
    expect(drawn.data, contains('👤'));
    expect(drawn.maxLines, isNotNull);
    expect(drawn.overflow, TextOverflow.ellipsis);
  });

  testWidgets('a plain ASCII release is untouched', (tester) async {
    await pump(
      tester,
      coreWith([
        {
          'infoHash': 'c' * 40,
          'name': 'Alpha 720p',
          'description': 'Alpha.720p.mkv',
        },
      ]),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Alpha 720p'), findsOneWidget);
    expect(find.text('Alpha.720p.mkv'), findsOneWidget);
  });
}
