import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/widgets/poster_tile.dart';

/// An `HttpClient` that answers every request with one image, so the
/// poster resolves through `Image.network`'s real path -- provider, cache
/// key, decode -- without a network.
class _OneImageClient implements HttpClient {
  _OneImageClient(this.bytes);

  final Uint8List bytes;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _Request(bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  _Request(this.bytes);

  final Uint8List bytes;

  @override
  final HttpHeaders headers = _Headers();

  @override
  Future<HttpClientResponse> close() async => _Response(bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Headers implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.bytes);

  final Uint8List bytes;

  @override
  int get statusCode => 200;

  @override
  int get contentLength => bytes.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A PNG of [width] by [height]: the size a TMDB-backed addon serves a
/// poster at.
Future<Uint8List> png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = Colors.red,
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Resolves the image the tile built and answers with what was decoded.
Future<ImageInfo> decoded(WidgetTester tester) async {
  final image = tester.widget<Image>(find.byType(Image));
  final done = Completer<ImageInfo>();
  final stream = image.image.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener((info, _) {
    if (!done.isCompleted) done.complete(info);
  });
  stream.addListener(listener);
  final info = await done.future;
  stream.removeListener(listener);
  return info;
}

void main() {
  /// Pumps a 130 dp tile holding a 1000×1500 poster at [devicePixelRatio]
  /// and reports the decoded picture's width.
  Future<int> decodedWidthAt(
    WidgetTester tester, {
    required double devicePixelRatio,
  }) async {
    final poster = (await tester.runAsync(() => png(1000, 1500)))!;
    tester.view.devicePixelRatio = devicePixelRatio;
    addTearDown(tester.view.reset);
    late final ImageInfo info;
    await tester.runAsync(
      () => HttpOverrides.runZoned(() async {
        imageCache.clear();
        await tester.pumpWidget(
          const MaterialApp(
            home: Center(
              child: SizedBox(
                width: 130,
                height: 195,
                child: PosterImage(url: 'https://posters.example/one.jpg'),
              ),
            ),
          ),
        );
        await tester.pump();
        info = await decoded(tester);
      }, createHttpClient: (_) => _OneImageClient(poster)),
    );
    return info.image.width;
  }

  testWidgets(
    'a poster is decoded at the width of the tile, not of the file',
    (tester) async {
      expect(await decodedWidthAt(tester, devicePixelRatio: 1), 130);
    },
    // Encoding and decoding a real 1000×1500 picture is what is measured.
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'the bound counts physical pixels, so a sharper screen decodes larger',
    (tester) async {
      expect(await decodedWidthAt(tester, devicePixelRatio: 2), 260);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets('no poster is the fallback box, at the tile\'s size', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 130,
            height: 195,
            child: PosterImage(url: null),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
