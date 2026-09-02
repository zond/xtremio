import 'stream.dart';

/// Quality hints addons bury in a stream's free-text `name` / `description`
/// (`"1080p"`, `"💾 1.51 GB"`, `"👤 42"`, `"Torrentio\n4k HDR"`), parsed
/// for chips. Nothing here is normative: the engine does not model quality.
final class StreamHints {
  const StreamHints({this.resolution, this.size, this.seeders, this.filename});

  /// `2160p` | `4K` | `1080p` | `720p` | `480p`, as written (4k upper-cased).
  final String? resolution;

  /// `1.51 GB`-style size, normalized to one space before the unit.
  final String? size;

  /// Seeder count, from a `👤 42` marker.
  final int? seeders;

  /// `behaviorHints.filename`, when the addon set it.
  final String? filename;

  static final RegExp _resolution = RegExp(
    r'\b(2160p|4k|1080p|720p|480p)\b',
    caseSensitive: false,
  );
  static final RegExp _size = RegExp(
    r'\b(\d+(?:\.\d+)?)\s?(GB|MB)\b',
    caseSensitive: false,
  );
  static final RegExp _seeders = RegExp(r'👤\s?(\d+)');

  /// Parses [stream]'s name, description and filename.
  factory StreamHints.of(StreamInfo stream) => StreamHints.parse(
    [?stream.name, ?stream.description, ?stream.filename].join('\n'),
    filename: stream.filename,
  );

  factory StreamHints.parse(String text, {String? filename}) {
    final resolution = _resolution.firstMatch(text)?.group(1);
    final size = _size.firstMatch(text);
    final seeders = _seeders.firstMatch(text)?.group(1);
    return StreamHints(
      resolution: resolution == null
          ? null
          : resolution.toLowerCase() == '4k'
          ? '4K'
          : resolution.toLowerCase(),
      size: size == null
          ? null
          : '${size.group(1)} ${size.group(2)!.toUpperCase()}',
      seeders: seeders == null ? null : int.tryParse(seeders),
      filename: filename,
    );
  }

  /// Chip labels in display order.
  List<String> get chips => [
    ?resolution,
    ?size,
    if (seeders != null) '$seeders seeders',
  ];

  /// [text] with the size and seeder hints and their emoji markers removed
  /// (resolutions stay: they are usually part of a filename), or null when
  /// nothing readable is left, so a `💾 1.51 GB` description does not
  /// repeat the size chip.
  String? strip(String? text) {
    if (text == null) return null;
    final stripped = text
        .replaceAll(_seeders, '')
        .replaceAll(_size, '')
        .replaceAll(RegExp(r'[💾👤📺🎬⚙️]'), '')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAllMapped(RegExp(r'(^|\n)[ |·\-,]+'), (m) => m.group(1)!)
        .replaceAll(RegExp(r'\n\s*\n'), '\n')
        .trim();
    return stripped.isEmpty ? null : stripped;
  }
}
