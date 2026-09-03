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

/// What a start-up did about where the downloads go, so a caller (and a
/// test) can see which of the situations it was in.
enum DownloadDestinationOutcome {
  /// Nothing to do: this platform has no default of its own and nobody has
  /// answered, so the server keeps deciding.
  nothing,

  /// Nobody had answered and the platform's default was applied -- recorded
  /// as the app's doing, not as an answer.
  appliedPlatformDefault,

  /// A destination was already in force and was left exactly where it was.
  kept,

  /// A `downloadsDir` that predates the registry's record was adopted as
  /// the answer, so a server that drops it later can be corrected.
  adoptedExisting,

  /// The folder chosen was missing from the settings -- the server clears a
  /// `downloadsDir` it cannot prepare at boot -- and went back.
  restoredChoice,

  /// The folder chosen could not be prepared at all: it is still on record,
  /// and the platform default stands in for it meanwhile.
  choiceUnavailable,

  /// Nothing could be read or written; the downloads stay where the server
  /// puts them.
  failed,
}

/// Settles where the downloads go, which is what start-up does once.
///
/// The registry's record ([DownloadsRegistry.destination]) is the question's
/// answer, not the server's `downloadsDir`: a null there is both "with the
/// cache, on purpose" and "nobody has been asked", and the server clears a
/// `downloadsDir` it cannot prepare at boot -- an SD card that is not in the
/// device -- which on Android would otherwise park every download in a cache
/// the OS may reclaim mid-file, the very thing the platform default exists
/// to avoid.
///
/// So, by what the registry holds:
///
/// * a folder the user chose is put back whenever the settings no longer
///   have it, and if it cannot be prepared it *stays on record* while
///   [resolve]'s default stands in for it -- the card may be back next
///   time, and the Downloads screen can say which folder is missing;
/// * `Default (with the cache)` is an answer like any other and is left
///   alone;
/// * a default this app applied before is re-applied only if the server
///   lost it;
/// * nothing answered means a first run: the platform's default is applied
///   and recorded as the app's, or -- on a platform with none -- nothing is
///   asked of the server at all. A `downloadsDir` already there (a build
///   from before any of this was recorded) is adopted as the answer rather
///   than overwritten.
///
/// Failure is not worth a word on screen: the downloads still work where
/// the server puts them, and the picker on the Downloads screen can still
/// move them.
Future<DownloadDestinationOutcome> applyDefaultDestination(
  DownloadsClient client, {
  DownloadDestinationResolver resolve = platformDefaultDestination,
}) async {
  try {
    final destination = (await client.list()).destination;
    switch (destination.kind) {
      case DownloadDestinationKind.cache:
        return DownloadDestinationOutcome.kept;
      case DownloadDestinationKind.explicit:
        return await _restore(client, destination.path!, resolve);
      case DownloadDestinationKind.platformDefault:
      case DownloadDestinationKind.unset:
        return await _default(client, destination, resolve);
    }
  } catch (error) {
    if (kDebugMode) debugPrint('downloads destination: $error');
    return DownloadDestinationOutcome.failed;
  }
}

/// Puts [chosen] back when the settings no longer have it, and falls back on
/// the platform default -- without touching the record -- when it cannot be
/// prepared.
Future<DownloadDestinationOutcome> _restore(
  DownloadsClient client,
  String chosen,
  DownloadDestinationResolver resolve,
) async {
  if (await client.directory() == chosen) {
    return DownloadDestinationOutcome.kept;
  }
  try {
    await client.setDirectory(chosen);
    return DownloadDestinationOutcome.restoredChoice;
  } catch (error) {
    if (kDebugMode) debugPrint('downloads destination $chosen: $error');
  }
  final fallback = await resolve();
  if (fallback != null) {
    try {
      await client.applyDefaultDirectory(fallback);
    } catch (error) {
      if (kDebugMode) debugPrint('downloads destination $fallback: $error');
    }
  }
  return DownloadDestinationOutcome.choiceUnavailable;
}

/// Applies this platform's default where nothing has been chosen: on a first
/// run, and again if the server lost the default a run before applied.
Future<DownloadDestinationOutcome> _default(
  DownloadsClient client,
  DownloadDestination destination,
  DownloadDestinationResolver resolve,
) async {
  final fallback = await resolve();
  // A platform with no default of its own changes nothing -- the server
  // keeps deciding -- and nothing is asked of it either.
  if (fallback == null) {
    return destination.isSettled
        ? DownloadDestinationOutcome.kept
        : DownloadDestinationOutcome.nothing;
  }
  final live = await client.directory();
  if (live != null) {
    // A destination with nothing on record is one an older build set, or
    // something outside the app did: it is where the downloads already are,
    // so it is adopted rather than moved -- and being on record is what
    // lets a start-up put it back when the server drops it.
    if (destination.isSettled) return DownloadDestinationOutcome.kept;
    await client.setDirectory(live);
    return DownloadDestinationOutcome.adoptedExisting;
  }
  await client.applyDefaultDirectory(fallback);
  return DownloadDestinationOutcome.appliedPlatformDefault;
}
