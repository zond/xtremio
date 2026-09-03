import '../../core/core.dart';

/// What a stream says about itself, once the structured fields and the
/// free text have both been read: enough to put every addon's answers in
/// one order and to label a row with what is actually known.
///
/// **Nothing here is normative.** stremio-core models a stream as a source
/// plus a name, a description and `behaviorHints`; quality, size and
/// seeders are not fields of anything. So this reads, in order of how much
/// it can be trusted:
///
/// - **Structured**, and preferred wherever it exists:
///   `behaviorHints.videoSize` (bytes), `behaviorHints.filename`,
///   `behaviorHints.bingeGroup` (a release tag such as `pdm-1080p`), and
///   the source variant ([StreamInfo.kind]).
/// - **Text, but reliable**: the resolution and the source tags addons
///   write into the name and the filename (`1080p`, `WEB-DL`, `x265`), and
///   the size from the `💾 1.51 GB` convention when `videoSize` is absent
///   — that exact convention is in our own recorded fixture.
/// - **A guess, by convention only**: seeders. No addon protocol carries
///   them; torrent addons write `👤 42` into the description. A parse that
///   finds nothing is [seeders] null, never zero.
///
/// Every field is nullable and nothing is ever defaulted: an absent value
/// means "not known", which is a different thing from "none" and sorts and
/// renders differently. A badge for an unknown is not drawn at all.
final class StreamFacts {
  const StreamFacts({
    this.resolution,
    this.sizeBytes,
    this.seeders,
    this.tags = const [],
    this.sourceKind,
    this.addonName,
    this.releaseTag,
    this.filename,
  });

  /// The video height, when one could be read.
  final StreamResolution? resolution;

  /// The file's size in bytes: `behaviorHints.videoSize` when the addon set
  /// it, else the `1.51 GB` written into the text. Never zero — an addon
  /// that says `videoSize: 0` is saying nothing.
  final int? sizeBytes;

  /// Seeders, when the description carried the convention. Null is
  /// "unknown", and is not the same as a swarm with nobody in it.
  final int? seeders;

  /// Source and codec tags, canonically spelled, in the fixed order of the
  /// table that recognises them (never the order they appeared in), so the
  /// same release always reads the same way.
  final List<String> tags;

  /// The `StreamSource` variant, or null for [StreamKind.unknown] — the
  /// engine could not tell either.
  final StreamKind? sourceKind;

  /// The addon that answered with this stream, as the row should name it.
  final String? addonName;

  /// `behaviorHints.bingeGroup`: the addon's own tag for "the same release
  /// as", e.g. `pdm-1080p`. Read for a resolution when nothing else has
  /// one, and kept because it is the closest thing to a release id.
  final String? releaseTag;

  /// `behaviorHints.filename`, when the addon set it.
  final String? filename;

  /// Reads [stream]. [addonName] is the label the list should show, which
  /// the stream itself never carries — it comes from the profile, or from
  /// the host of the manifest URL it was asked at.
  factory StreamFacts.of(StreamInfo stream, {String? addonName}) {
    final hints = stream.behaviorHints;
    final releaseTag = hints['bingeGroup'] as String?;
    final filename = stream.filename;
    final name = stream.name;
    final description = stream.description;
    // Most trusted first: the name and the filename are where a release is
    // described, the binge group is the addon's own release tag, and the
    // description is free text that happens to often repeat both.
    final ranked = [?name, ?filename, ?releaseTag, ?description];
    final all = ranked.join('\n');
    return StreamFacts(
      resolution: _firstResolution(ranked),
      sizeBytes: _videoSize(hints['videoSize']) ?? _parseSize(all),
      seeders: _parseSeeders(all),
      tags: _parseTags(all),
      sourceKind: stream.kind == StreamKind.unknown ? null : stream.kind,
      addonName: addonName,
      releaseTag: releaseTag,
      filename: filename,
    );
  }

  /// The badges a row should draw, in display order, with an unknown
  /// omitted entirely rather than shown as a placeholder.
  List<String> get badges => [?resolutionLabel, ?sizeLabel, ?seedersLabel];

  String? get resolutionLabel => resolution?.label;

  /// `1.51 GB`, in the same 1024-based units the addons' own text uses.
  String? get sizeLabel => formatSize(sizeBytes);

  String? get seedersLabel => switch (seeders) {
    null => null,
    1 => '1 seeder',
    final count => '$count seeders',
  };

