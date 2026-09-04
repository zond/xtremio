import '../resource.dart';
import 'loadable.dart';
import 'meta_item.dart';
import 'stream.dart';

/// The URLs stremio-core derived for the selected stream (`StreamUrls`).
///
/// Note this struct is snake_case on the wire, unlike the rest of the model.
final class StreamUrls {
  const StreamUrls(this.json, {this.convertedStream});

  final Map<String, dynamic> json;

  /// The second half of the engine's `(StreamUrls, Stream)` pair: the
  /// stream after source conversion (torrent hints resolved, ...).
  final StreamInfo? convertedStream;

  /// What to hand to the player: the direct URL for `url` streams, or the
  /// streaming server's `/{infoHash}/{fileIdx}` URL for torrents. Null when
  /// the stream cannot be played by a media player (magnet, external, ...).
  Uri? get streamingUrl => _uri(json['streaming_url']);

  Uri? get downloadUrl => _uri(json['download_url']);
  Uri? get magnetUrl => _uri(json['magnet_url']);

  static Uri? _uri(Object? value) =>
      value is String ? Uri.tryParse(value) : null;
}

/// Where the library says playback last stopped.
final class LibraryProgress {
  const LibraryProgress({required this.timeOffset, required this.duration});

  /// Milliseconds, like the `TimeChanged` action.
  final int timeOffset;
  final int duration;

  /// A resume point worth seeking to (some progress, not at the very end).
  bool get isResumable =>
      timeOffset > 0 && (duration == 0 || timeOffset < duration * 0.95);
}

/// One subtitle file an addon offers (`Subtitles`): a URL to an SRT/VTT
/// file plus its language.
final class SubtitleInfo {
  const SubtitleInfo(this.json);

  final Map<String, dynamic> json;

  String get id => json['id'] as String? ?? url.toString();

  /// Language code as the addon sent it (`eng`, `pob`, ...).
  String get lang => json['lang'] as String? ?? '';
  Uri get url => Uri.parse(json['url'] as String);
  String? get label => json['label'] as String?;

  /// [url] with everything folded away that cannot change *which file*
  /// comes back: the scheme and host lower-cased, a default port and any
  /// fragment dropped, trailing slashes off the path, and the query's
  /// parameters put in a fixed order.
  ///
  /// Nothing is removed from the query. The one parameter OpenSubtitles v3
  /// ever sends is `senc` (`?senc=cp1250`), which picks the encoding of the
  /// bytes it hands back -- strip that and two genuinely different files
  /// collapse into one. The path keeps its case: only the host is
  /// case-insensitive.
  String get normalizedUrl => normalizeUrl(url);

  /// The keys two entries must share to be the same file. Both are
  /// checked, so an addon that gives a stable id collapses with one that
  /// only gives a URL, and two addons naming the same file with slightly
  /// different URLs collapse too.
  ///
  /// The id is scoped by language: an id names a file and a file has one
  /// language, so an id two unrelated addons happen to reuse (`1`, `2`,
  /// ...) can only merge entries that at least claim the same language.
  Iterable<String> get identityKeys sync* {
    yield 'url:$normalizedUrl';
    final id = json['id'] as String?;
    if (id != null && id.isNotEmpty) {
      yield 'id:${lang.trim().toLowerCase()}|$id';
    }
  }

  /// See [normalizedUrl]. Anything without a scheme and host (a `data:`
  /// URL, a relative one) is compared as it stands.
  static String normalizeUrl(Uri url) {
    if (url.scheme.isEmpty || url.host.isEmpty) return url.toString();
    final scheme = url.scheme.toLowerCase();
    final defaultPort = switch (scheme) {
      'https' => 443,
      'http' => 80,
      _ => 0,
    };
    var path = url.path;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: scheme,
      host: url.host.toLowerCase(),
      port: url.port == defaultPort ? null : url.port,
      path: path,
      query: url.query.isEmpty
          ? null
          : (url.query.split('&')..sort()).join('&'),
    ).toString();
  }

  static List<SubtitleInfo> listFromJson(Object? json) => [
    for (final item in (json as List<dynamic>? ?? const []))
      SubtitleInfo(item as Map<String, dynamic>),
  ];
}

