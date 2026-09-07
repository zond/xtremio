import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../../widgets/focusable_tile.dart';
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
    this.picks,
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

  /// How often this viewer has picked each language, or null where
  /// nothing keeps count -- a player mounted with no preferences above
  /// it.
  ///
  /// **The counts, not a ranking.** Which languages win is decided here,
  /// over the languages of [groups] and [embedded] together, because
  /// [pinnedNote] claims a comparison among the languages *on offer
  /// here* and the widget drawing the sheet is the only thing that knows
  /// what is on offer. A caller handing down a finished ranking could
  /// rank less than the sheet -- rank the addons' rows alone, and the
  /// note calls one of them the commonest on offer with a language
  /// picked three times as often drawn a few rows above it -- and
  /// nothing here could tell, because the counts that would show it up
  /// stayed with the caller. So there is no such parameter, and the
  /// comparison the note reports is the one that was really made.
  ///
  /// A language of [groups] that wins is **lifted, not copied** -- it
  /// appears once, above, and not again in the alphabet below, because
  /// two rows that apply the same file are exactly what `_disambiguated`
  /// exists to prevent. A winner this sheet offers only as a track in
  /// [embedded] is not lifted at all: its row is drawn above this
  /// section already, so there is nothing here to move, and [pinnedNote]
  /// is what says where it went.
  ///
  /// A language the sheet does not offer at all cannot win: a pin moves a
  /// row that exists, and this menu never invents one for a language
  /// nothing answered with.
  final SubtitlePickMemory? picks;

  /// Opens the panel that shifts and stretches what is playing. Offered
  /// only while something *is* playing: with subtitles off there is
  /// nothing on screen to move, and a control that does nothing visible
  /// is worse than one that is not there.
  final VoidCallback onAdjustTiming;

  /// The row that opens the hand adjustment.
  static const String adjustTimingLabel = 'Adjust timing';

  /// The heading over the lifted rows.
  static const String pinnedLabel = 'You usually pick';

  /// What that heading's note says, which has to be true of one row as
  /// well as of two: a viewer with a single second language sees one.
  ///
  /// **"on offer here" is the whole of what makes it true, and "here" is
  /// the whole sheet.** A pin is only ever a language this episode
  /// actually offers, so the language this viewer really picks most often
  /// can be missing from the answer altogether -- and then a note calling
  /// the row above it their commonest asserts the opposite of what the
  /// counts say. The comparison [SubtitlePickMemory.pinned] makes is
  /// among the languages on offer, and that is the comparison this
  /// sentence reports.
  ///
  /// The languages in the file are on offer here too, three rows up, so
  /// they are in that comparison ([picks]) -- and one of them can win a
  /// place without there being a row down here to lift. [shown] is the
  /// rows lifted and [inFile] the winners already drawn as tracks in the
  /// video: the count in the first sentence is both, which is what the
  /// ranking really compared, and the second sentence is what stops that
  /// count promising a row it did not move.
  ///
  /// What makes the first sentence true is that this menu ranked the
  /// sheet itself, both sections of it, and drew the note from that same
  /// ranking -- which is why [picks] is the counts and not a ranking a
  /// caller could have taken over less than the sheet.
  static String pinnedNote(int shown, {int inFile = 0}) {
    final total = shown + inFile;
    final head = total == 1
        ? 'The language on offer here that you pick most often'
        : 'The $total languages on offer here that you pick most often';
    if (inFile == 0) return '$head, lifted out of the list below.';
    return '$head. ${inFile == 1 ? 'One is' : '$inFile are'} already in '
        'this file, above; ${shown == 1 ? 'the other is' : 'the rest are'} '
        'lifted out of the list below.';
  }

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

  /// The languages this viewer picks most often *of the ones this sheet
  /// offers*, most picked first: [SubtitleMenu.picks] asked about the
  /// addons' rows and the video's own tracks together.
  ///
  /// The union is built here, out of the two lists this widget draws,
  /// and that is the whole of what makes [SubtitleMenu.pinnedNote]'s "on
  /// offer here" true: nothing outside the menu gets to decide what was
  /// compared. A language the file and an addon both offer is named
  /// twice and counted once, because it is one language to the viewer
  /// and one to the counts (`subtitleLanguageLabel` is what both are
  /// stored under, and `SubtitlePickMemory.pinned` keeps the first
  /// mention). The alphabet is named first so a tie between two addon
  /// rows still comes out alphabetically, and a tie with a track in the
  /// file is spent on the row a viewer would otherwise have to find.
  List<String> get _pinnedLanguages =>
      widget.picks?.pinned([
        for (final group in widget.groups) group.language,
        for (final track in widget.embedded)
          if (track.language case final code? when code.trim().isNotEmpty)
            subtitleLanguageLabel(code),
      ]) ??
      const [];

  /// The pinned groups, in the order [_pinnedLanguages] puts them, and
  /// everything else in the order it arrived -- which is the alphabet
  /// [subtitlesByRelease] left it in.
  ///
  /// Two things leave the section off the sheet rather than heading an
  /// empty one. Lifting every language there is moves no row nearer the
  /// top and costs a heading and a note for it. And a winner can have no
  /// row down here at all, because the file carries it and its row is
  /// two sections up: when both winners are like that nothing is lifted,
  /// and the freed slots are deliberately *not* handed to the next
  /// language down -- the heading says these are the ones picked most
  /// often, the third most picked is not that, and the two that are sit
  /// at the top of this sheet already.
  (List<SubtitleLanguageGroup>, List<SubtitleLanguageGroup>) _split(
    List<String> languages,
  ) {
    final pinned = [
      for (final language in languages)
        for (final group in widget.groups)
          if (group.language == language) group,
    ];
    if (pinned.isEmpty || pinned.length == widget.groups.length) {
      return (const [], widget.groups);
    }
    return (
      pinned,
      [
        for (final group in widget.groups)
          if (!pinned.contains(group)) group,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeId = widget.activeId;
    final pinnedLanguages = _pinnedLanguages;
    final (pinned, rest) = _split(pinnedLanguages);
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
        if (pinned.isNotEmpty) ...[
          const _SectionLabel(SubtitleMenu.pinnedLabel),
          _SectionNote(
            // The winners the lift did not take are the ones the file
            // itself carries: every winner came out of the union
            // [_pinnedLanguages] built from these two lists, so a
            // language with no row lifted down here has one drawn up
            // there.
            SubtitleMenu.pinnedNote(
              pinned.length,
              inFile: pinnedLanguages.length - pinned.length,
            ),
          ),
          for (final group in pinned) ..._languageRows(group, activeId),
        ],
        if (rest.isNotEmpty || widget.loading)
          const _SectionLabel('From subtitle addons'),
        for (final group in rest) ..._languageRows(group, activeId),
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

  /// One language: the row that applies its best-known file, and -- where
  /// it has more than one -- the row that opens the rest under it.
  ///
  /// One list of rows for both sections, because a pinned language is the
  /// same row moved and not a different kind of row: the file it applies,
  /// the mark it carries and the files behind it are whatever they would
  /// have been down in the alphabet.
  List<Widget> _languageRows(SubtitleLanguageGroup group, String? activeId) => [
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
  ];

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
/// offering every *other* file on offer -- the one playing is what is
/// being measured, so it is not among them. The ordering is the menu's
/// own, so a file the addon says was cut for this release is at the head
/// of its language here too: it is the likeliest to be in sync, and being
/// in sync is the whole of what makes a good reference. **One row per
/// language**, for the same reason the subtitle menu has one, with the
/// rest of a language behind a row of their own.
///
/// **The viewer picks, and nothing guesses.** The measurement is only as
/// good as the reference's own sync with the video, which no metadata
/// knows and no addon claims -- the viewer, having tried a file or two,
/// does.
class SubtitleReferenceMenu extends StatefulWidget {
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

  /// What the row that shows or hides a language's remaining candidates
  /// says. [others] is the count behind it, the head of the language
  /// being drawn already.
  static String othersLabel(
    String language,
    int others, {
    required bool expanded,
  }) {
    if (expanded) return 'Hide other $language files';
    return '$others other $language ${others == 1 ? 'file' : 'files'}';
  }

  @override
  State<SubtitleReferenceMenu> createState() => _SubtitleReferenceMenuState();
}

class _SubtitleReferenceMenuState extends State<SubtitleReferenceMenu> {
  /// The languages whose other files are shown, by display name. Kept in
  /// the state so a `player` update (an addon that answered late) does
  /// not fold an open group back up.
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      children: [
        const _MenuHeader(SubtitleReferenceMenu.title),
        const _SectionNote(SubtitleReferenceMenu.note),
        for (final group in widget.groups) ..._language(group),
      ],
    );
  }

  /// One language: the file it would offer first, and the rest behind a
  /// row of their own.
  ///
  /// The same shape as [SubtitleMenu], and for the same reason. A
  /// language answers with sixty-nine files often enough that listing
  /// every candidate of every language puts the second language sixty-odd
  /// presses down a remote's D-pad -- and reaching for a *second*
  /// language is exactly what this sheet is for, since the reason to
  /// match at all is that the file in one language is out of sync. The
  /// head of a language is the likeliest reference anyway: the ordering
  /// puts the file the addon says was cut for this release first.
  List<Widget> _language(SubtitleLanguageGroup group) {
    final candidates = group.options
        .where((option) => option.id != widget.playingId)
        .toList();
    if (candidates.isEmpty) return const [];
    final expanded = _expanded.contains(group.language);
    return [
      _SectionLabel(group.language),
      _referenceTile(candidates.first),
      if (candidates.length > 1) ...[
        _AlternativesTile(
          label: SubtitleReferenceMenu.othersLabel(
            group.language,
            candidates.length - 1,
            expanded: expanded,
          ),
          expanded: expanded,
          onTap: () => setState(() {
            if (!_expanded.remove(group.language)) {
              _expanded.add(group.language);
            }
          }),
        ),
        if (expanded)
          for (final option in candidates.skip(1)) _referenceTile(option),
      ],
    ];
  }

  Widget _referenceTile(SubtitleOption option) => ListTile(
    leading: const Icon(Icons.compare_arrows),
    title: Text(option.name, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      SubtitleMenu.optionDetail(option),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    onTap: () => widget.onPick(option.subtitle),
  );
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
                FocusMarked(
                  borderRadius: FocusMarked.stadium,
                  child: ChoiceChip(
                    key: bufferChipKey(choice),
                    label: Text(choice.label),
                    selected: choice == buffer.choice,
                    onSelected: onBufferAhead == null || buffer.busy
                        ? null
                        : (_) => onBufferAhead!(choice),
                  ),
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
                FocusMarked(
                  borderRadius: FocusMarked.stadium,
                  child: ChoiceChip(
                    label: Text(rateLabel(option)),
                    selected: option == rate,
                    onSelected: (_) => onRate(option),
                  ),
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
                FocusMarked(
                  borderRadius: FocusMarked.stadium,
                  child: ChoiceChip(
                    label: Text(sizeLabel(size)),
                    selected: size == settings.subtitlesSize,
                    onSelected: onSetting == null
                        ? null
                        : (_) =>
                              onSetting(ProfileSettings.subtitlesSizeKey, size),
                  ),
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

/// One row of a picker.
///
/// A plain [ListTile], and deliberately not wrapped in a [FocusMarked] the
/// way the chips two sections up are. These menus are a modal bottom sheet
/// -- the app's own surface, in the app's own near-black, with a known
/// contrast against a near-white fill -- and not something drawn over the
/// video, which is the case the double ring exists for. So the theme
/// floor's fill is the whole of the indicator here, and a row that lifted
/// and cast a shadow as focus walked sixty uploads would only make the
/// list harder to read. See `FocusTheme`.
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
