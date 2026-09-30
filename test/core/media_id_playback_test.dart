import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/player/playback_engine.dart';
import 'package:xtremio/src/rust/api/media.dart' as rust;

import '../support/rust_lib.dart';

/// **media_kit plays `xtremio://<id>`**, for real, on this machine: the
/// embedded server running, a stream registered with it, and a media_kit
/// [Player] (`vo=null`, `ao=null`) opening the id through the vendored
/// patch (`third_party/media_kit/PATCHES.md`) and the protocol
/// [MediaKitEngine.registerMediaIdProtocolOn] registers -- position
/// advances, and a seek lands.
///
/// The stream is a `/proxy` of a WAV this test serves on loopback: no
/// network, and no `ffmpeg` to make a film with. `rust/tests/mpv_stream.rs`
/// is the torrent's half, against libmpv without media_kit.
///
/// Needs a libmpv; skipped where there is none (CI's runners have none).
void main() {
  final libmpv = _hasLibmpv();

  testWidgets('a media id plays through media_kit and seeks', skip: !libmpv, (
    tester,
  ) async {
    await tester.runAsync(() async {
      await initRustForTests();
      MediaKit.ensureInitialized();
      final tmp = await Directory.systemTemp.createTemp('xtremio-media-id-');
      final origin = await _serveWav(seconds: 60);
      addTearDown(() async {
        await stopServerForTests();
        await origin.close(force: true);
        await tmp.delete(recursive: true);
      });
      final base = await startServerForTests(
        configDir: Directory('${tmp.path}/server'),
        cacheDir: Directory('${tmp.path}/cache'),
      );

      const ids = RustMediaIds();
      // `proxiedThroughServer` leaves a loopback origin alone (every
      // loopback URL is the server's own), so the `/proxy` URL is
      // written out here.
      final target = Uri.encodeComponent('http://127.0.0.1:${origin.port}');
      final id = ids.register(base.resolve('proxy/d=$target/tone.wav'));
      ids.setPlay(id, token: 'test.1', buffer: 'normal');
      expect(await ids.resolve(id), isNull);

      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      addTearDown(player.dispose);
      final errors = <String>[];
      player.stream.error.listen(errors.add);
      final native = player.platform! as NativePlayer;
      await native.waitForPlayerInitialization;
      await native.setProperty('ao', 'null');
      var registrations = 0;
      await MediaKitEngine.registerMediaIdProtocolOn(native, ({
        required int ctx,
        required String libmpvPath,
      }) {
        registrations++;
        return rust.mpvStreamRegister(ctx: ctx, libmpvPath: libmpvPath);
      });
      expect(registrations, 1);

      await player.open(Media(mediaIdUrl(id).toString()));
      await _until(
        () => player.state.position > const Duration(seconds: 1),
        what: () => 'playback to start (errors: $errors)',
      );
      expect(player.state.duration.inSeconds, inInclusiveRange(59, 60));
      expect(player.state.playlist.medias.single.uri, 'xtremio://$id');

      await player.seek(const Duration(seconds: 40));
      await _until(
        () => player.state.position >= const Duration(seconds: 40),
        what: () => 'the seek to land (errors: $errors)',
      );
    });
  });
}

bool _hasLibmpv() {
  if (!Platform.isLinux) return false;
  for (final name in ['libmpv.so.2', 'libmpv.so']) {
    try {
      DynamicLibrary.open(name);
      return true;
    } catch (_) {}
  }
  return false;
}

/// Waits for [done] with a deadline, polling: a real player on a real
/// clock, which is what `runAsync` is for.
Future<void> _until(
  bool Function() done, {
  required String Function() what,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for ${what()}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A loopback origin that serves [seconds] of a tone as a WAV, with ranges,
/// as the server's proxy wants of an origin it reads in process.
Future<HttpServer> _serveWav({required int seconds}) async {
  const rate = 8000;
  final samples = rate * seconds;
  final wav = ByteData(44 + samples * 2);
  void ascii(int at, String text) {
    for (var i = 0; i < text.length; i++) {
      wav.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  wav.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  wav.setUint32(16, 16, Endian.little);
  wav.setUint16(20, 1, Endian.little);
  wav.setUint16(22, 1, Endian.little);
  wav.setUint32(24, rate, Endian.little);
  wav.setUint32(28, rate * 2, Endian.little);
  wav.setUint16(32, 2, Endian.little);
  wav.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  wav.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    final sample = (math.sin(2 * math.pi * 440 * i / rate) * 8000).round();
    wav.setInt16(44 + i * 2, sample, Endian.little);
  }
  final bytes = wav.buffer.asUint8List();

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    response.headers
      ..set(HttpHeaders.contentTypeHeader, 'audio/wav')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    final range = RegExp(r'^bytes=(\d+)-(\d*)$')
        .firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    var start = 0;
    var end = bytes.length - 1;
    if (range != null) {
      start = int.parse(range.group(1)!);
      if (range.group(2)!.isNotEmpty) {
        end = math.min(end, int.parse(range.group(2)!));
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${bytes.length}',
      );
    }
    response.contentLength = end - start + 1;
    if (request.method != 'HEAD') {
      response.add(Uint8List.sublistView(bytes, start, end + 1));
    }
    await response.close();
  });
  return server;
}
