import 'dart:io';
import 'dart:typed_data';

import '../../core/core.dart';
import 'local_media.dart';

/// [LocalMediaSource] on a desktop: the folders the viewer chose in
/// Settings ([AppPrefs.localFolders]), walked for video files.
///
/// **Folders the viewer chose, not the disk.** Stremio's own Local Files
/// addon searched the whole home folder (seven levels deep on Linux, the
/// system's search index elsewhere), which finds every clip and sample
/// file on the machine; a folder somebody pointed at is a folder of films.
/// Hidden folders are skipped, links are not followed, and a walk stops at
/// [maxDepth] and [maxFiles] so a folder chosen by mistake -- a whole disk
/// -- costs a bounded scan.
class DesktopLocalMediaSource implements LocalMediaSource {
  const DesktopLocalMediaSource({required this.prefs});

  final AppPrefs prefs;

  /// How deep under a chosen folder the walk goes: a film in its own
  /// folder, a series in season folders, a collection above either.
  static const int maxDepth = 6;

  /// The most files one scan lists, over every folder together.
  static const int maxFiles = 5000;

  /// The extensions that are videos worth listing, lower case.
  static const Set<String> videoExtensions = {
    'mkv',
    'mp4',
    'm4v',
    'avi',
    'mov',
    'wmv',
    'webm',
    'ts',
    'm2ts',
    'mpg',
    'mpeg',
  };

  @override
  String get setupTitle => 'No folder to look in';

  @override
  String get setupDetail =>
      'Choose the folders your videos are in, in Settings under Local.';

  @override
  Future<LocalMediaAccess> access() async => prefs.localFolders.isEmpty
      ? LocalMediaAccess.unavailable
      : LocalMediaAccess.granted;

  /// Nothing to ask: a folder is chosen in Settings, not granted here.
  @override
  Future<LocalMediaAccess> requestAccess() => access();

  @override
  Future<List<LocalMediaFacts>> scan() async {
    final found = <LocalMediaFacts>[];
    for (final folder in prefs.localFolders) {
      await _walk(Directory(folder), 0, found);
      if (found.length >= maxFiles) break;
    }
    return found;
  }

  static Future<void> _walk(
    Directory dir,
    int depth,
    List<LocalMediaFacts> found,
  ) async {
    if (depth > maxDepth || found.length >= maxFiles) return;
    final List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } on FileSystemException {
      // A folder that went away or cannot be read is a folder with
      // nothing in it, not a scan that failed.
      return;
    }
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final child in children) {
      if (found.length >= maxFiles) return;
      // From the path and not the URI, which is escaped: a name is shown
      // and searched for as the viewer wrote it.
      final name = child.path.substring(
        child.path.lastIndexOf(Platform.pathSeparator) + 1,
      );
      if (name.isEmpty || name.startsWith('.')) continue;
      if (child is Directory) {
        await _walk(child, depth + 1, found);
      } else if (child is File &&
          isVideoName(name) &&
          !isReleaseSample(name, folder: _nameOf(dir))) {
        int? size;
        try {
          size = await child.length();
        } on FileSystemException {
          size = null;
        }
        found.add((
          uri: child.uri.toString(),
          name: name,
          size: size,
          durationMillis: null,
          height: null,
        ));
      }
    }
  }

  static String _nameOf(Directory dir) {
    final path = dir.path.endsWith(Platform.pathSeparator)
        ? dir.path.substring(0, dir.path.length - 1)
        : dir.path;
    return path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);
  }

  /// None: a desktop has no system thumbnailer this app can ask, so a card
  /// keeps its icon.
  @override
  Future<Uint8List?> thumbnail(String uri, {required int size}) async => null;

  /// Whether [name] ends in one of [videoExtensions].
  static bool isVideoName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return false;
    return videoExtensions.contains(name.substring(dot + 1).toLowerCase());
  }
}
