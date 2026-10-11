/// What the viewer has said about titles: liked, disliked, or not interested.
///
/// Two buttons on a details screen -- a happy face and a sad one -- and the
/// "Not interested" of a For you tile write here. What they say is read by
/// the For you row: a liked title weighs more as a source, a disliked one
/// is no source at all and never suggested, a dismissed one is never
/// suggested again.
///
/// **Ids and nothing else.** A row is a title's id, which face, and when it
/// was given. No name, no poster: nothing here is worth redacting, and a
/// row is the same few bytes on the device as on the service it is synced
/// to (`FacesSync`).
///
/// **Newest wins, per title, and clearing is a value.** Pressing the active
/// face clears it, and that is written down as a row with no face and the
/// time it was cleared rather than as an absence -- an absence is what
/// another device that has not heard yet looks like, and merging would
/// bring the old face back. [Faces.clearedAt] is the same idea for the whole
/// set: "Forget my likes" on any device stamps it, and every row older is
/// dropped wherever it is merged.
library;

import 'package:flutter/foundation.dart';

/// One of the things a title can be marked with.
enum Face {
  /// The happy face.
  like('like'),

  /// The sad face.
  dislike('dislike'),

  /// "Not interested" on a For you tile.
  dismissed('dismissed');

  const Face(this.stored);

  /// The word written to the preferences file and sent to the service.
  final String stored;

  static Face? parse(Object? value) => switch (value) {
    'like' => Face.like,
    'dislike' => Face.dislike,
    'dismissed' => Face.dismissed,
    _ => null,
  };
}

/// What one title is marked with, and when that was said. [face] null is a
/// face taken off again.
@immutable
final class FaceMark {
  const FaceMark(this.face, this.at);

  final Face? face;

  /// Milliseconds since the epoch, UTC.
  final int at;

  /// The word on the wire: a face's, or `none` for a cleared one.
  String get stored => face?.stored ?? 'none';

  Map<String, Object> toJson() => {'kind': stored, 'at': at};

  /// One stored or sent row, or null when it is not one this build reads.
  static FaceMark? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final kind = json['kind'];
    if (at is! int || at < 0) return null;
    if (kind == 'none') return FaceMark(null, at);
    final face = Face.parse(kind);
    return face == null ? null : FaceMark(face, at);
  }

  @override
  bool operator ==(Object other) =>
      other is FaceMark && other.face == face && other.at == at;

  @override
  int get hashCode => Object.hash(face, at);

  @override
  String toString() => 'FaceMark($stored, $at)';
}

/// Every title marked, by id.
@immutable
final class Faces {
  const Faces(this.marks, {this.clearedAt = 0});

  static const Faces empty = Faces({});

  /// Title id to its mark, cleared marks included.
  final Map<String, FaceMark> marks;

  /// When the whole set was last forgotten, in milliseconds; every mark at
  /// or before it is dropped by [merged]. Zero for never.
  final int clearedAt;

  /// How many marks are kept at most: far past what anybody presses, and
  /// small enough that the whole set is one request.
  static const int limit = 5000;

  /// What [id] is marked with now, or null.
  Face? of(String id) => marks[id]?.face;

  /// The ids marked [face].
  Set<String> idsWith(Face face) => {
    for (final MapEntry(:key, :value) in marks.entries)
      if (value.face == face) key,
  };

  /// This set with [id] marked [face] (null clears it) at [at].
  Faces marking(String id, Face? face, DateTime at) => Faces(
    _capped({...marks, id: FaceMark(face, at.toUtc().millisecondsSinceEpoch)}),
    clearedAt: clearedAt,
  );

  /// [marks] cut to the newest [limit], which is all the service keeps.
  static Map<String, FaceMark> _capped(Map<String, FaceMark> marks) {
    if (marks.length <= limit) return marks;
    final newest = marks.entries.toList()
      ..sort((a, b) => b.value.at.compareTo(a.value.at));
    return Map.fromEntries(newest.take(limit));
  }

