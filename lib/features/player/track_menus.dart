import 'package:flutter/material.dart';

import 'playback_engine.dart';

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
