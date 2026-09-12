import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/bundled_licenses.dart';
import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/settings/settings_screen.dart';

import '../support/fake_core_client.dart';
import '../support/fixtures.dart';

/// What a compiled Xtremio has to carry, and where a viewer finds it.
///
/// The source is MIT, but a build embeds `stream-server`, which links
/// `unrar-rs` (GPL-3.0-or-later) so a RAR archive inside a torrent plays.
/// unrar-rs's licence asks that a binary redistribution reproduce its
/// licence file, the unRAR restriction included -- so the text has to be
/// inside the build, not merely in the repository.
void main() {
  testWidgets('the licences a binary owes travel inside it', (tester) async {
    registerBundledLicenses();
    final entries = <LicenseEntry>[
      await for (final entry in LicenseRegistry.licenses) entry,
    ];
    final ours = entries.where(
      (entry) => entry.packages.any(
        (name) => name.contains('unrar-rs') || name.contains('Xtremio'),
      ),
    );
    expect(ours, hasLength(2));

    final text = ours
        .expand((entry) => entry.paragraphs)
        .map((paragraph) => paragraph.text)
        .join('\n');
    // The restriction unrar-rs exists to carry, and the licence the binary
    // is under.
    expect(text, contains('UnRAR source code may be used in any software'));
    expect(text, contains('GNU GENERAL PUBLIC LICENSE'));
    expect(text, contains('Version 3, 29 June 2007'));
  });

  testWidgets('Settings offers them, and says what a build is under', (
    tester,
  ) async {
    final core = FakeCoreClient(
      state: {CoreField.ctx: loadCtxLoggedOutFixture()},
    );
    await tester.pumpWidget(
      CoreScope(
        client: core,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.byKey(const ValueKey('setting-licences'));
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('The source is MIT; a built Xtremio is GPL-3.0-or-later'),
      findsOneWidget,
    );

    await tester.tap(tile);
    // Pumped, not settled: the page spins an indicator while it reads the
    // texts, so there is no frame where nothing is animating.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(LicensePage), findsOneWidget);
  });
}
