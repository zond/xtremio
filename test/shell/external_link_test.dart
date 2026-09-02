import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/external_link.dart';

import '../support/fake_link_opener.dart';

void main() {
  testWidgets('ExternalLinkScope hands out the opener it was given', (
    tester,
  ) async {
    final opener = FakeLinkOpener();
    late ExternalLinkOpener found;
    await tester.pumpWidget(
      ExternalLinkScope(
        opener: opener,
        child: Builder(
          builder: (context) {
            found = ExternalLinkScope.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(found, same(opener));

    await found.open(Uri.parse('https://example.com/configure'));
    expect(opened(opener), ['https://example.com/configure']);
  });

  testWidgets('without a scope the real url_launcher opener is used', (
    tester,
  ) async {
    late ExternalLinkOpener found;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          found = ExternalLinkScope.of(context);
          return const SizedBox.shrink();
        },
      ),
    );
    expect(found, isA<UrlLauncherLinkOpener>());
  });
}

List<String> opened(FakeLinkOpener opener) => [
  for (final url in opener.opened) url.toString(),
];
