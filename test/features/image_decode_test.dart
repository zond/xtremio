/// Every network image decodes at the size it is drawn at.
///
/// A decoded picture is width x height x 4 bytes resident whatever box it
/// is drawn in, so a 1000x1500 poster is about six megabytes whether it
/// fills the screen or a thumbnail. On the Chromecast with Google TV this
/// app is used on -- two gigabytes for the whole system -- browsing two
/// titles and their sources, with nothing played, cost 57 MB of native
/// heap and took the resident set to 267 MB; the low-memory killer has
/// taken the app at 203 MB and at 147 MB. Artwork is where that goes.
///
/// So each of these asserts the bound that reaches the [Image], derived
/// from the box the picture is drawn in and the device's pixel ratio --
/// `cacheWidth` and `cacheHeight` count physical pixels, and getting that
/// wrong is a blurry logo across a television, which is worse than the
/// memory it saves. The last test is the guard: it reads `lib/` and fails
/// on a network image that names no bound at all.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addon_widgets.dart';
import 'package:xtremio/features/details/meta_details_screen.dart';
import 'package:xtremio/features/details/tv_meta_header.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/features/settings/account_section.dart';
import 'package:xtremio/features/settings/settings_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_density.dart';

import '../support/fake_core_client.dart';
import '../support/fake_playback_engine.dart';
import '../support/fake_torrent_stats_client.dart';
import '../support/fixtures.dart';
import '../support/images.dart';
import '../support/tv.dart';

const String movieId = 'tt0063350';

/// A phone, and a window wide enough for the two-pane details layout.
const Size phoneSize = Size(400, 3000);
const Size wideSize = Size(1200, 2400);

/// A screen sharp enough that a ratio left out of a bound shows up as a
/// factor of two rather than as nothing at all.
const double ratio = 2;

