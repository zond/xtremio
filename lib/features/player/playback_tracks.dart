import 'dart:ui' show Color;

import '../../core/state/profile.dart';

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

/// How text subtitles are drawn: `profile.settings.subtitlesSize` /
/// `subtitlesTextColor` / `subtitlesBackgroundColor` turned into a text
/// style (see [SubtitleStyle.fromSettings]).
///
/// Rendered by Flutter (media_kit's `SubtitleView`), not by libass, so this
/// is a text style rather than mpv `sub-*` properties. Bitmap subtitles
/// (PGS, VobSub) are not drawn in this path at all.
final class SubtitleStyle {
  const SubtitleStyle({
    this.fontSize = baseFontSize,
    this.color = const Color(0xFFFFFFFF),
    this.backgroundColor = const Color(0x00000000),
  });

  /// [fontSize] is [baseFontSize] scaled by `subtitlesSize` (percent); the
  /// colours are the settings' `#RRGGBBAA` strings, with the engine's
  /// defaults (white on nothing) for anything unparsable.
  factory SubtitleStyle.fromSettings(ProfileSettings settings) => SubtitleStyle(
    fontSize: baseFontSize * settings.subtitlesSize / 100,
    color: parseRgbaHex(settings.subtitlesTextColor) ?? const Color(0xFFFFFFFF),
    backgroundColor:
        parseRgbaHex(settings.subtitlesBackgroundColor) ??
        const Color(0x00000000),
  );

  /// Logical pixels at `subtitlesSize` 100 %.
  static const double baseFontSize = 32;

  /// The `subtitlesSize` values offered, in percent (stremio-web's list).
  static const List<int> sizes = [75, 100, 125, 150, 175, 200, 250];

  /// Text colours offered, as the `#RRGGBBAA` the setting stores.
  static const Map<String, String> textColors = {
    'White': '#FFFFFFFF',
    'Yellow': '#FFEB3BFF',
    'Cyan': '#4DD0E1FF',
    'Green': '#81C784FF',
    'Orange': '#FFB74DFF',
  };

  /// Background colours offered; fully transparent means no box.
  static const Map<String, String> backgroundColors = {
    'None': '#00000000',
    'Translucent': '#000000AA',
    'Black': '#000000FF',
    'Grey': '#424242FF',
  };

  /// Logical pixels.
  final double fontSize;
  final Color color;

  /// A box behind each line; fully transparent (the engine's default) draws
  /// none and the text gets a shadow for readability instead.
  final Color backgroundColor;

  bool get hasBackground => backgroundColor.a > 0;

  /// `#RRGGBB` or `#RRGGBBAA` (stremio-core's colour strings) to a [Color];
  /// null for anything else.
  static Color? parseRgbaHex(String hex) {
    final digits = hex.startsWith('#') ? hex.substring(1) : hex;
    if (digits.length != 6 && digits.length != 8) return null;
    final value = int.tryParse(digits, radix: 16);
    if (value == null) return null;
    final rgb = digits.length == 6 ? value : value >> 8;
    final alpha = digits.length == 6 ? 0xFF : value & 0xFF;
    return Color((alpha << 24) | rgb);
  }

  /// The `#RRGGBBAA` form of [color], upper-case as stremio-core writes it.
  static String toRgbaHex(Color color) {
    final argb = color.toARGB32();
    final rgba = ((argb & 0x00FFFFFF) << 8) | (argb >> 24);
    return '#${rgba.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }

  SubtitleStyle copyWith({
    double? fontSize,
    Color? color,
    Color? backgroundColor,
  }) => SubtitleStyle(
    fontSize: fontSize ?? this.fontSize,
    color: color ?? this.color,
    backgroundColor: backgroundColor ?? this.backgroundColor,
  );

  @override
  bool operator ==(Object other) =>
      other is SubtitleStyle &&
      other.fontSize == fontSize &&
      other.color == color &&
      other.backgroundColor == backgroundColor;

  @override
  int get hashCode => Object.hash(fontSize, color, backgroundColor);

  @override
  String toString() =>
      'SubtitleStyle($fontSize, ${toRgbaHex(color)} on '
      '${toRgbaHex(backgroundColor)})';
}
