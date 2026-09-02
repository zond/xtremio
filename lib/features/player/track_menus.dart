import 'package:flutter/material.dart';

import '../../core/core.dart';
import 'language_names.dart';
import 'playback_engine.dart';

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

/// Playback speed and subtitle appearance.
class PlayerSettingsSheet extends StatelessWidget {
  const PlayerSettingsSheet({
    super.key,
    required this.rate,
    required this.rates,
    required this.onRate,
    required this.subtitleStyle,
  });

  final double rate;
  final List<double> rates;
  final ValueChanged<double> onRate;

  /// Edited in place; the player listens and restyles the subtitles.
  final ValueNotifier<SubtitleStyle> subtitleStyle;

  static String rateLabel(double rate) =>
      '${rate == rate.roundToDouble() ? rate.toInt() : rate}×';

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        const _MenuHeader('Playback settings'),
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
        const _SectionLabel('Subtitle style'),
        ValueListenableBuilder<SubtitleStyle>(
          valueListenable: subtitleStyle,
          builder: (context, style, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final size in SubtitleStyle.fontSizes)
                      ChoiceChip(
                        label: Text('${size.toInt()}'),
                        tooltip: 'Font size ${size.toInt()}',
                        selected: size == style.fontSize,
                        onSelected: (_) => subtitleStyle.value = style.copyWith(
                          fontSize: size,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final entry in SubtitleStyle.colors.entries)
                      ChoiceChip(
                        avatar: CircleAvatar(
                          backgroundColor: entry.value,
                          radius: 8,
                        ),
                        label: Text(entry.key),
                        selected: entry.value == style.color,
                        onSelected: (_) => subtitleStyle.value = style.copyWith(
                          color: entry.value,
                        ),
                      ),
                  ],
                ),
              ),
              SwitchListTile(
                title: const Text('Background box'),
                subtitle: const Text('Easier to read over bright scenes'),
                value: style.background,
                onChanged: (value) =>
                    subtitleStyle.value = style.copyWith(background: value),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
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
                      backgroundColor: style.background
                          ? const Color(0xAA000000)
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
