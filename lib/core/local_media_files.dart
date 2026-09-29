/// Videos on this device: what they are, which film or episode each one
/// turned out to be, and the one object that keeps that record up to date.
///
/// The shape is the linked Drive files' ([LinkedDriveFile]) on purpose: a
/// file with a name and nothing else to go on, matched to a Cinemeta title
/// by that name ([matchDriveFile]) and shown the same ways -- under its
/// title in the Library and as a source on its details page when it
/// matched, and in the Library's **Local** list either way.
///
/// **Where the files come from is a [LocalMediaSource]**: Android's media
/// index (MediaStore) on a phone or a television, and the folders the
/// viewer chose in Settings on a desktop. Neither is a scan of the whole
/// disk. What a source answers is an address the player opens as it is --
/// `content://` on Android, which media_kit turns into a file descriptor
/// for libmpv, and `file://` on a desktop -- so nothing here reads a byte
/// of the video.
///
/// **What is kept is the record, not the files.** The list with each
/// file's match lives in the preferences ([AppPrefs.localMediaKey]),
/// because matching asks Cinemeta once per file and a phone holds
/// hundreds: a file already asked about -- matched or not -- is not asked
/// about again until its name changes. A scan replaces the list with what
/// the source answers now, carrying each surviving file's answer over.
library;

import 'package:flutter/foundation.dart';

import 'drive_link.dart';

/// One video as a [LocalMediaSource] reports it.
typedef LocalMediaFacts = ({
  String uri,
  String name,
  int? size,
  int? durationMillis,
  int? height,
});

/// One video on this device, and what it was matched to.
@immutable
final class LocalMediaFile {
  const LocalMediaFile({
    required this.uri,
    required this.name,
    this.size,
    this.durationMillis,
    this.height,
    this.match,
    this.checked = false,
    this.hidden = false,
  });

  /// The address the player opens: `content://` or `file://`.
  final String uri;

  /// The file name, with its extension: the whole of what matching has.
  final String name;

  final int? size;
  final int? durationMillis;

  /// The video's height in pixels, where the index knows it.
  final int? height;

  /// The Cinemeta title this file is, or null.
  final LinkedDriveMatch? match;

  /// Whether Cinemeta has been asked about this file under this [name].
  /// True with no [match] is an answer -- nothing matched -- and is not
  /// asked again; false is a file nobody has asked about yet, or one whose
  /// asking failed and will be tried again.
  final bool checked;

  /// Taken out of the Local list by the viewer (a clip nothing matched,
  /// kept off the list as clutter). The file is untouched, and a scan that
  /// finds it again keeps it hidden.
  final bool hidden;

  bool isFor(String cinemetaId, {String? videoId}) =>
      match?.isFor(cinemetaId, videoId: videoId) ?? false;

  /// This file as [facts] describe it now, keeping its answer while the
  /// name holds: a file renamed is a file the old answer was not about.
  LocalMediaFile reconciledWith(LocalMediaFacts facts) {
    final renamed = facts.name != name;
    return LocalMediaFile(
      uri: uri,
      name: facts.name,
      size: facts.size ?? size,
      durationMillis: facts.durationMillis ?? durationMillis,
      height: facts.height ?? height,
      match: renamed ? null : match,
      checked: !renamed && checked,
      hidden: hidden,
    );
  }

  LocalMediaFile answered(LinkedDriveMatch? match) => LocalMediaFile(
    uri: uri,
    name: name,
    size: size,
    durationMillis: durationMillis,
    height: height,
    match: match,
    checked: true,
    hidden: hidden,
  );

  LocalMediaFile withHidden(bool hidden) => LocalMediaFile(
    uri: uri,
    name: name,
    size: size,
    durationMillis: durationMillis,
    height: height,
    match: match,
    checked: checked,
    hidden: hidden,
  );

  static LocalMediaFile ofFacts(LocalMediaFacts facts) => LocalMediaFile(
    uri: facts.uri,
    name: facts.name,
    size: facts.size,
    durationMillis: facts.durationMillis,
    height: facts.height,
  );

