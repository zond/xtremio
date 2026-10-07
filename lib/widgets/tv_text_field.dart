import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shell/device_profile.dart';
import '../shell/speech_input.dart';
import '../shell/tv_text_entry.dart';
import 'focusable_tile.dart';
import 'remote_press.dart';

/// The one single-line text field in the app, wherever something has to be
/// typed: an email address, a password, a search, a URL, a folder.
///
/// Off a television it is the plain [TextField] every one of those places
/// had before, with the same [decoration] and the same callbacks, and
/// nothing about the phone or the desktop changes.
///
/// On a television it stops being a text field at all. It draws the same
/// [InputDecoration] around the current value (masked when the [kind] is a
/// secret) and takes focus like any other control, so the D-pad walks past
/// it in every direction; pressing select hands the whole job to
/// [TvTextEntry], which is a screen the system keyboard can actually own.
/// See [TvTextEntry] for why Flutter's own field cannot be typed into with
/// a remote.
///
/// A returned string is put in the [controller] and then announced to
/// [onChanged] and [onSubmitted], because confirming on that screen is the
/// remote's version of pressing Done. A cancelled screen returns nothing
/// and neither the value nor the focus here moves.
///
/// A field that [typesInPlace] also takes a hardware keyboard's typing
/// while it has focus, with no screen at all: each character, and
/// Backspace, changes the value and is announced to [onChanged] alone, the
/// way a keystroke is in the plain field.
class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    required this.controller,
    required this.decoration,
    this.kind = TvTextKind.text,
    this.enabled = true,
    this.autofocus = false,
    this.autofillHints,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.typesInPlace = false,
    this.voice = false,
  });

  final TextEditingController controller;
  final InputDecoration decoration;
  final TvTextKind kind;
  final bool enabled;

  /// Takes focus when it is built. Off a television this also opens the
  /// keyboard, as it always has; on one it only puts focus here, and the
  /// text-entry screen still waits for a press.
  final bool autofocus;

  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Empties the field, from a button at its trailing edge that shows only
  /// while there is something to clear.
  ///
  /// Off a television that button is the decoration's `suffixIcon`, drawn
  /// inside the box, where it has always been. On one it sits beside the
  /// box instead, as a control of its own, because inside it is neither
  /// reachable nor pressable: the field takes focus as a whole, so
  /// directional traversal has nothing to the right of the text to step
  /// to, and [RemotePress] takes select for the typing screen before any
  /// descendant of it can. A button drawn where a remote cannot go is
  /// worse than no button.
  final VoidCallback? onClear;

  /// On a television, a hardware keyboard types straight into the field
  /// while it has focus, rather than only select opening the text-entry
  /// screen. For a field whose every change is acted on as it is typed
  /// (Search); a field that only means something once it is finished keeps
  /// to the screen, whose confirming is the submit.
  ///
  /// Only printable characters and Backspace are taken: the D-pad, select,
  /// Enter and Back carry no character and go where they always went.
  final bool typesInPlace;

  /// On a television, a microphone button at the field's right end that
  /// fills it by voice ([SpeechInput]): what is heard shows in the field,
  /// muted, as it is said, and the final transcript is announced as a
  /// confirmed entry is. Pressing it again, Back, focus leaving it or the
  /// app being hidden stops listening and leaves the value as it was.
  ///
  /// Never a dead control: where the device has no recognizer, the
  /// permission is refused or the recognizer cannot record, it opens the
  /// text-entry screen instead, whose keyboard has a microphone of its own
  /// -- with a line saying why, where there is something to say. Off a
  /// television nothing changes: the keyboard there has the microphone.
  ///
  /// The button is drawn inside the field's outline, over room the
  /// decoration keeps free for it, and is a sibling of the field rather
  /// than a child: inside its [RemotePress] it could be landed on and not
  /// pressed. Since its box is inside the field's, directional traversal
  /// would never step right onto it, so the field sends right there itself.
  final bool voice;

  /// What the text-entry screen is headed with: whatever this field is
  /// already labelled, so nothing has to be named twice.
  String get label => decoration.labelText ?? decoration.hintText ?? '';

  /// What the field shows while listening, before anything is heard.
  static const String listeningText = 'Listening…';

  /// One character of a masked value.
  static const String obscuringCharacter = '•';

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  bool _focused = false;

  /// A text-entry screen is up; a second press must not open another.
  bool _editing = false;

  /// The field's own focus stop on a television, which is where Clear puts
  /// the remote once it has done its job.
  final FocusNode _fieldFocus = FocusNode(debugLabel: 'TvTextField');

  /// The microphone's stop ([TvTextField.voice]).
  final FocusNode _micFocus = FocusNode(debugLabel: 'TvTextField voice');

  /// The microphone's room at the field's trailing edge: a suffix icon's.
  static const double _micWidth = 48;

  /// A press of the microphone, from before its start is answered to its
  /// end; null between presses.
  StreamSubscription<SpeechEvent>? _speech;

  /// The recognizer is listening.
  bool _listening = false;

  /// What it has heard so far, shown in place of the value until the end.
  String? _heard;

  /// Ends the listening when the app is hidden; there only while it lasts.
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _micFocus.addListener(_onMicFocus);
  }

  @override
  void dispose() {
    if (_speech != null) unawaited(SpeechInput.stop());
    _endSpeech(rebuild: false);
    _fieldFocus.dispose();
    _micFocus.dispose();
    super.dispose();
  }

  Future<void> _edit() async {
    if (_editing) return;
    _editing = true;
    final typed = await TvTextEntry.edit(
      label: widget.label,
      value: widget.controller.text,
      kind: widget.kind,
    );
    _editing = false;
    // Cancelled, or no platform side: the value stands.
    if (!mounted || typed == null) return;
    _confirm(typed);
  }

  /// [typed] as the field's value, announced the way pressing Done is.
  void _confirm(String typed) {
    widget.controller.text = typed;
    widget.onChanged?.call(typed);
    widget.onSubmitted?.call(typed);
  }

  /// The microphone ([TvTextField.voice]): a press starts listening, a
  /// press while listening stops it.
  Future<void> _speak() async {
    if (_speech != null) {
      _cancelSpeech();
      return;
    }
    if (_editing) return;
    // Where Back and the D-pad go while it listens, so that either ends it.
    _micFocus.requestFocus();
    // Before the start: the first words can follow its answer at once.
    final press = SpeechInput.events.listen(_onSpeech);
    _speech = press;
    final started = await SpeechInput.start();
    if (!identical(_speech, press)) {
      // Ended while the start was on its way: by focus, Back or the app
      // going away. The recognizer it started goes too.
      if (started == SpeechStart.listening) unawaited(SpeechInput.stop());
      return;
    }
    switch (started) {
      case SpeechStart.listening:
        _lifecycle = AppLifecycleListener(onHide: _cancelSpeech);
        setState(() {
          _listening = true;
          _heard = null;
        });
      case SpeechStart.unavailable:
        _endSpeech();
        await _edit();
      case SpeechStart.denied:
        _endSpeech();
        _tell(SpeechError.permission.message);
        await _edit();
      case SpeechStart.busy:
        _endSpeech();
    }
  }

  void _onSpeech(SpeechEvent event) {
    if (!mounted) return;
    switch (event) {
      case SpeechPartial(:final text):
        setState(() => _heard = text);
      case SpeechFinal(:final text):
        _endSpeech();
        _confirm(text);
      case SpeechFailed(:final error):
        _endSpeech();
        _tell(error.message);
        if (error.opensKeyboard) unawaited(_edit());
    }
  }

  /// Stops listening on the viewer's account; the value stands as it was.
  void _cancelSpeech() {
    if (_speech == null) return;
    unawaited(SpeechInput.stop());
    _endSpeech();
  }

  /// Lets the press go: the subscription (whose end stops the recognizer
  /// too), the listening state and what was heard.
  void _endSpeech({bool rebuild = true}) {
    unawaited(_speech?.cancel());
    _speech = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    if (!_listening && _heard == null) return;
    if (rebuild && mounted) {
      setState(() {
        _listening = false;
        _heard = null;
      });
    } else {
      _listening = false;
      _heard = null;
    }
  }

  /// Focus leaving the button ends the press, listening or still being
  /// started (the permission dialog can be up).
  void _onMicFocus() {
    if (!_micFocus.hasFocus) _cancelSpeech();
  }

  void _tell(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Keys on the field itself: right to the microphone, which traversal
  /// cannot reach from a box that contains it, then a hardware keyboard's
  /// typing where the field [TvTextField.typesInPlace].
  KeyEventResult _onFieldKey(FocusNode node, KeyEvent event) {
    if (widget.voice &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _micFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return widget.typesInPlace ? _onKey(node, event) : KeyEventResult.ignored;
  }

  /// A hardware key while the field has focus ([TvTextField.typesInPlace]).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !widget.enabled) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final text = widget.controller.text;
    final String typed;
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      if (text.isEmpty) return KeyEventResult.handled;
      typed = text.characters.skipLast(1).string;
    } else {
      final character = event.character;
      if (character == null || !_printable(character)) {
        return KeyEventResult.ignored;
      }
      typed = text + character;
    }
    widget.controller.text = typed;
    widget.onChanged?.call(typed);
    return KeyEventResult.handled;
  }

  /// Something that is written, rather than a control character (Enter's
  /// carriage return, Tab, Delete).
  static bool _printable(String character) =>
      character.runes.every((rune) => rune >= 0x20 && rune != 0x7f);

  /// The Clear button, or nothing when there is nothing to clear.
  ///
  /// On a television the press hands focus to the field first: emptying
  /// it takes the button out of the tree, and a focused node that leaves
  /// the tree leaves the remote on nothing -- no ring anywhere, and the
  /// next press of the D-pad has to find its own way back. The field is
  /// what is left where the button was, and typing something new is the
  /// usual next step anyway.
  Widget? _clearButton({bool refocus = false}) {
    final onClear = widget.onClear;
    if (onClear == null || !widget.enabled || widget.controller.text.isEmpty) {
      return null;
    }
    return IconButton(
      tooltip: 'Clear',
      icon: const Icon(Icons.close),
      onPressed: refocus
          ? () {
              _fieldFocus.requestFocus();
              onClear();
            }
          : onClear,
    );
  }

  @override
  Widget build(BuildContext context) =>
      DeviceScope.isTv(context) ? _buildTv(context) : _buildField();

  /// Rebuilt on the controller, not on the parent: whether there is
  /// anything to clear changes with every edit, and a parent that does not
  /// rebuild on typing would leave the button as it was.
  Widget _buildField() => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => TextField(
      controller: widget.controller,
      decoration: widget.decoration.copyWith(suffixIcon: _clearButton()),
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      keyboardType: widget.kind.keyboardType,
      obscureText: widget.kind.isSecret,
      autocorrect: widget.kind.autocorrects,
      autofillHints: widget.autofillHints,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
    ),
  );

  Widget _buildTv(BuildContext context) {
    final theme = Theme.of(context);
    final onTap = widget.enabled ? _edit : null;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final heard = _listening ? (_heard ?? TvTextField.listeningText) : null;
        final text = heard ?? widget.controller.text;
        // The ring and the fill are the app's, not this field's: the ink
        // falls through to `ThemeData.focusColor`, the theme floor's, and
        // the ring comes from the same emphasis every other control reads.
        // Not a fill of its own -- that would be a cue nothing else in the
        // app uses, and one the Bold switch could not reach. A
        // [FocusTreatment.row], because the field sits in a column of them
        // and a zoom would put it over its neighbours.
        final field = FocusMarked(
          child: RemotePress(
            onTap: onTap,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              includeSemantics: false,
              onKeyEvent: widget.typesInPlace || widget.voice
                  ? _onFieldKey
                  : null,
              child: InkWell(
                onTap: onTap,
                focusNode: _fieldFocus,
                autofocus: widget.autofocus,
                onFocusChange: (focused) {
                  if (mounted) setState(() => _focused = focused);
                },
                child: InputDecorator(
                  decoration: widget.decoration.copyWith(
                    enabled: widget.enabled,
                    suffixIcon: widget.voice
                        ? const SizedBox(width: _micWidth)
                        : null,
                  ),
                  isFocused: _focused,
                  isEmpty: text.isEmpty,
                  child: Text(
                    widget.kind.isSecret && heard == null
                        ? TvTextField.obscuringCharacter * text.length
                        : text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // What is heard is not the value yet, and looks it.
                    style: heard == null
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                  ),
                ),
              ),
            ),
          ),
        );
        // Beside the field, not inside it: its own focus stop, to the right
        // of the one the field is, and outside the [RemotePress] that would
        // otherwise turn select on it into the typing screen. The row is
        // there whether or not the button is, so that a first character
        // arriving does not reparent the field and take its focus with it.
        final row = Row(
          children: [
            Expanded(
              child: widget.voice
                  ? Stack(
                      children: [
                        field,
                        Positioned(
                          top: 0,
                          right: 0,
                          bottom: 0,
                          width: _micWidth,
                          child: Center(
                            child: IconButton(
                              key: const Key('tv-text-field-voice'),
                              focusNode: _micFocus,
                              tooltip: _listening
                                  ? 'Stop listening'
                                  : 'Voice input',
                              isSelected: _listening,
                              icon: const Icon(Icons.mic_none),
                              // Listening: the filled microphone in a ring
                              // of the accent colour, still, so that
                              // nothing on the screen moves but the words.
                              selectedIcon: Icon(
                                Icons.mic,
                                color: theme.colorScheme.primary,
                              ),
                              style: _listening
                                  ? IconButton.styleFrom(
                                      side: BorderSide(
                                        color: theme.colorScheme.primary,
                                        width: 2,
                                      ),
                                    )
                                  : null,
                              onPressed: widget.enabled ? _speak : null,
                            ),
                          ),
                        ),
                      ],
                    )
                  : field,
            ),
            _clearButton(refocus: true) ?? const SizedBox.shrink(),
          ],
        );
        if (!widget.voice) return row;
        // Back while listening is the end of listening, and nothing more:
        // the rung exists only while the microphone visibly listens.
        return PopScope(
          canPop: !_listening,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _cancelSpeech();
          },
          child: row,
        );
      },
    );
  }
}
