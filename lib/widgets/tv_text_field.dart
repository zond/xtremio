import 'package:flutter/material.dart';

import '../shell/device_profile.dart';
import '../shell/tv_text_entry.dart';
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

  /// What the text-entry screen is headed with: whatever this field is
  /// already labelled, so nothing has to be named twice.
  String get label => decoration.labelText ?? decoration.hintText ?? '';

  /// One character of a masked value.
  static const String obscuringCharacter = '•';

  /// How strongly the focused field is filled on a television. Material's
  /// own `focusColor` is a few percent of black or white, which is not a
  /// cue across a room.
  static const double focusFill = 0.24;

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  bool _focused = false;

  /// A text-entry screen is up; a second press must not open another.
  bool _editing = false;

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
    widget.controller.text = typed;
    widget.onChanged?.call(typed);
    widget.onSubmitted?.call(typed);
  }

  @override
  Widget build(BuildContext context) =>
      DeviceScope.isTv(context) ? _buildTv(context) : _buildField();

  Widget _buildField() => TextField(
    controller: widget.controller,
    decoration: widget.decoration,
    enabled: widget.enabled,
    autofocus: widget.autofocus,
    keyboardType: widget.kind.keyboardType,
    obscureText: widget.kind.isSecret,
    autocorrect: widget.kind.autocorrects,
    autofillHints: widget.autofillHints,
    textInputAction: widget.textInputAction,
    onChanged: widget.onChanged,
    onSubmitted: widget.onSubmitted,
  );

  Widget _buildTv(BuildContext context) {
    final theme = Theme.of(context);
    final onTap = widget.enabled ? _edit : null;
    return RemotePress(
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        autofocus: widget.autofocus,
        focusColor: theme.colorScheme.primary.withValues(
          alpha: TvTextField.focusFill,
        ),
        onFocusChange: (focused) {
          if (mounted) setState(() => _focused = focused);
        },
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final text = widget.controller.text;
            return InputDecorator(
              decoration: widget.decoration.copyWith(enabled: widget.enabled),
              isFocused: _focused,
              isEmpty: text.isEmpty,
              child: Text(
                widget.kind.isSecret
                    ? TvTextField.obscuringCharacter * text.length
                    : text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            );
          },
        ),
      ),
    );
  }
}
