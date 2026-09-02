import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/shell/root_shell.dart';

import 'support/fake_core_client.dart';
import 'support/fake_playback_engine.dart';
import 'support/fixtures.dart';

/// The anonymous profile's `ctx` with `hardwareDecoding` set.
Map<String, dynamic> ctxDecoding({required bool hardware}) {
  final ctx = loadCtxLoggedOutFixture();
  final profile = ctx['profile'] as Map<String, dynamic>;
  final settings = profile['settings'] as Map<String, dynamic>;
  settings[ProfileSettings.hardwareDecodingKey] = hardware;
  return ctx;
}

/// A core with the given `ctx` and a board that plans no catalogs (so the
/// Board section settles instead of spinning).
FakeCoreClient coreWith(Map<String, dynamic> ctx) => FakeCoreClient(
  state: {
    CoreField.ctx: ctx,
    CoreField.board: {
      'selected': {'type': null, 'extra': <Object>[]},
      'catalogs': <Object>[],
      'catalogLabels': <Object>[],
    },
  },
);

void main() {
  /// Every `hardwareDecoding` the app asked an engine to be built with.
  late List<bool> built;

  setUp(() => built = []);

  Widget app(FakeCoreClient core) => XtremioApp(
    core: core,
    engineBuilder: ({required bool hardwareDecoding}) {
      built.add(hardwareDecoding);
      return FakePlaybackEngine();
    },
  );

  /// What a player does when it opens: asks the [PlaybackScope] the app
  /// supplies for its engine.
  PlaybackEngine openPlayer(WidgetTester tester) =>
      PlaybackScope.of(tester.element(find.byType(RootShell)))();

  testWidgets('the first player after launch already follows the stored '
      'hardwareDecoding', (tester) async {
    await tester.pumpWidget(app(coreWith(ctxDecoding(hardware: false))));
    await tester.pumpAndSettle();

    openPlayer(tester);
    expect(built, [false]);
  });

  testWidgets('a changed setting applies to the next player that opens', (
    tester,
  ) async {
    final core = coreWith(ctxDecoding(hardware: false));
    await tester.pumpWidget(app(core));
    await tester.pumpAndSettle();
    openPlayer(tester);

    core.setState(CoreField.ctx, ctxDecoding(hardware: true));
    await tester.pumpAndSettle();
    openPlayer(tester);
    expect(built, [false, true]);
  });

  testWidgets('with no settings from the core, hardware decoding stays on '
      '(stremio-core\'s default)', (tester) async {
    await tester.pumpWidget(app(coreWith(const {})));
    await tester.pumpAndSettle();

    openPlayer(tester);
    expect(built, [true]);
  });
}
