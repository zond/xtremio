import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/discover/discover_screen.dart';

import '../support/fake_core_client.dart';

/// State recorded from the real core by rust/tests/cinemeta.rs.
Map<String, dynamic> loadDiscoverFixture() => jsonDecode(
  File('rust/tests/fixtures/discover_cinemeta_top.json').readAsStringSync(),
) as Map<String, dynamic>;

void main() {
  test('DiscoverState reads the recorded Cinemeta page', () {
    final state = DiscoverState.fromJson(loadDiscoverFixture());
    expect(state.selected?.path.id, 'top');
    expect(state.pages, hasLength(1));
    expect(state.items, hasLength(50));
    expect(state.items.first.name, isNotEmpty);
    expect(state.items.first.poster, startsWith('https://'));
    expect(state.hasNextPage, isTrue);
    expect(state.nextPage?.path.extra, const [ExtraValue('skip', '50')]);
    expect(state.isLoadingMore, isFalse);
  });

  testWidgets('loads the catalog on mount and renders the poster grid', (
    tester,
  ) async {
    final fixture = loadDiscoverFixture();
    final core = FakeCoreClient(state: {CoreField.discover: fixture});
    await tester.pumpWidget(
      MaterialApp(
        home: CoreScope(client: core, child: const DiscoverScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final expected = CoreActions.loadDiscover(DiscoverScreen.defaultRequest);
    expect(core.dispatched, hasLength(1));
    expect(core.dispatched.single.field, CoreField.discover);
    expect(core.dispatched.single.action, expected.action);

    final firstName = DiscoverState.fromJson(fixture).items.first.name;
    expect(find.text(firstName), findsOneWidget);

    // Leaving the screen unloads the field.
    await tester.pumpWidget(const SizedBox());
    expect(
      core.dispatched.last.action,
      CoreActions.unload(CoreField.discover).action,
    );
  });

  testWidgets(
    'shows a spinner while the first page loads and the error otherwise',
    (tester) async {
      final core = FakeCoreClient(
        state: {
          CoreField.discover: {
            'selected': null,
            'selectable': {'nextPage': null},
            'catalog': [
              {
                'request': DiscoverScreen.defaultRequest.toJson(),
                'content': {'type': 'Loading'},
              },
            ],
          },
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CoreScope(client: core, child: const DiscoverScreen()),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      core.setState(CoreField.discover, {
        'selected': null,
        'selectable': {'nextPage': null},
        'catalog': [
          {
            'request': DiscoverScreen.defaultRequest.toJson(),
            'content': {
              'type': 'Err',
              'content': {
                'type': 'Env',
                'content': {'message': 'HTTP 503'},
              },
            },
          },
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('HTTP 503'), findsOneWidget);
    },
  );
}
