/// The record of what a Google Drive pairing has left behind: which files
/// this device can reach, and since when.
///
/// The phone hands the television two things -- a refresh token and the id
/// of the file the viewer picked -- and they are not the same kind of
/// thing at all, so they are not stored in the same place. The token is a
/// live credential and lives in the [SecretStore]. This half is a list of
/// file ids and names, which is no more secret than the library is, and
/// lives in the preferences file with everything else the viewer chose.
///
/// The list is **not** a list of grants. One token reaches every file the
/// account has ever picked through this OAuth client -- measured: a token
/// from a second pairing reads a file picked during the first -- so this
/// is a record of what was linked and therefore what to *show*, never a
/// permission check. Nothing here can take a file away, which is why
/// there is no "unlink one file": see [DriveAccount.unlink].
library;

import 'package:flutter/foundation.dart';

/// Which catalogue title a linked file turned out to be.
///
/// **The identity and not the decoration.** The one question asked of this
/// record is not "what does the row draw" but "given a meta id and a video
/// id, which linked files are that?" -- a linked `Breaking Bad S01E01`
/// belongs under that episode on the ordinary details screen, and a match
/// that recorded only enough to draw a poster would leave whatever asks
/// that question to redo the matching. So the id, the type and, for an
/// episode, the season and the episode are all here, and [videoId] answers
/// the question in the shape the engine already asks it in.
///
/// [name] and [year] are the catalogue's own, kept so that a list of linked
/// files can say what each one matched without asking Cinemeta again. They
/// are what the answer *said*, not a second opinion about it.
///
/// [season] and [episode] come from the **filename**, not from Cinemeta:
/// the search catalogue answers with titles and has no videos in it, and
/// the file is the only thing that knows which episode it holds. They are
/// either both set (an episode) or both null (a film).
@immutable
final class LinkedDriveMatch {
  const LinkedDriveMatch({
    required this.cinemetaId,
    required this.type,
    required this.name,
    this.year,
    this.season,
    this.episode,
  });

  /// The catalogue's id, an `tt`-prefixed IMDb id for everything Cinemeta
  /// answers. What every other addon in the app is keyed on.
  final String cinemetaId;

  /// stremio's own type word: `movie` or `series`. Not derived from the
  /// presence of an episode, because a route needs it either way and
  /// guessing it later is the migration this record exists to avoid.
  final String type;

  /// What the catalogue calls the title.
  final String name;

  /// The year the catalogue gave, when it gave one.
  final int? year;

  final int? season;
  final int? episode;

  /// Both halves of an episode are known, so this file is one episode of a
  /// series rather than a whole title.
  bool get isEpisode => season != null && episode != null;

  /// The engine's own id for the video this file holds
  /// (`tt0903747:1:1`), or null for a film -- whose video id *is* its meta
  /// id, which callers already have.
  String? get videoId => isEpisode ? '$cinemetaId:$season:$episode' : null;

  /// Whether this match is [cinemetaId], and [videoId] when one is asked
  /// for. The reverse lookup, in one place: see [LinkedDriveFiles.matching].
  bool isFor(String cinemetaId, {String? videoId}) =>
      this.cinemetaId == cinemetaId &&
      (videoId == null || videoId == (this.videoId ?? cinemetaId));

  Map<String, Object> toJson() => {
    'id': cinemetaId,
    'type': type,
    'name': name,
    'year': ?year,
    'season': ?season,
    'episode': ?episode,
  };

  /// One stored match, or null when it is not one this build can use.
  ///
  /// An id and a type are what a lookup and a route need, and a match
  /// missing either is not a match -- it is a row claiming one. A season
  /// without an episode, or the reverse, is half a claim about which video
  /// this is, so both are dropped together rather than one being invented.
  static LinkedDriveMatch? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final type = json['type'];
    if (id is! String || id.trim().isEmpty) return null;
    if (type is! String || type.trim().isEmpty) return null;
    final name = json['name'];
    final season = json['season'];
    final episode = json['episode'];
    final whole = season is int && episode is int;
    return LinkedDriveMatch(
      cinemetaId: id.trim(),
      type: type.trim(),
      name: name is String ? name : '',
      year: json['year'] is int ? json['year'] as int : null,
      season: whole ? season : null,
      episode: whole ? episode : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LinkedDriveMatch &&
      other.cinemetaId == cinemetaId &&
      other.type == type &&
      other.name == name &&
      other.year == year &&
      other.season == season &&
      other.episode == episode;

  @override
  int get hashCode =>
      Object.hash(cinemetaId, type, name, year, season, episode);

  @override
  String toString() => 'LinkedDriveMatch(${videoId ?? cinemetaId}, $name)';
}

/// One file a pairing linked.
@immutable
final class LinkedDriveFile {
  const LinkedDriveFile({
    required this.fileId,
    required this.name,
    required this.mimeType,
    required this.linkedAt,
    this.match,
  });

