/// Settings → Recommendations: the key, the model, and "Test this model".
///
/// The two things this file is here to hold are the ones that cost money
/// or leak something. **With no key nothing is asked of anybody** — not a
/// probe, not a default key, nothing; and **the key is never on screen,
/// never in a failure and never in what a viewer would copy out of this
/// app**, because the repository is public and the APKs are handed
/// around.
///
/// The third is that leaving the screen stops the check. Six calls to a
/// provider the viewer is paying for must not go on being made because
/// somebody pressed Back.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/settings/recommendations_section.dart';
import 'package:xtremio/features/settings/settings_screen.dart';
import 'package:xtremio/features/similar/check_keys.dart';
import 'package:xtremio/features/similar/check_model.dart';
import 'package:xtremio/features/similar/similar_titles.dart';
import 'package:xtremio/shell/tv_text_entry.dart';
import 'package:xtremio/widgets/tv_text_field.dart';

import '../support/diagnostics_capture.dart';
import '../support/fake_core_client.dart';
import '../support/fake_model_check.dart';
import '../support/fake_prefs_client.dart';
import '../support/fixtures.dart';

/// A key of the shape a viewer would paste, and of no use to anybody.
const String pastedKey = 'AIza-not-a-real-key';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<AnswerKey> keys;
  late FakePrefsClient storage;
  late AppPrefs prefs;

  /// Every key and model a check was built with, so a test can say that
  /// one was never built at all.
  late List<String> built;

  /// The model behind whatever check is built next.
  late FakeCheckModel answering;

  setUpAll(() async {
    keys = await loadAnswerKeys();
  });

  Future<void> start({String? apiKey, String? similarModel}) async {
    storage = FakePrefsClient({
      AppPrefs.similarApiKeyKey: ?apiKey,
      AppPrefs.similarModelKey: ?similarModel,
    });
    prefs = AppPrefs(client: storage);
    await prefs.load();
    built = [];
    answering = FakeCheckModel.attentive(keys);
  }

  /// A catalogue that has every film the keys rate and nothing else.
  Future<List<Map<String, dynamic>>> catalogue(
    String type,
    String query,
  ) async => const [];

  Widget section() => RecommendationsSection(
    prefs: prefs,
    checkFor: ({required String apiKey, required String model}) {
      built.add('$model with $apiKey');
      return ModelCheck(
        provider: answering,
        search: catalogue,
        loadKeys: () async => keys,
      );
    },
  );

  /// The section on a screen of its own, reached the way the settings
  /// list reaches it, so that leaving it is a real pop.
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      Scaffold(body: ListView(children: [section()])),
                ),
              ),
              child: const Text('Settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
  }

  testWidgets('with no key the action is unavailable and nothing is asked', (
    tester,
  ) async {
    await start();
    await open(tester);

    final tile = tester.widget<ListTile>(
      find.byKey(RecommendationsSection.testKey),
    );
    expect(tile.enabled, isFalse);
    expect(tile.onTap, isNull);
    expect(find.text('Paste an API key first.'), findsOneWidget);

    await tester.tap(find.byKey(RecommendationsSection.testKey));
    await tester.pumpAndSettle();

    expect(built, isEmpty, reason: 'no key means no check, not a failed one');
    expect(answering.ordered, isEmpty);
    expect(answering.asked, isEmpty);
    expect(find.textContaining('Judgement'), findsNothing);
  });

  testWidgets('the key is obscured, and is nowhere on the screen', (
    tester,
  ) async {
    await start(apiKey: pastedKey);
    await open(tester);

    final field = tester.widget<TvTextField>(
      find.byKey(RecommendationsSection.apiKeyFieldKey),
    );
    expect(field.kind, TvTextKind.password);
    expect(field.kind.isSecret, isTrue);
    // Off a television that is Flutter's own field, obscured.
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(RecommendationsSection.apiKeyFieldKey),
              matching: find.byType(TextField),
            ),
          )
          .obscureText,
      isTrue,
    );
    // And nothing anywhere else on the screen has written it out.
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data ?? '', isNot(contains(pastedKey)));
    }
  });

  testWidgets('a pasted key is stored, and an emptied box forgets it', (
    tester,
  ) async {
    await start();
    await open(tester);

    await tester.enterText(
      find.byKey(RecommendationsSection.apiKeyFieldKey),
      pastedKey,
    );
    await tester.tap(find.byKey(RecommendationsSection.saveApiKeyKey));
    await tester.pumpAndSettle();

    expect(prefs.similarApiKey, pastedKey);
    expect(storage.stored[AppPrefs.similarApiKeyKey], pastedKey);
    expect(
      tester
          .widget<ListTile>(find.byKey(RecommendationsSection.testKey))
          .enabled,
      isTrue,
      reason: 'a key is what turns the check on',
    );

    await tester.enterText(
      find.byKey(RecommendationsSection.apiKeyFieldKey),
      '   ',
    );
    await tester.tap(find.byKey(RecommendationsSection.saveApiKeyKey));
    await tester.pumpAndSettle();

    // Blank is not a key: the feature is off, and nothing is left behind
    // in the file for a later load to read back as one.
    expect(prefs.similarApiKey, isNull);
    expect(storage.stored.containsKey(AppPrefs.similarApiKeyKey), isFalse);
  });

  testWidgets('emptying the model box goes back to the measured default', (
    tester,
  ) async {
    await start(apiKey: pastedKey, similarModel: 'gemini-9.9-flash-latest');
    await open(tester);

    expect(
      tester
          .widget<TvTextField>(find.byKey(RecommendationsSection.modelFieldKey))
          .controller
          .text,
      'gemini-9.9-flash-latest',
    );

    await tester.enterText(
      find.byKey(RecommendationsSection.modelFieldKey),
      '',
    );
    await tester.tap(find.byKey(RecommendationsSection.saveModelKey));
    await tester.pumpAndSettle();

    expect(prefs.similarModel, defaultSimilarModel);
    // The box says what the setting is rather than staying blank over a
    // setting that is not blank.
    expect(
      tester
          .widget<TvTextField>(find.byKey(RecommendationsSection.modelFieldKey))
          .controller
          .text,
      defaultSimilarModel,
    );
  });

  testWidgets('a check reports three numbers, each said beside itself', (
    tester,
  ) async {
    await start(apiKey: pastedKey);
    await open(tester);

    await tester.tap(find.byKey(RecommendationsSection.testKey));
    await tester.pumpAndSettle();

    expect(built, ['$defaultSimilarModel with $pastedKey']);
    expect(find.text('Usable.'), findsOneWidget);
    // Chance beside the score, because the number says nothing alone.
    expect(find.text('Judgement 1.00 · chance is 0.50'), findsOneWidget);
    expect(find.text('Agreement 1.00'), findsOneWidget);
    expect(find.textContaining('Invented films: none in'), findsOneWidget);
    expect(find.textContaining('Slowest call'), findsOneWidget);
    // And it says what the agreement number is not.
    expect(
      find.textContaining('this is a floor and not a mark'),
      findsOneWidget,
    );
    expect(
      find.textContaining('sorts by relatedness scores below chance'),
      findsOneWidget,
    );
  });

  testWidgets('leaving the screen cancels the check', (tester) async {
    await start(apiKey: pastedKey);
    answering = FakeCheckModel.attentive(keys)..holding = Completer<void>();
    await open(tester);

    await tester.tap(find.byKey(RecommendationsSection.testKey));
    await tester.pump();
    expect(
      find.text(
        'Asking. Six calls against answer keys for three films; '
        'leaving this screen stops it.',
      ),
      findsOneWidget,
    );
    expect(answering.ordered, hasLength(1));

    // Back. The call in flight cannot be recalled; the other five can.
    final context = tester.element(find.byKey(RecommendationsSection.testKey));
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    answering.holding!.complete();
    await tester.pumpAndSettle();

    expect(answering.ordered, hasLength(1));
    expect(answering.asked, isEmpty, reason: 'the other five were never made');
  });

  testWidgets('changing the key clears numbers it no longer describes', (
    tester,
  ) async {
    await start(apiKey: pastedKey);
    await open(tester);

    await tester.tap(find.byKey(RecommendationsSection.testKey));
    await tester.pumpAndSettle();
    expect(find.text('Usable.'), findsOneWidget);

    await tester.enterText(
      find.byKey(RecommendationsSection.apiKeyFieldKey),
      'AIza-another-key',
    );
    await tester.tap(find.byKey(RecommendationsSection.saveApiKeyKey));
    await tester.pumpAndSettle();

    // Those numbers were about a different key. Leaving them up beside a
    // new one is the app saying something it has not measured.
    expect(find.text('Usable.'), findsNothing);
    expect(find.textContaining('Judgement'), findsNothing);
  });

  testWidgets('a check abandoned mid-flight cannot report over a newer one', (
    tester,
  ) async {
    await start(apiKey: pastedKey);
    answering = FakeCheckModel(
      ordering: (target, films) =>
          throw const SimilarTitlesFailure(SimilarTrouble.gone, '404'),
    )..holding = Completer<void>();
    await open(tester);

    await tester.tap(find.byKey(RecommendationsSection.testKey));
    await tester.pump();

    // The key changes while the first call is still out. What that call
    // then says is about a key nobody is using.
    await tester.enterText(
      find.byKey(RecommendationsSection.apiKeyFieldKey),
      'AIza-another-key',
    );
    await tester.tap(find.byKey(RecommendationsSection.saveApiKeyKey));
    await tester.pumpAndSettle();
    answering.holding!.complete();
    await tester.pumpAndSettle();

    expect(find.text('No answer'), findsNothing);
  });

  testWidgets('a model that does not answer is reported in words', (
    tester,
  ) async {
    final lines = captureDiagnostics();
    await start(apiKey: pastedKey);
    answering = FakeCheckModel(
      ordering: (target, films) =>
          throw const SimilarTitlesFailure(SimilarTrouble.gone, '404'),
    );
    await open(tester);

    await tester.tap(find.byKey(RecommendationsSection.testKey));
    await tester.pumpAndSettle();

    expect(find.text('No answer'), findsOneWidget);
    expect(
      find.text(
        'The model did not answer: ${SimilarTrouble.gone.describe}. '
        'Nothing was measured.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Judgement'), findsNothing);
    // Not one character of the key, on screen or in anything copied out.
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data ?? '', isNot(contains(pastedKey)));
    }
    for (final line in lines) {
      expect(line, isNot(contains(pastedKey)));
    }
  });

  testWidgets('the section is on the settings screen, under Interface', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await start();
    await tester.pumpWidget(
      CoreScope(
        client: FakeCoreClient(
          state: {CoreField.ctx: loadCtxLoggedOutFixture()},
        ),
        child: PrefsScope(
          prefs: prefs,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(RecommendationsSection.title), findsOneWidget);
    expect(find.byType(RecommendationsSection), findsOneWidget);
    // Between what the app shows and where it streams from: it is about
    // what appears under a title, not about the account or the server.
    expect(
      tester.getTopLeft(find.text('Interface')).dy,
      lessThan(tester.getTopLeft(find.text(RecommendationsSection.title)).dy),
    );
    expect(
      tester.getTopLeft(find.text(RecommendationsSection.title)).dy,
      lessThan(tester.getTopLeft(find.text('Streaming server')).dy),
    );
  });
}
