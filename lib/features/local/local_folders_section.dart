import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/core.dart';
import 'folder_access.dart';
import 'local_media.dart';

/// Asks the viewer for a folder: its path, or null for a dialog closed
/// without one.
typedef FolderPicker = Future<String?> Function();

/// The system's own folder dialog.
Future<String?> pickFolderWithTheSystem() =>
    getDirectoryPath(confirmButtonText: 'Look here');

/// Settings → Local, on a desktop: the folders the Library's Local list is
/// found in ([AppPrefs.localFolders], walked by `DesktopLocalMediaSource`),
/// one row each with a way to drop it, and a row that adds another.
///
/// Every change looks again at once: a folder added is a list the viewer
/// expects to see filled, and one dropped takes its videos out of the
/// Library with it.
class LocalFoldersSection extends StatelessWidget {
  const LocalFoldersSection({
    super.key,
    required this.prefs,
    required this.media,
    this.pickFolder = pickFolderWithTheSystem,
    this.access = const NoFolderAccess(),
  });

  final AppPrefs prefs;
  final LocalMedia media;
  final FolderPicker pickFolder;

  /// Keeps a picked folder readable after a restart (see [FolderAccess]).
  final FolderAccess access;

  static const String addLabel = 'Add a folder';
  static const String removeTooltip = 'Stop looking here';

  /// What the add row says under its title: the scan's state.
  static String statusLine({required bool scanning, required int found}) =>
      scanning
      ? 'Looking for videos…'
      : found == 1
      ? '1 video found'
      : '$found videos found';

  Future<void> _add() async {
    final picked = await pickFolder();
    if (picked == null || picked.isEmpty) return;
    final folders = prefs.localFolders;
    if (folders.contains(picked)) return;
    // Now, while the picker's grant holds: on macOS this is the only
    // moment the folder can be bookmarked.
    await access.remember(picked);
    await prefs.setLocalFolders([...folders, picked]);
    await media.refresh();
  }

  Future<void> _remove(String folder) async {
    await prefs.setLocalFolders([
      for (final kept in prefs.localFolders)
        if (kept != folder) kept,
    ]);
    await access.forget(folder);
    await media.refresh();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([prefs, media]),
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final folder in prefs.localFolders)
          ListTile(
            key: ValueKey('local-folder:$folder'),
            leading: const Icon(Icons.folder_outlined),
            title: Text(folder),
            trailing: IconButton(
              tooltip: removeTooltip,
              icon: const Icon(Icons.close),
              onPressed: () => _remove(folder),
            ),
          ),
        ListTile(
          key: const ValueKey('local-folder-add'),
          leading: const Icon(Icons.create_new_folder_outlined),
          title: const Text(addLabel),
          subtitle: Text(
            prefs.localFolders.isEmpty
                ? 'Where your videos are, for the Library\'s Local list'
                : statusLine(
                    scanning: media.scanning,
                    found: media.files.entries.length,
                  ),
          ),
          onTap: _add,
        ),
      ],
    ),
  );
}
