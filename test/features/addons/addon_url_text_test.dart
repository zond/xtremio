import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/features/addons/addon_url_text.dart';
import 'package:xtremio/shell/device_profile.dart';

import '../../support/tv.dart';

/// A configured addon's manifest URL carries the viewer's keys in its path.
/// A television, which the whole room reads, shows its host and hides the
/// rest behind Show; a phone shows it whole.
void main() {
  const configured =
      'https://torrentio.strem.fun/realdebrid=SECRETKEY123/manifest.json';
  const bare = 'https://v3-cinemeta.strem.io/manifest.json';

  Widget on(DeviceProfile device, String url) => DeviceScope(
    profile: device,
    child: MaterialApp(home: Scaffold(body: AddonUrlText(url))),
  );

  testWidgets('a television shows the host until Show is pressed', (
    tester,
  ) async {
    await tester.pumpWidget(on(tv, configured));

    expect(find.textContaining('SECRETKEY123'), findsNothing);
    expect(find.text('torrentio.strem.fun/…'), findsOneWidget);

    await tester.tap(find.text('Show'));
    await tester.pump();
    expect(find.text(configured), findsOneWidget);

    await tester.tap(find.text('Hide'));
    await tester.pump();
    expect(find.textContaining('SECRETKEY123'), findsNothing);
  });

  testWidgets('a phone shows the whole URL, selectable', (tester) async {
    await tester.pumpWidget(
      on(const DeviceProfile(isTv: false, hasTouch: true), configured),
    );

    expect(find.widgetWithText(SelectableText, configured), findsOneWidget);
    expect(find.text('Show'), findsNothing);
  });

  testWidgets('a bare manifest URL has nothing to hide, even on a television', (
    tester,
  ) async {
    await tester.pumpWidget(on(tv, bare));

    expect(find.widgetWithText(SelectableText, bare), findsOneWidget);
    expect(find.text('Show'), findsNothing);
  });

  test('anything past the bare manifest path is hidden', () {
    for (final url in [
      'https://addon.example/manifest.json?key=1',
      'https://user:pass@addon.example/manifest.json',
      'https://addon.example/key/manifest.json',
      'https://addon.example/manifest.json#k',
    ]) {
      expect(AddonUrlText.hasNothingToHide(url), isFalse, reason: url);
    }
    expect(
      AddonUrlText.concealed('http://10.0.0.2:7000/k/manifest.json'),
      '10.0.0.2:7000/…',
    );
  });
}
