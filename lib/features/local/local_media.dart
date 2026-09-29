/// The one object that keeps this device's videos up to date: where they
/// are found ([LocalMediaSource]), the scan that renews the record
/// ([LocalMediaFiles], in the preferences) and the matching that fills it in.
/// See `lib/core/local_media_files.dart` for what a file is and why the
/// record is kept.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../core/core.dart';
import '../drive/drive_match.dart';
import '../similar/similar_resolver.dart';
import 'android_local_media_source.dart';
import 'desktop_local_media_source.dart';

/// The source this platform finds videos with: Android's media index on a
/// phone or a television, the chosen folders on a desktop, and none on
/// iOS, which is not shipped.
LocalMediaSource? platformLocalMediaSource(AppPrefs prefs) {
  if (Platform.isAndroid) return const AndroidLocalMediaSource();
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    return DesktopLocalMediaSource(prefs: prefs);
  }
  return null;
}

/// Whether [name], in the folder named [folder], is a release's sample
/// clip rather than the release: a scene release carries a minute of
/// itself in a `Sample` folder, or named `sample-...` or `....sample.mkv`,
/// and a list of them beside the films is noise. Both sources leave them
/// out.
bool isReleaseSample(String name, {String? folder}) {
  if (folder != null && folder.toLowerCase() == 'sample') return true;
  final lower = name.toLowerCase();
  return lower.startsWith('sample-') ||
      lower.startsWith('sample.') ||
      RegExp(r'[.\-_]sample\.[a-z0-9]+$').hasMatch(lower);
}

/// What a scan could do.
enum LocalMediaAccess {
  /// The source has what it needs: the index can be read, or folders are
  /// chosen.
  granted,

  /// Android's video permission has not been given; asking may.
  askable,

  /// Refused for good, or there is nothing to scan (no folder chosen on a
  /// desktop): nothing a press here can change.
  unavailable,
}

/// Where this device's videos are found.
abstract interface class LocalMediaSource {
  /// What the Local list says when [access] is
  /// [LocalMediaAccess.unavailable]: why, and where the viewer can change
  /// it.
  String get setupTitle;
  String get setupDetail;

  /// Whether [scan] can read anything now.
  Future<LocalMediaAccess> access();

  /// Asks for what [access] said was missing; answers the access after.
  Future<LocalMediaAccess> requestAccess();

  /// Every video the source knows of now.
  Future<List<LocalMediaFacts>> scan();
}

/// A source with nothing in it: iOS, and anything with no source wired.
class NoLocalMediaSource implements LocalMediaSource {
  const NoLocalMediaSource();

  @override
  String get setupTitle => 'No local videos here';

  @override
  String get setupDetail => 'This device has no videos Xtremio can reach.';

  @override
  Future<LocalMediaAccess> access() async => LocalMediaAccess.unavailable;

  @override
  Future<LocalMediaAccess> requestAccess() async =>
      LocalMediaAccess.unavailable;

  @override
  Future<List<LocalMediaFacts>> scan() async => const [];
}

/// This device's videos: the record in the preferences, the scan that
/// renews it, and the matching that fills it in. One for the whole app.
///
/// **Nothing scans until asked**: [refresh] at start-up only when access is
/// already granted (so the first launch shows no permission prompt), and
/// when the viewer opens the Local list, which is where asking belongs.
class LocalMedia extends ChangeNotifier {
  LocalMedia({
    required this.prefs,
    this.source = const NoLocalMediaSource(),
    this.search = cinemetaSearch,
  });

  final AppPrefs prefs;
  final LocalMediaSource source;
  final CatalogueSearch search;

  /// The record, as the preferences hold it.
  LocalMediaFiles get files => prefs.localMedia;

  LocalMediaAccess _access = LocalMediaAccess.unavailable;

  /// What the last check said about reaching the videos.
  LocalMediaAccess get accessState => _access;

  bool _scanning = false;

  /// A scan or its matching is under way.
  bool get scanning => _scanning;

  Future<void>? _refreshing;
  bool _pending = false;
  bool _pendingAsk = false;

  /// Scans if access is already there, and asks for it only when [ask]:
  /// the Local list asks, start-up does not. Then matches whatever has not
  /// been asked about.
  ///
  /// One at a time, and **a call during one is a pass after it**, which the
  /// returned future includes: a folder added in Settings while the
  /// start-up scan runs is a folder that scan never read.
  Future<void> refresh({bool ask = false}) {
    _pending = true;
    _pendingAsk |= ask;
    return _refreshing ??= _drain().whenComplete(() => _refreshing = null);
  }

  Future<void> _drain() async {
    while (_pending) {
      final ask = _pendingAsk;
      _pending = false;
      _pendingAsk = false;
      await _refresh(ask: ask);
    }
  }

  Future<void> _refresh({required bool ask}) async {
    var access = await _safely(source.access, LocalMediaAccess.unavailable);
    if (access == LocalMediaAccess.askable && ask) {
      access = await _safely(
        source.requestAccess,
        LocalMediaAccess.unavailable,
      );
    }
    _setAccess(access);
    if (access != LocalMediaAccess.granted) return;
    _setScanning(true);
    try {
      final found = await _safely(source.scan, const <LocalMediaFacts>[]);
      await prefs.setLocalMedia(files.reconciled(found));
      notifyListeners();
      await _match();
    } finally {
      _setScanning(false);
    }
  }

  /// Asks Cinemeta about every file not asked about yet, one at a time,
  /// writing each answer as it comes. A catalogue that cannot be reached
  /// leaves the file unasked, for the next refresh.
  Future<void> _match() async {
    for (final file in files.entries) {
      if (file.checked) continue;
      final LinkedDriveMatch? match;
      try {
        match = await matchDriveFile(file.name, search: search);
      } on DriveCatalogueUnreachable {
        continue;
      }
      await prefs.setLocalMedia(files.answering(file.uri, match));
      notifyListeners();
    }
  }

  static Future<T> _safely<T>(Future<T> Function() call, T fallback) async {
    try {
      return await call();
    } on Object {
      return fallback;
    }
  }

  void _setAccess(LocalMediaAccess access) {
    if (_access == access) return;
    _access = access;
    notifyListeners();
  }

  void _setScanning(bool scanning) {
    if (_scanning == scanning) return;
    _scanning = scanning;
    notifyListeners();
  }
}

/// Puts the app's one [LocalMedia] above every screen.
class LocalMediaScope extends InheritedNotifier<LocalMedia> {
  const LocalMediaScope({
    super.key,
    required LocalMedia? media,
    required super.child,
  }) : super(notifier: media);

  /// The [LocalMedia] above [context], or null where there is none (a
  /// widget test that does not care about local files).
  static LocalMedia? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LocalMediaScope>()?.notifier;
}
