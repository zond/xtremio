/// What the viewer fixed about a subtitle's timing, remembered under what
/// caused it.
///
/// Nothing re-times a subtitle but the viewer, because a declared frame
/// rate says where an upload came from and not how it is timed. What that
/// leaves is the correction they made by hand, and a correction made once
/// is worth not making again: the same subtitle group, on the same show,
/// is out by the same amount next episode.
///
/// The two adjustments have different causes, so they are remembered
/// under different keys, and the asymmetry is the whole point:
///
/// - **A speed is series + subtitle group.** What a file was timed
///   against is a property of where it came from, and the addon's own
///   grouping (`SubtitleInfo.group`) says that better than the declared
///   rate does. Video releases of one show almost always share a frame
///   rate, so a speed learned against one release carries safely to the
///   next.
/// - **A shift is series + subtitle group + video release.** An offset is
///   the video's pre-roll less whatever pre-roll the subtitle's source
///   assumed, so it depends on *both* sides: change either and the answer
///   changes.
///
/// Any part of a key being unknown -- an addon that sends no group, a
/// release nothing has named yet -- means that adjustment is not
/// remembered at all. A narrower key is forgotten more often, and being
/// forgotten is the price of never being wrong.
library;

import 'package:flutter/foundation.dart';

/// One adjustment the viewer made, with the parts of the key that caused
/// it.
///
/// A speed entry carries no [release] and a shift entry carries one,
/// which is how the two are told apart both here and in the stored file.
@immutable
final class SubtitleSyncEntry {
  /// A speed the viewer chose for [group]'s files of [series], as
  /// [SubtitleSyncMemory] stores it (`SubtitleSpeedDirection.stored`).
  ///
  /// The value is opaque here: this is the file's shape, and what a
  /// direction is called is the player's business.
  const SubtitleSyncEntry.speed({
    required this.series,
    required this.group,
    required String direction,
  }) : release = null,
       speed = direction,
       shiftSteps = 0;

  /// An offset the viewer measured between [group]'s files of [series]
  /// and this particular [release], counted in presses of the shift
  /// control so it is the same integer the panel is holding.
  const SubtitleSyncEntry.shift({
    required this.series,
    required this.group,
    required String this.release,
    required int steps,
  }) : speed = null,
       shiftSteps = steps;

  /// The show or film the adjustment was made on: the meta item's id,
  /// not the episode's, since an episode is not what a subtitle group is
  /// timed against.
  final String series;

  /// The addon's grouping of the file that was adjusted
  /// (`SubtitleInfo.group`).
  final String group;

  /// The video release the offset was measured against, and null on a
  /// speed entry -- which does not depend on one.
  final String? release;

  /// The stored direction of the speed toggle, and null on a shift
  /// entry.
  final String? speed;

  /// Presses of the shift control, and 0 on a speed entry.
  final int shiftSteps;

  /// The entry as it is written to the preferences file: only the fields
  /// that are part of this kind, so a speed row and a shift row are
  /// visibly different things in a file someone may well read.
  Map<String, Object> toJson() => {
    'series': series,
    'group': group,
    'release': ?release,
    'speed': ?speed,
    if (release != null) 'shift': shiftSteps,
  };

  /// One stored row, or null when it is not one this build can use: a
  /// missing key part, a value of the wrong type, a row that names
  /// neither adjustment. Preferences are forgiving -- a row that cannot
  /// be read is dropped, never a failure to load.
  static SubtitleSyncEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final series = _token(json['series']);
    final group = _token(json['group']);
    if (series == null || group == null) return null;
    final release = _token(json['release']);
    if (release == null) {
      final speed = _token(json['speed']);
      return speed == null
          ? null
          : SubtitleSyncEntry.speed(
              series: series,
              group: group,
              direction: speed,
            );
    }
    final steps = json['shift'];
    if (steps is! int || steps == 0) return null;
    return SubtitleSyncEntry.shift(
      series: series,
      group: group,
      release: release,
      steps: steps,
    );
  }

  /// Whether this remembers a speed for the same series and group.
  bool isSpeedFor(String series, String group) =>
      speed != null && this.series == series && this.group == group;

  /// Whether this remembers a shift for the same series, group and
  /// release. All three, because all three caused it.
  bool isShiftFor(String series, String group, String release) =>
      this.release == release && this.series == series && this.group == group;

  static String? _token(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleSyncEntry &&
      other.series == series &&
      other.group == group &&
      other.release == release &&
      other.speed == speed &&
      other.shiftSteps == shiftSteps;

  @override
  int get hashCode => Object.hash(series, group, release, speed, shiftSteps);
}

