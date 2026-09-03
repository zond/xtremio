import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/widgets/focusable_tile.dart';
import 'package:xtremio/widgets/remote_press.dart';

const tv = DeviceProfile(isTv: true, hasTouch: false);

/// [child] in a Material app, on a TV unless [device] says otherwise.
Widget harness(Widget child, {DeviceProfile device = tv}) => DeviceScope(
  profile: device,
  child: MaterialApp(home: Scaffold(body: child)),
);

/// [count] square tiles in a row; the tile at [nodeAt] gets [node].
Widget tiles({int count = 3, FocusNode? node, int nodeAt = 0}) => Row(
  children: [
    for (var i = 0; i < count; i++)
      SizedBox.square(
        dimension: 100,
        child: FocusableTile(
          onTap: () {},
          focusNode: i == nodeAt ? node : null,
          child: Text('tile $i'),
        ),
      ),
  ],
);

bool ringOf(WidgetTester tester, String label) => tester
    .widget<FocusRing>(
      find.ancestor(of: find.text(label), matching: find.byType(FocusRing)),
    )
    .focused;

void main() {
  testWidgets('on a TV the ring follows focus', (tester) async {
    await tester.pumpWidget(harness(tiles()));
    expect(find.byType(FocusRing), findsNWidgets(3));
    expect(ringOf(tester, 'tile 0'), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(ringOf(tester, 'tile 0'), isTrue);
    expect(ringOf(tester, 'tile 1'), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(ringOf(tester, 'tile 0'), isFalse);
    expect(ringOf(tester, 'tile 1'), isTrue);

    // The ring is a border drawn over the child only while focused.
    final boxes = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .toList();
    final borders = [
      for (final box in boxes) (box.decoration as BoxDecoration).border,
    ];
    expect(borders.whereType<Border>(), hasLength(1));
    expect(borders.whereType<Border>().single.top.width, FocusRing.width);
    expect(
      boxes.every((b) => b.position == DecorationPosition.foreground),
      true,
    );
  });

  testWidgets('off a TV the tile is a plain InkWell without a ring', (
    tester,
  ) async {
    await tester.pumpWidget(harness(tiles(), device: DeviceProfile.fallback));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(find.byType(FocusRing), findsNothing);
    expect(find.byType(InkWell), findsNWidgets(3));
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<FocusableTile>(),
      isNotNull,
    );
  });

  testWidgets('taps, long presses and secondary taps still reach the tile', (
    tester,
  ) async {
    final events = <String>[];
    await tester.pumpWidget(
      harness(
        SizedBox.square(
          dimension: 100,
          child: FocusableTile(
            onTap: () => events.add('tap'),
            onLongPress: () => events.add('long'),
            onSecondaryTap: () => events.add('secondary'),
            child: const Text('tile'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('tile'));
    await tester.longPress(find.text('tile'));
    await tester.tap(find.text('tile'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(events, ['tap', 'long', 'secondary']);
  });

  group('remote keys on a TV', () {
    Widget tile(List<String> events, {bool longPress = true}) =>
        SizedBox.square(
          dimension: 100,
          child: FocusableTile(
            onTap: () => events.add('tap'),
            onLongPress: longPress ? () => events.add('long') : null,
            onSecondaryTap: () => events.add('secondary'),
            defaultFocus: true,
            child: const Text('tile'),
          ),
        );

    testWidgets('select taps on release; held, it is the long press', (
      tester,
    ) async {
      final events = <String>[];
      await tester.pumpWidget(harness(tile(events)));
      await tester.pumpAndSettle();
      expect(ringOf(tester, 'tile'), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(events, ['tap']);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(RemotePress.holdDuration * 2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(events, ['tap', 'long']);
    });

    testWidgets('the menu key is the long press, or the secondary tap when '
        'the tile has no long press', (tester) async {
      final events = <String>[];
      await tester.pumpWidget(harness(tile(events)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(events, ['long']);

      events.clear();
      await tester.pumpWidget(harness(tile(events, longPress: false)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(events, ['secondary']);
    });

    testWidgets('off a TV there is no remote handling', (tester) async {
      final events = <String>[];
      await tester.pumpWidget(
        harness(
          Focus(autofocus: true, child: tile(events)),
          device: DeviceProfile.fallback,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RemotePress), findsNothing);
    });
  });

  group('focus memory', () {
    /// Three tiles ([ids], a, b, c by default) under [store] (or none); the
    /// first is the default.
    Widget remembered(
      FocusMemoryStore? store, {
      List<String> ids = const ['a', 'b', 'c'],
    }) {
      final row = Row(
        children: [
          for (final id in ids)
            SizedBox.square(
              dimension: 100,
              child: FocusableTile(
                onTap: () {},
                memoryId: id,
                defaultFocus: id == ids.first,
                child: Text('tile $id'),
              ),
            ),
        ],
      );
      return store == null ? row : FocusMemory(store: store, child: row);
    }

    testWidgets('the default tile takes focus when nothing is remembered', (
      tester,
    ) async {
      final store = FocusMemoryStore();
      await tester.pumpWidget(harness(remembered(store)));
      await tester.pumpAndSettle();

      expect(ringOf(tester, 'tile a'), isTrue);
      expect(store.lastFocused, 'a');
    });

    testWidgets('moving focus updates the memory', (tester) async {
      final store = FocusMemoryStore();
      await tester.pumpWidget(harness(remembered(store)));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      expect(ringOf(tester, 'tile c'), isTrue);
      expect(store.lastFocused, 'c');
    });

    testWidgets('the remembered tile takes focus over the default', (
      tester,
    ) async {
      final store = FocusMemoryStore()..lastFocused = 'b';
      await tester.pumpWidget(harness(remembered(store)));
      await tester.pumpAndSettle();

      expect(ringOf(tester, 'tile a'), isFalse);
      expect(ringOf(tester, 'tile b'), isTrue);
    });

    testWidgets('a remembered tile that is gone leaves focus alone', (
      tester,
    ) async {
      final store = FocusMemoryStore()..lastFocused = 'z';
      await tester.pumpWidget(harness(remembered(store)));
      await tester.pumpAndSettle();

      expect(find.byType(FocusRing), findsNWidgets(3));
      expect(
        tester
            .widgetList<FocusRing>(find.byType(FocusRing))
            .where((r) => r.focused),
        isEmpty,
      );
    });

    testWidgets('a tile rebuilt as the remembered one does not take focus', (
      tester,
    ) async {
      // Focus is elsewhere (on a button outside the tiles' scope, as the
      // rail is outside a tab's) and tile z is remembered but not built;
      // then the strip shifts so that the widget that showed tile a now
      // shows tile z. Autofocus was decided when the tile first appeared;
      // becoming the remembered tile later must not steal focus.
      final store = FocusMemoryStore()..lastFocused = 'z';
      final button = FocusNode();
      addTearDown(button.dispose);
      Widget page(List<String> ids) => Column(
        children: [
          TextButton(focusNode: button, onPressed: () {}, child: Text('x')),
          FocusScope(child: remembered(store, ids: ids)),
        ],
      );
      await tester.pumpWidget(harness(page(['a', 'b', 'c'])));
      button.requestFocus();
      await tester.pumpAndSettle();
      expect(button.hasPrimaryFocus, isTrue);

      await tester.pumpWidget(harness(page(['z', 'b', 'c'])));
      await tester.pumpAndSettle();

      expect(find.text('tile z'), findsOneWidget);
      expect(button.hasPrimaryFocus, isTrue);
      expect(ringOf(tester, 'tile z'), isFalse);
    });

    testWidgets('without a memory the default tile still takes focus', (
      tester,
    ) async {
      await tester.pumpWidget(harness(remembered(null)));
      await tester.pumpAndSettle();

      expect(ringOf(tester, 'tile a'), isTrue);
    });

    testWidgets('off a TV nothing autofocuses and nothing is remembered', (
      tester,
    ) async {
      final store = FocusMemoryStore();
      await tester.pumpWidget(
        harness(remembered(store), device: DeviceProfile.fallback),
      );
      await tester.pumpAndSettle();

      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<FocusableTile>(),
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(store.lastFocused, isNull);
    });
  });

  group('focus scrolls the tile into view', () {
    /// A 300 px wide strip of ten 100 px tiles; tile 3 is just outside the
    /// viewport (built, since it is within the cache extent) and [node] is
    /// its focus node.
    Widget strip(ScrollController controller, FocusNode node) => Center(
      child: SizedBox(
        width: 300,
        height: 100,
        child: ListView.builder(
          controller: controller,
          scrollDirection: Axis.horizontal,
          itemCount: 10,
          itemBuilder: (context, i) => SizedBox.square(
            dimension: 100,
            child: FocusableTile(
              onTap: () {},
              focusNode: i == 3 ? node : null,
              child: Text('tile $i'),
            ),
          ),
        ),
      ),
    );

    testWidgets('on a TV, centring it', (tester) async {
      final controller = ScrollController();
      final node = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(node.dispose);
      await tester.pumpWidget(harness(strip(controller, node)));
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      final viewport = tester.getRect(find.byType(ListView));
      // Built (within the cache extent) but not on screen.
      expect(find.text('tile 3'), findsNothing);
      expect(
        tester.getRect(find.text('tile 3', skipOffstage: false)).left,
        viewport.right,
      );

      node.requestFocus();
      await tester.pumpAndSettle();

      expect(node.hasPrimaryFocus, isTrue);
      expect(ringOf(tester, 'tile 3'), isTrue);
      expect(controller.offset, 200);
      expect(tester.getRect(find.text('tile 3')).left, viewport.left + 100);
    });

    testWidgets('off a TV focus leaves the scroll alone', (tester) async {
      final controller = ScrollController();
      final node = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(node.dispose);
      await tester.pumpWidget(
        harness(strip(controller, node), device: DeviceProfile.fallback),
      );
      await tester.pumpAndSettle();

      node.requestFocus();
      await tester.pumpAndSettle();

      expect(node.hasPrimaryFocus, isTrue);
      expect(controller.offset, 0);
    });
  });
}