  /// [bytes] as `1.51 GB`; null for null. Binary units, matching what the
  /// `💾` convention is computed with.
  static String? formatSize(int? bytes) {
    if (bytes == null) return null;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    // Whole bytes and kilobytes have no meaningful fraction to show.
    final digits = unit <= 1 ? 0 : (value >= 100 ? 0 : 2);
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  /// The first resolution any of [sources] yields, in their order.
  static StreamResolution? _firstResolution(List<String> sources) {
    for (final source in sources) {
      final found = _resolutionIn(source);
      if (found != null) return found;
    }
    return null;
  }

  static StreamResolution? _resolutionIn(String text) {
    final token = _resolutionPattern.firstMatch(text);
    if (token != null) {
      return _resolutionTokens[token.group(1)!.toLowerCase()];
    }
    // `1920x1080`, which filenames from a ripper often carry instead.
    final dimensions = _dimensionsPattern.firstMatch(text);
    final height = dimensions == null
        ? null
        : int.tryParse(dimensions.group(2)!);
    return height == null ? null : StreamResolution.forHeight(height);
  }

  /// `behaviorHints.videoSize`, when it is a positive count of bytes. Zero
  /// is not a size; an addon that sends it is saying nothing.
  static int? _videoSize(Object? value) {
    final bytes = switch (value) {
      final int bytes => bytes,
      final double bytes => bytes.round(),
      final String bytes => int.tryParse(bytes),
      _ => null,
    };
    return bytes != null && bytes > 0 ? bytes : null;
  }

  static int? _parseSize(String text) {
    final match = _sizePattern.firstMatch(text);
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!.replaceAll(',', '.'));
    if (value == null) return null;
    final multiplier = _sizeUnits[match.group(2)!.toLowerCase()[0]]!;
    return (value * multiplier).round();
  }

  static int? _parseSeeders(String text) {
    for (final pattern in _seederPatterns) {
      final match = pattern.firstMatch(text);
      if (match != null) return int.tryParse(match.group(1)!);
    }
    return null;
  }

  static List<String> _parseTags(String text) => [
    for (final MapEntry(key: label, value: pattern) in _tagPatterns.entries)
      if (pattern.hasMatch(text)) label,
  ];

  static final RegExp _resolutionPattern = RegExp(
    r'\b(2160p|4k|uhd|1440p|1080p|720p|576p|480p|360p|240p)\b',
    caseSensitive: false,
  );

  static const Map<String, StreamResolution> _resolutionTokens = {
    '2160p': StreamResolution.uhd2160,
    '4k': StreamResolution.uhd2160,
    'uhd': StreamResolution.uhd2160,
    '1440p': StreamResolution.qhd1440,
    '1080p': StreamResolution.fhd1080,
    '720p': StreamResolution.hd720,
    '576p': StreamResolution.sd576,
    '480p': StreamResolution.sd480,
    '360p': StreamResolution.sd360,
    '240p': StreamResolution.sd240,
  };

  static final RegExp _dimensionsPattern = RegExp(
    r'\b(\d{3,4})\s?[x×]\s?(\d{3,4})\b',
    caseSensitive: false,
  );

  /// `1.51 GB`, `700MB`, `1,4 GiB`. A bare `B` is not a unit here: no video
  /// is measured in bytes, and the number before it is usually something
  /// else entirely.
  static final RegExp _sizePattern = RegExp(
    r'(?<![\w.])(\d+(?:[.,]\d+)?)\s?([KMGT])i?B\b',
    caseSensitive: false,
  );

  static const Map<String, int> _sizeUnits = {
    'k': 1024,
    'm': 1024 * 1024,
    'g': 1024 * 1024 * 1024,
    't': 1024 * 1024 * 1024 * 1024,
  };

  /// The `👤 42` convention first, then the two ways an addon spells it out.
  static final List<RegExp> _seederPatterns = [
    RegExp(r'👤\s?(\d+)'),
    RegExp(r'\bseeder?s?\s*[:=]\s*(\d+)', caseSensitive: false),
    RegExp(r'\b(\d+)\s?seeders?\b', caseSensitive: false),
  ];

