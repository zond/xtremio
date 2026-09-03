import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../downloads/download_labels.dart';
import 'language_names.dart';
import 'playback_engine.dart';
import 'subtitle_color_chips.dart';

/// The subtitle picker: off, the tracks embedded in the file, and the files
/// the subtitle addons (or the stream itself) offer.
class SubtitleMenu extends StatelessWidget {
  const SubtitleMenu({
    super.key,
    required this.embedded,
    required this.external,
    required this.activeId,
    required this.loading,
    required this.onOff,
    required this.onEmbedded,
    required this.onExternal,
  });

  final List<TrackInfo> embedded;
  final List<SubtitleInfo> external;

  /// [TrackInfo.id] of the active embedded track, or the URL of the active
  /// external one; null when subtitles are off.
  final String? activeId;

  /// Some subtitle addon has not answered yet.
  final bool loading;
  final VoidCallback onOff;
  final ValueChanged<TrackInfo> onEmbedded;
  final ValueChanged<SubtitleInfo> onExternal;

  /// `title`, else the language, else a numbered fallback.
  static String embeddedLabel(TrackInfo track, int index) =>
      track.title ??
      (track.language == null
          ? 'Track ${index + 1}'
          : languageName(track.language!));

  static String externalLabel(SubtitleInfo subtitle) =>
      subtitle.label ?? languageName(subtitle.lang);

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      children: [
        const _MenuHeader('Subtitles'),
        _MenuTile(title: 'Off', selected: activeId == null, onTap: onOff),
        if (embedded.isNotEmpty) const _SectionLabel('In this file'),
        for (final (index, track) in embedded.indexed)
          _MenuTile(
            title: embeddedLabel(track, index),
            subtitle: track.title != null && track.language != null
                ? languageName(track.language!)
                : null,
            selected: activeId == track.id,
            onTap: () => onEmbedded(track),
          ),
        if (external.isNotEmpty || loading) const _SectionLabel('From addons'),
        for (final subtitle in external)
          _MenuTile(
            title: externalLabel(subtitle),
            subtitle: subtitle.url.host,
            selected: activeId == subtitle.url.toString(),
            onTap: () => onExternal(subtitle),
          ),
        if (loading)
          const ListTile(
            leading: SizedBox(
              width: 24,
              height: 24,
              child: Padding(
                padding: EdgeInsets.all(2),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            title: Text('Looking for subtitles…'),
          ),
      ],
    );
  }
}

/// The audio track picker.
class AudioMenu extends StatelessWidget {
  const AudioMenu({
    super.key,
    required this.tracks,
    required this.activeId,
    required this.onSelect,
  });

  final List<TrackInfo> tracks;
  final String? activeId;
  final ValueChanged<TrackInfo> onSelect;

  static String label(TrackInfo track, int index) =>
      track.title ??
      (track.language == null
          ? 'Audio ${index + 1}'
          : languageName(track.language!));

  /// Language (when the title took the first line), channel layout and
  /// codec, whichever are known.
  static String? details(TrackInfo track) {
    final parts = [
      if (track.title != null && track.language != null)
        languageName(track.language!),
      ?track.channels,
      ?track.codec,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      children: [
        const _MenuHeader('Audio'),
        for (final (index, track) in tracks.indexed)
          _MenuTile(
            title: label(track, index),
            subtitle: details(track),
            selected: activeId == track.id,
            onTap: () => onSelect(track),
          ),
      ],
    );
  }
}

/// What the player's settings sheet shows about the buffer: the choice in
/// force for the playback on screen, whether the whole-file download it
/// asked for is still being taken, and what to say about it (the device had
/// no room; the file is being kept). Carried as one value so the sheet can
/// listen to it while it is open -- the pin is answered after the sheet is
/// already up.
final class BufferAheadStatus {
  const BufferAheadStatus(this.choice, {this.busy = false, this.note});

  final BufferAhead choice;
  final bool busy;
  final String? note;
}

/// Playback speed and subtitle appearance, and the way out to what is kept
/// on the device. The appearance is the profile's `subtitlesSize` /
/// `subtitlesTextColor` / `subtitlesBackgroundColor`, so a pick here is an
/// `UpdateSettings` that every later player sees too.
class PlayerSettingsSheet extends StatelessWidget {
  const PlayerSettingsSheet({
    super.key,
    required this.rate,
    required this.rates,
    required this.onRate,
    required this.settings,
    required this.onSetting,
    this.onDownloads,
    this.buffer = const BufferAheadStatus(BufferAhead.normal),
    this.onBufferAhead,
  });

