import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/tv_meta_header.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../../support/fake_core_client.dart';
import '../../support/fake_playback_engine.dart';
import '../../support/fake_torrent_stats_client.dart';
import '../../support/fixtures.dart';
import '../../support/tv.dart';

/// The plot of a title, on a panel the viewer cannot point at.
///
/// The header clips the description to a couple of lines, which is right:
/// a viewer three metres away came to the screen to pick something, not to
/// read. What was wrong is that the ellipsis was the end of it -- plain
/// text, no focus stop, no key -- so the rest of the plot could not be
/// reached at all with a remote. Reported from a Chromecast.
///
/// So the four things this has to be are checked on descriptions of a
/// known length rather than on whatever a recorded fixture happens to
/// wrap to: the remote stops on it, it is dressed as something that can be
/// pressed rather than as something to read, select unfolds it and folds
/// it back without the remote moving, and an unfolded plot longer than the
/// panel can be read to its last line.
const String movieId = 'tt0063350';
const String seriesId = 'tt0903747';

/// A plot that runs past two lines on a 1280 panel, and not much past: the
/// ordinary case, where unfolding it still fits on the screen.
final String longPlot =
    'A ragtag group of Pennsylvanians barricade '
    'themselves in an old farmhouse to remain safe from a horde of '
    'flesh-eating ghouls that are ravaging the East coast of the United '
    'States. ${'The radio says the dead are walking and nobody knows why. ' * 4}';

/// A plot taller than a 720p panel once it is unfolded.
final String tallPlot =
    'A ragtag group of Pennsylvanians barricade '
    'themselves in an old farmhouse. '
    '${'The dead are walking, the radio is repeating itself, and the '
            'television has nothing new to say about any of it. ' * 30}';

/// Two lines' worth and no more: nothing behind the ellipsis, because
/// there is no ellipsis.
const String shortPlot = 'Ghouls walk; a farmhouse holds.';

