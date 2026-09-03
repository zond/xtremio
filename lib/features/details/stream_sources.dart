import '../../core/core.dart';

/// What the addons between them offered, indexed by source.
///
/// Two listings are the same source when they are the same *content*, not
/// when they look alike: [StreamInfo.sourceKey] — an info hash and a file
/// index for a torrent, the URL for a direct one — which is the same
/// identity the download path already keys a pin by. Two different releases
/// with the same resolution and the same size are two sources and stay two
/// rows.
///
/// A source several listings name is worth collapsing for two reasons:
///
/// - the list says the same thing twice, which is what a viewer sees; and
/// - the listings often carry *different* `announce` sets, and the union of
///   them is a strictly better torrent to hand the server. [merged] is what
///   makes that union reach playback and downloads: the row that survives
///   plays with every tracker anybody named.
///
/// Which addons offered it is kept too ([alsoFrom]), because a row that
/// silently swallowed another addon's answer would be hiding an option.
/// Addons are held by the name the list shows, so an addon installed twice
/// (two configurations of one Torrentio) is one name and collapses without
/// a word — that is the addon repeating itself, not two answers.
final class StreamSourceIndex {
  const StreamSourceIndex._(this._sources);

  /// Reads every listing in list order; the order they come in is the order
  /// [alsoFrom] names them in and the order the trackers are merged in.
  factory StreamSourceIndex.of(
    Iterable<({String addon, StreamInfo stream})> listings,
  ) {
    final sources = <String, _SharedSource>{};
    for (final listing in listings) {
      final key = listing.stream.sourceKey;
      if (key == null) continue;
      (sources[key] ??= _SharedSource()).add(listing.addon, listing.stream);
    }
    return StreamSourceIndex._(sources);
  }

  /// Nothing was listed: every stream is its own source.
  static const StreamSourceIndex empty = StreamSourceIndex._({});

  final Map<String, _SharedSource> _sources;

  /// [stream] carrying every tracker any listing of the same source named,
  /// first seen first and each one once. [stream] itself when that is
  /// already what it carries.
  StreamInfo merged(StreamInfo stream) {
    final source = _sourceOf(stream);
    return source == null ? stream : stream.withTrackers(source.trackers);
  }

  /// The other addons that offered this source, in listing order. Empty
  /// when [addon] is the only one that did — including when it offered it
  /// more than once.
  List<String> alsoFrom(String addon, StreamInfo stream) => [
    for (final name in _sourceOf(stream)?.addons ?? const <String>[])
      if (name != addon) name,
  ];

  _SharedSource? _sourceOf(StreamInfo stream) {
    final key = stream.sourceKey;
    return key == null ? null : _sources[key];
  }
}

/// One source as every listing of it described it.
final class _SharedSource {
  /// The addons that offered it, distinct and in listing order.
  final List<String> addons = [];

  /// Their trackers, unioned: first seen wins its place, and none twice.
  final List<String> trackers = [];
  final Set<String> _seen = {};

  void add(String addon, StreamInfo stream) {
    if (!addons.contains(addon)) addons.add(addon);
    for (final tracker in stream.trackers) {
      if (_seen.add(tracker)) trackers.add(tracker);
    }
  }
}

/// How a row says the same source came from somewhere else too.
String alsoFromLabel(List<String> addons) => 'Also from ${addons.join(', ')}';
