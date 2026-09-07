/// What the viewer fixed about a subtitle's timing, remembered under what
/// caused it.
///
/// Nothing re-times a subtitle but the viewer, because a declared frame
/// rate says where an upload came from and not how it is timed. What that
/// leaves is the correction they made by hand, and a correction made once
/// is worth not making again: the same release group, on the same show,
/// is out by the same amount next episode.
///
/// The two adjustments have different causes, so they are remembered
/// under different keys, and the asymmetry is the whole point:
///
/// - **A speed is series + release group.** What a file was timed against
///   is a property of where it came from, and the group that cut the
///   release (`SubtitleInfo.releaseGroupKey`, lower-cased) is the one
///   thing an addon says about a file that means the same thing on the
///   next episode. Video releases of one show almost always share a frame
///   rate, so a speed learned against one release carries safely to the
///   next.
/// - **A shift is series + release group + video release.** An offset is
///   the video's pre-roll less whatever pre-roll the subtitle's source
///   assumed, so it depends on *both* sides: change either and the answer
///   changes.
///
/// This used to key on the addon's own bucket (`g`), which was believed to
/// name one uploader's batch across a whole series and does not: it is
/// re-assigned per answer, so the integer that meant the WEBRip family
/// last episode means the DVDRip one this episode (`SubtitleInfo.group`
/// carries the measurement). A speed looked up under it therefore usually
/// missed, and now and then hit a family it was never measured on.
///
/// Both are real numbers, because both are now *measured*: a viewer
/// marking the picture right, or a match against a file they say is in
/// sync, solves for a ratio and an offset that no menu of values
/// contains. The ratio the owner's own Swedish files want is 1.0440
/// where the PAL constant is 1.0427, and the three seconds between those
/// two across an episode is the whole reason this stopped being a
/// direction.
///
/// Any part of a key being unknown -- an addon that names no release
/// group, a release nothing has named yet -- means that adjustment is not
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
  /// The multiplier the viewer's corrections came to for
  /// [releaseGroup]'s files of [series]: `sub-speed`, with 1.0 being the
  /// file's own timing.
  ///
  /// Whether it was measured or judged is not recorded, because nothing
  /// reads it back differently: what is stored is the number that was on
  /// the player.
  const SubtitleSyncEntry.speed({
    required this.series,
    required this.releaseGroup,
    required double ratio,
  }) : release = null,
       speed = ratio,
       shiftSeconds = 0;

  /// The offset the viewer's corrections came to between
  /// [releaseGroup]'s files of [series] and this particular [release]:
  /// `sub-delay`, in seconds.
  const SubtitleSyncEntry.shift({
    required this.series,
    required this.releaseGroup,
    required String this.release,
    required double seconds,
  }) : speed = null,
       shiftSeconds = seconds;

  /// The show or film the adjustment was made on: the meta item's id,
  /// not the episode's, since an episode is not what a subtitle group is
  /// timed against.
  final String series;

  /// The group that cut the release the adjusted file was made for,
  /// lower-cased (`SubtitleInfo.releaseGroupKey`) -- the only name an
  /// addon gives a file that survives to the next episode.
  final String releaseGroup;

  /// The video release the offset was measured against, and null on a
  /// speed entry -- which does not depend on one.
  final String? release;

  /// The multiplier, and null on a shift entry.
  final double? speed;

  /// The offset in seconds, and 0 on a speed entry.
  final double shiftSeconds;

  /// The entry as it is written to the preferences file: only the fields
  /// that are part of this kind, so a speed row and a shift row are
  /// visibly different things in a file someone may well read.
  Map<String, Object> toJson() => {
    'series': series,
    'releaseGroup': releaseGroup,
    'release': ?release,
    'speed': ?speed,
    if (release != null) 'shiftSeconds': shiftSeconds,
  };

  /// One stored row, or null when it is not one this build can use: a
  /// missing key part, a value of the wrong type, a row that names
  /// neither adjustment. Preferences are forgiving -- a row that cannot
  /// be read is dropped, never a failure to load.
  ///
  /// That is also the whole of the migration off the two builds before
  /// this one. A `speed` of `"stretch"` is not a number and a row with no
  /// `shiftSeconds` names no offset, so the rows that stored a toggle
  /// direction and a count of presses go; and a row keyed on the addon's
  /// bucket wrote that under `group` rather than `releaseGroup`, so those
  /// go too. They lapse rather than being carried over, because a `g`
  /// cannot be turned into a release group: the name is not in the row,
  /// and the answer it was an index into is long gone. What that costs is
  /// one adjustment made a second time. What keeping them would cost is a
  /// multiplier applied under a key that never meant what it was stored
  /// as -- which is the bug this re-key exists to end.
  static SubtitleSyncEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final series = _token(json['series']);
    final releaseGroup = _token(json['releaseGroup']);
    if (series == null || releaseGroup == null) return null;
    final release = _token(json['release']);
    if (release == null) {
      final ratio = _number(json['speed']);
      return ratio == null
          ? null
          : SubtitleSyncEntry.speed(
              series: series,
              releaseGroup: releaseGroup,
              ratio: ratio,
            );
    }
    final seconds = _number(json['shiftSeconds']);
    if (seconds == null || seconds == 0) return null;
    return SubtitleSyncEntry.shift(
      series: series,
      releaseGroup: releaseGroup,
      release: release,
      seconds: seconds,
    );
  }

  /// Whether this remembers a speed for the same series and release
  /// group.
  bool isSpeedFor(String series, String releaseGroup) =>
      speed != null &&
      this.series == series &&
      this.releaseGroup == releaseGroup;

  /// Whether this remembers a shift for the same series, release group
  /// and release. All three, because all three caused it.
  bool isShiftFor(String series, String releaseGroup, String release) =>
      this.release == release &&
      this.series == series &&
      this.releaseGroup == releaseGroup;

  static String? _token(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  /// [value] as a correction, or null when it is not one. A NaN or an
  /// infinity is not: both survive a round trip through Dart's own JSON
  /// codec, and both would reach `sub-speed` or `sub-delay` as a number
  /// the player cannot use. What range a *usable* correction is in is
  /// the player's business rather than the file's.
  static double? _number(Object? value) {
    if (value is! num) return null;
    final number = value.toDouble();
    return number.isFinite ? number : null;
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleSyncEntry &&
      other.series == series &&
      other.releaseGroup == releaseGroup &&
      other.release == release &&
      other.speed == speed &&
      other.shiftSeconds == shiftSeconds;

  @override
  int get hashCode =>
      Object.hash(series, releaseGroup, release, speed, shiftSeconds);
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

  /// The multiplier remembered for [releaseGroup]'s files of [series],
  /// or null when none is.
  double? speedFor({required String? series, required String? releaseGroup}) {
    if (series == null || releaseGroup == null) return null;
    for (final entry in entries) {
      if (entry.isSpeedFor(series, releaseGroup)) return entry.speed;
    }
    return null;
  }

  /// The offset in seconds remembered for [releaseGroup]'s files of
  /// [series] against [release], and 0 when none is -- including when any
  /// part of the key is unknown.
  double shiftSecondsFor({
    required String? series,
    required String? releaseGroup,
    required String? release,
  }) {
    if (series == null || releaseGroup == null || release == null) return 0;
    for (final entry in entries) {
      if (entry.isShiftFor(series, releaseGroup, release)) {
        return entry.shiftSeconds;
      }
    }
    return 0;
  }

  /// This memory with what the viewer has now got on screen written into
  /// it: [speed] and [shiftSeconds] under their own keys, both moved to
  /// the front, and either dropped when it has gone back to untouched.
  ///
  /// Untouched is *forgotten* rather than stored as a correction of zero.
  /// A viewer who presses Reset is saying this file needs nothing, and
  /// nothing remembered is exactly what nothing applied looks like next
  /// time.
  ///
  /// Nothing is remembered without a [series] and a [releaseGroup] to key
  /// it on, and no shift without a [release]: a guess about which files an
  /// adjustment belongs to would apply it to files it was never made for.
  /// The shift entries are left alone when the release is unknown --
  /// there is no way to tell which of them this would have replaced.
  SubtitleSyncMemory remembering({
    required String? series,
    required String? releaseGroup,
    required String? release,
    required double? speed,
    required double shiftSeconds,
  }) {
    if (series == null || releaseGroup == null) return this;
    final kept = [
      for (final entry in entries)
        if (!entry.isSpeedFor(series, releaseGroup) &&
            !(release != null &&
                entry.isShiftFor(series, releaseGroup, release)))
          entry,
    ];
    final updated = <SubtitleSyncEntry>[
      if (speed != null)
        SubtitleSyncEntry.speed(
          series: series,
          releaseGroup: releaseGroup,
          ratio: speed,
        ),
      if (release != null && shiftSeconds != 0)
        SubtitleSyncEntry.shift(
          series: series,
          releaseGroup: releaseGroup,
          release: release,
          seconds: shiftSeconds,
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