  /// Canonical label to what spells it. Iteration order is the display
  /// order of [tags], so the source comes before the dynamic range before
  /// the codec whatever order the addon wrote them in.
  static final Map<String, RegExp> _tagPatterns = {
    'REMUX': RegExp(r'\bremux\b', caseSensitive: false),
    'BluRay': RegExp(r'\bblu-?ray\b|\bbdremux\b', caseSensitive: false),
    'BDRip': RegExp(r'\b(?:bd|br)rip\b', caseSensitive: false),
    'WEB-DL': RegExp(r'\bweb-?dl\b', caseSensitive: false),
    'WEBRip': RegExp(r'\bweb-?rip\b', caseSensitive: false),
    'HDTV': RegExp(r'\bhdtv\b', caseSensitive: false),
    'DVDRip': RegExp(r'\bdvd-?rip\b', caseSensitive: false),
    'CAM': RegExp(r'\bcam(?:rip)?\b', caseSensitive: false),
    'HDR': RegExp(r'\bhdr(?:10)?\+?\b', caseSensitive: false),
    'DV': RegExp(r'\bdolby[ .]?vision\b|\bdo?vi?\b', caseSensitive: false),
    'HEVC': RegExp(r'\bx265\b|\bh\.?265\b|\bhevc\b', caseSensitive: false),
    'AVC': RegExp(r'\bx264\b|\bh\.?264\b|\bavc\b', caseSensitive: false),
    'AV1': RegExp(r'\bav1\b', caseSensitive: false),
    '10bit': RegExp(r'\b10-?bits?\b', caseSensitive: false),
    'Atmos': RegExp(r'\batmos\b', caseSensitive: false),
    'DTS': RegExp(r'\bdts(?:-?hd)?\b', caseSensitive: false),
    'PROPER': RegExp(r'\bproper\b', caseSensitive: false),
  };
}

/// A video height, as the ladder a sort walks down. The label is the way
/// the height is usually written, so a badge reads like the release does.
enum StreamResolution {
  uhd2160(2160, '2160p'),
  qhd1440(1440, '1440p'),
  fhd1080(1080, '1080p'),
  hd720(720, '720p'),
  sd576(576, '576p'),
  sd480(480, '480p'),
  sd360(360, '360p'),
  sd240(240, '240p');

  const StreamResolution(this.height, this.label);

  /// Pixels, and the only thing the comparator looks at.
  final int height;

  final String label;

  /// The rung [height] belongs to: the highest one it reaches. `1088`
  /// (a mod-16 1080p encode) is 1080p; anything below the bottom rung is
  /// null rather than pinned to it.
  static StreamResolution? forHeight(int height) {
    for (final resolution in values) {
      if (height >= resolution.height) return resolution;
    }
    return null;
  }
}

/// The order the flat sources list is in: **resolution first (highest
/// first), then seeders when both are known, then size (largest first)**.
///
/// Unknowns never sink a stream on their own:
///
/// - An unknown **resolution** is its own bucket, and that bucket sorts
///   after every known one. It is not zero and it is not interleaved: a
///   stream nobody could read a resolution from would otherwise land
///   between tiers at random, and a whole addon that names its streams
///   plainly would be scattered through the list.
/// - An unknown **seeder count** or **size** does not compare at all. The
///   tie simply is not broken there and falls through to the next rule,
///   which leaves the engine's own order (the addon's own ranking) intact
///   rather than pushing the stream anywhere.
///
/// Pure, and total in the sense a sort needs: reflexive, and consistent
/// whichever way round the arguments come.
int compareStreamFacts(StreamFacts a, StreamFacts b) {
  final byResolution = _compareBuckets(
    a.resolution?.height,
    b.resolution?.height,
  );
  if (byResolution != 0) return byResolution;
  final bySeeders = _compareKnown(a.seeders, b.seeders);
  if (bySeeders != 0) return bySeeders;
  return _compareKnown(a.sizeBytes, b.sizeBytes);
}

/// Larger first, with "unknown" as a bucket of its own after the known
/// values.
int _compareBuckets(int? a, int? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}

/// Larger first, but only when both sides are known; an unknown leaves the
/// tie for the next rule.
int _compareKnown(int? a, int? b) =>
    a == null || b == null ? 0 : b.compareTo(a);

/// [items] in [compareStreamFacts] order, **stably**: two streams that
/// compare equal come out in the order they went in, so what the addon
/// itself ranked first still shows through.
///
/// Stability has to be built here because `List.sort` does not promise it.
/// [facts] is called once per item.
List<T> sortedByStreamFacts<T>(
  List<T> items,
  StreamFacts Function(T item) facts,
) {
  final decorated = [
    for (final (index, item) in items.indexed) (index, item, facts(item)),
  ];
  decorated.sort((a, b) {
    final byFacts = compareStreamFacts(a.$3, b.$3);
    return byFacts != 0 ? byFacts : a.$1.compareTo(b.$1);
  });
  return [for (final entry in decorated) entry.$2];
}
