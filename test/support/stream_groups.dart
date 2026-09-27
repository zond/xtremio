/// `meta_details` stream groups: what one addon answered for one video, the
/// way the engine records it.
///
/// `addon` is the addon's manifest URL, or a bare host standing for
/// `https://<host>/manifest.json`. The video defaults to the movie fixture,
/// Night of the Living Dead (`tt0063350`).
library;

const _movieId = 'tt0063350';

String _base(String addon) =>
    addon.contains('://') ? addon : 'https://$addon/manifest.json';

/// A group whose `content` is [content] as given.
Map<String, dynamic> streamGroup(
  String addon,
  Map<String, dynamic>? content, {
  String type = 'movie',
  String id = _movieId,
}) => {
  'request': {
    'base': _base(addon),
    'path': {'resource': 'stream', 'type': type, 'id': id, 'extra': <Object>[]},
  },
  'content': content,
};

/// An addon that answered with [streams].
Map<String, dynamic> readyGroup(
  String addon,
  List<Map<String, dynamic>> streams, {
  String type = 'movie',
  String id = _movieId,
}) => streamGroup(
  addon,
  {'type': 'Ready', 'content': streams},
  type: type,
  id: id,
);

/// An addon that answered and had nothing: the error the engine calls
/// "nothing here".
Map<String, dynamic> emptyGroup(
  String addon, {
  String type = 'movie',
  String id = _movieId,
}) => streamGroup(
  addon,
  {
    'type': 'Err',
    'content': {'type': 'EmptyContent'},
  },
  type: type,
  id: id,
);

/// An addon still being waited on.
Map<String, dynamic> loadingGroup(
  String addon, {
  String type = 'movie',
  String id = _movieId,
}) => streamGroup(addon, {'type': 'Loading'}, type: type, id: id);

/// An addon whose host is gone: `Err Env`, as the engine records a fetch
/// that failed.
Map<String, dynamic> failedGroup(
  String addon, {
  String type = 'movie',
  String id = _movieId,
}) => streamGroup(
  addon,
  {
    'type': 'Err',
    'content': {
      'type': 'Env',
      'content': {'code': 1, 'message': 'Failed to fetch: 404 Not Found'},
    },
  },
  type: type,
  id: id,
);

/// A Torrentio-style group for the episode [videoId], to graft onto the
/// series fixture (the default addons have no torrents for it): one
/// playable 1080p torrent.
Map<String, dynamic> torrentioEpisodeGroup(String videoId) => readyGroup(
  'https://torrentio.example/manifest.json',
  [
    {
      'infoHash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'fileIdx': 3,
      'name': 'Torrentio\n1080p',
      'description': 'Breaking.Bad.S01E01.1080p.mkv\n👤 42 💾 1.51 GB',
      'behaviorHints': {'filename': 'Breaking.Bad.S01E01.1080p.mkv'},
    },
  ],
  type: 'series',
  id: videoId,
);
