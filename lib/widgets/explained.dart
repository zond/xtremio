import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../shell/device_profile.dart';
import 'remote_press.dart';

/// A settings row that shows its title only and keeps what it means in an
/// explanation, opened on demand.
///
/// An explanation under every title made the rows long, and some of them far
/// too long to read in passing. So the row is the title, and the words are a
/// press away. A row whose second line is live state (a status, a version,
/// free space) keeps that line, because a value is not an explanation.
///
/// **Off a television the row's icon opens it.** The icon is an
/// [ExplainIcon], which finds this widget above it and turns into a button
/// with the tooltip [tooltip]. The rest of the row keeps its own action.
///
/// **On a television it is a held OK.** A second stop per row would double
/// the remote's walk down the screen, so the row stays one stop and a long
/// press on it opens the explanation, the way Continue watching's tiles open
/// their actions. That is [RemotePress], so what is left of the held key is
/// swallowed and does not press the dialog's Close. A short press does what
/// it always did: it activates whatever in the row has focus (the row
/// itself, a switch, a menu, a colour chip).
///
/// Either way the explanation is [ExplanationDialog], opened by [show].
class Explained extends StatelessWidget {
  const Explained({
    super.key,
    required this.title,
    required this.explanation,
    required this.child,
  });

  /// The row's title, which is also the explanation's heading.
  final String title;

  /// What the row means, in a short plain paragraph.
  final String explanation;

  /// The row, whose leading icon is an [ExplainIcon].
  final Widget child;

  /// The icon's tooltip, and so its name to a screen reader.
  static const String tooltip = 'What is this?';

  /// The same, as the action a screen reader offers on the row.
  static const CustomSemanticsAction action = CustomSemanticsAction(
    label: tooltip,
  );

  /// The row [context] is drawn in, or null outside one.
  static Explained? of(BuildContext context) =>
      context.findAncestorWidgetOfExactType<Explained>();

  /// Opens [explanation] under [title] over the current screen.
  static Future<void> show(
    BuildContext context, {
    required String title,
    required String explanation,
  }) => showDialog<void>(
    context: context,
    builder: (_) => ExplanationDialog(title: title, explanation: explanation),
  );

  /// A short press on the row: the activation the key would have made on its
  /// own, sent to whatever in the row holds focus. [RemotePress] takes the key
  /// so that it can tell a press from a hold, and this hands the press on.
  static void _activateFocused() {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return;
    Actions.maybeInvoke(focused, const ActivateIntent());
  }

  @override
  Widget build(BuildContext context) {
    if (!DeviceScope.isTv(context)) return child;
    return RemotePress(
      onTap: _activateFocused,
      onLongPress: () => show(context, title: title, explanation: explanation),
      child: child,
    );
  }
}

/// The leading icon of an [Explained] row: the control that opens the row's
/// explanation.
///
/// Off a television it is an [IconButton] with the tooltip
/// [Explained.tooltip]. On a television it is the icon as it was, because the
/// row is the stop and a held OK is the way in ([Explained]).
///
/// It also gives the row a screen reader action of the same name. A switch
/// row merges everything inside it into one node, the icon's button with
/// it, so the action is how a screen reader still finds the explanation
/// there.
class ExplainIcon extends StatelessWidget {
  const ExplainIcon(this.icon, {super.key});

  /// The small info icon, for a row that has no icon of its own.
  const ExplainIcon.info({super.key}) : icon = const Icon(Icons.info_outline);

  /// The row's own icon: an [Icon] usually, a flag or a picture sometimes.
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    final row = Explained.of(context);
    assert(row != null, 'An ExplainIcon belongs inside an Explained row.');
    if (row == null) return icon;
    void open() =>
        Explained.show(context, title: row.title, explanation: row.explanation);
    return Semantics(
      customSemanticsActions: {Explained.action: open},
      child: DeviceScope.isTv(context)
          ? icon
          : IconButton(
              tooltip: Explained.tooltip,
              // As wide as the icon and as tall as a touch target. A wider
              // button would push the title right, and on a 320 dp phone
              // the longer titles would lose a word to the next line.
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 24,
                minHeight: kMinInteractiveDimension,
              ),
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: icon,
              onPressed: open,
            ),
    );
  }
}

/// A row's explanation: its title, the paragraph, and Close.
///
/// On a television it is set larger and wider, to be read from across a
/// room, and Close has focus, so OK closes it. Back closes it too, as it
/// closes any dialog. Focus goes back to the row it was opened from, which
/// is where the route under it left it.
class ExplanationDialog extends StatelessWidget {
  const ExplanationDialog({
    super.key,
    required this.title,
    required this.explanation,
  });

  final String title;
  final String explanation;

  static const String closeLabel = 'Close';

  @override
  Widget build(BuildContext context) {
    final isTv = DeviceScope.isTv(context);
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text(title),
      scrollable: true,
      content: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isTv ? 720 : 400),
        child: Text(
          explanation,
          style: isTv
              ? text.titleLarge?.copyWith(fontWeight: FontWeight.w400)
              : text.bodyLarge,
        ),
      ),
      actions: [
        TextButton(
          autofocus: isTv,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(closeLabel),
        ),
      ],
    );
  }
}
