import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/main.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/root_shell.dart';

import '../support/fake_core_client.dart';

const tv = DeviceProfile(isTv: true, hasTouch: false);

/// A core whose board plans no catalogs, so the shell settles.
FakeCoreClient emptyBoardCore() => FakeCoreClient(
  state: {
    CoreField.board: {
      'selected': {'type': null, 'extra': <Object>[]},
      'catalogs': <Object>[],
      'catalogLabels': <Object>[],
    },
  },
);

/// Routes the `xtremio/device` channel to [handler] for one test; a null
/// handler leaves the channel unanswered, as on a platform without the
/// Kotlin side.
void mockDeviceChannel(Future<Object?> Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(DeviceProfile.channel, handler);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceScope', () {
    testWidgets('without a scope every widget is on the fallback device', (
      tester,
    ) async {
      late DeviceProfile seen;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            seen = DeviceScope.of(context);
            return const SizedBox();
          },
        ),
      );
      expect(seen, DeviceProfile.fallback);
      expect(seen.isTv, isFalse);
    });

    testWidgets('a scope hands its profile down', (tester) async {
      late DeviceProfile seen;
      late bool seenTv;
      await tester.pumpWidget(
        DeviceScope(
          profile: tv,
          child: Builder(
            builder: (context) {
              seen = DeviceScope.of(context);
              seenTv = DeviceScope.isTv(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, tv);
      expect(seenTv, isTrue);
    });

    testWidgets('XtremioApp puts its device profile above the shell', (
      tester,
    ) async {
      await tester.pumpWidget(XtremioApp(core: emptyBoardCore(), device: tv));
      await tester.pumpAndSettle();

      expect(DeviceScope.of(tester.element(find.byType(RootShell))), tv);
    });

    testWidgets('XtremioBootstrap hands the detected device to the app', (
      tester,
    ) async {
      final core = emptyBoardCore();
      await tester.pumpWidget(
        XtremioBootstrap(device: tv, boot: () async => (core, core.initInfo)),
      );
      await tester.pumpAndSettle();

      expect(DeviceScope.of(tester.element(find.byType(RootShell))), tv);
    });

    testWidgets('XtremioApp is not a TV unless told so', (tester) async {
      await tester.pumpWidget(XtremioApp(core: emptyBoardCore()));
      await tester.pumpAndSettle();

      final profile = DeviceScope.of(tester.element(find.byType(RootShell)));
      expect(profile.isTv, isFalse);
      expect(profile, DeviceProfile.fallback);
    });
  });

  group('DeviceProfile.detect', () {
    final List<MethodCall> calls = [];

    setUp(calls.clear);
    tearDown(() => mockDeviceChannel(null));

    test('on Android reads isTv and hasTouch from the channel', () async {
      mockDeviceChannel((call) async {
        calls.add(call);
        return {'isTv': true, 'hasTouch': false};
      });

      final profile = await DeviceProfile.detect(
        platform: TargetPlatform.android,
      );

      expect(profile, tv);
      expect(calls.map((c) => c.method), ['profile']);
    });

    test('on an Android phone the channel says not a TV', () async {
      mockDeviceChannel((call) async => {'isTv': false, 'hasTouch': true});

      final profile = await DeviceProfile.detect(
        platform: TargetPlatform.android,
      );

      expect(profile, const DeviceProfile(isTv: false, hasTouch: true));
    });

    test('a channel that throws yields the fallback', () async {
      mockDeviceChannel((call) async {
        throw PlatformException(code: 'boom', message: 'no UiModeManager');
      });

      final profile = await DeviceProfile.detect(
        platform: TargetPlatform.android,
      );

      expect(profile, DeviceProfile.fallback);
    });

    test('a channel nobody answers yields the fallback', () async {
      mockDeviceChannel(null);

      final profile = await DeviceProfile.detect(
        platform: TargetPlatform.android,
      );

      expect(profile, DeviceProfile.fallback);
    });

    test('a reply missing a key keeps that key at the fallback', () async {
      mockDeviceChannel((call) async => {'isTv': true});

      final profile = await DeviceProfile.detect(
        platform: TargetPlatform.android,
      );

      expect(profile, const DeviceProfile(isTv: true, hasTouch: true));
    });

    test('a desktop resolves without a channel call', () async {
      mockDeviceChannel((call) async {
        calls.add(call);
        return {'isTv': true, 'hasTouch': true};
      });

      for (final platform in [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        final profile = await DeviceProfile.detect(platform: platform);
        expect(profile, const DeviceProfile(isTv: false, hasTouch: false));
      }
      expect(
        await DeviceProfile.detect(platform: TargetPlatform.iOS),
        const DeviceProfile(isTv: false, hasTouch: true),
      );
      expect(calls, isEmpty);
    });

    test('defaults to the running platform', () async {
      // Tests run on a desktop host: no channel call, not a TV.
      mockDeviceChannel((call) async {
        calls.add(call);
        return {'isTv': true, 'hasTouch': true};
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      expect((await DeviceProfile.detect()).isTv, isFalse);
      expect(calls, isEmpty);
    });
  });
}
