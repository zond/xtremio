import 'dart:ui' show Color;

/// One selectable audio or subtitle track the engine found in the media.
/// Our own value type so the [PlaybackEngine] interface stays free of
/// `media_kit` types (and tests can build them by hand).
final class TrackInfo {
  const TrackInfo({
    required this.id,
    this.title,
    this.language,
    this.isDefault = false,
    this.codec,
    this.channels,
  });

  /// The backend's track id (mpv's numeric `id`, as a string).
  final String id;
  final String? title;

  /// ISO 639 code as the container carries it (`eng`, `en`, ...).
  final String? language;
  final bool isDefault;

  /// Audio only: codec name and channel layout when the demuxer knows them.
  final String? codec;
  final String? channels;

  @override
  bool operator ==(Object other) =>
      other is TrackInfo &&
      other.id == id &&
      other.title == title &&
      other.language == language &&
      other.isDefault == isDefault &&
      other.codec == codec &&
      other.channels == channels;

  @override
  int get hashCode =>
      Object.hash(id, title, language, isDefault, codec, channels);

  @override
  String toString() => 'TrackInfo($id, $title, $language)';
}

/// The tracks available in the open media plus which ones are selected.
/// Synthetic `auto`/`no` entries are not listed; "no subtitles" is
/// [activeSubtitleId] `== null`.
final class PlaybackTracks {
  const PlaybackTracks({
    this.audio = const [],
    this.subtitle = const [],
    this.activeAudioId,
    this.activeSubtitleId,
  });

  final List<TrackInfo> audio;
  final List<TrackInfo> subtitle;
  final String? activeAudioId;

  /// The embedded subtitle track's id, or the URL of an external one
  /// loaded through `setExternalSubtitle`.
  final String? activeSubtitleId;

  /// Same tracks with different selections; a null argument clears one
  /// when its `clear` flag is set.
  PlaybackTracks copyWith({
    String? activeAudioId,
    String? activeSubtitleId,
    bool clearSubtitle = false,
  }) => PlaybackTracks(
    audio: audio,
    subtitle: subtitle,
    activeAudioId: activeAudioId ?? this.activeAudioId,
    activeSubtitleId: clearSubtitle
        ? null
        : activeSubtitleId ?? this.activeSubtitleId,
  );

  @override
  bool operator ==(Object other) =>
      other is PlaybackTracks &&
      _listEquals(other.audio, audio) &&
      _listEquals(other.subtitle, subtitle) &&
      other.activeAudioId == activeAudioId &&
      other.activeSubtitleId == activeSubtitleId;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(audio),
    Object.hashAll(subtitle),
    activeAudioId,
    activeSubtitleId,
  );

  static bool _listEquals(List<TrackInfo> a, List<TrackInfo> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// How text subtitles are drawn.
///
/// Rendered by Flutter (media_kit's `SubtitleView`), not by libass, so this
/// is a text style rather than mpv `sub-*` properties. Bitmap subtitles
/// (PGS, VobSub) are not drawn in this path at all.
final class SubtitleStyle {
  const SubtitleStyle({
    this.fontSize = 32,
    this.color = const Color(0xFFFFFFFF),
    this.background = true,
  });

  /// Logical pixels.
  final double fontSize;
  final Color color;

  /// A translucent black box behind each line, for readability on bright
  /// scenes.
  final bool background;

  static const List<double> fontSizes = [22, 28, 32, 40, 48];

  static const Map<String, Color> colors = {
    'White': Color(0xFFFFFFFF),
    'Yellow': Color(0xFFFFEB3B),
    'Cyan': Color(0xFF4DD0E1),
    'Green': Color(0xFF81C784),
  };

  SubtitleStyle copyWith({double? fontSize, Color? color, bool? background}) =>
      SubtitleStyle(
        fontSize: fontSize ?? this.fontSize,
        color: color ?? this.color,
        background: background ?? this.background,
      );

  @override
  bool operator ==(Object other) =>
      other is SubtitleStyle &&
      other.fontSize == fontSize &&
      other.color == color &&
      other.background == background;

  @override
  int get hashCode => Object.hash(fontSize, color, background);
}