void main() {
  AppPrefs flatPrefs() {
    final prefs = AppPrefs.inMemory();
    unawaited(prefs.setStreamsSectioned(false));
    unawaited(prefs.setFocusEmphasis(FocusEmphasis.bold));
    return prefs;
  }

  /// A fixture with a description of this test's choosing: the film, or
  /// the series, whose screen carries four rungs of episodes and sources
  /// under the header and so is a good deal taller than the panel.
  Map<String, dynamic> saying(String description, {bool series = false}) {
    final fixture = series
        ? loadSeriesEpisodeMetaDetailsFixture()
        : loadMetaDetailsFixture();
    final content =
        ((fixture['metaItems'] as List<dynamic>).first
                as Map<String, dynamic>)['content']['content']
            as Map<String, dynamic>;
    content['description'] = description;
    return fixture;
  }

  /// The details screen under a television, in the theme the app would
  /// have given it -- the floor (`FocusTheme`) is half of what says this
  /// block can be pressed, and a bare [MaterialApp] does not have it.
  Future<void> pump(
    WidgetTester tester,
    String description, {
    DeviceProfile device = tv,
    Size size = tvSize,
    bool series = false,
  }) async {
    useScreen(tester, size);
    final prefs = flatPrefs();
    addTearDown(prefs.dispose);
    await tester.pumpWidget(
      DeviceScope(
        profile: device,
        child: CoreScope(
          client: FakeCoreClient(
            state: {CoreField.metaDetails: saying(description, series: series)},
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
                home: MetaDetailsScreen(
                  type: series ? 'series' : 'movie',
                  id: series ? seriesId : movieId,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Walks up the ladder into the header, and then left onto the
  /// description.
  ///
  /// Up lands on the bookmark, which is where it landed before there was
  /// anything else in the header to land on: the row hands the remote to
  /// its first stop in reading order and the bookmark is drawn at the top
  /// of it. The description is the wide block under the facts, so it is
  /// the bookmark's left-hand neighbour.
  Future<void> upToTheDescription(WidgetTester tester) async {
    for (var i = 0; i < 8 && !focusIn<TvMetaHeader>(); i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    expect(
      focusIn<TvMetaHeader>(),
      isTrue,
      reason: 'the remote never reached the header',
    );
    if (!focusIn<TvDescription>()) {
      await press(tester, LogicalKeyboardKey.arrowLeft);
    }
    expect(
      focusIn<TvDescription>(),
      isTrue,
      reason: 'the remote never reached the description',
    );
  }

  /// The `Text` the description is drawn with.
  Text words(WidgetTester tester) => tester.widget<Text>(
    find.descendant(
      of: find.byType(TvDescription),
      matching: find.byType(Text),
    ),
  );

  /// How tall the description is drawn right now.
  double height(WidgetTester tester) =>
      tester.getRect(find.byType(TvDescription)).height;

  testWidgets('the remote stops on a description there is more of', (
    tester,
  ) async {
    await pump(tester, longPlot);

    await upToTheDescription(tester);

    // What this app draws on a control the remote is standing on: the ring
    // put on by hand, because this is over a darkened backdrop, and the
    // floor's near-white fill under it because the ink here is Material's.
    // A [Readout] -- the same block of words with nothing behind select --
    // wears the ring alone, and the fill is the difference a viewer reads.
    expect(focusMarks(), {FocusMark.ring, FocusMark.fill});
  });

  testWidgets('and says the same thing to a screen reader: a button, not a '
      'block to read', (tester) async {
    await pump(tester, longPlot);
    final handle = tester.ensureSemantics();

    await upToTheDescription(tester);

    // Asked at the words, so what answers is the node the block's own
    // [Semantics] and its focus put together.
    final semantics = tester.getSemantics(find.text(longPlot)).flagsCollection;
    expect(semantics.isFocused, Tristate.isTrue);
    expect(semantics.isButton, isTrue);
    handle.dispose();
  });

  testWidgets('a description that already fits is not a stop: select on it '
      'would do nothing', (tester) async {
    await pump(tester, shortPlot);

    expect(find.text(shortPlot), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(TvDescription),
        matching: find.byType(Focus),
      ),
      findsNothing,
      reason:
          'a ring on a block whose select does nothing is a lie, and on a '
          'remote it is also a press spent walking past it',
    );

    // And the walk is the one it always was: up from the rungs lands on
    // the bookmark, and there is nothing beside it to land on.
    for (var i = 0; i < 8 && !focusIn<TvMetaHeader>(); i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    expect(focusedTooltip(), TvMetaHeader.addTooltip);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIn<TvDescription>(), isFalse);
  });

  testWidgets('select unfolds it, and select again folds it back', (
    tester,
  ) async {
    await pump(tester, longPlot);
    await upToTheDescription(tester);
    final clipped = height(tester);
    expect(words(tester).maxLines, TvMetaHeader.descriptionLines);
    expect(words(tester).overflow, TextOverflow.ellipsis);

    await press(tester, LogicalKeyboardKey.select);

    // Nothing is clipped and nothing is ellipsised: the whole plot is on
    // the panel, which is the press the viewer made.
    expect(words(tester).maxLines, isNull);
    expect(words(tester).overflow, isNot(TextOverflow.ellipsis));
    expect(height(tester), greaterThan(clipped));

    await press(tester, LogicalKeyboardKey.select);

    expect(words(tester).maxLines, TvMetaHeader.descriptionLines);
    expect(height(tester), clipped);
  });

  testWidgets('and select unfolds it when the key comes up, not when it '
      'goes down', (tester) async {
    // What every stop in this app does with select, and what Android does:
    // a control activates on release, and a held key is a hold rather than
    // a stream of activations. Material's own shortcut fires on the way
    // down and again on every repeat, which on a key somebody is leaning
    // on is a plot flapping open and shut.
    await pump(tester, longPlot);
    await upToTheDescription(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(words(tester).maxLines, TvMetaHeader.descriptionLines);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(words(tester).maxLines, isNull);
  });

  testWidgets('and the remote is left where it was pressed, both times', (
    tester,
  ) async {
    // Expanding must not move the remote off what it is on, and collapsing
    // must not leave it on something that is no longer drawn. The stop is
    // one node either side of the toggle, which is what makes both true.
    await pump(tester, longPlot);
    await upToTheDescription(tester);
    final node = FocusManager.instance.primaryFocus;

    await press(tester, LogicalKeyboardKey.select);
    expect(focusIn<TvDescription>(), isTrue);
    expect(FocusManager.instance.primaryFocus, same(node));

    await press(tester, LogicalKeyboardKey.select);
    expect(focusIn<TvDescription>(), isTrue);
    expect(FocusManager.instance.primaryFocus, same(node));
    expect(
      tester.getRect(find.byType(TvDescription)).top,
      lessThan(tvSize.height),
      reason:
          'and standing on it with it off the screen is the same dead '
          'end as standing on nothing',
    );
  });

  testWidgets('one longer than the panel is walked to its last line', (
    tester,
  ) async {
    // The same bug in a new place: unfolding a plot that runs off the
    // bottom and then being unable to read the end of it is exactly what
    // the ellipsis was. [ReadableBlock] is what walks it, a part-screenful
    // per press, and lets the D-pad go once there is none of it left.
    await pump(tester, tallPlot);
    await upToTheDescription(tester);
    await press(tester, LogicalKeyboardKey.select);

    final block = find.byType(TvDescription);
    expect(
      tester.getRect(block).bottom,
      greaterThan(tvSize.height),
      reason: 'this plot does not fit on the panel unfolded',
    );
    expect(
      tester.getRect(block).top,
      greaterThanOrEqualTo(-0.5),
      reason: 'and it is read from its first line, not its last',
    );

    for (
      var presses = 0;
      presses < 8 && tester.getRect(block).bottom > tvSize.height + 0.5;
      presses++
    ) {
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(
        focusIn<TvDescription>(),
        isTrue,
        reason: 'the walk keeps the remote on the plot until it is read',
      );
    }
    expect(
      tester.getRect(block).bottom,
      lessThanOrEqualTo(tvSize.height + 0.5),
      reason: 'every line of it has been on the screen',
    );

    // And then it lets go: a block that kept the down key for ever would
    // be worse than one that could not be reached.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<TvDescription>(), isFalse);
  });

  testWidgets('and folding it back brings the header back with it', (
    tester,
  ) async {
    // Collapsing must not leave the remote standing on something that is
    // no longer drawn. Walking down a plot this long scrolls the header a
    // screenful and a half off the top, and folding it there only makes
    // the words short: the page stays where the walk left it, which on a
    // screen with rungs enough under the header -- a series -- is still
    // well below it. So the block is put back in front of the viewer.
    await pump(tester, tallPlot, series: true);
    await upToTheDescription(tester);
    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    final block = find.byType(TvDescription);
    expect(
      tester.getRect(block).top,
      lessThan(0),
      reason: 'the header is off the top of the panel by now',
    );

    await press(tester, LogicalKeyboardKey.select);

    expect(focusIn<TvDescription>(), isTrue);
    final folded = tester.getRect(block);
    expect(folded.top, greaterThanOrEqualTo(-0.5));
    expect(folded.bottom, lessThanOrEqualTo(tvSize.height + 0.5));
  });

  testWidgets('and coming back to it sideways starts at its first line', (
    tester,
  ) async {
    // The bookmark is a press to the right whether or not it is on the
    // screen, and the press back is Flutter's own traversal, which reveals
    // a stop with one edge against one edge of the viewport -- for a block
    // this tall, its last line. Reading starts at the top of a paragraph
    // whichever way the remote came.
    await pump(tester, tallPlot);
    await upToTheDescription(tester);
    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    final block = find.byType(TvDescription);
    expect(tester.getRect(block).top, lessThan(0));

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTooltip(), TvMetaHeader.addTooltip);
    await press(tester, LogicalKeyboardKey.arrowLeft);

    expect(focusIn<TvDescription>(), isTrue);
    expect(tester.getRect(block).top, greaterThanOrEqualTo(-0.5));
  });

  testWidgets('the header has two stops, and they are side by side', (
    tester,
  ) async {
    // The bookmark is where it always was and is still what a press up
    // from the rungs lands on; the description is beside it. Both
    // directions, because a stop reachable one way only is a stop half the
    // walk falls off.
    await pump(tester, longPlot);
    await upToTheDescription(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTooltip(), TvMetaHeader.addTooltip);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusIn<TvDescription>(), isTrue);
  });

  testWidgets('a phone is left alone: it has its own More button', (
    tester,
  ) async {
    // Two mechanisms for one idea is two things to keep right, and the
    // phone's works: the words are reachable by touch and by screen reader
    // there, and the button under them says the rest is there.
    await pump(
      tester,
      longPlot,
      device: DeviceProfile.fallback,
      size: const Size(400, 800),
    );

    expect(find.byType(TvDescription), findsNothing);
    expect(find.byType(TvMetaHeader), findsNothing);
    expect(find.text('More'), findsOneWidget);
  });
}
