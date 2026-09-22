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

/// What a key can see, already filtered and ordered — which is the
/// catalogue's job and is tested in `model_catalogue_test.dart`.
const List<String> listedModels = [
  defaultSimilarModel,
  'gemini-3.6-flash-lite',
  'gemini-3.6-flash',
  'gemini-3.1-pro',
];

/// What the chooser's menu offers, in order, as it is labelled.
List<String?> offered(WidgetTester tester) => tester
    .widget<DropdownButton<String>>(
      find.byKey(RecommendationsSection.modelMenuKey),
    )
    .items!
    .map((item) => (item.child as Text).data)
    .toList();

/// What the chooser says is chosen.
String? chosen(WidgetTester tester) => tester
    .widget<DropdownButton<String>>(
      find.byKey(RecommendationsSection.modelMenuKey),
    )
    .value;

/// Opens the chooser and picks the entry labelled [label] — the last one,
/// because the closed button is drawn with the same words as the menu
/// entry it is showing.
Future<void> pick(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(RecommendationsSection.modelMenuKey));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

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

  /// Every key a catalogue was asked for, so that a test can say nothing
  /// was asked at all.
  late List<String> listedFor;

  /// What the catalogue answers next. A test that is about the fallbacks
  /// replaces it before the section is built.
  late Future<List<String>> Function(String apiKey) listing;

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
    listedFor = [];
    listing = (_) async => listedModels;
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
    listModels: (apiKey) {
      listedFor.add(apiKey);
      return listing(apiKey);
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

  testWidgets('whose key it is, said on the field and on the line under', (
    tester,
  ) async {
    await start();
    await open(tester);

    // They all look alike, and pasting an OpenAI key here and waiting is
    // the mistake this section is most likely to be handed.
    expect(find.text('Gemini key'), findsOneWidget);
    expect(
      find.textContaining('Made in Google AI Studio'),
      findsOneWidget,
      reason: 'where a key comes from',
    );
    expect(
      find.textContaining('An OpenAI or OpenRouter key will not work here'),
      findsOneWidget,
    );
    expect(find.textContaining('a Google Gemini model'), findsOneWidget);
    expect(find.text('Gemini model'), findsOneWidget);
  });

  testWidgets('with no key nothing is listed and the default is offered', (
    tester,
  ) async {
    await start();
    await open(tester);

    // There is nothing to ask with, and asking anyway is the one thing
    // this section must never do.
    expect(listedFor, isEmpty);
    expect(chosen(tester), defaultSimilarModel);
    expect(offered(tester), [
      RecommendationsSection.label(defaultSimilarModel),
    ]);
    expect(
      find.text('The measured default, until a key is pasted.'),
      findsOneWidget,
    );
    // And a name can still go in, for a viewer who is about to paste a
    // key and already knows which model they want.
    expect(find.byKey(RecommendationsSection.modelFieldKey), findsOneWidget);
  });

  testWidgets('with a key the list is fetched once and fills the chooser', (
    tester,
  ) async {
    await start(apiKey: pastedKey);
    await open(tester);

    expect(listedFor, [pastedKey]);
    expect(offered(tester), [
      '$defaultSimilarModel · measured',
      'gemini-3.6-flash-lite',
      'gemini-3.6-flash',
      'gemini-3.1-pro',
    ]);
    expect(chosen(tester), defaultSimilarModel);
    expect(find.text('4 models this key can see.'), findsOneWidget);
    // There is a list to choose from, so there is no box to type into.
    expect(find.byKey(RecommendationsSection.modelFieldKey), findsNothing);
    // What the chooser must not imply is that everything in it works.
    expect(
      find.textContaining('Being listed is not being usable'),
      findsOneWidget,
    );
    expect(find.textContaining('Test this model below'), findsOneWidget);

    // A rebuild is not another account to ask about: running the check
    // rebuilds the section repeatedly and asks the catalogue nothing.
    await tester.tap(find.byKey(RecommendationsSection.testKey));
    await tester.pumpAndSettle();
    expect(listedFor, [pastedKey]);
  });

  testWidgets('choosing a model writes it, and the default goes back', (
    tester,
  ) async {
    await start(apiKey: pastedKey);
    await open(tester);

    await pick(tester, 'gemini-3.6-flash');
    expect(prefs.similarModel, 'gemini-3.6-flash');
    expect(storage.stored[AppPrefs.similarModelKey], 'gemini-3.6-flash');
    expect(chosen(tester), 'gemini-3.6-flash');

    await pick(tester, '$defaultSimilarModel · measured');
    expect(prefs.similarModel, defaultSimilarModel);
    // The default is what an unset preference already means, so it is not
    // written down as though it had been chosen over something.
    expect(storage.stored.containsKey(AppPrefs.similarModelKey), isFalse);
  });

  testWidgets('a failed fetch keeps the model, says so, and takes a name', (
    tester,
  ) async {
    final lines = captureDiagnostics();
    await start(apiKey: pastedKey, similarModel: 'gemini-9.9-flash-latest');
    // What a client really throws when a listing cannot be made: the
    // request, quoted back, with the key in the query of it.
    listing = (apiKey) async => throw Exception(
      'GET https://generativelanguage.googleapis.com/v1beta/models'
      '?key=$apiKey failed',
    );
    await open(tester);

    // What the viewer configured stands: a list that did not arrive is
    // not an instruction to change anything.
    expect(prefs.similarModel, 'gemini-9.9-flash-latest');
    expect(chosen(tester), 'gemini-9.9-flash-latest');
    expect(
      find.text('The list could not be fetched. What is set here stands.'),
      findsOneWidget,
    );
    // Not one character of the key, on screen or in anything copied out,
    // and this is the moment to look: the exception carried the whole
    // request back, key and all, and what is drawn is a sentence.
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data ?? '', isNot(contains(pastedKey)));
    }
    for (final line in lines) {
      expect(line, isNot(contains(pastedKey)));
    }

    // And they are not locked out of a model we failed to list.
    expect(find.byKey(RecommendationsSection.modelFieldKey), findsOneWidget);
    await tester.enterText(
      find.byKey(RecommendationsSection.modelFieldKey),
      'gemini-4.0-flash-lite',
    );
    await tester.tap(find.byKey(RecommendationsSection.saveModelKey));
    await tester.pumpAndSettle();
    expect(prefs.similarModel, 'gemini-4.0-flash-lite');
    expect(chosen(tester), 'gemini-4.0-flash-lite');
  });

  testWidgets('emptying the by-hand box goes back to the measured default', (
    tester,
  ) async {
    await start(apiKey: pastedKey, similarModel: 'gemini-9.9-flash-latest');
    listing = (_) async =>
        throw const SimilarTitlesFailure(SimilarTrouble.unreachable);
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

  testWidgets('a list fetched with a key nobody is using is dropped', (
    tester,
  ) async {
    await start(apiKey: pastedKey);
    final held = Completer<List<String>>();
    listing = (apiKey) => apiKey == pastedKey
        ? held.future
        : Future.value(const ['gemini-4.0-flash-lite']);
    await open(tester);

    // The key changes while the first listing is still out.
    await tester.enterText(
      find.byKey(RecommendationsSection.apiKeyFieldKey),
      'AIza-another-key',
    );
    await tester.tap(find.byKey(RecommendationsSection.saveApiKeyKey));
    await tester.pumpAndSettle();
    held.complete(listedModels);
    await tester.pumpAndSettle();

    expect(listedFor, [pastedKey, 'AIza-another-key']);
    // What the old key could see is not what this one can, and a menu
    // filled from it would be the app offering another account's models.
    expect(offered(tester), contains('gemini-4.0-flash-lite'));
    expect(offered(tester), isNot(contains('gemini-3.6-flash')));
  });

  testWidgets('a list that arrives after the key is cleared is dropped', (
    tester,
  ) async {
    await start(apiKey: pastedKey);
    final held = Completer<List<String>>();
    listing = (_) => held.future;
    await open(tester);

    await tester.enterText(
      find.byKey(RecommendationsSection.apiKeyFieldKey),
      '',
    );
    await tester.tap(find.byKey(RecommendationsSection.saveApiKeyKey));
    await tester.pumpAndSettle();
    held.complete(listedModels);
    await tester.pumpAndSettle();

    // No key is no list. A menu filled after the key was taken away is
    // the app offering models out of an account it can no longer reach.
    expect(prefs.similarApiKey, isNull);
    expect(offered(tester), [
      RecommendationsSection.label(defaultSimilarModel),
    ]);
    expect(find.byKey(RecommendationsSection.modelFieldKey), findsOneWidget);
  });

  testWidgets('a listing that failed is asked again when Save is pressed', (
    tester,
  ) async {
    await start(apiKey: pastedKey);
    listing = (_) async =>
        throw const SimilarTitlesFailure(SimilarTrouble.unreachable);
    await open(tester);
    expect(find.byKey(RecommendationsSection.modelFieldKey), findsOneWidget);

    // Nothing about the key changed; the network did. Save is the press
    // that is already there for trying again.
    listing = (_) async => listedModels;
    await tester.tap(find.byKey(RecommendationsSection.saveApiKeyKey));
    await tester.pumpAndSettle();

    expect(listedFor, [pastedKey, pastedKey]);
    expect(offered(tester), hasLength(listedModels.length));
    expect(find.byKey(RecommendationsSection.modelFieldKey), findsNothing);
  });

  testWidgets('a model the list does not have is still shown and chosen', (
    tester,
  ) async {
    // The measured default of a version ago, which answers "404, no
    // longer available to new users" and is listed for nobody.
    await start(apiKey: pastedKey, similarModel: 'gemini-2.5-flash');
    await open(tester);

    expect(chosen(tester), 'gemini-2.5-flash');
    // The viewer chose it. A list that silently drops it is a list that
    // overrides them, so it is on the end of the list and still chosen.
    expect(offered(tester), [
      ...listedModels.map(RecommendationsSection.label),
      'gemini-2.5-flash',
    ]);
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