/// One subtitle file together with where it came from: the manifest URL of
/// the addon whose `subtitles` answer carried it, or null when it rode on
/// the stream itself. The menu needs that to tell two files of the same
/// language apart.
final class SubtitleSource {
  const SubtitleSource(this.subtitle, {this.addonBase});

  final SubtitleInfo subtitle;
  final String? addonBase;
}

/// Where subtitles for this Player session should come from
/// (`SubtitlePreference`), remembered by the engine across `Load Player`
/// until `Unload`.
final class SubtitlePreference {
  const SubtitlePreference({required this.enabled, this.source, this.language});

  final bool enabled;

  /// `embedded` or `external`; null to keep the client's own ordering.
  final String? source;

  /// Normalized language code; null when unknown.
  final String? language;

  factory SubtitlePreference.fromJson(Map<String, dynamic> json) =>
      SubtitlePreference(
        enabled: json['enabled'] as bool? ?? false,
        source: json['source'] as String?,
        language: json['language'] as String?,
      );
}

/// View over the `player` field (`Player`).
final class PlayerState {
  const PlayerState({
    required this.selectedStream,
    required this.selectedVideoId,
    required this.stream,
    required this.metaItem,
    required this.nextVideo,
    required this.nextStream,
    required this.progress,
    required this.subtitles,
    required this.subtitlePreference,
    this.streamRequest,
    this.metaRequest,
    this.subtitlesPath,
  });

  /// The stream as it was loaded; null when the model is unloaded.
  final StreamInfo? selectedStream;

  /// The video the stream was requested for (`streamRequest.path.id`).
  final String? selectedVideoId;

  /// Null until `Load Player` ran; `Err` when the stream cannot be
  /// converted (e.g. a torrent while no streaming server is configured).
  final Loadable<StreamUrls>? stream;

  final ResourceLoadable<MetaItem>? metaItem;
  final VideoInfo? nextVideo;

  /// The stream the engine picked for [nextVideo] (same addon, matching
  /// binge group); null when it found none, in which case the next episode
  /// has to be chosen from its own stream list.
  final StreamInfo? nextStream;
  final LibraryProgress? progress;

  /// One entry per subtitle addon asked (`Player.subtitles`), each Loading,
  /// Ready with its files, or Err.
  final List<ResourceLoadable<List<SubtitleInfo>>> subtitles;
  final SubtitlePreference? subtitlePreference;

  /// The requests `Load Player` was given, so a follow-up load (the next
  /// episode) can be built from them.
  final ResourceRequest? streamRequest;
  final ResourceRequest? metaRequest;
  final ResourcePath? subtitlesPath;

  factory PlayerState.fromJson(Map<String, dynamic> json) {
    final selected = json['selected'] as Map<String, dynamic>?;
    final selectedStream = selected?['stream'] as Map<String, dynamic>?;
    final stream = json['stream'] as Map<String, dynamic>?;
    final metaItem = json['metaItem'] as Map<String, dynamic>?;
    final nextVideo = json['nextVideo'] as Map<String, dynamic>?;
    final libraryState =
        (json['libraryItem'] as Map<String, dynamic>?)?['state']
            as Map<String, dynamic>?;
    final streamRequest = selected?['streamRequest'] as Map<String, dynamic>?;
    final metaRequest = selected?['metaRequest'] as Map<String, dynamic>?;
    final subtitlesPath = selected?['subtitlesPath'] as Map<String, dynamic>?;
    final nextStream = json['nextStream'] as Map<String, dynamic>?;
    final preference = json['subtitlePreference'] as Map<String, dynamic>?;
    return PlayerState(
      selectedStream: selectedStream == null
          ? null
          : StreamInfo(selectedStream),
      selectedVideoId:
          (streamRequest?['path'] as Map<String, dynamic>?)?['id'] as String?,
      stream: stream == null
          ? null
          : Loadable.fromJson(stream, (content) {
              // `(StreamUrls, Stream<ConvertedStreamSource>)`: a 2-tuple.
              final pair = content as List<dynamic>;
              final converted = pair.length > 1 ? pair[1] : null;
              return StreamUrls(
                pair[0] as Map<String, dynamic>,
                convertedStream: converted is Map<String, dynamic>
                    ? StreamInfo(converted)
                    : null,
              );
            }),
      metaItem: metaItem == null
          ? null
          : ResourceLoadable.fromJson(
              metaItem,
              (content) => MetaItem(content as Map<String, dynamic>),
            ),
      nextVideo: nextVideo == null ? null : VideoInfo(nextVideo),
      nextStream: nextStream == null ? null : StreamInfo(nextStream),
      subtitles: [
        for (final entry in (json['subtitles'] as List<dynamic>? ?? const []))
          ResourceLoadable.fromJson(
            entry as Map<String, dynamic>,
            SubtitleInfo.listFromJson,
          ),
      ],
      subtitlePreference: preference == null
          ? null
          : SubtitlePreference.fromJson(preference),
      streamRequest: streamRequest == null
          ? null
          : ResourceRequest.fromJson(streamRequest),
      metaRequest: metaRequest == null
          ? null
          : ResourceRequest.fromJson(metaRequest),
      subtitlesPath: subtitlesPath == null
          ? null
          : ResourcePath.fromJson(subtitlesPath),
      progress: libraryState == null
          ? null
          : LibraryProgress(
              timeOffset: (libraryState['timeOffset'] as num?)?.toInt() ?? 0,
              duration: (libraryState['duration'] as num?)?.toInt() ?? 0,
            ),
    );
  }

