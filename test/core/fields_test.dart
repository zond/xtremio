import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

void main() {
  test('every field has the snake_case wire name of the Rust model', () {
    expect(
      {for (final field in CoreField.values) field: field.wireName},
      {
        CoreField.ctx: 'ctx',
        CoreField.continueWatchingPreview: 'continue_watching_preview',
        CoreField.board: 'board',
        CoreField.search: 'search',
        CoreField.discover: 'discover',
        CoreField.metaDetails: 'meta_details',
        CoreField.streamingServer: 'streaming_server',
        CoreField.player: 'player',
        CoreField.library: 'library',
        CoreField.installedAddons: 'installed_addons',
        CoreField.remoteAddons: 'remote_addons',
        CoreField.addonDetails: 'addon_details',
      },
    );
  });

  test('wire names round-trip through fromWireName', () {
    for (final field in CoreField.values) {
      expect(CoreField.fromWireName(field.wireName), field);
    }
    expect(CoreField.fromWireName('installedAddons'), isNull);
    expect(CoreField.fromWireName('library_with_filters'), isNull);
  });

  test('the phase 3 fields ride NewState events', () {
    final event = CoreEvent.parse(
      '{"name":"NewState","args":["library","installed_addons",'
      '"remote_addons","addon_details"]}',
    ) as NewStateEvent;
    expect(event.fields, [
      CoreField.library,
      CoreField.installedAddons,
      CoreField.remoteAddons,
      CoreField.addonDetails,
    ]);
  });
}
