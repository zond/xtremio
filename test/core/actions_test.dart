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

  test('board and search ranges are inclusive LoadRange actions', () {
    // Byte-for-byte the actions dispatched in rust/tests/board.rs.
    expect(
      jsonDecode(jsonEncode(CoreActions.loadBoardRange(0, 2).toJson())),
      jsonDecode('''
        {"field":"board","action":{"action":"CatalogsWithExtra","args":{
          "action":"LoadRange","args":{"start":0,"end":2}}}}'''),
    );
    expect(
      jsonDecode(
        jsonEncode(CoreActions.loadSearch('night of the living dead').toJson()),
      ),
      jsonDecode('''
        {"field":"search","action":{"action":"Load","args":{
          "model":"CatalogsWithExtra","args":{"type":null,
          "extra":[["search","night of the living dead"]]}}}}'''),
    );
    final range = CoreActions.loadSearchRange(0, 4);
    expect(range.field, CoreField.search);
    expect(range.action, CoreActions.loadBoardRange(0, 4).action);
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

  test('loadDiscoverDefault passes no Selected so the engine picks one', () {
    final action = CoreActions.loadDiscoverDefault();
    expect(action.field, CoreField.discover);
    // `ActionLoad::CatalogWithFilters(Option<Selected>)`: `args: null` is
    // None, which `selected_update` resolves to the first selectable type.
    expect(action.action, {
      'action': 'Load',
      'args': {'model': 'CatalogWithFilters', 'args': null},
    });
    expect(jsonEncode(action.action), contains('"args":null'));
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

  test('loadMetaDetails with a video id asks for its streams, no guess', () {
    final json = CoreActions.loadMetaDetails(
      type: 'series',
      id: 'tt0903747',
      videoId: 'tt0903747:1:2',
    );
    expect(json.action['args']['args'], {
      'metaPath': {
        'resource': 'meta',
        'type': 'series',
        'id': 'tt0903747',
        'extra': <Object>[],
      },
      'streamPath': {
        'resource': 'stream',
        'type': 'series',
        'id': 'tt0903747:1:2',
        'extra': <Object>[],
      },
      'guessStream': false,
    });
    // An explicit streamPath wins, and guessStream can be forced.
    final explicit = CoreActions.loadMetaDetails(
      type: 'movie',
      id: 'tt1',
      videoId: 'ignored',
      streamPath: const ResourcePath(
        resource: 'stream',
        type: 'movie',
        id: 'x',
      ),
      guessStream: true,
    );
    expect(explicit.action['args']['args']['streamPath']['id'], 'x');
    expect(explicit.action['args']['args']['guessStream'], isTrue);
  });

  test('markVideoAsWatched carries the raw video and the flag as a tuple', () {
    final video = {'id': 'tt1:1:2', 'title': 'Two', 'season': 1, 'episode': 2};
    expect(CoreActions.markVideoAsWatched(video, watched: true).toJson(), {
      'field': 'meta_details',
      'action': {
        'action': 'MetaDetails',
        'args': {
          'action': 'MarkVideoAsWatched',
          'args': [video, true],
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

  test('video params and subtitle preference nest under Player', () {
    expect(CoreActions.playerVideoParamsChanged(filename: 'e1.mkv').toJson(), {
      'field': 'player',
      'action': {
        'action': 'Player',
        'args': {
          'action': 'VideoParamsChanged',
          'args': {
            'videoParams': {'hash': null, 'size': null, 'filename': 'e1.mkv'},
          },
        },
      },
    });
    expect(
      CoreActions.playerSubtitlePreferenceChanged(
        enabled: true,
        source: 'embedded',
        language: 'eng',
      ).action['args'],
      {
        'action': 'SubtitlePreferenceChanged',
        'args': {
          'preference': {
            'enabled': true,
            'source': 'embedded',
            'language': 'eng',
          },
        },
      },
    );
    // Absent options are omitted, as the Rust side skips them when None.
    expect(
      CoreActions.playerSubtitlePreferenceChanged(enabled: false)
          .action['args']['args'],
      {
        'preference': {'enabled': false},
      },
    );
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

  test('requests are equal by value, extras in order', () {
    final request = ResourceRequest.cinemetaCatalog(
      type: 'movie',
      id: 'top',
      extra: const [ExtraValue('genre', 'Drama'), ExtraValue('skip', '100')],
    );
    final copy = ResourceRequest.fromJson(
      jsonDecode(jsonEncode(request.toJson())) as Map<String, dynamic>,
    );
    expect(copy, request);
    expect(copy.hashCode, request.hashCode);
    expect(copy.path, request.path);

    expect(
      ResourceRequest.cinemetaCatalog(type: 'movie', id: 'top'),
      isNot(request),
    );
    expect(
      ResourceRequest.cinemetaCatalog(
        type: 'movie',
        id: 'top',
        extra: const [ExtraValue('skip', '100'), ExtraValue('genre', 'Drama')],
      ),
      isNot(request),
    );
    expect(
      request.copyWith(path: request.path.copyWith(id: 'year')),
      isNot(request),
    );
    expect(
      ResourceRequest(
        base: 'https://other.example/manifest.json',
        path: request.path,
      ),
      isNot(request),
    );
  });

  group('Ctx actions', () {
    test('every Ctx action targets the ctx field, nested under Ctx', () {
      final actions = [
        CoreActions.login(email: 'e', password: 'p'),
        CoreActions.register(
          email: 'e',
          password: 'p',
          consent: const GdprConsent(
            tos: true,
            privacy: true,
            marketing: false,
          ),
        ),
        CoreActions.logout(),
        CoreActions.pullAddonsFromAPI(),
        CoreActions.pullUserFromAPI(),
        CoreActions.syncLibraryWithAPI(),
        CoreActions.pullNotifications(),
        CoreActions.addToLibrary({'id': 'tt1', 'type': 'movie', 'name': 'x'}),
        CoreActions.removeFromLibrary('tt1'),
        CoreActions.rewindLibraryItem('tt1'),
        CoreActions.libraryItemMarkAsWatched('tt1', watched: true),
        CoreActions.toggleLibraryItemNotifications('tt1', disabled: true),
        CoreActions.installAddon(const AddonDescriptor({'transportUrl': 'u'})),
        CoreActions.uninstallAddon(
          const AddonDescriptor({'transportUrl': 'u'}),
        ),
        CoreActions.upgradeAddon(const AddonDescriptor({'transportUrl': 'u'})),
        CoreActions.updateSettings({'bingeWatching': false}),
      ];
      for (final action in actions) {
        expect(action.field, CoreField.ctx, reason: '${action.action}');
        expect(action.toJson()['field'], 'ctx');
        expect(action.action['action'], 'Ctx');
        expect(action.action['args'], isA<Map<String, dynamic>>());
      }
    });

    test('login is an AuthRequest tagged Login with facebook false', () {
      expect(CoreActions.login(email: 'a@b.c', password: 'pw').toJson(), {
        'field': 'ctx',
        'action': {
          'action': 'Ctx',
          'args': {
            'action': 'Authenticate',
            'args': {
              'type': 'Login',
              'email': 'a@b.c',
              'password': 'pw',
              'facebook': false,
            },
          },
        },
      });
    });

    test('register carries gdpr_consent in snake_case', () {
      final action = CoreActions.register(
        email: 'a@b.c',
        password: 'pw',
        consent: const GdprConsent(
          tos: true,
          privacy: true,
          marketing: false,
          from: 'xtremio',
        ),
      );
      expect(action.action['args'], {
        'action': 'Authenticate',
        'args': {
          'type': 'Register',
          'email': 'a@b.c',
          'password': 'pw',
          'gdpr_consent': {
            'tos': true,
            'privacy': true,
            'marketing': false,
            'from': 'xtremio',
          },
        },
      });
    });

    test(
      'unit actions carry no args; PullUserFromAPI carries an empty map',
      () {
        expect(CoreActions.logout().action['args'], {'action': 'Logout'});
        expect(jsonEncode(CoreActions.logout().action), contains('"Logout"}'));
        expect(CoreActions.pullAddonsFromAPI().action['args'], {
          'action': 'PullAddonsFromAPI',
        });
        expect(CoreActions.syncLibraryWithAPI().action['args'], {
          'action': 'SyncLibraryWithAPI',
        });
        expect(CoreActions.pullNotifications().action['args'], {
          'action': 'PullNotifications',
        });
        // `PullUserFromAPI { token: Option<AuthKey> }` is a struct variant: the
        // args object must be present even with no token.
        expect(CoreActions.pullUserFromAPI().action['args'], {
          'action': 'PullUserFromAPI',
          'args': <String, dynamic>{},
        });
        expect(
          jsonEncode(CoreActions.pullUserFromAPI().action),
          contains('"args":{}'),
        );
      },
    );

    test('library mutations use the engine argument shapes', () {
      final meta = {'id': 'tt1', 'type': 'movie', 'name': 'One'};
      expect(CoreActions.addToLibrary(meta).action['args'], {
        'action': 'AddToLibrary',
        'args': meta,
      });
      expect(CoreActions.removeFromLibrary('tt1').action['args'], {
        'action': 'RemoveFromLibrary',
        'args': 'tt1',
      });
      expect(CoreActions.rewindLibraryItem('tt1').action['args'], {
        'action': 'RewindLibraryItem',
        'args': 'tt1',
      });
      expect(
        CoreActions.libraryItemMarkAsWatched(
          'tt1',
          watched: false,
        ).action['args'],
        {
          'action': 'LibraryItemMarkAsWatched',
          'args': {'id': 'tt1', 'is_watched': false},
        },
      );
      expect(
        CoreActions.toggleLibraryItemNotifications(
          'tt1',
          disabled: true,
        ).action['args'],
        {
          'action': 'ToggleLibraryItemNotifications',
          'args': ['tt1', true],
        },
      );
    });

    test('addon actions send the whole descriptor back', () {
      final json = {
        'manifest': {'id': 'x', 'version': '1.0.0', 'name': 'X'},
        'transportUrl': 'https://x/manifest.json',
        'flags': {'official': false, 'protected': false},
      };
      final descriptor = AddonDescriptor(json);
      expect(CoreActions.installAddon(descriptor).action['args'], {
        'action': 'InstallAddon',
        'args': json,
      });
      expect(
        CoreActions.uninstallAddon(descriptor).action['args']['action'],
        'UninstallAddon',
      );
      expect(CoreActions.upgradeAddon(descriptor).action['args'], {
        'action': 'UpgradeAddon',
        'args': json,
      });
    });

    test('updateSettings passes the map through untouched', () {
      final settings = {'bingeWatching': false, 'seekTimeDuration': 5000};
      expect(CoreActions.updateSettings(settings).action['args'], {
        'action': 'UpdateSettings',
        'args': settings,
      });
    });
  });

  group('library and addon loads', () {
    test('loadLibrary matches the request shape of the Rust recorder', () {
      // Byte-for-byte the action dispatched in rust/tests/library_addons.rs.
      expect(
        jsonDecode(
          jsonEncode(CoreActions.loadLibrary(const LibraryRequest()).toJson()),
        ),
        jsonDecode(
          '{"field":"library","action":{"action":"Load","args":{'
          '"model":"LibraryWithFilters","args":{"request":{'
          '"type":null,"sort":"lastwatched","page":1}}}}}',
        ),
      );
      final page2 = CoreActions.loadLibrary(
        const LibraryRequest(type: 'series', sort: LibrarySort.name, page: 2),
      );
      expect(page2.action['args']['args']['request'], {
        'type': 'series',
        'sort': 'name',
        'page': 2,
      });
      expect(CoreActions.loadLibraryNextPage().toJson(), {
        'field': 'library',
        'action': {
          'action': 'LibraryWithFilters',
          'args': {'action': 'LoadNextPage'},
        },
      });
    });

    test('loadInstalledAddons wraps the type in a request', () {
      expect(
        CoreActions.loadInstalledAddons(const InstalledAddonsRequest())
            .toJson(),
        {
          'field': 'installed_addons',
          'action': {
            'action': 'Load',
            'args': {
              'model': 'InstalledAddonsWithFilters',
              'args': {
                'request': {'type': null},
              },
            },
          },
        },
      );
      expect(
        CoreActions.loadInstalledAddons(
          const InstalledAddonsRequest(type: 'movie'),
        ).action['args']['args'],
        {
          'request': {'type': 'movie'},
        },
      );
    });

    test("loadRemoteAddons is Discover's Load on the remote_addons field", () {
      final none = CoreActions.loadRemoteAddons(null);
      expect(none.field, CoreField.remoteAddons);
      expect(none.action, {
        'action': 'Load',
        'args': {'model': 'CatalogWithFilters', 'args': null},
      });
      final community = CoreActions.loadRemoteAddons(
        const ResourceRequest(
          base: kCinemetaManifestUrl,
          path: ResourcePath(
            resource: 'addon_catalog',
            type: 'all',
            id: 'community',
          ),
        ),
      );
      expect(community.action['args']['args'], {
        'request': {
          'base': kCinemetaManifestUrl,
          'path': {
            'resource': 'addon_catalog',
            'type': 'all',
            'id': 'community',
            'extra': <Object>[],
          },
        },
      });
      expect(CoreActions.loadRemoteAddonsNextPage().toJson(), {
        'field': 'remote_addons',
        'action': {
          'action': 'CatalogWithFilters',
          'args': {'action': 'LoadNextPage'},
        },
      });
    });

    test('loadAddonDetails takes the manifest URL as transportUrl', () {
      expect(CoreActions.loadAddonDetails(kCinemetaManifestUrl).toJson(), {
        'field': 'addon_details',
        'action': {
          'action': 'Load',
          'args': {
            'model': 'AddonDetails',
            'args': {'transportUrl': kCinemetaManifestUrl},
          },
        },
      });
    });

    test('unload is per field for the phase 3 models too', () {
      for (final field in [
        CoreField.library,
        CoreField.installedAddons,
        CoreField.remoteAddons,
        CoreField.addonDetails,
      ]) {
        final json = CoreActions.unload(field).toJson();
        expect(json['field'], field.wireName);
        expect(json['action'], {'action': 'Unload'});
      }
    });
  });
}
