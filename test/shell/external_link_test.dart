import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;
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

  test('the url_launcher opener reports a failed launch as false', () async {
    // url_launcher_linux never returns false: a URL nothing opens is a
    // PlatformException, and one the plugin refuses an ArgumentError.
    final url = Uri.parse('https://example.com/configure');
    final launched = <Uri>[];
    final opener = UrlLauncherLinkOpener(
      launch: (url, {required mode}) async {
        launched.add(url);
        expect(mode, LaunchMode.externalApplication);
        throw PlatformException(code: 'Launch Error', message: 'no handler');
      },
    );
    expect(await opener.open(url), isFalse);
    expect(launched, [url]);

    final refusing = UrlLauncherLinkOpener(
      launch: (url, {required mode}) async => throw ArgumentError('bad URL'),
    );
    expect(await refusing.open(url), isFalse);

    // A launcher's own answer passes through.
    final honest = UrlLauncherLinkOpener(
      launch: (url, {required mode}) async => true,
    );
    expect(await honest.open(url), isTrue);
  });
}

List<String> opened(FakeLinkOpener opener) => [
  for (final url in opener.opened) url.toString(),
];
