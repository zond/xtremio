import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_text_entry.dart';
import 'package:xtremio/widgets/tv_text_field.dart';

const tv = DeviceProfile(isTv: true, hasTouch: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<MethodCall> calls = [];

  /// Routes `xtremio/device` to [handler]; a null handler leaves it
  /// unanswered, as on a platform with no Kotlin side.
  void mockChannel(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DeviceProfile.channel, handler);
  }

  /// Answers every `editText` with [typed] and records the call.
  void answersWith(String? typed) {
    mockChannel((call) async {
      calls.add(call);
      return typed;
    });
  }

  setUp(calls.clear);
  tearDown(() => mockChannel(null));

  Widget host(
    TextEditingController controller, {
    bool isTv = true,
    TvTextKind kind = TvTextKind.text,
    bool autofocus = false,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
  }) => DeviceScope(
    profile: isTv ? tv : DeviceProfile.fallback,
    child: MaterialApp(
      home: Scaffold(
        body: TvTextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Email'),
          kind: kind,
          autofocus: autofocus,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
      ),
    ),
  );

  group('on a television', () {
    testWidgets('a press opens the platform screen and takes the string', (
      tester,
    ) async {
      answersWith('me@example.com');
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final changed = <String>[];
      final submitted = <String>[];
      await tester.pumpWidget(
        host(controller, onChanged: changed.add, onSubmitted: submitted.add),
      );

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(calls.single.method, TvTextEntry.method);
      expect(calls.single.arguments, {
        'label': 'Email',
        'value': '',
        'kind': 'text',
      });
      expect(controller.text, 'me@example.com');
      // Confirming there is the remote's way of pressing Done.
      expect(changed, ['me@example.com']);
      expect(submitted, ['me@example.com']);
      expect(find.text('me@example.com'), findsOneWidget);
    });

    testWidgets('the field is not a TextField, so the D-pad is free', (
      tester,
    ) async {
      answersWith(null);
      final controller = TextEditingController(text: 'kept');
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller));

      expect(find.byType(TextField), findsNothing);
      expect(find.byType(EditableText), findsNothing);
      expect(find.text('kept'), findsOneWidget);
    });

    testWidgets("the remote's select key opens it", (tester) async {
      answersWith('typed');
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller, autofocus: true));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(controller.text, 'typed');
    });

    testWidgets('a cancelled screen leaves the value alone', (tester) async {
      answersWith(null);
      final controller = TextEditingController(text: 'kept');
      addTearDown(controller.dispose);
      final changed = <String>[];
      await tester.pumpWidget(host(controller, onChanged: changed.add));

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(controller.text, 'kept');
      expect(changed, isEmpty);
    });

    testWidgets('a platform error leaves the value alone and does not throw', (
      tester,
    ) async {
      mockChannel((call) async {
        calls.add(call);
        throw PlatformException(code: 'text_entry_unavailable');
      });
      final controller = TextEditingController(text: 'kept');
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller));

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(calls, hasLength(1));
      expect(controller.text, 'kept');
    });

    testWidgets('a channel nobody answers leaves the value alone', (
      tester,
    ) async {
      mockChannel(null);
      final controller = TextEditingController(text: 'kept');
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller));

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(controller.text, 'kept');
    });

    testWidgets('a password asks for masking and shows none of itself', (
      tester,
    ) async {
      answersWith('hunter2');
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller, kind: TvTextKind.password));

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect((calls.single.arguments as Map)['kind'], 'password');
      expect(controller.text, 'hunter2');
      expect(find.text('hunter2'), findsNothing);
      expect(find.text('•' * 'hunter2'.length), findsOneWidget);
    });

    testWidgets('the value it opens with is the one on screen', (tester) async {
      answersWith('');
      final controller = TextEditingController(text: 'half typed');
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller));

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect((calls.single.arguments as Map)['value'], 'half typed');
    });
  });

  group('off a television', () {
    testWidgets('it is the ordinary field, and the channel is never called', (
      tester,
    ) async {
      answersWith('from the platform');
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller, isTv: false));

      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'typed here');
      await tester.pumpAndSettle();

      expect(controller.text, 'typed here');
      expect(calls, isEmpty);
    });

    testWidgets('a password field obscures itself as it always did', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(controller, isTv: false, kind: TvTextKind.password),
      );

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.obscureText, isTrue);
      expect(field.autocorrect, isFalse);
    });
  });
}