  /// This set and [other] together: per title the newer mark (this one's on
  /// a tie), the later [clearedAt] of the two, and every mark at or before
  /// that dropped. A mark only one side has is kept -- which is what makes
  /// a first sync add the device's set to the service's rather than
  /// replace it.
  Faces merged(Faces other) {
    final cleared = clearedAt > other.clearedAt ? clearedAt : other.clearedAt;
    final result = <String, FaceMark>{};
    for (final source in [marks, other.marks]) {
      for (final MapEntry(:key, :value) in source.entries) {
        if (value.at <= cleared) continue;
        final held = result[key];
        if (held == null || value.at > held.at) result[key] = value;
      }
    }
    return Faces(_capped(result), clearedAt: cleared);
  }

  Map<String, Object> toJson() => {
    'faces': {
      for (final MapEntry(:key, :value) in marks.entries) key: value.toJson(),
    },
    'clearedAt': clearedAt,
  };

  /// A stored or answered set; rows this build cannot read are dropped, and
  /// anything that is not a set at all is [empty].
  static Faces fromJson(Object? json) {
    if (json is! Map) return empty;
    final raw = json['faces'];
    final marks = <String, FaceMark>{};
    if (raw is Map) {
      for (final MapEntry(:key, :value) in raw.entries) {
        final mark = FaceMark.fromJson(value);
        if (key is String && key.isNotEmpty && mark != null) marks[key] = mark;
      }
    }
    final cleared = json['clearedAt'];
    return Faces(marks, clearedAt: cleared is int && cleared > 0 ? cleared : 0);
  }

  @override
  bool operator ==(Object other) =>
      other is Faces &&
      other.clearedAt == clearedAt &&
      mapEquals(other.marks, marks);

  @override
  int get hashCode => Object.hash(
    clearedAt,
    Object.hashAllUnordered(
      marks.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );
}

/// Every account's faces on this device, apart: each mark is kept under
/// the Stremio user id it was made under, or under [nobody] when it was
/// made signed out.
///
/// So signing out of one account and into another does not hand the first
/// one's likes to the second. The faces shown are the signed-in account's
/// and nobody's ([shownFor]); another account's stay here untouched and
/// come back when that account signs in again. Nobody's go to the first
/// account that syncs, once, and leave this set as they do (`FacesSync`).
@immutable
final class FacesByAccount {
  const FacesByAccount(this.accounts);

  static const FacesByAccount empty = FacesByAccount({});

  /// The owner of the marks made signed out.
  static const String nobody = '';

  /// Owner (a user id, or [nobody]) to that owner's marks.
  final Map<String, Faces> accounts;

  /// [owner]'s own marks; null is [nobody].
  Faces of(String? owner) => accounts[owner ?? nobody] ?? Faces.empty;

  /// What the device shows while [owner] is signed in (null: signed out):
  /// that account's marks and nobody's, the newer on a title they share.
  Faces shownFor(String? owner) =>
      owner == null ? of(null) : of(owner).merged(of(null));

  /// This with [owner]'s marks replaced by [faces].
  FacesByAccount withOwner(String? owner, Faces faces) => FacesByAccount({
    for (final MapEntry(:key, :value) in accounts.entries)
      if (key != (owner ?? nobody)) key: value,
    if (faces.marks.isNotEmpty || faces.clearedAt != 0) owner ?? nobody: faces,
  });

  bool get isEmpty => accounts.isEmpty;

  Map<String, Object> toJson() => {
    'byAccount': {
      for (final MapEntry(:key, :value) in accounts.entries)
        key: value.toJson(),
    },
  };

  /// The stored value. A set written before marks had owners (the shape of
  /// [Faces.toJson]) was made by nobody anybody can name now, so it is
  /// [nobody]'s and goes to the first account that syncs.
  static FacesByAccount fromJson(Object? json) {
    if (json is! Map) return empty;
    final byAccount = json['byAccount'];
    if (byAccount is! Map) {
      final old = Faces.fromJson(json);
      return empty.withOwner(null, old);
    }
    var result = empty;
    for (final MapEntry(:key, :value) in byAccount.entries) {
      if (key is! String) continue;
      result = result.withOwner(
        key == nobody ? null : key,
        Faces.fromJson(value),
      );
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is FacesByAccount && mapEquals(other.accounts, accounts);

  @override
  int get hashCode => Object.hashAllUnordered(
    accounts.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}
