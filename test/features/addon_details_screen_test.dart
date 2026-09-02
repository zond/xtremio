import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/addons/addon_details_screen.dart';
import 'package:xtremio/shell/external_link.dart';

import '../support/fake_core_client.dart';
import '../support/fake_link_opener.dart';
import '../support/fixtures.dart';

void main() {
  const cinemeta = 'https://v3-cinemeta.strem.io/manifest.json';

  Widget harness(FakeCoreClient core, FakeLinkOpener opener) => CoreScope(
    client: core,
    child: ExternalLinkScope(
      opener: opener,
      child: const MaterialApp(
        home: AddonDetailsScreen(transportUrl: cinemeta),
      ),
    ),
  );

  FakeCoreClient fakeCore({
    Map<String, dynamic>? details,
    Map<String, dynamic>? ctx,
  }) => FakeCoreClient(
    state: {
      CoreField.addonDetails: details ?? loadAddonDetailsFixture(),
      CoreField.ctx: ctx ?? loadCtxLoggedOutFixture(),
    },
  );

  /// A deep copy of the Cinemeta fixture, so tests can bend one side.
  Map<String, dynamic> details() =>
      jsonDecode(jsonEncode(loadAddonDetailsFixture())) as Map<String, dynamic>;

  Map<String, dynamic> remoteContent(Map<String, dynamic> details) =>
      details['remoteAddon']['content']['content'] as Map<String, dynamic>;

  /// Cinemeta as a regular addon: neither side protected.
  Map<String, dynamic> unprotected() {
    final json = details();
    json['localAddon']['flags']['protected'] = false;
    remoteContent(json)['flags']['protected'] = false;
    return json;
  }

  List<CoreAction> ctxActions(FakeCoreClient core) => [
    for (final action in core.dispatched)
      if (action.action['action'] == 'Ctx') action,
  ];

  testWidgets('loads the manifest on mount, renders it, unloads on dispose', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core, FakeLinkOpener()));
    await tester.pumpAndSettle();

    expect(core.dispatched, hasLength(1));
    expect(core.dispatched.single.field, CoreField.addonDetails);
    expect(
      core.dispatched.single.action,
      CoreActions.loadAddonDetails(cinemeta).action,
    );
    expect(core.dispatched.single.action['args']['args'], {
      'transportUrl': cinemeta,
    });

    // Name in the app bar and the card, version, flags, description.
    expect(find.text('Cinemeta'), findsNWidgets(2));
    expect(find.text('v3.0.14'), findsOneWidget);
    expect(find.text('Installed'), findsOneWidget);
    expect(find.text('Official'), findsOneWidget);
    expect(find.text('Protected'), findsOneWidget);
    expect(find.textContaining('The official addon'), findsOneWidget);
    expect(find.text(cinemeta), findsOneWidget);
    // Installed, protected, same version: nothing to do to it.
    expect(find.text('Install'), findsNothing);
    expect(find.text('Update'), findsNothing);
    expect(find.text('Uninstall'), findsNothing);
    expect(find.text('Configure'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    expect(core.dispatched, hasLength(2));
    expect(core.dispatched.last.field, CoreField.addonDetails);
    expect(
      core.dispatched.last.action,
      CoreActions.unload(CoreField.addonDetails).action,
    );
    expect(core.dispatched.where((a) => a.field == null), isEmpty);
  });

  testWidgets('Install sends the fetched descriptor to InstallAddon', (
    tester,
  ) async {
    final json = details();
    json['localAddon'] = null;
    final core = fakeCore(details: json);
    await tester.pumpWidget(harness(core, FakeLinkOpener()));
    await tester.pumpAndSettle();

    expect(find.text('Installed'), findsNothing);
    expect(find.text('Uninstall'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Install'));
    await tester.pump();

    final actions = ctxActions(core);
    expect(actions, hasLength(1));
    expect(actions.single.field, CoreField.ctx);
    expect(actions.single.action['args']['action'], 'InstallAddon');
    expect(actions.single.action['args']['args'], remoteContent(json));
  });

  testWidgets('a different fetched version offers Update -> UpgradeAddon', (
    tester,
  ) async {
    final json = unprotected();
    json['localAddon']['manifest']['version'] = '3.0.13';
    final core = fakeCore(details: json);
    await tester.pumpWidget(harness(core, FakeLinkOpener()));
    await tester.pumpAndSettle();

    expect(find.text('Installed v3.0.13, v3.0.14 available.'), findsOneWidget);
    expect(find.text('Install'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pump();

    final actions = ctxActions(core);
    expect(actions, hasLength(1));
    expect(actions.single.field, CoreField.ctx);
    expect(actions.single.action['args']['action'], 'UpgradeAddon');
    expect(actions.single.action['args']['args'], remoteContent(json));
    expect(
      actions.single.action['args']['args']['manifest']['version'],
      '3.0.14',
    );
  });

  testWidgets('Uninstall sends the installed descriptor; protected has none', (
    tester,
  ) async {
    final json = unprotected();
    final core = fakeCore(details: json);
    await tester.pumpWidget(harness(core, FakeLinkOpener()));
    await tester.pumpAndSettle();

    expect(find.text('Update'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Uninstall'));
    await tester.pump();

    final actions = ctxActions(core);
    expect(actions, hasLength(1));
    expect(actions.single.field, CoreField.ctx);
    expect(actions.single.action['args']['action'], 'UninstallAddon');
    expect(actions.single.action['args']['args'], json['localAddon']);
  });

  testWidgets('configurationRequired: Configure is primary, no Install', (
    tester,
  ) async {
    final json = details();
    json['localAddon'] = null;
    remoteContent(json)['manifest']['behaviorHints']['configurable'] = true;
    remoteContent(json)['manifest']['behaviorHints']['configurationRequired'] =
        true;
    final core = fakeCore(details: json);
    final opener = FakeLinkOpener();
    await tester.pumpWidget(harness(core, opener));
    await tester.pumpAndSettle();

    expect(find.text('Install'), findsNothing);
    expect(find.text('Configuration required'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Configure'));
    await tester.pump();

    expect(
      [for (final url in opener.opened) url.toString()],
      ['https://v3-cinemeta.strem.io/configure'],
    );
    expect(ctxActions(core), isEmpty);
  });

  testWidgets('a configurable installed addon gets a Configure link', (
    tester,
  ) async {
    final json = details();
    json['localAddon']['manifest']['behaviorHints']['configurable'] = true;
    remoteContent(json)['manifest']['behaviorHints']['configurable'] = true;
    final core = fakeCore(details: json);
    final opener = FakeLinkOpener(result: false);
    await tester.pumpWidget(harness(core, opener));
    await tester.pumpAndSettle();

    expect(find.text('Install'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Configure'));
    await tester.pumpAndSettle();

    expect(
      opener.opened.single.toString(),
      'https://v3-cinemeta.strem.io/configure',
    );
    // The opener refused: the user is told.
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Could not open'), findsOneWidget);
  });

  testWidgets('a failed manifest fetch shows the message and retries', (
    tester,
  ) async {
    final json = details();
    json['localAddon'] = null;
    json['remoteAddon']['content'] = {
      'type': 'Err',
      'content': {'code': 4, 'message': 'connection refused'},
    };
    final core = fakeCore(details: json);
    await tester.pumpWidget(harness(core, FakeLinkOpener()));
    await tester.pumpAndSettle();

    expect(find.text('The manifest could not be fetched'), findsOneWidget);
    expect(find.text('connection refused'), findsOneWidget);
    expect(find.text('Install'), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(core.dispatched, hasLength(2));
    expect(
      core.dispatched.last.action,
      CoreActions.loadAddonDetails(cinemeta).action,
    );
  });

  testWidgets('a failed fetch of an installed addon keeps its card', (
    tester,
  ) async {
    final json = unprotected();
    json['remoteAddon']['content'] = {
      'type': 'Err',
      'content': {'code': 4, 'message': 'connection refused'},
    };
    final core = fakeCore(details: json);
    await tester.pumpWidget(harness(core, FakeLinkOpener()));
    await tester.pumpAndSettle();

    expect(find.text('Cinemeta'), findsNWidgets(2));
    expect(find.textContaining('connection refused'), findsOneWidget);
    expect(find.text('Uninstall'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
  });

  testWidgets('addonsLocked shows the banner and disables mutations', (
    tester,
  ) async {
    final json = details();
    json['localAddon'] = null;
    final ctx = loadCtxLoggedOutFixture();
    (ctx['profile'] as Map<String, dynamic>)['addonsLocked'] = true;
    final core = fakeCore(details: json, ctx: ctx);
    await tester.pumpWidget(harness(core, FakeLinkOpener()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Addons are locked'), findsOneWidget);
    final install = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Install'),
    );
    expect(install.onPressed, isNull);
  });

  testWidgets('a failed addon mutation shows the engine message', (
    tester,
  ) async {
    final core = fakeCore();
    await tester.pumpWidget(harness(core, FakeLinkOpener()));
    await tester.pumpAndSettle();

    // Another error source is not this screen's business.
    core.emit(
      const RuntimeCoreEvent({
        'event': 'Error',
        'args': {
          'error': {
            'type': 'Other',
            'code': 1,
            'message': 'User is not logged in',
          },
          'source': {'event': 'LibrarySyncWithAPIPlanned', 'args': null},
        },
      }),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);

    core.emit(
      const RuntimeCoreEvent({
        'event': 'Error',
        'args': {
          'error': {
            'type': 'Other',
            'code': 5,
            'message': 'Addon is protected',
          },
          'source': {
            'event': 'AddonUninstalled',
            'args': {'transport_url': cinemeta, 'id': 'com.linvo.cinemeta'},
          },
        },
      }),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Addon is protected'), findsOneWidget);
  });
}
