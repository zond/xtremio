import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

/// A `core_get_state` answered by hand, counting what it was asked.
class Fetcher {
  final List<String> asked = [];
  final List<Completer<String>> pending = [];

  Future<String> call(String wireName) {
    asked.add(wireName);
    final completer = Completer<String>();
    pending.add(completer);
    return completer.future;
  }

  /// Answers the oldest outstanding fetch.
  void answer(Map<String, dynamic> json) =>
      pending.removeAt(0).complete(jsonEncode(json));

  void fail(Object error) => pending.removeAt(0).completeError(error);
}

void main() {
  test('concurrent pulls of one field share one fetch and one map', () async {
    final fetch = Fetcher();
    final pulls = FieldPulls(fetch.call);

    final a = pulls.pull(CoreField.ctx);
    final b = pulls.pull(CoreField.ctx);
    final c = pulls.pull(CoreField.ctx);
    expect(fetch.asked, ['ctx'], reason: 'three readers, one round trip');

    fetch.answer({'profile': {}});
    final maps = await Future.wait([a, b, c]);
    expect(maps[0], {'profile': {}});
    expect(identical(maps[0], maps[1]), isTrue, reason: 'one decode');
    expect(identical(maps[1], maps[2]), isTrue);
  });

  test(
    'a pull after the fetch, with nothing changed, is the same map',
    () async {
      final fetch = Fetcher();
      final pulls = FieldPulls(fetch.call);

      final first = pulls.pull(CoreField.ctx);
      fetch.answer({'v': 1});
      final map = await first;

      final again = await pulls.pull(CoreField.ctx);
      expect(fetch.asked, ['ctx'], reason: 'nothing was fetched again');
      expect(identical(again, map), isTrue);
    },
  );

  test('a NewState naming the field makes the next pull fetch again', () async {
    final fetch = Fetcher();
    final pulls = FieldPulls(fetch.call);

    final first = pulls.pull(CoreField.ctx);
    fetch.answer({'v': 1});
    final before = await first;

    pulls.invalidate([CoreField.ctx]);
    final next = pulls.pull(CoreField.ctx);
    expect(fetch.asked, ['ctx', 'ctx']);
    fetch.answer({'v': 2});
    final after = await next;
    expect(after, {'v': 2});
    expect(identical(before, after), isFalse);
  });

  test('a NewState during a pull hands that pull to its callers and fetches '
      'afresh for the generation after it', () async {
    final fetch = Fetcher();
    final pulls = FieldPulls(fetch.call);

    final stale = pulls.pull(CoreField.ctx);
    pulls.invalidate([CoreField.ctx]);
    final fresh = pulls.pull(CoreField.ctx);
    expect(fetch.asked, ['ctx', 'ctx'], reason: 'the in-flight one is old');

    // The old pull lands last: it must not displace the newer map.
    fetch.pending.removeLast().complete(jsonEncode({'v': 2}));
    fetch.pending.removeLast().complete(jsonEncode({'v': 1}));
    expect(await stale, {'v': 1}, reason: 'what its callers asked for');
    final freshMap = await fresh;
    expect(freshMap, {'v': 2});

    final again = await pulls.pull(CoreField.ctx);
    expect(identical(again, freshMap), isTrue, reason: 'the newer map won');
    expect(fetch.asked, hasLength(2));
  });

  test('a failed fetch reaches every caller and is not kept', () async {
    final fetch = Fetcher();
    final pulls = FieldPulls(fetch.call);

    final a = pulls.pull(CoreField.board);
    final b = pulls.pull(CoreField.board);
    fetch.fail(StateError('core is not initialized'));
    await expectLater(a, throwsStateError);
    await expectLater(b, throwsStateError);

    final retry = pulls.pull(CoreField.board);
    expect(fetch.asked, ['board', 'board'], reason: 'a failure is retried');
    fetch.answer({'catalogs': []});
    expect(await retry, {'catalogs': []});
  });

  test('fields are pulled independently and a clear forgets them', () async {
    final fetch = Fetcher();
    final pulls = FieldPulls(fetch.call);

    final ctx = pulls.pull(CoreField.ctx);
    final board = pulls.pull(CoreField.board);
    expect(fetch.asked, ['ctx', 'board']);
    fetch.answer({'profile': {}});
    fetch.answer({'catalogs': []});
    final ctxMap = await ctx;
    await board;

    pulls.invalidate([CoreField.board]);
    expect(
      identical(await pulls.pull(CoreField.ctx), ctxMap),
      isTrue,
      reason: 'a board change is not a ctx change',
    );
    expect(fetch.asked, ['ctx', 'board']);

    pulls.clear();
    final afresh = pulls.pull(CoreField.ctx);
    expect(fetch.asked, ['ctx', 'board', 'ctx']);
    fetch.answer({'profile': {}});
    await afresh;
  });
}
