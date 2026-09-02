import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

void main() {
  test('envelope carries the field wire name and the action', () {
    final json = CoreActions.unload(CoreField.metaDetails).toJson();
    expect(json, {
      'field': 'meta_details',
      'action': {'action': 'Unload'},
    });
  });

  test('loadBoard is a Load of CatalogsWithExtra', () {
    expect(CoreActions.loadBoard().toJson(), {
      'field': 'board',
      'action': {
        'action': 'Load',
        'args': {
          'model': 'CatalogsWithExtra',
          'args': {'type': null, 'extra': <Object>[]},
        },
      },
    });
    expect(
      CoreActions.loadBoard(
        type: 'movie',
        extra: const [ExtraValue('genre', 'Drama')],
      ).toJson()['action']['args']['args'],
      {
        'type': 'movie',
        'extra': [
          ['genre', 'Drama'],
        ],
      },
    );
  });

  test('loadDiscover matches the request shape the Rust network test uses', () {
    final action = CoreActions.loadDiscover(
      ResourceRequest.cinemetaCatalog(type: 'movie', id: 'top'),
    );
    // Byte-for-byte the action dispatched in rust/tests/cinemeta.rs.
    expect(
      jsonDecode(jsonEncode(action.toJson())),
      jsonDecode('''
        {"field":"discover","action":{"action":"Load","args":{
          "model":"CatalogWithFilters","args":{"request":{
            "base":"https://v3-cinemeta.strem.io/manifest.json",
            "path":{"resource":"catalog","type":"movie","id":"top","extra":[]}
        }}}}}'''),
    );
    expect(CoreActions.loadDiscoverNextPage().toJson()['action'], {
      'action': 'CatalogWithFilters',
      'args': {'action': 'LoadNextPage'},
    });
  });

  test('loadMetaDetails defaults to guessing the stream', () {
    final json = CoreActions.loadMetaDetails(type: 'series', id: 'tt0903747');
    expect(json.field, CoreField.metaDetails);
    expect(json.action, {
      'action': 'Load',
      'args': {
        'model': 'MetaDetails',
        'args': {
          'metaPath': {
            'resource': 'meta',
            'type': 'series',
            'id': 'tt0903747',
            'extra': <Object>[],
          },
          'streamPath': null,
          'guessStream': true,
        },
      },
    });
  });

  test('player actions nest under Player', () {
    expect(
      CoreActions.playerTimeChanged(
        time: 1000,
        duration: 5000,
        device: 'xtremio',
      ).toJson(),
      {
        'field': 'player',
        'action': {
          'action': 'Player',
          'args': {
            'action': 'TimeChanged',
            'args': {'time': 1000, 'duration': 5000, 'device': 'xtremio'},
          },
        },
      },
    );
    expect(CoreActions.playerEnded().action, {
      'action': 'Player',
      'args': {'action': 'Ended'},
    });
    expect(CoreActions.playerPausedChanged(true).action['args'], {
      'action': 'PausedChanged',
      'args': {'paused': true},
    });
    final stream = {'infoHash': 'abc', 'fileIdx': 0};
    final load = CoreActions.loadPlayer(
      stream: stream,
      streamRequest: ResourceRequest.cinemetaCatalog(type: 'movie', id: 'top'),
    );
    expect(load.action['args']['args']['stream'], stream);
    expect(load.action['args']['args']['metaRequest'], isNull);
  });

  test('resource types roundtrip through JSON', () {
    final request = ResourceRequest.cinemetaCatalog(
      type: 'movie',
      id: 'top',
      extra: const [ExtraValue('skip', '100')],
    );
    final copy = ResourceRequest.fromJson(
      jsonDecode(jsonEncode(request.toJson())) as Map<String, dynamic>,
    );
    expect(copy.base, kCinemetaManifestUrl);
    expect(copy.path.id, 'top');
    expect(copy.path.extra, const [ExtraValue('skip', '100')]);
  });
}
