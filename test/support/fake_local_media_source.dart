import 'dart:async';
import 'dart:typed_data';

import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/local/local_media.dart';

/// A [LocalMediaSource] that answers what a test says: [access] until a
/// request, [afterRequest] after one, and [files] from every scan.
class FakeLocalMediaSource implements LocalMediaSource {
  FakeLocalMediaSource({
    this.accessNow = LocalMediaAccess.granted,
    this.afterRequest = LocalMediaAccess.granted,
    List<LocalMediaFacts>? files,
  }) : files = files ?? [];

  LocalMediaAccess accessNow;
  LocalMediaAccess afterRequest;
  List<LocalMediaFacts> files;

  int requests = 0;
  int scans = 0;

  /// What [thumbnail] answers, by address.
  Map<String, Uint8List> thumbnails = {};

  @override
  Future<Uint8List?> thumbnail(String uri, {required int size}) async =>
      thumbnails[uri];

  /// When set, a scan waits for it before answering.
  Completer<void>? holdScan;

  @override
  String get setupTitle => 'Fake setup title';

  @override
  String get setupDetail => 'Fake setup detail';

  @override
  Future<LocalMediaAccess> access() async => accessNow;

  @override
  Future<LocalMediaAccess> requestAccess() async {
    requests++;
    accessNow = afterRequest;
    return accessNow;
  }

  @override
  Future<List<LocalMediaFacts>> scan() async {
    scans++;
    final snapshot = [...files];
    await holdScan?.future;
    return snapshot;
  }
}

/// A file's facts with only the parts a test names.
LocalMediaFacts localFacts(String uri, String name, {int? height}) =>
    (uri: uri, name: name, size: null, durationMillis: null, height: height);
