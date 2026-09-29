import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/local/local_media.dart';
import 'package:xtremio/main.dart';

import 'support/empty_board.dart';
import 'support/fake_deep_links.dart';
import 'support/fake_downloads_client.dart';
import 'support/fake_local_media_source.dart';
import 'support/fake_prefs_client.dart';
import 'support/fake_sharing.dart';

/// Puts one decoded picture nobody is showing into the framework's image
/// cache, the state a poster is in once its row has scrolled away. The
/// decode is real engine work, so it runs outside the test's fake clock.
Future<void> cacheOneImage(WidgetTester tester) async {
  final image = (await tester.runAsync(
    () => createTestImage(width: 4, height: 4),
  ))!;
  imageCache.putIfAbsent(
    Object(),
    () => OneFrameImageStreamCompleter(
      SynchronousFuture(ImageInfo(image: image)),
    ),
  );
}

/// What the app holds in decoded images, and what it releases when it is
/// backgrounded.
///
/// Flutter's own image cache stops at 100 MiB, too high for a 2 GB Android
/// TV: the low-memory killer has taken the app at 311-379 MB resident while
/// backgrounded.
void main() {
  setUp(() {
    final ceiling = imageCache.maximumSizeBytes;
    addTearDown(() {
      imageCache.clear();
      imageCache.maximumSizeBytes = ceiling;
    });
  });

  testWidgets('the bootstrap caps the image cache at 16 MiB', (tester) async {
    // Flutter's default ceiling, before bootstrap lowers it.
    expect(imageCache.maximumSizeBytes, 100 << 20);
    final core = emptyBoardCore();
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    await tester.pumpWidget(
      XtremioBootstrap(
        boot: () async => (core, core.initInfo),
        downloads: downloads,
        prefs: AppPrefs(client: FakePrefsClient()),
        serverSettings: RecordingServerSettings(),
        sharingActivity: FakeSharingActivity(),
      ),
    );
    // Before the boot completes: the splash is the last frame with nothing
    // decoded on it, so the ceiling has to be down by then.
    expect(
      imageCache.maximumSizeBytes,
      XtremioBootstrap.imageCacheCeilingBytes,
    );
    expect(XtremioBootstrap.imageCacheCeilingBytes, 16 << 20);
    await tester.pumpAndSettle();
    expect(imageCache.maximumSizeBytes, 16 << 20);
  });

  testWidgets('going to the background empties the image cache', (
    tester,
  ) async {
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    await tester.pumpWidget(
      XtremioApp(
        core: emptyBoardCore(),
        // The decode below runs real async, in which a missing platform
        // plugin is an uncaught exception rather than the usual logged line.
        deepLinks: FakeDeepLinks(),
        downloads: downloads,
        prefs: AppPrefs(client: FakePrefsClient()),
        serverSettings: RecordingServerSettings(),
        sharingActivity: FakeSharingActivity(),
      ),
    );
    await tester.pumpAndSettle();
    await cacheOneImage(tester);
    expect(imageCache.currentSize, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();

    expect(imageCache.currentSize, 0);
  });

  testWidgets('an interruption does not: a dialog would cost the board its '
      'posters', (tester) async {
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    await tester.pumpWidget(
      XtremioApp(
        core: emptyBoardCore(),
        // The decode below runs real async, in which a missing platform
        // plugin is an uncaught exception rather than the usual logged line.
        deepLinks: FakeDeepLinks(),
        downloads: downloads,
        prefs: AppPrefs(client: FakePrefsClient()),
        serverSettings: RecordingServerSettings(),
        sharingActivity: FakeSharingActivity(),
      ),
    );
    await tester.pumpAndSettle();
    await cacheOneImage(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(imageCache.currentSize, 1);
  });

  testWidgets('coming back to the app looks for local videos again: one '
      'deleted meanwhile is gone', (tester) async {
    final downloads = FakeDownloadsClient();
    addTearDown(downloads.dispose);
    final prefs = AppPrefs(client: FakePrefsClient());
    final source = FakeLocalMediaSource(
      files: [localFacts('content://media/external/video/media/1', 'a.mkv')],
    );
    final media = LocalMedia(
      prefs: prefs,
      source: source,
      search: (type, query) async => const [],
    );
    addTearDown(media.dispose);
    await tester.pumpWidget(
      XtremioApp(
        core: emptyBoardCore(),
        deepLinks: FakeDeepLinks(),
        downloads: downloads,
        prefs: prefs,
        serverSettings: RecordingServerSettings(),
        sharingActivity: FakeSharingActivity(),
        localMedia: media,
      ),
    );
    await tester.pumpAndSettle();
    expect(source.scans, 1, reason: 'at start-up, access being there');
    expect(media.files.entries, hasLength(1));

    source.files = [];
    // Away and back the way a device goes, a state at a time.
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(source.scans, 2);
    expect(media.files.entries, isEmpty);
    expect(source.requests, 0, reason: 'coming back never asks');
  });
}
