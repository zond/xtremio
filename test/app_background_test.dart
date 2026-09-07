import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/app.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/main.dart';

import 'support/fake_core_client.dart';
import 'support/fake_deep_links.dart';
import 'support/fake_downloads_client.dart';
import 'support/fake_prefs_client.dart';
import 'support/fake_sharing.dart';

/// What the app holds in decoded images, and what it lets go of when it is
/// put in the background.
///
/// Both numbers come from the owner's Chromecast with Google TV: 2 GB of RAM
/// for the whole system, and Android's low-memory killer taking the app
/// twice in one day at 311-379 MB resident the moment it was backgrounded.
/// Flutter's own image cache stops at 100 MiB and nothing in the app used
/// to lower it, and a backgrounded app used to hold exactly what it held in
/// the foreground.
///
/// A core whose board plans no catalogs, so the shell settles.
FakeCoreClient emptyBoardCore() => FakeCoreClient(
  state: {
    CoreField.board: {
      'selected': {'type': null, 'extra': <Object>[]},
      'catalogs': <Object>[],
      'catalogLabels': <Object>[],
    },
  },
);

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

void main() {
  setUp(() {
    final ceiling = imageCache.maximumSizeBytes;
    addTearDown(() {
      imageCache.clear();
      imageCache.maximumSizeBytes = ceiling;
    });
  });

  testWidgets('the bootstrap caps the image cache at 32 MiB', (tester) async {
    // Flutter's own ceiling, which is what the app ran under until now.
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
    expect(XtremioBootstrap.imageCacheCeilingBytes, 32 << 20);
    await tester.pumpAndSettle();
    expect(imageCache.maximumSizeBytes, 32 << 20);
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
}