  /// Drive's own id for the file, which is what a byte-range request is
  /// made against and the only field here that must be right.
  final String fileId;

  /// What the file is called in the viewer's Drive, for the list they are
  /// shown. A name is what a person recognises; the id is not.
  final String name;

  /// What Drive says it is (`video/x-matroska`, `video/mp4`). Kept because
  /// a Drive folder holds more than films, and the list has to be able to
  /// say what it is offering without opening anything.
  final String mimeType;

  /// When this file was first linked, in UTC. Stamped by [DriveAccount]
  /// from its clock rather than taken from a caller, so every row in the
  /// list is on the same clock.
  final DateTime linkedAt;

  /// Which catalogue title this file turned out to be, or null.
  ///
  /// It is here rather than in a second list keyed by [fileId] because two
  /// records of the same thing start disagreeing the moment one of them is
  /// written and the other is not. One field and not three loose ones for
  /// the same reason a level narrower: a season with no id, or an id with
  /// no type, is a half-answer nothing can act on, and a
  /// [LinkedDriveMatch] cannot half-exist.
  ///
  /// Null until a match is made, and null for a file no match is ever
  /// found for, which is an ordinary outcome and not a failure -- see
  /// `drive_match.dart`.
  final LinkedDriveMatch? match;

  /// The matched title's id, for the readers that want only that.
  String? get cinemetaId => match?.cinemetaId;

  /// Whether this file is the video [videoId] of [cinemetaId] (or the film
  /// [cinemetaId], when no video is named). False for a file nothing has
  /// matched.
  bool isFor(String cinemetaId, {String? videoId}) =>
      match?.isFor(cinemetaId, videoId: videoId) ?? false;

  /// This row with [match] recorded, or cleared when it is null.
  LinkedDriveFile withMatch(LinkedDriveMatch? match) => LinkedDriveFile(
    fileId: fileId,
    name: name,
    mimeType: mimeType,
    linkedAt: linkedAt,
    match: match,
  );

  /// The row as it is written to the preferences file. The match is written
  /// only when there is one, so a file somebody reads does not claim one
  /// that was never made.
  Map<String, Object> toJson() => {
    'id': fileId,
    'name': name,
    'mime': mimeType,
    'linkedAt': linkedAt.toUtc().toIso8601String(),
    'match': ?match?.toJson(),
  };

