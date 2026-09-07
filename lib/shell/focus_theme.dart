import 'package:flutter/material.dart';

import '../core/focus_emphasis.dart';
import '../widgets/focusable_tile.dart';

/// The floor under everything the remote can land on that this app did not
/// draw itself: [FocusEmphasis] derived into [ThemeData], so a Material
/// control is clearly marked without opting in to anything.
///
/// [FocusHighlight] is worn by what the app builds -- a poster, a menu row,
/// a rail destination -- and every one of those had to be wrapped by hand.
/// Material's own controls could not be, and for a long time were not: the
/// setting reached exactly one widget in the app, so a settings row, a
/// dialog's buttons, the ⋮ menu on an installed addon and every control on
/// Downloads and Diagnostics wore Flutter's default focus tint -- an
/// overlay of about a tenth of the surface colour, no outline at all, and
/// deaf to the switch. Across a room on a projector that is not a focus
/// indicator; it is the same class of fault as a button that is drawn and
/// dead, and there were twenty files of it.
///
/// **One stroke over a lift, not two strokes.** [FocusRing] paints strokes
/// of opposite luminance because it is drawn over poster art and video:
/// whatever is underneath, one of the two contrasts with it. A
/// [ButtonStyle] carries a single [BorderSide] and a [ChipThemeData] a
/// single side, so the floor cannot do that. It does not have to: every
/// surface it covers is drawn on the app's own near-black ground or on the
/// player's black scrim, so one near-white stroke has a known background to
/// contrast with. What is drawn straight over unknown content is what wears
/// a [FocusHighlight] instead, and that split is the whole division of
/// labour here.
///
/// **What it cannot reach**, and what therefore has to be wrapped:
///
/// - **A chip's outline.** The fill reaches a chip like anything else --
///   `RawChip` builds an [InkWell] with no focus colour of its own, so it
///   falls through to [ThemeData.focusColor] -- but the stroke cannot be
///   given from here, although a chip does take a
///   [WidgetStateBorderSide]: `ChipThemeData.lerp` resolves a side for the
///   *empty* state and dereferences it, so a side that is a border only
///   while focused throws the moment the theme animates -- which is on
///   every flip of the switch. `CheckboxThemeData.lerp` does the same, and
///   is why the box in the account form is given the overlay alone. So a
///   chip is wrapped by hand for the outline and keeps the fill.
/// - **[ListTile]** takes no per-state shape, so a focused row is filled
///   and not outlined. That is enough on the app's own solid background,
///   which is where every list of them is -- and not enough over video,
///   which is why the player's menus wrap their rows.
/// - **[NavigationRail]** hands out no focus nodes at all, so the shell
///   draws that ring itself where it keeps its own nodes; the fill below
///   still reaches it, because its ink falls back to [ThemeData.focusColor]
///   like any other.
///
/// **A television only.** [FocusEmphasis] is a choice about a room and a
/// panel the app knows nothing about, made with a remote; off a television
/// focus follows a pointer or Tab against a background the viewer is an
/// arm's length from, and Material's own tint is what every other desktop
/// application draws. So `XtremioApp` applies this exactly where
/// [FocusHighlighted] and [FocusMarked] draw anything, and for the same
/// reason.
abstract final class FocusTheme {
  /// The stroke around a focused control: [FocusRing]'s light one. Not the
  /// theme's violet, for the reason the ring gives -- its luminance is the
  /// problem being solved.
  static const Color stroke = FocusRing.innerColor;

  /// How thick that stroke is: half of [FocusRing]'s width, because the
  /// ring spends the other half on its second stroke and this has only
  /// one.
  static double strokeWidth(FocusEmphasis emphasis) =>
      FocusRing.widthFor(emphasis) / 2;

  /// What a focused control is lifted by, over its own background. Small:
  /// it is drawn *under* the control's label and icon (an ink overlay
  /// paints below the child), so a heavy one washes out a white icon on
  /// the player's bar, and the stroke is the cue that carries this anyway.
  static double lift(FocusEmphasis emphasis) =>
      emphasis == FocusEmphasis.bold ? 0.28 : 0.16;