/// Every adjustment still remembered, most recently made first.
///
/// Recency is the order itself rather than a timestamp: it is what the
/// bound drops by, and a stored time would be one more thing to keep
/// honest for no more answer than the position already gives.
@immutable
final class SubtitleSyncMemory {
  const SubtitleSyncMemory(this.entries);

  /// Nothing remembered: a fresh install, and what an unreadable stored
  /// value reads as.
  static const SubtitleSyncMemory empty = SubtitleSyncMemory(
    <SubtitleSyncEntry>[],
  );

  /// Most recently made first. Nothing else depends on the order, so
  /// [remembering] is free to move what it touches to the front.
  final List<SubtitleSyncEntry> entries;

  /// How many adjustments are kept. Two per show -- a speed and a shift
  /// -- so this is dozens of shows, and a viewer who fixes twenty does
  /// not pay for the twenty-first with a file that grows for the life of
  /// the install.
  ///
  /// What falls off the end is what was adjusted longest ago, which is
  /// the one thing about a correction that says it is unlikely to be
  /// wanted again.
  static const int limit = 64;

  /// The stored direction remembered for [group]'s files of [series], or
  /// null when none is.
  String? speedFor({required String? series, required String? group}) {
    if (series == null || group == null) return null;
    for (final entry in entries) {
      if (entry.isSpeedFor(series, group)) return entry.speed;
    }
    return null;
  }

  /// The presses of the shift control remembered for [group]'s files of
  /// [series] against [release], and 0 when none are -- including when
  /// any part of the key is unknown.
  int shiftStepsFor({
    required String? series,
    required String? group,
    required String? release,
  }) {
    if (series == null || group == null || release == null) return 0;
    for (final entry in entries) {
      if (entry.isShiftFor(series, group, release)) return entry.shiftSteps;
    }
    return 0;
  }

  /// This memory with what the viewer has now got on screen written into
  /// it: [speed] and [shiftSteps] under their own keys, both moved to the
  /// front, and either dropped when it has gone back to untouched.
  ///
  /// Untouched is *forgotten* rather than stored as a correction of zero.
  /// A viewer who presses Reset is saying this file needs nothing, and
  /// nothing remembered is exactly what nothing applied looks like next
  /// time.
  ///
  /// Nothing is remembered without a [series] and a [group] to key it on,
  /// and no shift without a [release]: a guess about which files an
  /// adjustment belongs to would apply it to files it was never made for.
  /// The shift entries are left alone when the release is unknown --
  /// there is no way to tell which of them this would have replaced.
  SubtitleSyncMemory remembering({
    required String? series,
    required String? group,
    required String? release,
    required String? speed,
    required int shiftSteps,
  }) {
    if (series == null || group == null) return this;
    final kept = [
      for (final entry in entries)
        if (!entry.isSpeedFor(series, group) &&
            !(release != null && entry.isShiftFor(series, group, release)))
          entry,
    ];
    final updated = <SubtitleSyncEntry>[
      if (speed != null)
        SubtitleSyncEntry.speed(series: series, group: group, direction: speed),
      if (release != null && shiftSteps != 0)
        SubtitleSyncEntry.shift(
          series: series,
          group: group,
          release: release,
          steps: shiftSteps,
        ),
      ...kept,
    ];
    final bounded = updated.length <= limit
        ? updated
        : updated.sublist(0, limit);
    final next = SubtitleSyncMemory(List.unmodifiable(bounded));
    return next == this ? this : next;
  }

  /// What is written under the preferences' one key: a list, because a
  /// JSON object's key order is not something either side of the FFI
  /// boundary promises to keep, and the order here *is* the recency.
  List<Object> toJson() => [for (final entry in entries) entry.toJson()];

  /// Reads the stored value, dropping any row this build cannot use and
  /// keeping at most [limit] of them -- a file written by a build with a
  /// larger bound is not a reason to carry an unbounded list around.
  static SubtitleSyncMemory fromJson(Object? json) {
    if (json is! List) return empty;
    final entries = <SubtitleSyncEntry>[];
    for (final row in json) {
      final entry = SubtitleSyncEntry.fromJson(row);
      if (entry != null) entries.add(entry);
      if (entries.length == limit) break;
    }
    return entries.isEmpty ? empty : SubtitleSyncMemory(entries);
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleSyncMemory && listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hashAll(entries);
}
