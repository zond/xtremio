import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/tv_ladder.dart';

import 'package:xtremio/widgets/remote_press.dart';

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

  group('select on a row where landing already chooses', () {
    /// Rows 0 and 20, the top one moving on after select when [advance];
    /// its cards are plain buttons, or [RemotePress] tiles when [remote].
    /// Every press of a top card is counted in [pressed].
    Widget advancing({
      required bool advance,
      required bool remote,
      required List<String> pressed,
    }) {
      Widget topCard(String label) => remote
          ? RemotePress(
              onTap: () => pressed.add(label),
              onLongPress: () => pressed.add('$label held'),
              child: Focus(focusNode: _nodeFor(label), child: Text(label)),
            )
          : ElevatedButton(
              focusNode: _nodeFor(label),
              onPressed: () => pressed.add(label),
              child: Text(label),
            );
      return DeviceScope(
        profile: tv,
        child: MaterialApp(
          home: Scaffold(
            body: TvLadder(
              child: Column(
                children: [
                  TvLadderRow(
                    level: 0,
                    advanceOnSelect: advance,
                    child: Row(children: [topCard('a'), topCard('b')]),
                  ),
                  TvLadderRow(
                    level: 20,
                    child: Row(children: [_card('c'), _card('d')]),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    for (final remote in [false, true]) {
      final kind = remote ? 'a remote-press tile' : 'a plain button';
      testWidgets('on $kind, select does what the card does and moves down', (
        tester,
      ) async {
        useScreen(tester, tvSize);
        final pressed = <String>[];
        await tester.pumpWidget(
          advancing(advance: true, remote: remote, pressed: pressed),
        );
        _nodeFor('b').requestFocus();
        await tester.pumpAndSettle();

        await press(tester, LogicalKeyboardKey.select);

        expect(pressed, ['b'], reason: "the card's own action still runs");
        expect(_focused(), 'c', reason: 'and then what down does');
      });
    }

    for (final remote in [false, true]) {
      final kind = remote ? 'a remote-press tile' : 'a plain button';
      testWidgets('on $kind in a row not marked for it, select stays put', (
        tester,
      ) async {
        useScreen(tester, tvSize);
        final pressed = <String>[];
        await tester.pumpWidget(
          advancing(advance: false, remote: remote, pressed: pressed),
        );
        _nodeFor('a').requestFocus();
        await tester.pumpAndSettle();

        await press(tester, LogicalKeyboardKey.select);

        expect(pressed, ['a']);
        expect(_focused(), 'a');
      });
    }

    testWidgets('a held select is the card\'s, and the remote stays', (
      tester,
    ) async {
      useScreen(tester, tvSize);
      final pressed = <String>[];
      await tester.pumpWidget(
        advancing(advance: true, remote: true, pressed: pressed),
      );
      _nodeFor('a').requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(
        RemotePress.holdDuration + const Duration(milliseconds: 50),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(pressed, ['a held']);
      expect(_focused(), 'a', reason: 'a long press is not a choice made');
    });
  });

  testWidgets('a press down onto a row below the fold brings it on screen', (
    tester,
  ) async {
    // The layout and order chips are plain controls, which do not scroll
    // themselves into view the way the tiles do: the remote went down onto
    // the order chips and they stayed off screen until the next press.
    useScreen(tester, tvSize);
    await tester.pumpWidget(
      DeviceScope(
        profile: tv,
        child: MaterialApp(
          home: Scaffold(
            body: TvLadder(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    TvLadderRow(level: 0, child: _card('a')),
                    SizedBox(height: tvSize.height * 2),
                    TvLadderRow(level: 20, child: _card('b')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _nodeFor('a').requestFocus();
    await tester.pumpAndSettle();
    bool onScreen(String label) {
      final box = tester.getRect(find.text(label));
      return box.top >= 0 && box.bottom <= tvSize.height;
    }

    expect(onScreen('b'), isFalse, reason: 'below the fold to start');

    await press(tester, LogicalKeyboardKey.arrowDown);

    expect(_focused(), 'b');
    expect(
      onScreen('b'),
      isTrue,
      reason: 'and on screen, with no second press',
    );

    await press(tester, LogicalKeyboardKey.arrowUp);

    expect(_focused(), 'a');
    expect(onScreen('a'), isTrue, reason: 'and back up again');
  });
}
