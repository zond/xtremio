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

/// One file a pairing linked.
@immutable
final class LinkedDriveFile {
  const LinkedDriveFile({
    required this.fileId,
    required this.name,
    required this.mimeType,
    required this.linkedAt,
    this.cinemetaId,
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

  /// Which Cinemeta title this file turned out to be, once something
  /// matches filenames against the catalogue -- **nothing writes this
  /// yet**. It is here because the alternative, discovering the id
  /// somewhere else and keeping it in a second list keyed by [fileId], is
  /// how two records of the same thing start disagreeing. Null until a
  /// match is made, and null for a file no match is ever found for, which
  /// is an ordinary outcome and not a failure.
  final String? cinemetaId;

  /// This row with [cinemetaId] filled in, or cleared when it is null.
  LinkedDriveFile withCinemetaId(String? cinemetaId) => LinkedDriveFile(
    fileId: fileId,
    name: name,
    mimeType: mimeType,
    linkedAt: linkedAt,
    cinemetaId: cinemetaId,
  );

  /// The row as it is written to the preferences file. The Cinemeta id is
  /// written only when there is one, so a file somebody reads does not
  /// claim a match that was never made.
  Map<String, Object> toJson() => {
    'id': fileId,
    'name': name,
    'mime': mimeType,
    'linkedAt': linkedAt.toUtc().toIso8601String(),
    'cinemeta': ?cinemetaId,
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
    final cinemeta = json['cinemeta'];
    return LinkedDriveFile(
      fileId: id.trim(),
      name: name is String ? name : '',
      mimeType: mime is String ? mime : '',
      linkedAt:
          (linkedAt is String ? DateTime.tryParse(linkedAt) : null)?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      cinemetaId: cinemeta is String && cinemeta.trim().isNotEmpty
          ? cinemeta.trim()
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LinkedDriveFile &&
      other.fileId == fileId &&
      other.name == name &&
      other.mimeType == mimeType &&
      other.linkedAt == linkedAt &&
      other.cinemetaId == cinemetaId;

  @override
  int get hashCode => Object.hash(fileId, name, mimeType, linkedAt, cinemetaId);

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
  /// ever since -- and keeps a Cinemeta id already matched against it,
  /// since a second pairing knows no more about the title than the first
  /// did. The name and the mime type are taken from the new row: those are
  /// what Drive says *now*, and a file can be renamed.
  LinkedDriveFiles linking(LinkedDriveFile file) {
    final known = forFile(file.fileId);
    final row = known == null
        ? file
        : LinkedDriveFile(
            fileId: file.fileId,
            name: file.name,
            mimeType: file.mimeType,
            linkedAt: known.linkedAt,
            cinemetaId: known.cinemetaId ?? file.cinemetaId,
          );
    return LinkedDriveFiles([
      row,
      for (final entry in entries)
        if (entry.fileId != file.fileId) entry,
    ]);
  }

  /// This list with [fileId]'s Cinemeta id set, or this list unchanged
  /// when no such file is linked or it already says that.
  LinkedDriveFiles withCinemetaId(String fileId, String? cinemetaId) {
    final known = forFile(fileId);
    if (known == null || known.cinemetaId == cinemetaId) return this;
    return LinkedDriveFiles([
      for (final entry in entries)
        if (entry.fileId == fileId) entry.withCinemetaId(cinemetaId) else entry,
    ]);
  }

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
