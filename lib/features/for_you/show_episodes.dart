/// Asking Cinemeta for a series' episode list (`ShowEpisodesMemory` keeps
/// what it answers).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/core.dart';
import '../similar/similar_resolver.dart' show cinemeta;

/// How a show's episodes are asked for: the list in stremio-core's order,
/// or null when nobody could say. A function so a test answers it.
typedef EpisodesFetch = Future<List<ShowEpisode>?> Function(String id);

/// Asks Cinemeta for series [id]'s videos (`/meta/series/{id}.json`).
Future<List<ShowEpisode>?> cinemetaEpisodes(
  String id, {
  Uri? base,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final origin = base ?? cinemeta;
    final url = origin.replace(
      pathSegments: [
        ...origin.pathSegments.where((s) => s.isNotEmpty),
        'meta',
        'series',
        '$id.json',
      ],
    );
    final body = await () async {
      final response = await client.getUrl(url).then((r) => r.close());
      final text = await response.transform(utf8.decoder).join();
      return response.statusCode == HttpStatus.ok ? text : null;
    }().timeout(timeout);
    return body == null ? null : episodesInMeta(jsonDecode(body));
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}
