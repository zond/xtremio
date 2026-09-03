import 'dart:io' show Directory, Platform;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/core.dart';

/// Where the downloaded files go, per platform: what the destination
/// control can offer, and what a first run picks on its own.
///
/// The server's own default is a folder in the torrent cache root, which is
/// right on a desktop and wrong on Android: `<cache>` there is the OS's to
/// reclaim whenever it wants room, and a purged half of a film is not a
/// download. So on Android the app points the server at the app-specific
/// external files directory instead -- readable and writable with no
/// permission at all on `minSdk` 24, and left alone by the system until the
/// app is uninstalled.
///
/// Answers a resolver's `null` everywhere else: a desktop keeps the server's
/// default, and nothing is written to the settings on every launch.
typedef DownloadDestinationResolver = Future<String?> Function();

/// A subfolder of the app's own external storage: no permission is needed
/// for it, and the torrent folders do not land among whatever else the app
/// keeps there.
const String downloadsFolderName = 'downloads';

/// The directories the destination control offers to choose between. On
/// Android those are the app's own external storage directories, an SD card
/// among them; everywhere else there are none to enumerate and a path is
/// typed instead.
Future<List<String>> platformDownloadDestinations() async {
  if (!Platform.isAndroid) return const [];
  final roots = await getExternalStorageDirectories();
  return [for (final root in roots ?? const <Directory>[]) _inside(root.path)];
}

/// Where downloads go when nobody has chosen: the app's external files
/// directory on Android, and null -- the server's own default, in the
/// torrent cache -- everywhere else.
Future<String?> platformDefaultDestination() async {
  if (!Platform.isAndroid) return null;
  final root = await getExternalStorageDirectory();
  return root == null ? null : _inside(root.path);
}

String _inside(String root) => '$root/$downloadsFolderName';

/// Points [client] at [resolve]'s directory unless the question has
/// already been answered, which is what start-up does once.
///
/// "Answered" is the registry's `destinationSettled` and
/// `destinationChoice`, not a non-null `downloadsDir`: choosing
/// `Default (with the cache)` on the Downloads screen writes null on
/// purpose, and reading that as "nobody has chosen" would silently move
/// the downloads on the next launch. A `downloadsDir` already set --
/// including one a build from before the flag wrote -- counts as answered
/// too, so an upgrade does not move anything.
///
/// The case worth acting on is the third one: settled on a *path* that the
/// settings no longer have. The server clears a `downloadsDir` it cannot
/// prepare at boot (an SD card that is not in the device) and persists the
/// null, which on Android would otherwise park every download in the app
/// cache the OS may reclaim mid-file -- the very thing the platform
/// default exists to avoid. So the recorded path is asked for again; if it
/// is really gone the platform default takes over, and never the cache.
///
/// A platform with no default of its own changes nothing -- the server
/// keeps deciding -- and nothing is asked of it either. Failure is not
/// worth a word on screen: the downloads still work where the server puts
/// them, and the picker on the Downloads screen can still move them.
Future<void> applyDefaultDestination(
  DownloadsClient client, {
  DownloadDestinationResolver resolve = platformDefaultDestination,
}) async {
  try {
    final path = await resolve();
    if (path == null) return;
    final registry = await client.list();
    if (await client.directory() != null) return;
    final chosen = registry.destinationChoice;
    if (chosen == null) {
      if (registry.destinationSettled) return;
      await client.setDirectory(path);
      return;
    }
    try {
      await client.setDirectory(chosen);
      return;
    } catch (error) {
      if (kDebugMode) debugPrint('downloads destination $chosen: $error');
    }
    await client.setDirectory(path);
  } catch (error) {
    if (kDebugMode) debugPrint('default downloads destination: $error');
  }
}
