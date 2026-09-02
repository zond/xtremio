import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

void main() {
  test('NewState lists changed fields', () {
    final event = CoreEvent.parse('{"name":"NewState","args":["board","ctx"]}');
    expect(event, isA<NewStateEvent>());
    final newState = event as NewStateEvent;
    expect(newState.fieldNames, ['board', 'ctx']);
    expect(newState.fields, [CoreField.board, CoreField.ctx]);
    expect(newState.touches(CoreField.board), isTrue);
    expect(newState.touches(CoreField.player), isFalse);
  });

  test('unknown fields are kept by name but skipped in the typed list', () {
    final event = CoreEvent.parse(
      '{"name":"NewState","args":["search","board"]}',
    ) as NewStateEvent;
    expect(event.fieldNames, ['search', 'board']);
    expect(event.fields, [CoreField.board]);
  });

  test('CoreEvent exposes the inner event name and args', () {
    final event = CoreEvent.parse(
      '{"name":"CoreEvent","args":{"event":"LibraryItemAdded","args":{"id":"tt1"}}}',
    );
    expect(event, isA<RuntimeCoreEvent>());
    final core = event as RuntimeCoreEvent;
    expect(core.name, 'LibraryItemAdded');
    expect(core.args, {'id': 'tt1'});
  });

  test('garbage never throws', () {
    expect(CoreEvent.parse('not json'), isA<UnknownCoreEvent>());
    expect(CoreEvent.parse('[1,2]'), isA<UnknownCoreEvent>());
    expect(CoreEvent.parse('{"name":"Nope"}'), isA<UnknownCoreEvent>());
    expect(
      CoreEvent.parse('{"name":"NewState","args":{}}'),
      isA<UnknownCoreEvent>(),
    );
  });
}