  /// What a focused control with *no* stroke available is filled by --
  /// [ThemeData.focusColor], which is where an [InkResponse] with no
  /// overlay of its own ends up: a [ListTile], a [PopupMenuItem], a
  /// [NavigationRail] destination. Heavier than [lift], since for these it
  /// is the whole indicator.
  static double fill(FocusEmphasis emphasis) =>
      emphasis == FocusEmphasis.bold ? 0.44 : 0.28;

  /// [base] with the focus floor for [emphasis] on it.
  ///
  /// Every component style is merged onto whatever [base] already carries
  /// (`TvDensity` has already set the icon buttons' minimum size by the
  /// time this runs), never assigned over it.
  static ThemeData apply(ThemeData base, FocusEmphasis emphasis) {
    final button = _focusStyle(emphasis);
    final extensions = base.extensions.values.toList()
      ..add(FocusFloor(emphasis));
    return base.copyWith(
      extensions: extensions,
      focusColor: stroke.withValues(alpha: fill(emphasis)),
      filledButtonTheme: FilledButtonThemeData(
        style: _merge(base.filledButtonTheme.style, button),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: _merge(base.elevatedButtonTheme.style, button),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: _merge(base.outlinedButtonTheme.style, button),
      ),
      textButtonTheme: TextButtonThemeData(
        style: _merge(base.textButtonTheme.style, button),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: _merge(base.iconButtonTheme.style, button),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: _merge(base.segmentedButtonTheme.style, button),
      ),
      // The entries of a [MenuAnchor]'s menu: the filter menu a television
      // gets in place of a dropdown is one of these.
      menuButtonTheme: MenuButtonThemeData(
        style: _merge(base.menuButtonTheme.style, button),
      ),
      switchTheme: base.switchTheme.copyWith(overlayColor: _overlay(emphasis)),
      // The overlay and not a side: `CheckboxThemeData.lerp` reads a side
      // resolved for the empty state and asserts it is not null, so a
      // per-state one throws the moment the theme animates -- which is on
      // every flip of the switch. The box is a `CheckboxListTile` in the
      // account form either way, and a list tile is filled.
      checkboxTheme: base.checkboxTheme.copyWith(
        overlayColor: _overlay(emphasis),
      ),
      radioTheme: base.radioTheme.copyWith(overlayColor: _overlay(emphasis)),
      // No slider: `SliderThemeData.overlayColor` is one colour rather
      // than a per-state property, and the app's one slider (the player's
      // volume) is built only off a television, because a slider takes
      // every arrow key for itself and a remote that landed on one could
      // never leave again.
    );
  }

  /// The emphasis [FocusTheme.apply] put on the theme in force below
  /// [context], or null where no floor was applied (off a television, or a
  /// widget test that pumped a screen under a bare `MaterialApp`).
  static FocusEmphasis? emphasisIn(BuildContext context) =>
      Theme.of(context).extension<FocusFloor>()?.emphasis;

  static ButtonStyle _focusStyle(FocusEmphasis emphasis) => ButtonStyle(
    overlayColor: _overlay(emphasis),
    side: WidgetStateProperty.resolveWith(_side(emphasis)),
  );

  /// Null off focus rather than a transparent colour: a null resolution
  /// falls through to whatever the component's own defaults say, so the
  /// floor changes the focused state and nothing else.
  static WidgetStateProperty<Color?> _overlay(FocusEmphasis emphasis) =>
      WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? stroke.withValues(alpha: lift(emphasis))
            : null,
      );

  static BorderSide? Function(Set<WidgetState>) _side(FocusEmphasis emphasis) =>
      (states) => states.contains(WidgetState.focused)
      ? BorderSide(color: stroke, width: strokeWidth(emphasis))
      : null;

  /// [extra] laid over [base], keeping every property [extra] says nothing
  /// about.
  static ButtonStyle _merge(ButtonStyle? base, ButtonStyle extra) =>
      base == null ? extra : extra.merge(base);
}