  /// One stored row, or null when it is not one this build can use.
  ///
  /// A row with no id is nothing: the id is what a request is made
  /// against. Everything else has an answer for being missing -- an empty
  /// name draws as an empty name, an unknown mime type is no worse than a
  /// wrong one, and an unreadable stamp is the epoch, which sorts last
  /// and says plainly that nobody knows. Dropping the row instead would
  /// hide a file the token still reaches.
  static LinkedDriveFile? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) return null;
    final name = json['name'];
    final mime = json['mime'];
    final linkedAt = json['linkedAt'];
    return LinkedDriveFile(
      fileId: id.trim(),
      name: name is String ? name : '',
      mimeType: mime is String ? mime : '',
      linkedAt:
          (linkedAt is String ? DateTime.tryParse(linkedAt) : null)?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      match: LinkedDriveMatch.fromJson(json['match']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LinkedDriveFile &&
      other.fileId == fileId &&
      other.name == name &&
      other.mimeType == mimeType &&
      other.linkedAt == linkedAt &&
      other.match == match;

  @override
  int get hashCode => Object.hash(fileId, name, mimeType, linkedAt, match);

  @override
  String toString() => 'LinkedDriveFile($fileId, $name)';
}

/// Every file that has been linked, most recently linked first.
@immutable
final class LinkedDriveFiles {
  const LinkedDriveFiles(this.entries);

  /// Nothing linked: a fresh install, and what an unreadable stored value
  /// reads as.
  static const LinkedDriveFiles empty = LinkedDriveFiles(<LinkedDriveFile>[]);

  /// One per file. The order is recency, and nothing reads it as anything
  /// else, so [linking] is free to move what it touches to the front.
  final List<LinkedDriveFile> entries;

  /// No bound, unlike the other lists in the preferences file. Those drop
  /// their oldest row because the worst it costs is asking a model again;
  /// dropping a row here would take a file off a list the viewer is shown
  /// while the token still reaches it, which is the list telling them
  /// something untrue. A row is about two hundred bytes and a person picks
  /// films by hand.
  bool get isEmpty => entries.isEmpty;

  bool get isNotEmpty => entries.isNotEmpty;

  /// The row for [fileId], or null when that file has never been linked.
  LinkedDriveFile? forFile(String fileId) {
    for (final entry in entries) {
      if (entry.fileId == fileId) return entry;
    }
    return null;
  }

  /// This list with [file] at the front.
  ///
  /// A file picked twice keeps the [LinkedDriveFile.linkedAt] of the first
  /// time -- that is when it became reachable, and it has been reachable
  /// ever since -- and keeps a match already made against it, since a
  /// second pairing knows no more about the title than the first did. The
  /// name and the mime type are taken from the new row: those are what
  /// Drive says *now*, and a file can be renamed.
  ///
  /// A renamed file therefore keeps the match its old name earned, which is
  /// the right way round: a rename is the viewer tidying up, not new
  /// evidence about which film it is, and re-matching on every rename would
  /// spend a search to reach the same answer or a worse one.
  LinkedDriveFiles linking(LinkedDriveFile file) {
    final known = forFile(file.fileId);
    final row = known == null
        ? file
        : LinkedDriveFile(
            fileId: file.fileId,
            name: file.name,
            mimeType: file.mimeType,
            linkedAt: known.linkedAt,
            match: known.match ?? file.match,
          );
    return LinkedDriveFiles([
      row,
      for (final entry in entries)
        if (entry.fileId != file.fileId) entry,
    ]);
  }

  /// This list with every one of [files] at the front, in the order given.
  ///
  /// One pairing links as many files as the viewer picked in the one Picker,
  /// so this is what a pairing writes and [linking] is the one-file case of
  /// it. Folded from the back, so [files] keeps its own order at the front
  /// of the result: the Picker hands over what was picked in the order it
  /// was picked, and a season linked in order should read in order. Each row
  /// goes in through [linking], so a file picked again keeps the moment it
  /// first became reachable, and a file named twice in one pick lands once.
  LinkedDriveFiles linkingAll(Iterable<LinkedDriveFile> files) {
    var all = this;
    for (final file in files.toList().reversed) {
      all = all.linking(file);
    }
    return all;
  }

  /// This list with [fileId]'s match recorded, or this list unchanged when
  /// no such file is linked or it already says that.
  LinkedDriveFiles withMatch(String fileId, LinkedDriveMatch? match) {
    final known = forFile(fileId);
    if (known == null || known.match == match) return this;
    return LinkedDriveFiles([
      for (final entry in entries)
        if (entry.fileId == fileId) entry.withMatch(match) else entry,
    ]);
  }

  /// Every linked file matched to [cinemetaId], and to [videoId] when one
  /// is named -- the reverse of what [LinkedDriveMatch] records.
  ///
  /// **This is the lookup a details screen makes**, which is why the match
  /// is stored as an identity rather than as a drawn row: asking "which of
  /// my linked files is this episode" must not mean matching filenames
  /// against the catalogue a second time. In recency order, like everything
  /// else here; there is normally one.
  List<LinkedDriveFile> matching(String cinemetaId, {String? videoId}) => [
    for (final entry in entries)
      if (entry.isFor(cinemetaId, videoId: videoId)) entry,
  ];

  List<Map<String, Object>> toJson() => [
    for (final entry in entries) entry.toJson(),
  ];

  /// The stored value read back, dropping every row this build cannot
  /// read. A value that is not a list at all is [empty].
  static LinkedDriveFiles fromJson(Object? json) {
    if (json is! List) return empty;
    final entries = <LinkedDriveFile>[];
    for (final row in json) {
      final entry = LinkedDriveFile.fromJson(row);
      if (entry != null) entries.add(entry);
    }
    return entries.isEmpty ? empty : LinkedDriveFiles(entries);
  }

  @override
  bool operator ==(Object other) =>
      other is LinkedDriveFiles && listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hashAll(entries);
}