void main() {
  /// The sources list flat, so these pumps do not depend on which
  /// resolution sections happen to be open.
  AppPrefs flatPrefs() {
    final prefs = AppPrefs.inMemory();
    unawaited(prefs.setStreamsSectioned(false));
    return prefs;
  }

  Widget harness(FakeCoreClient core, DeviceProfile device) => DeviceScope(
    profile: device,
    child: CoreScope(
      client: core,
      child: PrefsScope(
        prefs: flatPrefs(),
        child: PlaybackScope(
          createEngine: FakePlaybackEngine.new,
          torrentStats: FakeTorrentStatsClient(),
          child: MaterialApp(
            builder: device.isTv ? TvMediaQuery.builder : null,
            home: const MetaDetailsScreen(type: 'movie', id: movieId),
          ),
        ),
      ),
    ),
  );

  /// A screen [size] logical pixels across at [ratio] physical pixels to
  /// one of them: the view is set in physical pixels, so the layout is the
  /// same at every ratio and only the decodes move.
  void useScreenAt(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = size * ratio;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpDetails(
    WidgetTester tester, {
    required DeviceProfile device,
    required Size size,
  }) async {
    useScreenAt(tester, size);
    final core = FakeCoreClient(
      state: {CoreField.metaDetails: loadMetaDetailsFixture()},
    );
    await tester.pumpWidget(harness(core, device));
    await tester.pumpAndSettle();
  }

  /// The images the collapsing app bar draws, in the order it stacks
  /// them: the artwork, and the title's logo standing on it.
  List<Image> barImages(WidgetTester tester) => tester
      .widgetList<Image>(
        find.descendant(
          of: find.byType(FlexibleSpaceBar),
          matching: find.byType(Image),
        ),
      )
      .toList();

  group('the artwork behind the app bar', () {
    testWidgets('decodes at the width of the bar, not of the picture', (
      tester,
    ) async {
      await pumpDetails(
        tester,
        device: DeviceProfile.fallback,
        size: phoneSize,
      );

      final artwork = barImages(tester).first;
      expect(
        networkUrlOf(artwork),
        'https://images.metahub.space/background/medium/$movieId/img',
      );
      // The bar is the whole width of a phone, and the decode is that
      // width in physical pixels. Only the width: `cover` crops the rest
      // exactly as it did, and the picture keeps its own aspect.
      final drawn = tester.getSize(find.byWidget(artwork));
      expect(drawn.width, phoneSize.width);
      expect(decodeOf(artwork), (
        width: (drawn.width * ratio).round(),
        height: null,
      ));
    });

    testWidgets('and a wide window bounds it by the bar, which is not the '
        'window', (tester) async {
      await pumpDetails(tester, device: DeviceProfile.fallback, size: wideSize);

      // The wide layout gives the sources their own pane and the bar what
      // is left, so a bound taken from `MediaQuery` would decode most of
      // a megapixel nothing draws. This is why the width comes from the
      // bar's own constraints.
      final artwork = barImages(tester).first;
      final drawn = tester.getSize(find.byWidget(artwork));
      expect(drawn.width, lessThan(wideSize.width));
      expect(decodeOf(artwork), (
        width: (drawn.width * ratio).round(),
        height: null,
      ));
    });

    testWidgets('and the logo on it decodes at the height it is drawn at', (
      tester,
    ) async {
      await pumpDetails(
        tester,
        device: DeviceProfile.fallback,
        size: phoneSize,
      );

      // The height is the dimension the logo is drawn at -- the width
      // follows the lettering -- so the height is the one that is bound.
      final logo = barImages(tester).last;
      expect(
        networkUrlOf(logo),
        'https://images.metahub.space/logo/medium/$movieId/img',
      );
      expect(logo.height, isNotNull);
      expect(decodeOf(logo), (
        width: null,
        height: (logo.height! * ratio).round(),
      ));
    });
  });

  group('the logo on the television header', () {
    testWidgets('decodes at the height the header draws it at', (tester) async {
      await pumpDetails(tester, device: tv, size: tvSize);

      final logo = tester.widget<Image>(
        find
            .descendant(
              of: find.byType(TvMetaHeader),
              matching: find.byType(Image),
            )
            .first,
      );
      expect(
        networkUrlOf(logo),
        'https://images.metahub.space/logo/medium/$movieId/img',
      );
      // The box is [TvMetaHeader.logoHeight] tall whatever the logo turns
      // out to be, which is what keeps the rows below it from jumping, and
      // so it is also what the decode costs.
      expect(logo.height, TvMetaHeader.logoHeight);
      expect(decodeOf(logo), (
        width: null,
        height: (TvMetaHeader.logoHeight * ratio).round(),
      ));
    });
  });

  group("an addon's logo", () {
    testWidgets('decodes at the square it is drawn in, whichever square '
        'the screen asked for', (tester) async {
      const other = 72.0;
      tester.view.devicePixelRatio = ratio;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: Row(
            children: [
              AddonLogo(url: 'https://addon.example/logo.png'),
              AddonLogo(url: 'https://addon.example/logo.png', size: other),
            ],
          ),
        ),
      );

      // The list draws one per addon at [AddonLogo.defaultSize] and the
      // addon's own screen draws a larger one, so the bound is the box
      // rather than a number. Only the width, so `contain` letterboxes a
      // wide logo into the square exactly as it did.
      final logos = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(decodeOf(logos.first), (
        width: (AddonLogo.defaultSize * ratio).round(),
        height: null,
      ));
      expect(decodeOf(logos.last), (
        width: (other * ratio).round(),
        height: null,
      ));
    });
  });

  group("the account's picture", () {
    testWidgets('decodes at the circle it is drawn in', (tester) async {
      const url = 'https://account.example/me.png';
      final ctx = loadCtxLoggedInFixture();
      (((ctx['profile'] as Map<String, dynamic>)['auth']
                  as Map<String, dynamic>)['user']
              as Map<String, dynamic>)['avatar'] =
          url;
      tester.view.devicePixelRatio = ratio;
      tester.view.physicalSize = const Size(800, 1400) * ratio;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        CoreScope(
          client: FakeCoreClient(state: {CoreField.ctx: ctx}),
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // The picture goes into a [CircleAvatar] rather than an [Image], so
      // the bound is on the provider itself. The circle it fills is the
      // radius the section names, which is the radius Material would have
      // picked anyway.
      final avatar = tester
          .widgetList<CircleAvatar>(find.byType(CircleAvatar))
          .singleWhere((circle) => circle.foregroundImage != null);
      expect(
        tester.getSize(find.byWidget(avatar)).width,
        AccountSection.avatarRadius * 2,
      );
      expect(
        avatar.foregroundImage,
        isA<ResizeImage>()
            .having(
              (image) => (image.imageProvider as NetworkImage).url,
              'url',
              url,
            )
            .having(
              (image) => image.width,
              'width',
              (AccountSection.avatarRadius * 2 * ratio).round(),
            )
            .having((image) => image.height, 'height', isNull),
      );
    });
  });

  group('nothing decodes at the source resolution', () {
    test('every network image in lib/ names the size it decodes at', () {
      // The guard against a sixth. Every `Image.network` in the app is
      // read, and one that names neither `cacheWidth` nor `cacheHeight`
      // fails this: a provider is otherwise decoded at whatever the addon
      // served, which is the whole bug. A bare `NetworkImage` counts as
      // bounded only inside a `ResizeImage`, which cannot be built without
      // a width or a height of its own.
      //
      // Read as text rather than as a widget tree, because the point is
      // to catch the call nobody has written a screen test for. What it
      // does not see is an image built some third way -- an `Image.asset`
      // is not network artwork, and a provider assembled through a
      // variable would need a compiler.
      final unbounded = <String>[];
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      for (final file in files) {
        for (final call in _networkImages(_code(file))) {
          if (call.startsWith('ResizeImage(') ||
              call.contains('cacheWidth') ||
              call.contains('cacheHeight')) {
            continue;
          }
          unbounded.add('${file.path}: ${call.split('\n').first}...');
        }
      }

      expect(
        unbounded,
        isEmpty,
        reason:
            'a network image decoded at whatever the addon served: give it '
            'the width or the height of the box it is drawn in, times '
            'MediaQuery.devicePixelRatioOf(context)',
      );
    });
  });
}

/// [file]'s code with its comments taken out, so that a line *about*
/// `Image.network` is not read as a call to it.
String _code(File file) => file
    .readAsLinesSync()
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

/// Every network image built in [code], as written: the call and its
/// arguments, with the `ResizeImage` round a bare provider when there is
/// one.
List<String> _networkImages(String code) {
  const wrapper = 'ResizeImage(';
  final found = <String>[];
  for (final name in const ['Image.network(', 'NetworkImage(']) {
    var at = code.indexOf(name);
    while (at >= 0) {
      var depth = 0;
      var end = at + name.length - 1;
      for (; end < code.length; end++) {
        if (code[end] == '(') depth++;
        if (code[end] == ')' && --depth == 0) break;
      }
      final from =
          at >= wrapper.length && code.startsWith(wrapper, at - wrapper.length)
          ? at - wrapper.length
          : at;
      found.add(code.substring(from, end + 1));
      at = code.indexOf(name, end);
    }
  }
  return found;
}