/// A television draws focus whatever last moved it.
///
/// Flutter decides whether a focus highlight is painted at all from
/// [FocusManager.highlightMode], and on Android that starts at
/// [FocusHighlightMode.touch] -- a phone marks nothing until a keyboard
/// appears, and goes back to marking nothing at the next tap. A television
/// is the other case entirely: there is no pointer on one, focus is the
/// only way around, and the app draws an indicator for it on purpose. So
/// on one the mode is pinned to [FocusHighlightMode.traditional] for as
/// long as the app is up.
///
/// Two things follow, and the second is why this exists at all:
///
/// - Every fill the floor lays on is painted from the first frame rather
///   than from the first press. An [InkResponse] paints no focus highlight
///   in touch mode, so a control that is focused before any key arrives --
///   which on a set-top box is the state the app launches in -- wears
///   nothing.
/// - Nothing that is *not* focused is painted with the focus colour.
///   `DropdownButton` fills the **selected** entry of an open menu with
///   [ThemeData.focusColor] while the mode is touch (it is the one place
///   Flutter reads that colour to mean something other than focus), and
///   the floor has raised it to a near-white 0.28, or 0.44 under Bold, to
///   mean "the remote is here". A television with a touchscreen -- and
///   `DeviceProfile` allows for one -- opened that menu with a tap and got
///   its loudest cue on a row nobody was standing on. Traditional mode
///   takes that branch away: the entry Flutter autofocuses is the selected
///   one, so the same row is filled, and now because it really does hold
///   the remote.
///
/// It is a widget rather than a line in `main` so that it is put back when
/// the app goes away, which is a widget test's business rather than a
/// television's.
class AlwaysShowFocus extends StatefulWidget {
  const AlwaysShowFocus({super.key, required this.child});

  final Widget child;

  @override
  State<AlwaysShowFocus> createState() => _AlwaysShowFocusState();
}

class _AlwaysShowFocusState extends State<AlwaysShowFocus> {
  /// Read as the state is created, which is before anything here writes
  /// over it.
  final FocusHighlightStrategy _was = FocusManager.instance.highlightStrategy;

  @override
  void initState() {
    super.initState();
    // After the frame, not during it. Writing the strategy tells every
    // [InkResponse] in the tree at once, synchronously, and one that is
    // being taken down in the same frame answers by looking up its
    // [MediaQuery] from an element the framework has already deactivated
    // -- which is an assertion in a debug build. Nothing is focused
    // before the first frame is up anyway.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
      }
    });
  }

  @override
  void dispose() {
    // Only where this really did change it: the app never takes this
    // down, so the whole of this is for a widget test's next pump.
    if (FocusManager.instance.highlightStrategy != _was) {
      FocusManager.instance.highlightStrategy = _was;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// What [FocusTheme.apply] left on the theme: the emphasis the floor was
/// derived from.
///
/// It is here so that a screen's test can ask whether the floor is in force
/// where the remote is standing, which is the only thing about a theme that
/// is not visible in the widget tree. Nothing in `lib/` reads it.
@immutable
class FocusFloor extends ThemeExtension<FocusFloor> {
  const FocusFloor(this.emphasis);

  final FocusEmphasis emphasis;

  @override
  FocusFloor copyWith({FocusEmphasis? emphasis}) =>
      FocusFloor(emphasis ?? this.emphasis);

  /// Nothing here is a continuous value, so a half-finished theme change
  /// shows the emphasis it is heading for. The ring's own animations are
  /// the ones a viewer sees.
  @override
  FocusFloor lerp(FocusFloor? other, double t) =>
      t < 0.5 ? this : (other ?? this);

  @override
  bool operator ==(Object other) =>
      other is FocusFloor && other.emphasis == emphasis;

  @override
  int get hashCode => Object.hash(FocusFloor, emphasis);
}
