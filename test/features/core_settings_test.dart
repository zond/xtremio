import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/settings/core_settings.dart';
import 'package:xtremio/features/settings/settings_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fixtures.dart';

/// Settings → Player / Subtitles / Interface / Streaming server: every
/// control dispatches `UpdateSettings` with the recorded settings map and
/// exactly one key changed.
void main() {
  final embedded = Uri.parse('http://127.0.0.1:11470');

  Map<String, dynamic> fixtureSettings() =>
      loadCtxLoggedOutFixture()['profile']['settings'] as Map<String, dynamic>;

  /// The anonymous profile with [overrides] applied to its settings.
  Map<String, dynamic> ctxWith(Map<String, dynamic> overrides) {
    final ctx = loadCtxLoggedOutFixture();
    (ctx['profile']['settings'] as Map<String, dynamic>).addAll(overrides);
    return ctx;
  }

  /// The Settings screen on a viewport tall enough to build every section.
  Future<FakeCoreClient> pumpSettings(
    WidgetTester tester, {
    Map<String, dynamic>? ctx,
    Uri? embeddedUrl,
    bool embeddedServer = true,
  }) async {
    tester.view.physicalSize = const Size(900, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = FakeCoreClient(
      state: {
        CoreField.ctx: ctx ?? loadCtxLoggedOutFixture(),
        CoreField.streamingServer: {
          'settings': {'type': 'Ready'},
          'baseUrl': embedded.toString(),
        },
      },
      initInfo: CoreInitInfo(
        serverBaseUrl: embeddedServer ? embeddedUrl ?? embedded : null,
        schemaVersion: 25,
      ),
    );
    await tester.pumpWidget(
      CoreScope(
        client: core,
        initInfo: core.initInfo,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return core;
  }

  /// The one dispatched action is `UpdateSettings` to `ctx` with the whole
  /// recorded map and [key] set to [value].
  void expectOneKeyChanged(
    FakeCoreClient core,
    String key,
    Object? value, {
    Map<String, dynamic>? from,
  }) {
    expect(core.dispatched, hasLength(1), reason: '${core.dispatched}');
    final action = core.dispatched.single;
    expect(action.field, CoreField.ctx);
    final expected = {...from ?? fixtureSettings(), key: value};
    expect(action.toJson(), CoreActions.updateSettings(expected).toJson());
    // Deep equality: nothing else moved, and every key is still there.
    final sent = action.action['args']['args'] as Map<String, dynamic>;
    expect(sent.length, fixtureSettings().length);
    expect(Map.of(sent)..remove(key), Map.of(expected)..remove(key));
  }

  /// Picks [label] from the dropdown of the [setting] tile.
  Future<void> pick(WidgetTester tester, String setting, String label) async {
    await tester.tap(find.byKey(settingKey(setting)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  group('switches write the flipped value', () {
    for (final (key, expected) in [
      (ProfileSettings.bingeWatchingKey, false),
      (ProfileSettings.pauseOnMinimizeKey, true),
      (ProfileSettings.hardwareDecodingKey, false),
      (ProfileSettings.escExitFullscreenKey, false),
      (ProfileSettings.hideSpoilersKey, true),
    ]) {
      testWidgets(key, (tester) async {
        final core = await pumpSettings(tester);
        expect(
          tester.widget<SwitchListTile>(find.byKey(settingKey(key))).value,
          !expected,
        );
        await tester.tap(find.byKey(settingKey(key)));
        await tester.pump();
        expectOneKeyChanged(core, key, expected);
      });
    }
  });

  group('dropdowns write the picked value', () {
    for (final (key, label, expected) in [
      (ProfileSettings.nextVideoNotificationDurationKey, 'Disabled', 0),
      (ProfileSettings.nextVideoNotificationDurationKey, '90 s', 90000),
      (ProfileSettings.seekTimeDurationKey, '30 s', 30000),
      (ProfileSettings.seekShortTimeDurationKey, '5 s', 5000),
      (ProfileSettings.subtitlesSizeKey, '150 %', 150),
      (ProfileSettings.audioLanguageKey, 'German', 'ger'),
      (ProfileSettings.subtitlesLanguageKey, 'Player default', null),
    ]) {
      testWidgets('$key → $label', (tester) async {
        final core = await pumpSettings(tester);
        await pick(tester, key, label);
        expectOneKeyChanged(core, key, expected);
      });
    }

    testWidgets('show the current values', (tester) async {
      await pumpSettings(tester);
      DropdownButton<T> dropdown<T>(String key) =>
          tester.widget<DropdownButton<T>>(find.byKey(settingKey(key)));
      expect(
        dropdown<int>(ProfileSettings.nextVideoNotificationDurationKey).value,
        35000,
      );
      expect(dropdown<int>(ProfileSettings.seekTimeDurationKey).value, 10000);
      expect(
        dropdown<int>(ProfileSettings.seekShortTimeDurationKey).value,
        3000,
      );
      expect(dropdown<int>(ProfileSettings.subtitlesSizeKey).value, 100);
      expect(dropdown<String?>(ProfileSettings.audioLanguageKey).value, 'eng');
      expect(find.text('35 s'), findsOneWidget);
      expect(find.text('English'), findsNWidgets(2));
    });

    testWidgets('a value outside the list is still offered', (tester) async {
      final core = await pumpSettings(
        tester,
        ctx: ctxWith({'seekTimeDuration': 7000, 'audioLanguage': 'xx'}),
      );
      expect(find.text('7 s'), findsOneWidget);
      expect(find.text('xx'), findsOneWidget);
      // Picking the same value again writes nothing.
      await pick(tester, ProfileSettings.seekTimeDurationKey, '7 s');
      expect(core.dispatched, isEmpty);
    });
  });

  group('subtitle colours', () {
    testWidgets('text colour chips write the RGBA hex', (tester) async {
      final core = await pumpSettings(tester);
      final tile = find.byKey(
        settingKey(ProfileSettings.subtitlesTextColorKey),
      );
      expect(
        tester
            .widget<ChoiceChip>(
              find.descendant(
                of: tile,
                matching: find.widgetWithText(ChoiceChip, 'White'),
              ),
            )
            .selected,
        isTrue,
      );
      await tester.tap(
        find.descendant(of: tile, matching: find.text('Yellow')),
      );
      await tester.pump();
      expectOneKeyChanged(
        core,
        ProfileSettings.subtitlesTextColorKey,
        '#FFEB3BFF',
      );
    });

    testWidgets('background chips write the RGBA hex; None is transparent', (
      tester,
    ) async {
      final core = await pumpSettings(
        tester,
        ctx: ctxWith({'subtitlesBackgroundColor': '#000000FF'}),
      );
      final tile = find.byKey(
        settingKey(ProfileSettings.subtitlesBackgroundColorKey),
      );
      expect(
        tester
            .widget<ChoiceChip>(
              find.descendant(
                of: tile,
                matching: find.widgetWithText(ChoiceChip, 'Black'),
              ),
            )
            .selected,
        isTrue,
      );
      await tester.tap(find.descendant(of: tile, matching: find.text('None')));
      await tester.pump();
      expectOneKeyChanged(
        core,
        ProfileSettings.subtitlesBackgroundColorKey,
        '#00000000',
        from: {...fixtureSettings(), 'subtitlesBackgroundColor': '#000000FF'},
      );
    });
  });

  group('quitOnClose', () {
    testWidgets('is offered on desktop', (tester) async {
      final core = await pumpSettings(tester);
      final key = settingKey(ProfileSettings.quitOnCloseKey);
      expect(find.byKey(key), findsOneWidget);
      await tester.tap(find.byKey(key));
      await tester.pump();
      expectOneKeyChanged(core, ProfileSettings.quitOnCloseKey, false);
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('is not offered on phones and TVs', (tester) async {
      await pumpSettings(tester);
      expect(
        find.byKey(settingKey(ProfileSettings.quitOnCloseKey)),
        findsNothing,
      );
      expect(
        find.byKey(settingKey(ProfileSettings.escExitFullscreenKey)),
        findsOneWidget,
      );
    }, variant: TargetPlatformVariant.mobile());
  });

  group('streaming server', () {
    RadioGroup<bool> radios(WidgetTester tester) =>
        tester.widget<RadioGroup<bool>>(find.byType(RadioGroup<bool>));

    testWidgets('the engine pointing at the embedded server selects Embedded', (
      tester,
    ) async {
      // The recorded profile holds stremio-core's loopback default, which
      // init retargets at the embedded server: the same URL bar the slash.
      final core = await pumpSettings(tester);
      expect(radios(tester).groupValue, isFalse);
      expect(find.text(embedded.toString()), findsOneWidget);
      expect(
        find.byKey(StreamingServerSection.remoteUrlFieldKey),
        findsNothing,
      );
      expect(core.dispatched, isEmpty);
    });

    testWidgets('Embedded writes the URL init reported', (tester) async {
      final remote = {'streamingServerUrl': 'https://server.example.com/'};
      final core = await pumpSettings(tester, ctx: ctxWith(remote));
      expect(radios(tester).groupValue, isTrue);
      expect(
        tester
            .widget<TextField>(
              find.byKey(StreamingServerSection.remoteUrlFieldKey),
            )
            .controller
            ?.text,
        'https://server.example.com/',
      );

      await tester.tap(find.byKey(StreamingServerSection.embeddedKey));
      await tester.pump();
      expectOneKeyChanged(
        core,
        ProfileSettings.streamingServerUrlKey,
        embedded.toString(),
        from: {...fixtureSettings(), ...remote},
      );
    });

    testWidgets('Remote shows the field, validates, then writes the URL', (
      tester,
    ) async {
      final core = await pumpSettings(tester);
      await tester.tap(find.byKey(StreamingServerSection.remoteKey));
      await tester.pumpAndSettle();
      final field = find.byKey(StreamingServerSection.remoteUrlFieldKey);
      expect(field, findsOneWidget);
      expect(core.dispatched, isEmpty, reason: 'no URL to write yet');

      for (final bad in [
        'not a url',
        'ftp://host/',
        'http://',
        '192.168.1.10',
      ]) {
        await tester.enterText(field, bad);
        await tester.tap(find.byKey(StreamingServerSection.saveRemoteUrlKey));
        await tester.pump();
        expect(
          find.text(StreamingServerSection.invalidUrlMessage),
          findsOneWidget,
          reason: bad,
        );
        expect(core.dispatched, isEmpty, reason: bad);
      }

      await tester.enterText(field, ' http://192.168.1.10:11470 ');
      await tester.tap(find.byKey(StreamingServerSection.saveRemoteUrlKey));
      await tester.pump();
      expect(find.text(StreamingServerSection.invalidUrlMessage), findsNothing);
      expectOneKeyChanged(
        core,
        ProfileSettings.streamingServerUrlKey,
        'http://192.168.1.10:11470',
      );
    });

    testWidgets('without an embedded server only Remote can be chosen', (
      tester,
    ) async {
      final core = await pumpSettings(tester, embeddedServer: false);
      expect(find.text('Not running'), findsOneWidget);
      expect(
        tester
            .widget<RadioListTile<bool>>(
              find.byKey(StreamingServerSection.embeddedKey),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.byKey(StreamingServerSection.embeddedKey));
      await tester.pump();
      expect(core.dispatched, isEmpty);
    });
  });

  testWidgets('no control is offered until the settings are known', (
    tester,
  ) async {
    // A `ctx` without a profile: the settings map is empty, and a partial
    // UpdateSettings would be rejected by the engine.
    final core = await pumpSettings(tester, ctx: {});
    expect(find.text('Loading settings…'), findsWidgets);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(RadioGroup<bool>), findsNothing);
    expect(core.dispatched, isEmpty);

    core.setState(CoreField.ctx, loadCtxLoggedOutFixture());
    await tester.pumpAndSettle();
    expect(find.text('Loading settings…'), findsNothing);
    expect(
      find.byKey(settingKey(ProfileSettings.bingeWatchingKey)),
      findsOneWidget,
    );
  });
}
