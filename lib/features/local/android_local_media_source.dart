import 'package:flutter/services.dart';

import '../../core/core.dart';
import 'local_media.dart';

/// [LocalMediaSource] over Android's media index: the `xtremio/local_media`
/// channel (`LocalMediaChannel.kt`), which answers `content://` addresses
/// the player opens as they are. The camera's own folders are left out on
/// the Kotlin side; see there.
class AndroidLocalMediaSource implements LocalMediaSource {
  const AndroidLocalMediaSource({
    this.channel = const MethodChannel('xtremio/local_media'),
  });

  final MethodChannel channel;

  @override
  String get setupTitle => 'Xtremio cannot see your videos';

  @override
  String get setupDetail =>
      'Allow access to videos for Xtremio in Android\'s settings, under '
      'Apps.';

  @override
  Future<LocalMediaAccess> access() async =>
      _access(await channel.invokeMethod<String>('access'));

  @override
  Future<LocalMediaAccess> requestAccess() async =>
      _access(await channel.invokeMethod<String>('requestAccess'));

  static LocalMediaAccess _access(String? answer) => switch (answer) {
    'granted' => LocalMediaAccess.granted,
    'partial' => LocalMediaAccess.partial,
    'askable' => LocalMediaAccess.askable,
    _ => LocalMediaAccess.unavailable,
  };

  @override
  Future<List<LocalMediaFacts>> scan() async {
    final rows = await channel.invokeListMethod<Object?>('scan') ?? const [];
    return [
      for (final row in rows)
        if (row case {'uri': final String uri, 'name': final String name}
            when !isReleaseSample(name, folder: _string(row['folder'])))
          (
            uri: uri,
            name: name,
            size: _int(row['size']),
            durationMillis: _int(row['durationMillis']),
            height: _int(row['height']),
          ),
    ];
  }

  /// Android's own thumbnail of the video, which it keeps for every video
  /// it indexes.
  @override
  Future<Uint8List?> thumbnail(String uri, {required int size}) async {
    try {
      return await channel.invokeMethod<Uint8List>('thumbnail', {
        'uri': uri,
        'size': size,
      });
    } on PlatformException {
      return null;
    }
  }

  static int? _int(Object? value) => value is int ? value : null;

  static String? _string(Object? value) => value is String ? value : null;
}
