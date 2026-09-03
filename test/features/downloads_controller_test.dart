import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/downloads/downloads_controller.dart';

import '../support/fake_downloads_client.dart';

/// One download, at [downloaded] of 100 bytes.
DownloadsRegistry registryAt(int downloaded) {
  final view = DownloadView({
    'metaId': 'tt1',
    'videoId': 'tt1',
    'infoHash': 'abcdabcdabcdabcdabcd',
    'fileIdx': 0,
    'name': 'A Film',
    'size': 100,
    'downloaded': downloaded,
    'state': downloaded == 100 ? 'complete' : 'downloading',
  });
  return DownloadsRegistry(items: {view.key: view});
}

/// What the ticker pushes for that download: the numbers, and nothing of
/// the entry they belong to.
DownloadsProgressUpdate progressAt(int downloaded) => DownloadsProgressUpdate([
  DownloadProgress({
    'key': 'tt1:tt1',
    'downloaded': downloaded,
    'size': 100,
    'state': downloaded == 100 ? 'complete' : 'downloading',
    'path': '/downloads/a.mkv',
    'error': null,
    'completedAt': null,
  }),
]);

/// A client whose progress feed can end the way the real one's does: the
/// Rust side keeps one event sink, hands it to another client, and the
/// broadcast closes. A later look at `updates` opens a fresh one.
class ReopeningFeedClient extends FakeDownloadsClient {
  ReopeningFeedClient({super.registry});

  StreamController<DownloadsUpdate>? _feed;

  /// How many feeds have been opened, so a re-subscription is visible.
  int opened = 0;

  @override
  Stream<DownloadsUpdate> get updates {
    var feed = _feed;
    if (feed == null) {
      feed = _feed = StreamController<DownloadsUpdate>.broadcast();
      opened++;
    }
    return feed.stream;
  }

  void push(DownloadsUpdate update) => _feed?.add(update);

  /// Ends the feed, as handing the sink to another client does.
  Future<void> endFeed() async {
    final feed = _feed;
    _feed = null;
    await feed?.close();
  }
}

void main() {
  test('a progress feed that ended is picked up by the next listing', () async {
    final client = ReopeningFeedClient(registry: registryAt(10));
    addTearDown(client.dispose);
    final controller = DownloadsController(client);
    addTearDown(controller.dispose);
    await pumpEventQueue();
    expect(client.opened, 1);

    // Another client took the sink. Nothing reads `updates` again on its
    // own, so without a re-subscription progress stops for good.
    await client.endFeed();
    await pumpEventQueue();

    client.registry = registryAt(50);
    await controller.refresh();
    expect(client.opened, 2, reason: 'the listing opened a fresh feed');

    client.push(progressAt(90));
    await pumpEventQueue();
    expect(controller.registry['tt1:tt1']?.downloaded, 90);
  });

  test('a narrow row is laid over the entry, not put in its place', () async {
    final client = ReopeningFeedClient(registry: registryAt(10));
    addTearDown(client.dispose);
    final controller = DownloadsController(client);
    addTearDown(controller.dispose);
    await pumpEventQueue();

    client.push(progressAt(100));
    await pumpEventQueue();

    final view = controller.registry['tt1:tt1']!;
    expect(view.downloaded, 100);
    expect(view.isComplete, isTrue);
    expect(view.path, '/downloads/a.mkv');
    expect(
      view.name,
      'A Film',
      reason: 'what the row does not carry is what the listing brought',
    );
    expect(view.infoHash, 'abcdabcdabcdabcdabcd');
  });

  test('a row for an entry no listing has brought yet is dropped', () async {
    // The next listing carries the whole of it; there is nothing here to
    // lay six numbers over.
    final client = ReopeningFeedClient(registry: registryAt(10));
    addTearDown(client.dispose);
    final controller = DownloadsController(client);
    addTearDown(controller.dispose);
    await pumpEventQueue();

    client.push(
      DownloadsProgressUpdate([
        DownloadProgress(const {'key': 'tt9:tt9', 'downloaded': 5}),
      ]),
    );
    await pumpEventQueue();

    expect(controller.registry.length, 1);
    expect(controller.registry['tt9:tt9'], isNull);
  });
}
