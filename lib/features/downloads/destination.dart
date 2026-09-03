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

/// Points [client] at [resolve]'s directory unless a destination is already
/// set, which is what start-up does once.
///
/// A destination the user (or an earlier launch) chose is never overridden,
/// and a platform with no default of its own changes nothing -- the server
/// keeps deciding. Failure is not worth a word on screen: the downloads
/// still work where the server puts them, and the picker on the Downloads
/// screen can still move them.
Future<void> applyDefaultDestination(
  DownloadsClient client, {
  DownloadDestinationResolver resolve = platformDefaultDestination,
}) async {
  try {
    final path = await resolve();
    if (path == null) return;
    if (await client.directory() != null) return;
    await client.setDirectory(path);
  } catch (error) {
    if (kDebugMode) debugPrint('default downloads destination: $error');
  }
}
