import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/shell/device_profile.dart';
import 'package:xtremio/shell/tv_text_entry.dart';
import 'package:xtremio/widgets/tv_text_field.dart';

import '../support/tv.dart';

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
    VoidCallback? onClear,
    bool voice = false,
    InputDecoration decoration = const InputDecoration(labelText: 'Email'),
  }) => DeviceScope(
    profile: isTv ? tv : DeviceProfile.fallback,
    child: MaterialApp(
      home: Scaffold(
        body: TvTextField(
          controller: controller,
          decoration: decoration,
          kind: kind,
          autofocus: autofocus,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          onClear: onClear,
          voice: voice,
        ),
      ),
    ),
  );

  final mic = find.byKey(const Key('tv-text-field-voice'));

  /// The device's recognizer: there or not ([canRecognize]), answering
  /// [heard]; `editText` answers [typed]. Records every call.
  void answersSpeech({
    required bool canRecognize,
    String? heard,
    String? typed,
  }) {
    mockChannel((call) async {
      calls.add(call);
      return switch (call.method) {
        TvTextEntry.canRecognizeSpeechMethod => canRecognize,
        TvTextEntry.recognizeSpeechMethod => heard,
        TvTextEntry.method => typed,
        _ => null,
      };
    });
  }

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

    testWidgets('Clear leaves the remote on the field, not on nothing', (
      tester,
    ) async {
      // The button goes the moment there is nothing to clear, and the
      // focus it held would go with it.
      final controller = TextEditingController(text: 'dune');
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller, onClear: controller.clear));
      final clear = find.widgetWithIcon(IconButton, Icons.close);
      Focus.of(tester.element(find.byIcon(Icons.close))).requestFocus();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.context,
        isNotNull,
        reason: 'the button has the remote',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(controller.text, isEmpty);
      expect(clear, findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'TvTextField',
        reason: 'the field itself holds the focus now',
      );
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

  group('the microphone', () {
    testWidgets('is on a television, inside the field, which keeps its '
        'height', (tester) async {
      const search = InputDecoration(
        hintText: 'Search',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.search),
        contentPadding: EdgeInsets.symmetric(vertical: 10),
      );
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller, decoration: search));
      expect(mic, findsNothing, reason: 'only a field that asks for it');
      final without = tester.getRect(find.byType(InputDecorator));

      await tester.pumpWidget(
        host(controller, decoration: search, voice: true),
      );
      expect(mic, findsOneWidget);
      final field = tester.getRect(find.byType(InputDecorator));
      expect(field, without);
      final button = tester.getRect(mic);
      expect(field.contains(button.topLeft), isTrue);
      expect(field.contains(button.bottomRight - const Offset(1, 1)), isTrue);
      expect(button.right, field.right, reason: 'at its right end');
      // The text keeps out from under it, however long it is.
      controller.text = 'a title long enough to run the whole width ' * 4;
      await tester.pump();
      expect(
        tester.getRect(find.text(controller.text)).right,
        lessThanOrEqualTo(button.left),
      );
    });

    testWidgets('is not off a television', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller, isTv: false, voice: true));
      expect(find.byType(TextField), findsOneWidget);
      expect(mic, findsNothing);
      expect(find.byIcon(Icons.mic_none), findsNothing);
    });

    testWidgets('is right of the field for the D-pad, and the field left of '
        'it', (tester) async {
      final controller = TextEditingController(text: 'dune');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(controller, voice: true, onClear: controller.clear),
      );
      await tester.pump();
      tester
          .widget<InkWell>(find.byType(InkWell).first)
          .focusNode!
          .requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'TvTextField');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'TvTextField voice',
      );
      // On from it to Clear, beside the box, and back.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        Focus.of(tester.element(find.byIcon(Icons.close))).hasPrimaryFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'TvTextField voice',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'TvTextField');
    });

    testWidgets('fills the field with what was heard and confirms it', (
      tester,
    ) async {
      answersSpeech(canRecognize: true, heard: 'the thing');
      final controller = TextEditingController(text: 'old');
      addTearDown(controller.dispose);
      final changed = <String>[];
      final submitted = <String>[];
      await tester.pumpWidget(
        host(
          controller,
          voice: true,
          onChanged: changed.add,
          onSubmitted: submitted.add,
        ),
      );

      await tester.tap(mic);
      await tester.pumpAndSettle();

      expect(calls.map((call) => call.method), [
        TvTextEntry.canRecognizeSpeechMethod,
        TvTextEntry.recognizeSpeechMethod,
      ]);
      expect(calls.last.arguments, {'prompt': 'Email'});
      expect(controller.text, 'the thing');
      expect(changed, ['the thing']);
      expect(submitted, ['the thing']);
    });

    testWidgets('nothing heard leaves the field alone', (tester) async {
      answersSpeech(canRecognize: true);
      final controller = TextEditingController(text: 'kept');
      addTearDown(controller.dispose);
      final changed = <String>[];
      await tester.pumpWidget(
        host(controller, voice: true, onChanged: changed.add),
      );

      await tester.tap(mic);
      await tester.pumpAndSettle();

      expect(calls.last.method, TvTextEntry.recognizeSpeechMethod);
      expect(controller.text, 'kept');
      expect(changed, isEmpty);
    });

    testWidgets('with no recognizer it opens the keyboard screen instead', (
      tester,
    ) async {
      answersSpeech(canRecognize: false, typed: 'typed');
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller, voice: true));

      await tester.tap(mic);
      await tester.pumpAndSettle();

      expect(calls.map((call) => call.method), [
        TvTextEntry.canRecognizeSpeechMethod,
        TvTextEntry.method,
      ]);
      expect(controller.text, 'typed');
    });

    testWidgets('with no platform side at all it is the keyboard screen, '
        'which is not there either: nothing changes', (tester) async {
      mockChannel(null);
      final controller = TextEditingController(text: 'kept');
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller, voice: true));

      await tester.tap(mic);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(controller.text, 'kept');
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

    testWidgets('Clear comes and goes with the text, with no rebuild from '
        'above', (tester) async {
      // A parent that does not rebuild on typing is the ordinary case: the
      // field owns whether there is anything to clear.
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(controller, isTv: false, onClear: controller.clear),
      );
      expect(find.byTooltip('Clear'), findsNothing);

      await tester.enterText(find.byType(TextField), 'typed here');
      await tester.pump();
      expect(find.byTooltip('Clear'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear'));
      await tester.pump();
      expect(controller.text, isEmpty);
      expect(find.byTooltip('Clear'), findsNothing);
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
