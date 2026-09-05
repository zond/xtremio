import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../downloads/download_labels.dart';
import 'language_names.dart';
import 'playback_engine.dart';
import 'subtitle_color_chips.dart';
import 'subtitle_groups.dart';
import 'subtitle_timing.dart';

/// The subtitle picker.
///
/// Three things, in the order they are worth having: **Off**, the tracks
/// already **in this file** (no download, always in sync with the release),
/// and the files the subtitle addons (or the stream itself) offer -- those
/// last **one row per language**, not one row per upload.
///
/// A language with more than one file names the one it would apply and
/// offers the rest behind a row of its own ("18 other Spanish files"),
/// because the reason to reach for a second upload is almost always that
/// the first is out of sync with this release. That row is a sibling of
/// the language row rather than a button inside it, so a remote's D-pad
/// reaches it with one press down: a control nested in a focused tile's
/// rect is skipped by directional traversal.
class SubtitleMenu extends StatefulWidget {
  const SubtitleMenu({
    super.key,
    required this.embedded,
    required this.groups,
    required this.activeId,
    required this.loading,
    required this.onOff,
    required this.onEmbedded,
    required this.onExternal,
    required this.onAdjustTiming,
  });

  final List<TrackInfo> embedded;

  /// The addons' files, one entry per language (see
  /// [groupSubtitlesByLanguage]).
  final List<SubtitleLanguageGroup> groups;

  /// [TrackInfo.id] of the active embedded track, or the URL of the active
  /// external one; null when subtitles are off.
  final String? activeId;

  /// Some subtitle addon has not answered yet.
  final bool loading;
  final VoidCallback onOff;
  final ValueChanged<TrackInfo> onEmbedded;
  final ValueChanged<SubtitleInfo> onExternal;

  /// Opens the panel that shifts and stretches what is playing. Offered
  /// only while something *is* playing: with subtitles off there is
  /// nothing on screen to move, and a control that does nothing visible
  /// is worse than one that is not there.
  final VoidCallback onAdjustTiming;

  /// The row that opens the hand adjustment.
  static const String adjustTimingLabel = 'Adjust timing';

  /// `title`, else the language, else a numbered fallback.
  static String embeddedLabel(TrackInfo track, int index) =>
      track.title ??
      (track.language == null
          ? 'Track ${index + 1}'
          : languageName(track.language!));

  static String externalLabel(SubtitleInfo subtitle) =>
      subtitle.label ?? languageName(subtitle.lang);

  /// The two words a file cut for the video that is playing earns on its
  /// row.
  ///
  /// Such a file is at the head of its language, and a row that is first
  /// for a reason should say the reason: a viewer scrolling past sixty
  /// uploads has no other way to tell the one the addon says was made
  /// for this exact release. It is a fact about the *upload*, not a
  /// verdict about its timing and not a number to reason about -- the
  /// declared rate is still shown nowhere.
  static const String releaseNote = 'same release';

  /// The second line under one of a language's files: the addon that
  /// offered it, and whether it was cut for what is playing.
  static String optionDetail(SubtitleOption option) => option.matchesRelease
      ? '${option.sourceName} · $releaseNote'
      : option.sourceName;

  /// What the row that shows or hides one language's other files says,
  /// collapsed and expanded.
  static String alternativesLabel(
    SubtitleLanguageGroup group, {
    required bool expanded,
  }) {
    final others = group.options.length - 1;
    if (expanded) return 'Hide other ${group.language} files';
    return '$others other ${group.language} '
        '${others == 1 ? 'file' : 'files'}';
  }

  @override
  State<SubtitleMenu> createState() => _SubtitleMenuState();
}

