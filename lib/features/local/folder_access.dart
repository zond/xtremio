import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/core.dart';

/// Keeps the folders chosen for the Local list readable across restarts.
///
/// **Only macOS needs it.** A sandboxed Mac app may read a folder the viewer
/// picked until it quits, and after that only through a security-scoped
/// bookmark taken while it still could -- so a folder is bookmarked when it
/// is added ([remember]) and opened again from its bookmark before every
/// scan ([open]). Linux and Windows read a path as a path, and this does
/// nothing there.
abstract interface class FolderAccess {
  /// Takes what is needed to reach [folder] again, right after it was
  /// picked.
  Future<void> remember(String folder);

  /// Forgets [folder]'s way back, when it is taken off the list.
  Future<void> forget(String folder);

  /// Opens every remembered folder for reading, once per run.
  Future<void> open();
}

/// The platform's [FolderAccess]: bookmarks on macOS, nothing elsewhere.
FolderAccess platformFolderAccess(AppPrefs prefs) =>
    Platform.isMacOS ? MacFolderAccess(prefs: prefs) : const NoFolderAccess();

class NoFolderAccess implements FolderAccess {
  const NoFolderAccess();

  @override
  Future<void> remember(String folder) async {}

  @override
  Future<void> forget(String folder) async {}

  @override
  Future<void> open() async {}
}

/// [FolderAccess] over the `xtremio/folder_access` channel
/// (`FolderAccess` in `macos/Runner/MainFlutterWindow.swift`), the bookmarks kept in
/// [AppPrefs.localFolderBookmarks].
class MacFolderAccess implements FolderAccess {
  MacFolderAccess({
    required this.prefs,
    this.channel = const MethodChannel('xtremio/folder_access'),
  });

  final AppPrefs prefs;
  final MethodChannel channel;
  final Set<String> _opened = {};

  @override
  Future<void> remember(String folder) async {
    final String? bookmark;
    try {
      bookmark = await channel.invokeMethod<String>('bookmark', {
        'path': folder,
      });
    } on PlatformException {
      // Readable for this run anyway: the picker granted it.
      return;
    }
    if (bookmark == null || bookmark.isEmpty) return;
    _opened.add(folder);
    await prefs.setLocalFolderBookmarks({
      ...prefs.localFolderBookmarks,
      folder: bookmark,
    });
  }

  @override
  Future<void> forget(String folder) async {
    if (!prefs.localFolderBookmarks.containsKey(folder)) return;
    await prefs.setLocalFolderBookmarks({
      for (final MapEntry(:key, :value) in prefs.localFolderBookmarks.entries)
        if (key != folder) key: value,
    });
  }

  @override
  Future<void> open() async {
    final bookmarks = prefs.localFolderBookmarks;
    var renewed = bookmarks;
    for (final MapEntry(key: folder, value: bookmark) in bookmarks.entries) {
      if (_opened.contains(folder)) continue;
      final Map<Object?, Object?>? answer;
      try {
        answer = await channel.invokeMapMethod<Object?, Object?>('open', {
          'bookmark': bookmark,
        });
      } on PlatformException {
        // Gone, or moved out of reach: the walk finds nothing there, which
        // is what it should find.
        continue;
      }
      if (answer == null) continue;
      _opened.add(folder);
      // A bookmark the system calls stale still opened; the fresh one it
      // handed back is the one to keep.
      final fresh = answer['bookmark'];
      if (fresh is String && fresh.isNotEmpty && fresh != bookmark) {
        renewed = {...renewed, folder: fresh};
      }
    }
    if (!identical(renewed, bookmarks)) {
      await prefs.setLocalFolderBookmarks(renewed);
    }
  }
}
