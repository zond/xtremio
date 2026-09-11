import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/settings/core_settings.dart';
import 'package:xtremio/features/sharing/idle_sharing.dart';
import 'package:xtremio/features/settings/settings_screen.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/tv_text_field.dart';

import '../support/fake_core_client.dart';
import '../support/fake_prefs_client.dart';
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
    AppPrefs? prefs,
    DeviceProfile device = DeviceProfile.fallback,
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
    const screen = MaterialApp(home: SettingsScreen());
    await tester.pumpWidget(
      DeviceScope(
        profile: device,
        child: CoreScope(
          client: core,
          initInfo: core.initInfo,
          child: prefs == null
              ? screen
              : PrefsScope(prefs: prefs, child: screen),
        ),
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

  /// What the switch of [key] shows.
  bool switchValue(WidgetTester tester, String key) =>
      tester.widget<SwitchListTile>(find.byKey(settingKey(key))).value;

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

  group('writes in a row', () {
    testWidgets('the second carries the first before the engine reports it', (
      tester,
    ) async {
      // Every write sends the whole map; a second control changed before the
      // `ctx` round trip lands must not send the pre-first-change map.
      final core = await pumpSettings(tester);
      await tester.tap(
        find.byKey(settingKey(ProfileSettings.bingeWatchingKey)),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(settingKey(ProfileSettings.pauseOnMinimizeKey)),
      );
      await tester.pump();
      expect(core.dispatched, hasLength(2));
      final sent = core.dispatched.last.action['args']['args'];
      expect(sent, {
        ...fixtureSettings(),
        ProfileSettings.bingeWatchingKey: false,
        ProfileSettings.pauseOnMinimizeKey: true,
      });
      // The controls show what was sent…
      expect(switchValue(tester, ProfileSettings.bingeWatchingKey), isFalse);
      // …through a `ctx` pull asked for before the engine handled it, which
      // answers the settings from before the change: taken as the
      // authority, it snapped the control back and had the next change
      // send the old value again.
      core.setState(CoreField.ctx, loadCtxLoggedOutFixture());
      await tester.pumpAndSettle();
      expect(switchValue(tester, ProfileSettings.bingeWatchingKey), isFalse);
      await tester.tap(find.byKey(settingKey(ProfileSettings.hideSpoilersKey)));
      await tester.pump();
      expect(core.dispatched.last.action['args']['args'], {
        ...fixtureSettings(),
        ProfileSettings.bingeWatchingKey: false,
        ProfileSettings.pauseOnMinimizeKey: true,
        ProfileSettings.hideSpoilersKey: true,
      });
    });

    testWidgets(
      'a change waiting to be shown hides nothing else a pull brings',
      (tester) async {
        // Only the value sent is held; the rest of the map is the engine's.
        // Held whole, the map sent hid what the pull had for every other key
        // and the next write sent those back as they were.
        final core = await pumpSettings(tester);
        await tester.tap(
          find.byKey(settingKey(ProfileSettings.bingeWatchingKey)),
        );
        await tester.pump();

        core.setState(
          CoreField.ctx,
          ctxWith({ProfileSettings.hideSpoilersKey: true}),
        );
        await tester.pumpAndSettle();

        expect(switchValue(tester, ProfileSettings.bingeWatchingKey), isFalse);
        expect(switchValue(tester, ProfileSettings.hideSpoilersKey), isTrue);
      },
    );

    testWidgets('a pull that shows a change hands that setting back', (
      tester,
    ) async {
      final core = await pumpSettings(tester);
      await tester.tap(
        find.byKey(settingKey(ProfileSettings.bingeWatchingKey)),
      );
      await tester.pump();

      // The engine took it; the pull says so.
      core.setState(
        CoreField.ctx,
        ctxWith({ProfileSettings.bingeWatchingKey: false}),
      );
      await tester.pumpAndSettle();
      // And from then on the engine is the authority for it again: a later
      // change to it -- another device, a sync -- is what is shown.
      core.setState(
        CoreField.ctx,
        ctxWith({ProfileSettings.bingeWatchingKey: true}),
      );
      await tester.pumpAndSettle();

      expect(switchValue(tester, ProfileSettings.bingeWatchingKey), isTrue);
    });
  });

  group('dropdowns write the picked value', () {
    for (final (key, label, expected) in [
      (
        ProfileSettings.nextVideoNotificationDurationKey,
        'None (play at once)',
        0,
      ),
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
    testWidgets(
      'the up-next countdown at zero says the next episode plays at once, '
      'not that it is off',
      (tester) async {
        await pumpSettings(
          tester,
          ctx: ctxWith({'nextVideoNotificationDuration': 0}),
        );
        // What a zero does with Binge watching on is play the next episode
        // the moment this one ends, with no card: the label has to say so,
        // because a viewer reading "Disabled" under "Up-next countdown"
        // picks it to stop the next episode and gets the opposite. The
        // switch that stops it is named on the tile instead.
        expect(find.text('None (play at once)'), findsOneWidget);
        expect(find.text('Disabled'), findsNothing);
        expect(find.textContaining('turn off Binge watching'), findsOneWidget);
      },
    );
    testWidgets('a synonym code outside the list is labelled with the code', (
      tester,
    ) async {
      // The list keeps one code per name (`fre`, not `fra`); a profile
      // holding the other must not show two identical "French" entries.
      final core = await pumpSettings(
        tester,
        ctx: ctxWith({'subtitlesLanguage': 'fra'}),
      );
      final key = settingKey(ProfileSettings.subtitlesLanguageKey);
      expect(
        tester.widget<DropdownButton<String?>>(find.byKey(key)).value,
        'fra',
      );
      expect(find.text('French (fra)'), findsOneWidget);
      // Open: the button plus one menu entry each, `fre` as plain "French".
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
      expect(find.text('French (fra)'), findsNWidgets(2));
      expect(find.text('French'), findsOneWidget);
      // Picking the held value again writes nothing.
      await tester.tap(find.text('French (fra)').last);
      await tester.pumpAndSettle();
      expect(core.dispatched, isEmpty);
    });
  });

  group('buffer ahead', () {
    // Not a `profile.settings` field: it is the app's own preference (this
    // device's connection and disk, not the account), so it writes to the
    // preferences file and dispatches nothing at all.
    testWidgets('writes the picked choice to the preferences, not the core', (
      tester,
    ) async {
      final stored = FakePrefsClient();
      final prefs = AppPrefs(client: stored);
      final core = await pumpSettings(tester, prefs: prefs);

      expect(prefs.bufferAhead, BufferAhead.normal);
      await pick(tester, AppPrefs.bufferAheadKey, BufferAhead.large.label);

      expect(prefs.bufferAhead, BufferAhead.large);
      expect(core.dispatched, isEmpty, reason: '${core.dispatched}');
      // And it survives a restart: a fresh AppPrefs over the same file.
      final restarted = AppPrefs(client: stored);
      await restarted.load();
      expect(restarted.bufferAhead, BufferAhead.large);
    });

    testWidgets('shows the stored choice and what it costs', (tester) async {
      final prefs = AppPrefs(
        client: FakePrefsClient({
          AppPrefs.bufferAheadKey: BufferAhead.wholeFile.stored,
        }),
      );
      await prefs.load();
      await pumpSettings(tester, prefs: prefs);

      expect(
        tester
            .widget<DropdownButton<BufferAhead>>(
              find.byKey(settingKey(AppPrefs.bufferAheadKey)),
            )
            .value,
        BufferAhead.wholeFile,
      );
      // The trade-off is on the tile, not buried in a help page.
      expect(find.text(BufferAhead.wholeFile.description), findsOneWidget);
    });

    testWidgets('is offered before the settings have arrived', (tester) async {
      // It does not come out of `ctx`, so it must not wait for it the way
      // the `profile.settings` controls do.
      final prefs = AppPrefs(client: FakePrefsClient());
      await pumpSettings(tester, ctx: const {}, prefs: prefs);

      expect(find.byKey(settingKey(AppPrefs.bufferAheadKey)), findsOneWidget);
    });
  });

  group('share while idle', () {
    const tv = DeviceProfile(isTv: true, hasTouch: false);

    Finder theSwitch() => find.byKey(settingKey(AppPrefs.shareWhileIdleKey));

    testWidgets('starts on wherever it is drawn, and says what it does', (
      tester,
    ) async {
      // Nothing has been chosen, so what the switch shows is the default,
      // and the default no longer varies by device: the app does not guess
      // at what this connection costs anybody.
      await pumpSettings(tester, prefs: AppPrefs.inMemory(), device: tv);
      expect(tester.widget<SwitchListTile>(theSwitch()).value, isTrue);

      await pumpSettings(tester, prefs: AppPrefs.inMemory());
      expect(tester.widget<SwitchListTile>(theSwitch()).value, isTrue);

      // And what turning it on does is on the tile itself: "Share while
      // idle" alone leaves the viewer to guess what "idle" covers.
      expect(find.text(IdleSharing.description), findsOneWidget);
    });

    testWidgets('writes the choice to the preferences, not the core', (
      tester,
    ) async {
      final stored = FakePrefsClient();
      final prefs = AppPrefs(client: stored);
      final core = await pumpSettings(tester, prefs: prefs, device: tv);

      // A television turning it off is a decision, and it has to read back
      // as one rather than falling through to the default that says on.
      await tester.tap(theSwitch());
      await tester.pumpAndSettle();

      expect(prefs.shareWhileIdle, isFalse);
      expect(tester.widget<SwitchListTile>(theSwitch()).value, isFalse);
      expect(core.dispatched, isEmpty, reason: '${core.dispatched}');
      final restarted = AppPrefs(client: stored);
      await restarted.load();
      expect(restarted.shareWhileIdle, isFalse);
    });

    testWidgets('is offered on a phone too, and turns off there', (
      tester,
    ) async {
      // Unlike Bold focus: the choice exists on every device, and it is
      // the same choice -- a phone is where somebody is most likely to
      // want it off, and this is where they say so.
      final prefs = AppPrefs(client: FakePrefsClient());
      await pumpSettings(tester, prefs: prefs);

      await tester.tap(theSwitch());
      await tester.pumpAndSettle();

      expect(prefs.shareWhileIdle, isFalse);
    });

    testWidgets('is offered before the settings have arrived', (tester) async {
      // It does not come out of `ctx`, so it must not wait for it.
      await pumpSettings(tester, ctx: const {}, prefs: AppPrefs.inMemory());

      expect(theSwitch(), findsOneWidget);
    });
  });

  group('bold focus', () {
    const tv = DeviceProfile(isTv: true, hasTouch: false);

    Finder theSwitch() => find.byKey(settingKey(AppPrefs.focusEmphasisKey));

    testWidgets('a television is offered Bold, and it goes to the '
        'preferences', (tester) async {
      final stored = FakePrefsClient();
      final prefs = AppPrefs(client: stored);
      final core = await pumpSettings(tester, prefs: prefs, device: tv);

      expect(prefs.focusEmphasis, FocusEmphasis.standard);
      expect(tester.widget<SwitchListTile>(theSwitch()).value, isFalse);
      // What turning it on buys is on the tile, not in a help page.
      expect(find.text(FocusEmphasis.bold.description), findsOneWidget);

      // One press, where the dropdown this replaced cost a press to open,
      // a walk to the value and a press to choose.
      await tester.tap(theSwitch());
      await tester.pumpAndSettle();

      expect(prefs.focusEmphasis, FocusEmphasis.bold);
      expect(tester.widget<SwitchListTile>(theSwitch()).value, isTrue);
      expect(core.dispatched, isEmpty, reason: '${core.dispatched}');
      // The room does not change on a restart: a fresh AppPrefs over the
      // same file.
      final restarted = AppPrefs(client: stored);
      await restarted.load();
      expect(restarted.focusEmphasis, FocusEmphasis.bold);
    });

    testWidgets('a choice made before the switch existed survives it', (
      tester,
    ) async {
      // The stored key and both stored spellings are unchanged, so a
      // preferences file written by the dropdown build comes back as the
      // switch turned on -- and turning it off writes the other spelling
      // rather than removing the key.
      final stored = FakePrefsClient({
        AppPrefs.focusEmphasisKey: FocusEmphasis.bold.stored,
      });
      final prefs = AppPrefs(client: stored);
      await prefs.load();
      await pumpSettings(tester, prefs: prefs, device: tv);

      expect(tester.widget<SwitchListTile>(theSwitch()).value, isTrue);

      await tester.tap(theSwitch());
      await tester.pumpAndSettle();

      expect(prefs.focusEmphasis, FocusEmphasis.standard);
      expect(
        stored.stored[AppPrefs.focusEmphasisKey],
        FocusEmphasis.standard.stored,
      );
    });

    testWidgets('a phone is not offered it at all', (tester) async {
      // The indicator is only drawn on a television; off one, focus
      // follows a pointer or Tab.
      await pumpSettings(tester, prefs: AppPrefs.inMemory());

      expect(theSwitch(), findsNothing);
      expect(find.text('Bold focus'), findsNothing);
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
            .widget<TvTextField>(
              find.byKey(StreamingServerSection.remoteUrlFieldKey),
            )
            .controller
            .text,
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

    testWidgets('a saved URL is let go once a pull shows it with the slash', (
      tester,
    ) async {
      // stremio-core keeps the server as a `Url`, which puts a slash on a
      // URL typed without a path. Held until a pull showed the very string
      // sent, the URL typed was never let go: the screen went on showing
      // it over whatever the engine held from then on, and every later
      // change sent it back.
      final core = await pumpSettings(tester);
      await tester.tap(find.byKey(StreamingServerSection.remoteKey));
      await tester.pumpAndSettle();
      final field = find.byKey(StreamingServerSection.remoteUrlFieldKey);
      await tester.enterText(field, 'http://192.168.1.10:11470');
      await tester.tap(find.byKey(StreamingServerSection.saveRemoteUrlKey));
      await tester.pump();

      core.setState(
        CoreField.ctx,
        ctxWith({'streamingServerUrl': 'http://192.168.1.10:11470/'}),
      );
      await tester.pumpAndSettle();
      // Then another device moves it.
      const moved = 'https://server.example.com/';
      core.setState(CoreField.ctx, ctxWith({'streamingServerUrl': moved}));
      await tester.pumpAndSettle();

      expect(tester.widget<TvTextField>(field).controller.text, moved);
      await tester.tap(find.byKey(settingKey(ProfileSettings.hideSpoilersKey)));
      await tester.pump();
      expect(
        (core.dispatched.last.action['args']['args']
            as Map<String, dynamic>)[ProfileSettings.streamingServerUrlKey],
        moved,
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
    // Every switch over a `profile.settings` key is behind that pending
    // tile. The one that is drawn is the app's own preference, which does
    // not come out of `ctx` and must not wait for it.
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.byKey(settingKey(AppPrefs.shareWhileIdleKey)), findsOneWidget);
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
