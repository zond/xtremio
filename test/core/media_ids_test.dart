import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

/// `media_resolve`'s JSON as the player reads it: the server's `Resolved`
/// (stream-server `server/src/media/mod.rs`) or its `Refusal`; and what
/// asks the platform for a document's descriptor.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a document the platform cannot open is a refusal, and asks Rust '
      'nothing', () async {
    const channel = MethodChannel('xtremio/local_media.test');
    final asked = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          asked.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    const ids = RustMediaIds(localChannel: channel);
    const document = 'content://media/external/video/media/42';

    await expectLater(
      ids.registerLocalContent(Uri.parse(document), name: 'Holiday.mp4'),
      throwsA(isA<MediaRefusal>().having((r) => r.kind, 'kind', 'openFailed')),
    );
    expect(asked.single.method, 'openFd');
    expect(asked.single.arguments, {'uri': document});
  });

  test('a refusal is its kind and its sentence', () {
    final resolution = MediaResolution.fromJson(const {
      'refused': 'pairAgain',
      'message': 'Pair this device again.',
    });
    expect(resolution.refusal?.kind, 'pairAgain');
    expect(resolution.refusal?.message, 'Pair this device again.');
    expect(resolution.inProcess, isFalse);
  });

  test('a container resolves to the member inside it', () {
    final resolution = MediaResolution.fromJson(const {
      'name': 'Film.mp4',
      'contentType': 'video/mp4',
      'len': 4096,
      'member': {'name': 'Feature/Film.mp4', 'len': 4096},
      'sniffed': true,
      'inProcess': true,
      'proxyUrl': null,
    });
    expect(resolution.refusal, isNull);
    expect(resolution.name, 'Film.mp4');
    expect(resolution.memberName, 'Feature/Film.mp4');
    expect(resolution.inProcess, isTrue);
    expect(resolution.proxyUrl, isNull);
    expect(resolution.sniffed, isTrue);
  });

  test('an origin read forward hands over its /proxy URL', () {
    final resolution = MediaResolution.fromJson(const {
      'name': 'channel.m3u8',
      'contentType': 'application/vnd.apple.mpegurl',
      'len': 0,
      'member': null,
      'sniffed': false,
      'inProcess': false,
      'proxyUrl': 'http://127.0.0.1:1/proxy/d=https%3A%2F%2Flive/channel.m3u8',
    });
    expect(resolution.inProcess, isFalse);
    expect(resolution.proxyUrl?.pathSegments.first, 'proxy');
    expect(resolution.memberName, isNull);
    expect(resolution.sniffed, isFalse);
  });
}
