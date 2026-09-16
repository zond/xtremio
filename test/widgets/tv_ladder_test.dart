import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/tv_ladder.dart';

import '../support/tv.dart';

/// One focus node per card, so a test can put the remote somewhere to
/// start and read back where a press took it.
final Map<String, FocusNode> _nodes = {};

FocusNode _nodeFor(String label) =>
    _nodes.putIfAbsent(label, () => FocusNode(debugLabel: label));

Widget _card(String label) => ElevatedButton(
  focusNode: _nodeFor(label),
  onPressed: () {},
  child: Text(label),
);

/// The card the remote is standing on, by its label.
String? _focused() => FocusManager.instance.primaryFocus?.debugLabel;

/// A ladder of [rows], each `level: [labels]`, under something that counts
/// the presses nobody answered.
Widget _harness(
  Map<int, List<String>> rows, {
  required List<KeyEvent> loose,
  DeviceProfile profile = tv,
}) => DeviceScope(
  profile: profile,
  child: MaterialApp(
    home: Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) loose.add(event);
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        body: TvLadder(
          child: Column(
            children: [
              for (final row in rows.entries)
                TvLadderRow(
                  level: row.key,
                  child: Row(children: [for (final l in row.value) _card(l)]),
                ),
            ],
          ),
        ),
      ),
    ),
  ),
);

void main() {
  setUp(_nodes.clear);
  tearDown(() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    _nodes.clear();
  });

  testWidgets('a press down steps over a row with nothing to land on', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final loose = <KeyEvent>[];
    await tester.pumpWidget(
      _harness({
        0: ['a', 'b'],
        10: <String>[],
        20: ['c', 'd'],
      }, loose: loose),
    );
    _nodeFor('a').requestFocus();
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.arrowDown);

    expect(_focused(), 'c', reason: 'the empty row is passed over');
    expect(loose, isEmpty, reason: 'the ladder answered it');
  });

  testWidgets('a row hands the remote back to the card it was last on', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final loose = <KeyEvent>[];
    await tester.pumpWidget(
      _harness({
        0: ['a', 'b'],
        20: ['c', 'd'],
      }, loose: loose),
    );
    _nodeFor('d').requestFocus();
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused(), 'a', reason: 'the first card of a row never visited');

    await press(tester, LogicalKeyboardKey.arrowDown);

    expect(
      _focused(),
      'd',
      reason: 'the card the remote left, not the first of the row',
    );
  });

  testWidgets('a press no row can answer is left for whatever else wants it', (
    tester,
  ) async {
    useScreen(tester, tvSize);
    final loose = <KeyEvent>[];
    await tester.pumpWidget(
      _harness({
        0: ['a', 'b'],
        20: ['c', 'd'],
      }, loose: loose),
    );
    _nodeFor('a').requestFocus();
    await tester.pumpAndSettle();

    // Nothing above the top rung: swallowing this is a dead D-pad.
    await press(tester, LogicalKeyboardKey.arrowUp);

    expect(loose, hasLength(1));
    expect(loose.single.logicalKey, LogicalKeyboardKey.arrowUp);
  });

  testWidgets('off a television the rows are their children and nothing else', (
    tester,
  ) async {
    final loose = <KeyEvent>[];
    await tester.pumpWidget(
      _harness(
        {
          0: ['a'],
          20: ['c'],
        },
        loose: loose,
        profile: const DeviceProfile(isTv: false, hasTouch: true),
      ),
    );
    _nodeFor('a').requestFocus();
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.arrowDown);

    expect(loose, hasLength(1), reason: 'the ladder took no part in it');
  });
}