  final double rate;
  final List<double> rates;
  final ValueChanged<double> onRate;

  /// How far ahead this playback is buffering, and what became of the
  /// last choice.
  final BufferAheadStatus buffer;

  /// Changes it for this playback only; null when nothing can act on it
  /// (no player below this sheet). Reverts to the app-wide default with
  /// the next playback, which is what makes it worth having here as well
  /// as in Settings.
  final ValueChanged<BufferAhead>? onBufferAhead;

  /// The profile settings the style is read from.
  final ProfileSettings settings;

  /// Writes one setting; null while the settings are not known yet (the
  /// `ctx` field has not arrived), which disables the style chips: a
  /// partial map would be rejected by the engine.
  final void Function(String key, Object? value)? onSetting;

  /// Opens the Downloads screen. This is the player's only menu, so it is
  /// where the list has to be reachable from while something is playing;
  /// null when there is no downloads client above the player.
  final VoidCallback? onDownloads;

  /// The chip for one buffer choice, so a test (and the remote) can find it.
  static Key bufferChipKey(BufferAhead choice) =>
      ValueKey('buffer-${choice.stored}');

  static String rateLabel(double rate) =>
      '${rate == rate.roundToDouble() ? rate.toInt() : rate}×';

  static String sizeLabel(int percent) => '$percent %';

  @override
  Widget build(BuildContext context) {
    final style = SubtitleStyle.fromSettings(settings);
    final onSetting = this.onSetting;
    return ListView(
      shrinkWrap: true,
      // A `ListView` with no padding of its own takes the safe area out of
      // `MediaQuery` -- which is how the subtitle and audio menus stay off
      // a television's overscan band. Setting a padding opts out of that,
      // so the band has to be added back by hand or the last setting ends
      // up under the cropped edge of the panel.
      padding: EdgeInsets.only(
        bottom: 16 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        const _MenuHeader('Playback settings'),
        if (onDownloads != null)
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text(kDownloadsScreenTooltip),
            subtitle: const Text('What is kept for offline playback'),
            trailing: const Icon(Icons.chevron_right),
            onTap: onDownloads,
          ),
        _SectionLabel('Buffer ahead${buffer.busy ? ' …' : ''}'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              for (final choice in BufferAhead.values)
                ChoiceChip(
                  key: bufferChipKey(choice),
                  label: Text(choice.label),
                  selected: choice == buffer.choice,
                  onSelected: onBufferAhead == null || buffer.busy
                      ? null
                      : (_) => onBufferAhead!(choice),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            buffer.note ?? buffer.choice.description,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        const _SectionLabel('Speed'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              for (final option in rates)
                ChoiceChip(
                  label: Text(rateLabel(option)),
                  selected: option == rate,
                  onSelected: (_) => onRate(option),
                ),
            ],
          ),
        ),
        const _SectionLabel('Subtitle size'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              for (final size in SubtitleStyle.sizes)
                ChoiceChip(
                  label: Text(sizeLabel(size)),
                  selected: size == settings.subtitlesSize,
                  onSelected: onSetting == null
                      ? null
                      : (_) =>
                            onSetting(ProfileSettings.subtitlesSizeKey, size),
                ),
            ],
          ),
        ),
        const _SectionLabel('Subtitle colour'),
        SubtitleColorChips(
          colors: SubtitleStyle.textColors,
          selected: settings.subtitlesTextColor,
          onSelected: onSetting == null
              ? null
              : (hex) => onSetting(ProfileSettings.subtitlesTextColorKey, hex),
        ),
        const _SectionLabel('Subtitle background'),
        SubtitleColorChips(
          colors: SubtitleStyle.backgroundColors,
          selected: settings.subtitlesBackgroundColor,
          onSelected: onSetting == null
              ? null
              : (hex) =>
                    onSetting(ProfileSettings.subtitlesBackgroundColorKey, hex),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
            color: const Color(0xFF303030),
            child: Text(
              'Subtitle preview',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: style.fontSize * 0.6,
                color: style.color,
                backgroundColor: style.hasBackground
                    ? style.backgroundColor
                    : null,
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            'Text subtitles only (SRT, WebVTT, ASS text). Bitmap '
            'subtitles such as PGS or VobSub are listed but not drawn yet.',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _MenuHeader extends StatelessWidget {
  const _MenuHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.title,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(
      selected ? Icons.radio_button_checked : Icons.radio_button_off,
    ),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    selected: selected,
    onTap: onTap,
  );
}