class _SubtitleMenuState extends State<SubtitleMenu> {
  /// The languages whose other files are shown, by display name. Kept in
  /// the state so a `player` update (an addon that answered late) does not
  /// fold an open group back up.
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final activeId = widget.activeId;
    return ListView(
      shrinkWrap: true,
      children: [
        const _MenuHeader('Subtitles'),
        _MenuTile(
          title: 'Off',
          selected: activeId == null,
          onTap: widget.onOff,
        ),
        // Above the list rather than below it: a language answers with
        // sixty-nine files often enough that the bottom of this sheet is
        // a scroll away, and what a viewer reaches for after picking a
        // file that drifts is this.
        if (activeId != null)
          ListTile(
            leading: const Icon(Icons.av_timer),
            title: const Text(SubtitleMenu.adjustTimingLabel),
            subtitle: const Text('Shift or stretch what is playing'),
            onTap: widget.onAdjustTiming,
          ),
        if (widget.embedded.isNotEmpty) ...[
          const _SectionLabel('In this file'),
          const _SectionNote(
            'Already in the video: nothing to download, and always in '
            'sync with this release.',
          ),
          for (final (index, track) in widget.embedded.indexed)
            _MenuTile(
              title: SubtitleMenu.embeddedLabel(track, index),
              subtitle: track.title != null && track.language != null
                  ? languageName(track.language!)
                  : null,
              selected: activeId == track.id,
              onTap: () => widget.onEmbedded(track),
            ),
        ],
        if (widget.groups.isNotEmpty || widget.loading)
          const _SectionLabel('From subtitle addons'),
        for (final group in widget.groups) ...[
          _MenuTile(
            title: group.language,
            subtitle: _groupDetail(group, activeId),
            selected: group.contains(activeId),
            onTap: () => widget.onExternal(group.chosen(activeId).subtitle),
          ),
          if (group.hasAlternatives) ...[
            _AlternativesTile(
              label: SubtitleMenu.alternativesLabel(
                group,
                expanded: _expanded.contains(group.language),
              ),
              expanded: _expanded.contains(group.language),
              onTap: () => setState(() {
                if (!_expanded.remove(group.language)) {
                  _expanded.add(group.language);
                }
              }),
            ),
            if (_expanded.contains(group.language))
              for (final option in group.options)
                _MenuTile(
                  indented: true,
                  title: option.name,
                  subtitle: SubtitleMenu.optionDetail(option),
                  selected: activeId == option.id,
                  onTap: () => widget.onExternal(option.subtitle),
                ),
          ],
        ],
        if (widget.loading)
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

  /// The second line of a language row: which of its files it would apply
  /// and where that one came from. With only one file there is nothing to
  /// pick between, so it is just the addon.
  ///
  /// The row names one particular file, so the mark that file earns
  /// belongs here as much as on its own row: picking the language row is
  /// how a file is applied without ever opening the list under it.
  static String _groupDetail(SubtitleLanguageGroup group, String? activeId) {
    final chosen = group.chosen(activeId);
    final detail = SubtitleMenu.optionDetail(chosen);
    return group.hasAlternatives ? '${chosen.name} · $detail' : detail;
  }
}

/// Which file to measure the playing subtitle against.
///
/// Opened from the timing panel's [SubtitleTimingOverlay.matchLabel], and
/// listing every *other* file on offer -- the one playing is what is being
/// measured, so it is not among them. The ordering is the menu's own, so
/// a file the addon says was cut for this release is at the head of its
/// language here too: it is the likeliest to be in sync, and being in
/// sync is the whole of what makes a good reference.
///
/// **The viewer picks, and nothing guesses.** The measurement is only as
/// good as the reference's own sync with the video, which no metadata
/// knows and no addon claims -- the viewer, having tried a file or two,
/// does.
class SubtitleReferenceMenu extends StatelessWidget {
  const SubtitleReferenceMenu({
    super.key,
    required this.groups,
    required this.playingId,
    required this.onPick,
  });

  /// The files on offer, grouped as the subtitle menu groups them.
  final List<SubtitleLanguageGroup> groups;

  /// What is playing ([SubtitleOption.id]), which is the file being
  /// measured and so never a reference.
  final String? playingId;

  final ValueChanged<SubtitleInfo> onPick;

  static const String title = SubtitleTimingOverlay.matchLabel;

  /// Said once, at the top: the one thing the viewer knows that the app
  /// cannot work out for itself.
  static const String note =
      'Pick a file you have seen keep time with this video. Its timings '
      'are what this one is measured against, so the answer is only as '
      'good as that file.';

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      children: [
        const _MenuHeader(title),
        const _SectionNote(note),
        for (final group in groups)
          if (group.options.any((option) => option.id != playingId)) ...[
            _SectionLabel(group.language),
            for (final option in group.options)
              if (option.id != playingId)
                ListTile(
                  leading: const Icon(Icons.compare_arrows),
                  title: Text(
                    option.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    SubtitleMenu.optionDetail(option),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => onPick(option.subtitle),
                ),
          ],
      ],
    );
  }
}

/// The row under a language that shows or hides its other files. A row of
/// its own, so the remote reaches it by moving down, indented to line up
/// with the options it opens.
class _AlternativesTile extends StatelessWidget {
  const _AlternativesTile({
    required this.label,
    required this.expanded,
    required this.onTap,
  });

  final String label;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.only(left: 40, right: 16),
    leading: Icon(expanded ? Icons.expand_less : Icons.expand_more),
    title: Text(
      label,
      style: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
    onTap: onTap,
  );
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

/// A line of explanation under a [_SectionLabel].
class _SectionNote extends StatelessWidget {
  const _SectionNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall
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
    this.indented = false,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  /// One of a language's alternatives rather than a top-level row.
  final bool indented;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: indented
        ? const EdgeInsets.only(left: 40, right: 16)
        : null,
    leading: Icon(
      selected ? Icons.radio_button_checked : Icons.radio_button_off,
    ),
    // A row is a thing to choose between, not a paragraph to read. Both
    // lines are addon text -- a release name runs to a hundred and twenty
    // characters, which is six lines of one row on a phone -- and
    // `ListTile` grows to fit whatever it is given, so the cap is here.
    title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: subtitle == null
        ? null
        : Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
    selected: selected,
    onTap: onTap,
  );
}
