import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/discover/discover_catalogs.dart';

import '../support/fixtures.dart';

/// Which catalogs Discover offers and in what order: stremio-core's rule
/// for its own catalog menu, read off the installed addons' manifests.
void main() {
  ProfileState profileWith(List<Map<String, dynamic>> catalogs) =>
      ProfileState({
        'addons': [
          {
            'transportUrl': 'https://addon.example.org/manifest.json',
            'manifest': {'id': 'x', 'name': 'Example', 'catalogs': catalogs},
            'flags': <String, Object>{},
          },
        ],
      });

  test('the default addons: what opens with nothing typed, in install '
      'order', () {
    final catalogs = DiscoverCatalogs.of(
      ProfileState.fromCtx(loadCtxLoggedOutFixture()),
    );
    expect(catalogs.types, ['movie', 'series', 'channel']);
    expect(
      [for (final catalog in catalogs.ofType('series')) catalog.name],
      ['Popular', 'New', 'Featured'],
      reason:
          'Cinemeta\'s "Last videos" and "Calendar videos" need ids no menu '
          'offers, so they are not here',
    );
    // A catalog the manifest gives no name is its id.
    expect([for (final c in catalogs.ofType('channel')) c.name], ['top']);
    expect(catalogs.ofType('channel').single.addonName, 'YouTube');
  });

  test('a required property opens on its first option; one with none is '
      'left out', () {
    final catalogs = DiscoverCatalogs.of(
      profileWith([
        {
          'type': 'movie',
          'id': 'genres',
          'name': 'By genre',
          'extra': [
            {
              'name': 'genre',
              'isRequired': true,
              'options': ['Action', 'Drama'],
            },
            {'name': 'skip'},
          ],
        },
        {
          'type': 'movie',
          'id': 'search',
          'extra': [
            {'name': 'search', 'isRequired': true},
          ],
        },
        {'type': 'movie', 'id': 'plain'},
      ]),
    );
    expect([for (final c in catalogs.catalogs) c.name], ['By genre', 'plain']);
    final genres = catalogs.catalogs.first.request;
    expect(genres.base, 'https://addon.example.org/manifest.json');
    expect(genres.path.resource, 'catalog');
    expect(genres.path.extra, [const ExtraValue('genre', 'Action')]);
    expect(catalogs.catalogs.last.request.path.extra, isEmpty);
  });

  test('the short form: a required property has no options to start from', () {
    final catalogs = DiscoverCatalogs.of(
      profileWith([
        {
          'type': 'movie',
          'id': 'needs',
          'extraRequired': ['genre'],
          'extraSupported': ['genre'],
        },
        {
          'type': 'movie',
          'id': 'takes',
          'extraSupported': ['genre', 'skip'],
        },
      ]),
    );
    expect([for (final c in catalogs.catalogs) c.name], ['takes']);
  });

  test('types come in stremio-core\'s order, and "all" is not one of them', () {
    final catalogs = DiscoverCatalogs.of(
      profileWith([
        for (final type in [
          'other',
          'anime',
          'all',
          'tv',
          'movie',
          'zeta',
          'series',
          'channel',
        ])
          {'type': type, 'id': 'c-$type'},
      ]),
    );
    expect(catalogs.types, [
      'movie',
      'series',
      'channel',
      'tv',
      'anime',
      'zeta',
      'other',
    ]);
    // Its catalog is still there: it is among All's rows.
    expect(catalogs.ofType('all'), hasLength(1));
  });
}
