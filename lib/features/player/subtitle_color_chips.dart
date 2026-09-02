import 'package:flutter/material.dart';

import 'playback_tracks.dart';

/// Named colour swatches; the current value is selected by its hex string,
/// and a value outside the palette shows as a "Custom" chip so the picker
/// never claims a colour the user did not set.
class SubtitleColorChips extends StatelessWidget {
  const SubtitleColorChips({
    super.key,
    required this.colors,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final Map<String, String> colors;
  final String selected;
  final ValueChanged<String>? onSelected;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final normalized = selected.toUpperCase();
    final known = colors.values.any((hex) => hex.toUpperCase() == normalized);
    final onSelected = this.onSelected;
    Widget chip(String name, String hex) => ChoiceChip(
      avatar: CircleAvatar(
        backgroundColor:
            SubtitleStyle.parseRgbaHex(hex) ?? const Color(0x00000000),
        radius: 8,
      ),
      label: Text(name),
      selected: hex.toUpperCase() == normalized,
      onSelected: onSelected == null ? null : (_) => onSelected(hex),
    );
    return Padding(
      padding: padding,
      child: Wrap(
        spacing: 8,
        children: [
          for (final entry in colors.entries) chip(entry.key, entry.value),
          if (!known) chip('Custom ($selected)', selected),
        ],
      ),
    );
  }
}
