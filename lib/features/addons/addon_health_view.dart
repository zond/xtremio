import 'package:flutter/material.dart';

import '../../core/core.dart';
import 'addon_health.dart';

/// How the Installed list is ordered.
enum AddonHealthSort {
  /// The profile's own order, which is the order the engine asks the addons
  /// in. The default, because it is the order everything else in the app
  /// shows them in.
  profileOrder('Profile order'),

  /// The two verdicts that name a problem first, so the addons worth
  /// deciding about are at the top of the list rather than somewhere in it.
  leastUsefulFirst('Least useful first');

  const AddonHealthSort(this.label);

  final String label;
}

/// Where a verdict puts an addon in [AddonHealthSort.leastUsefulFirst].
///
/// Broken, then useless, then not-yet-known, then working; an addon with no
/// verdict at all (a protected one) sorts last, since it cannot be
/// uninstalled and is never a decision to make. Ties keep profile order, so
/// the sort rearranges as little as it can.
int addonUsefulnessRank(AddonHealthVerdict? verdict) => switch (verdict) {
  AddonHealthVerdict.broken => 0,
  AddonHealthVerdict.useless => 1,
  AddonHealthVerdict.notEnoughEvidence => 2,
  AddonHealthVerdict.useful => 3,
  null => 4,
};

/// [addons] ordered by [sort], stably.
List<AddonDescriptor> sortedByHealth(
  List<AddonDescriptor> addons,
  AddonHealthSort sort,
  AddonHealthReport report,
  DateTime now,
) {
  if (sort == AddonHealthSort.profileOrder) return addons;
  final ranked = [
    for (var index = 0; index < addons.length; index++)
      (
        index,
        addonUsefulnessRank(report.healthOf(addons[index])?.verdict(now)),
        addons[index],
      ),
  ]..sort((a, b) => a.$2 == b.$2 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [for (final entry in ranked) entry.$3];
}

/// The verdict, as a chip that opens the evidence behind it.
///
/// It is tappable because a verdict nobody can check is a verdict nobody
/// should act on: the counts, when the addon last worked, and which of its
/// resources the numbers are about are all one tap away. The chevron is
/// what says so -- a verdict drawn as bare words reads as a label, which
/// is why the evidence behind it was asked for a second time by someone
/// who already had it.
class AddonHealthChip extends StatelessWidget {
  const AddonHealthChip({
    super.key,
    required this.addon,
    required this.health,
    required this.now,
  });

  final AddonDescriptor addon;
  final AddonHealth health;
  final DateTime now;

  /// The glyph for "there is more behind this": the same chevron a
  /// settings row, a track submenu and a source section wear, rather than a
  /// fifth way of saying it.
  static const IconData affordance = Icons.chevron_right;

  /// How big the chevron is drawn: a shade above the label's own size, so
  /// it is legible without becoming the loudest thing on the row.
  static const double affordanceSize = 14;

  /// The colour a verdict is drawn in: red for unreachable, amber for
  /// rarely having anything, grey for not knowing, and the theme's own
  /// accent for working. The label says the same thing in words, so the
  /// colour is a second reading and never the only one.
  static Color colorOf(AddonHealthVerdict verdict, ThemeData theme) =>
      switch (verdict) {
        AddonHealthVerdict.broken => theme.colorScheme.error,
        AddonHealthVerdict.useless => Colors.amber.shade400,
        AddonHealthVerdict.notEnoughEvidence =>
          theme.colorScheme.onSurfaceVariant,
        AddonHealthVerdict.useful => theme.colorScheme.primary,
      };

  /// What the chip says: the verdict, and for a working addon how often the
  /// resource it is asked for most actually has something. That share is
  /// the whole of what "working" is claiming, so it is shown rather than
  /// hidden behind the tap.
  static String labelOf(AddonHealth health, DateTime now) {
    final verdict = health.verdict(now);
    if (verdict != AddonHealthVerdict.useful) return verdict.label;
    final busiest = health.busiestKind(now);
    final record = busiest == null ? null : health.decayedTo(now)[busiest];
    if (busiest == null || record == null) return verdict.label;
    final percent = (record.answeredRatio * 100).round();
    return '${verdict.label} · ${busiest.label} $percent%';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verdict = health.verdict(now);
    final color = colorOf(verdict, theme);
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) =>
            AddonHealthEvidence(addon: addon, health: health, now: now),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              labelOf(health, now),
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
            const SizedBox(width: 2),
            Icon(affordance, size: affordanceSize, color: color),
          ],
        ),
      ),
    );
  }
}

/// Everything the verdict was read off: when the addon last worked, and the
/// three counts for every resource kind it declares.
class AddonHealthEvidence extends StatelessWidget {
  const AddonHealthEvidence({
    super.key,
    required this.addon,
    required this.health,
    required this.now,
  });

  final AddonDescriptor addon;
  final AddonHealth health;
  final DateTime now;

  static const String neverWorked = 'Never worked';
  static const String notAsked = 'not asked yet';
  static const String fading =
      'Counts fade: an answer is worth half as much a fortnight later, so an '
      'addon that has been fixed stops being argued with.';

  /// When the addon last answered with something, in words. Addon-wide,
  /// because that is what the verdict's silence half reads.
  static String lastWorked(DateTime? lastOk, DateTime now) {
    if (lastOk == null) return neverWorked;
    final days = now.difference(lastOk).inDays;
    if (days <= 0) return 'Last worked today';
    if (days == 1) return 'Last worked 1 day ago';
    return 'Last worked $days days ago';
  }

  /// One resource kind's line. A kind the addon declares but nothing has
  /// ever asked it for reads [notAsked] rather than three zeroes: the app
  /// only ever sees what a screen actually requested, and an unscrolled
  /// catalog was never asked at all.
  static String kindLine(
    AddonResourceKind kind,
    AddonHealthRecord? record,
    DateTime now,
  ) {
    if (record == null) return '${kind.label} · $notAsked';
    final aged = record.decayedTo(now);
    return '${kind.label} · ${aged.ok.round()} answered · '
        '${aged.empty.round()} empty · ${aged.fail.round()} failed';
  }

  /// The kinds to account for: everything the manifest declares, plus
  /// anything that was observed and is no longer declared (an addon can
  /// change its manifest, and hiding those counts would hide part of what
  /// the verdict was read off).
  List<AddonResourceKind> get kinds => [
    for (final kind in AddonResourceKind.values)
      if (health.declared.contains(kind) || health.records.containsKey(kind))
        kind,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verdict = health.verdict(now);
    final records = health.records;
    return AlertDialog(
      title: Text(addon.manifest.name),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AddonHealthChip.labelOf(health, now),
              style: theme.textTheme.titleSmall?.copyWith(
                color: AddonHealthChip.colorOf(verdict, theme),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              lastWorked(health.lastOk, now),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            for (final kind in kinds)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  kindLine(kind, records[kind], now),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              fading,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Says that nothing has answered since the app started, which is a
/// statement about the connection and not about any addon.
///
/// It matters most exactly here: a list of addons that have all just failed
/// is the most tempting place to uninstall a working one. The record itself
/// is not affected — a sweep in which everything failed is recorded against
/// nobody — so this is the only warning the viewer gets.
class AddonConnectionBanner extends StatelessWidget {
  const AddonConnectionBanner({super.key});

  static const String text =
      'Nothing has answered since the app started. That usually means this '
      'device cannot reach the internet, not that these addons are broken — '
      'and none of it has been counted against them.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Icon(
              Icons.wifi_off_outlined,
              color: theme.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