  bool get isLoaded => selectedStream != null;

  /// The URL to open in the player, once the engine has resolved it.
  Uri? get streamingUrl => stream?.contentOrNull?.streamingUrl;

  /// The stream as the engine converted it (`stream.content[1]`), whose
  /// `behaviorHints` may carry the filename subtitle lookups want.
  StreamInfo? get convertedStream {
    final content = stream?.contentOrNull;
    return content?.convertedStream;
  }

  /// Every subtitle file on offer with the addon that offered it: what the
  /// subtitle addons returned, then the stream's own `subtitles`, then the
  /// converted stream's.
  ///
  /// Deduplicated on [SubtitleInfo.identityKeys] -- the normalized URL and
  /// the addon's own id -- rather than on the exact URL string, so the same
  /// file reached two ways is one entry. The first answer wins, which keeps
  /// the addons' own order.
  List<SubtitleSource> get externalSubtitleSources {
    final seen = <String>{};
    final result = <SubtitleSource>[];
    void add(Iterable<SubtitleInfo> items, String? base) {
      for (final item in items) {
        final keys = item.identityKeys.toList();
        if (keys.any(seen.contains)) continue;
        seen.addAll(keys);
        result.add(SubtitleSource(item, addonBase: base));
      }
    }

    for (final entry in subtitles) {
      add(entry.contentOrNull ?? const [], entry.request.base);
    }
    add(selectedStream?.subtitlesJson.map(SubtitleInfo.new) ?? const [], null);
    add(convertedStream?.subtitlesJson.map(SubtitleInfo.new) ?? const [], null);
    return result;
  }

  /// [externalSubtitleSources] without the provenance.
  List<SubtitleInfo> get externalSubtitles => [
    for (final source in externalSubtitleSources) source.subtitle,
  ];

  /// Some subtitle addon has not answered yet.
  bool get subtitlesLoading => subtitles.any((entry) => entry.isLoading);

  /// Why nothing can be played: the conversion error, or a stream kind the
  /// engine resolved to no media URL.
  String? get unplayableReason {
    final stream = this.stream;
    if (stream is LoadableError<StreamUrls>) return stream.message;
    if (stream is LoadableReady<StreamUrls> && streamingUrl == null) {
      return 'This ${selectedStream?.kind.label.toLowerCase() ?? 'stream'} '
          'stream has no playable URL';
    }
    return null;
  }

  /// A title for the overlay: the meta item's name (plus the episode label
  /// and title for series), else the stream's own title.
  String get title {
    final meta = metaItem?.contentOrNull;
    if (meta == null) return selectedStream?.title ?? '';
    final videoId = selectedVideoId;
    final video = videoId == null ? null : meta.videoById(videoId);
    if (video == null || video.id == meta.id) return meta.name;
    final label = video.seasonEpisodeLabel;
    return '${meta.name} · ${label.isEmpty ? '' : '$label '}${video.title}';
  }
}