  Map<String, Object> toJson() => {
    'uri': uri,
    'name': name,
    'size': ?size,
    'durationMillis': ?durationMillis,
    'height': ?height,
    'match': ?match?.toJson(),
    if (checked) 'checked': true,
    if (hidden) 'hidden': true,
  };

  static LocalMediaFile? fromJson(Object? json) {
    if (json is! Map) return null;
    final uri = json['uri'];
    final name = json['name'];
    if (uri is! String || uri.trim().isEmpty) return null;
    if (name is! String) return null;
    int? integer(Object? value) => value is int ? value : null;
    return LocalMediaFile(
      uri: uri,
      name: name,
      size: integer(json['size']),
      durationMillis: integer(json['durationMillis']),
      height: integer(json['height']),
      match: LinkedDriveMatch.fromJson(json['match']),
      checked: json['checked'] == true,
      hidden: json['hidden'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LocalMediaFile &&
      other.uri == uri &&
      other.name == name &&
      other.size == size &&
      other.durationMillis == durationMillis &&
      other.height == height &&
      other.match == match &&
      other.checked == checked &&
      other.hidden == hidden;

  @override
  int get hashCode => Object.hash(
    uri,
    name,
    size,
    durationMillis,
    height,
    match,
    checked,
    hidden,
  );

  @override
  String toString() => 'LocalMediaFile($name)';
}

/// Every video this device's last scan found, in the order it found them.
@immutable
final class LocalMediaFiles {
  const LocalMediaFiles(this.entries);

  static const LocalMediaFiles empty = LocalMediaFiles(<LocalMediaFile>[]);

  final List<LocalMediaFile> entries;

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;

  LocalMediaFile? forUri(String uri) {
    for (final entry in entries) {
      if (entry.uri == uri) return entry;
    }
    return null;
  }

  /// The list a scan found, each file keeping what was known of it.
  LocalMediaFiles reconciled(List<LocalMediaFacts> found) {
    final seen = <String>{};
    return LocalMediaFiles([
      for (final facts in found)
        if (seen.add(facts.uri))
          forUri(facts.uri)?.reconciledWith(facts) ??
              LocalMediaFile.ofFacts(facts),
    ]);
  }

  LocalMediaFiles answering(String uri, LinkedDriveMatch? match) =>
      LocalMediaFiles([
        for (final entry in entries)
          if (entry.uri == uri) entry.answered(match) else entry,
      ]);

  /// The files that are [cinemetaId], or that video of it.
  /// This record with [uri] hidden from the Local list, or shown again.
  LocalMediaFiles hiding(String uri, {bool hidden = true}) => LocalMediaFiles([
    for (final entry in entries)
      if (entry.uri == uri) entry.withHidden(hidden) else entry,
  ]);

  List<LocalMediaFile> matching(String cinemetaId, {String? videoId}) => [
    for (final entry in entries)
      if (entry.isFor(cinemetaId, videoId: videoId)) entry,
  ];

  /// One match per title not already among [listed], of [type] or of any
  /// type: the cards the Library appends for matched files, as
  /// [LinkedDriveFiles.unlistedMatches] does for Drive.
  List<LinkedDriveMatch> unlistedMatches({
    required Set<String> listed,
    String? type,
  }) {
    final cards = <String>{...listed};
    return [
      for (final entry in entries)
        if (entry.match case final match?)
          if (type == null || match.type == type)
            if (cards.add(match.cinemetaId)) match,
    ];
  }

  List<Map<String, Object>> toJson() => [
    for (final entry in entries) entry.toJson(),
  ];

  static LocalMediaFiles fromJson(Object? json) {
    if (json is! List) return empty;
    final entries = <LocalMediaFile>[];
    for (final row in json) {
      final entry = LocalMediaFile.fromJson(row);
      if (entry != null) entries.add(entry);
    }
    return entries.isEmpty ? empty : LocalMediaFiles(entries);
  }

  @override
  bool operator ==(Object other) =>
      other is LocalMediaFiles && listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hashAll(entries);
}
