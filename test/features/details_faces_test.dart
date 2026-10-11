import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/face_buttons.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/tv_meta_header.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../support/fake_core_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_prefs_client.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fake_xervice.dart';
import '../support/fixtures.dart';
import '../support/tv.dart';

/// The happy and sad faces beside the bookmark: one replaces the other,
/// pressing the one that is on takes it off, the mark is kept on the device
/// and, where the app has an account to sync with, sent to it -- and on a
/// television both are stops the remote reaches from the bookmark.
void main() {
  const movieId = 'tt0063350';
  const key = 'stremio-session-key-abcdef0123456789';

  late AppPrefs prefs;

  /// Made inside each test, so its writes run in the test's own zone.
  Future<void> freshPrefs() async {
    prefs = AppPrefs(client: FakePrefsClient({'streamsSectioned': false}));
    addTearDown(prefs.dispose);
    await prefs.load();
  }

  Future<void> mount(
    WidgetTester tester, {
    DeviceProfile device = DeviceProfile.fallback,
    FacesSync? sync,
    bool prefsReady = false,
  }) async {
    if (!prefsReady) await freshPrefs();
    if (device.isTv) {
      useScreen(tester, tvSize);
    } else {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    final screen = DeviceScope(
      profile: device,
      child: CoreScope(
        client: FakeCoreClient(
          state: {CoreField.metaDetails: loadMetaDetailsFixture()},
        ),
        child: PrefsScope(
          prefs: prefs,
          child: PlaybackScope(
            createEngine: FakePlaybackEngine.new,
            torrentStats: FakeTorrentStatsClient(),
            child: MaterialApp(
              theme: XtremioApp.themeFor(
                isTv: device.isTv,
                emphasis: FocusEmphasis.bold,
              ),
              builder: device.isTv ? TvMediaQuery.builder : null,
              home: const MetaDetailsScreen(type: 'movie', id: movieId),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      sync == null
          ? screen
          : XerviceScope(
              faces: sync,
              driveVault: DriveVault(
                identity: sync.identity,
                account: DriveAccount(prefs: prefs),
              ),
              child: screen,
            ),
    );
    await tester.pumpAndSettle();
  }

  Finder button(String tooltip) => find.byTooltip(tooltip);

  bool isOn(WidgetTester tester, String tooltip) =>
      tester
          .widget<IconButton>(
            find.ancestor(
              of: button(tooltip),
              matching: find.byType(IconButton),
            ),
          )
          .isSelected ??
      false;

  testWidgets('one face replaces the other, and pressing it again clears it', (
    tester,
  ) async {
    await mount(tester);
    expect(button(FaceButtons.likeTooltip), findsOneWidget);
    expect(button(FaceButtons.dislikeTooltip), findsOneWidget);
    expect(isOn(tester, FaceButtons.likeTooltip), isFalse);

    await tester.tap(button(FaceButtons.likeTooltip));
    await tester.pumpAndSettle();
    expect(prefs.faces.of(movieId), Face.like);
    expect(isOn(tester, FaceButtons.likedTooltip), isTrue);
    expect(isOn(tester, FaceButtons.dislikeTooltip), isFalse);

    await tester.tap(button(FaceButtons.dislikeTooltip));
    await tester.pumpAndSettle();
    expect(prefs.faces.of(movieId), Face.dislike);
    expect(button(FaceButtons.likeTooltip), findsOneWidget);
    expect(isOn(tester, FaceButtons.dislikedTooltip), isTrue);

    await tester.tap(button(FaceButtons.dislikedTooltip));
    await tester.pumpAndSettle();
    expect(prefs.faces.of(movieId), isNull);
    expect(prefs.faces.marks[movieId]?.face, isNull);
    expect(
      prefs.faces.marks.containsKey(movieId),
      isTrue,
      reason: 'a cleared face is a mark, so a merge cannot bring it back',
    );
    expect(isOn(tester, FaceButtons.dislikeTooltip), isFalse);
  });

  testWidgets('a title dismissed from For you shows neither face on, and a '
      'like replaces the dismissal', (tester) async {
    await freshPrefs();
    await prefs.setFaces(
      Faces.empty.marking(movieId, Face.dismissed, DateTime.utc(2026)),
    );
    await mount(tester, prefsReady: true);
    expect(isOn(tester, FaceButtons.likeTooltip), isFalse);
    expect(isOn(tester, FaceButtons.dislikeTooltip), isFalse);
    await tester.tap(button(FaceButtons.likeTooltip));
    await tester.pumpAndSettle();
    expect(prefs.faces.of(movieId), Face.like);
  });

  testWidgets('a press is sent to the account where the app has one', (
    tester,
  ) async {
    final store = FakeFacesStore();
    final service = FakeXervice(accounts: {key: 'user-a'})
      ..routes = (request, user) =>
          store.routes(request, user) ?? const XerviceAnswer(404);
    await freshPrefs();
    prefs.setFacesOwner('user-a');
    final sync = FacesSync(
      prefs: prefs,
      identity: XerviceIdentity(http: service, authKey: () => key),
    );
    await mount(tester, sync: sync, prefsReady: true);
    await tester.tap(button(FaceButtons.dislikeTooltip));
    await tester.pumpAndSettle();
    expect(store.byUser['user-a']!.of(movieId), Face.dislike);
  });

  testWidgets('on a television both faces are stops right of the bookmark', (
    tester,
  ) async {
    await mount(tester, device: tv);
    for (var i = 0; i < 8 && !focusIn<TvMetaHeader>(); i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    // Onto the bookmark, from wherever the header put the remote.
    for (var i = 0; i < 3 && focusedTooltip() != TvMetaHeader.addTooltip; i++) {
      await press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focusedTooltip(), TvMetaHeader.addTooltip);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTooltip(), FaceButtons.likeTooltip);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTooltip(), FaceButtons.dislikeTooltip);

    await press(tester, LogicalKeyboardKey.select);
    expect(prefs.faces.of(movieId), Face.dislike);
    expect(focusedTooltip(), FaceButtons.dislikedTooltip);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTooltip(), FaceButtons.likeTooltip);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTooltip(), TvMetaHeader.addTooltip);
    // And left again is the text column, as it always was.
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIn<TvMetaHeader>(), isTrue);
    expect(focusedTooltip(), isNot(FaceButtons.likeTooltip));
    expect(focusedTooltip(), isNot(TvMetaHeader.addTooltip));
  });

  testWidgets('left from a bookmark the remote was put on goes to the '
      'column, never to a face', (tester) async {
    await mount(tester, device: tv);
    final bookmark = FocusManager.instance.rootScope.descendants.firstWhere(
      (node) =>
          node.context?.findAncestorWidgetOfExactType<Tooltip>()?.message ==
          TvMetaHeader.addTooltip,
    );
    bookmark.requestFocus();
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIn<TvMetaHeader>(), isTrue);
    expect(
      focusedTooltip(),
      isNot(anyOf(FaceButtons.likeTooltip, FaceButtons.dislikeTooltip)),
    );
    expect(focusedTooltip(), isNot(TvMetaHeader.addTooltip));
  });

  test('pressing the face that is on clears it; the other replaces it', () {
    expect(FaceButtons.after(null, Face.like), Face.like);
    expect(FaceButtons.after(Face.like, Face.like), isNull);
    expect(FaceButtons.after(Face.like, Face.dislike), Face.dislike);
    expect(FaceButtons.after(Face.dismissed, Face.dislike), Face.dislike);
  });
}
