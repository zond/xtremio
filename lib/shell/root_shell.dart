import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/focus_emphasis.dart';
import '../features/discover/discover_screen.dart';
import '../features/library/library_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/sharing/sharing_light.dart';
import '../widgets/back_rung.dart';
import '../widgets/focusable_tile.dart';
import 'device_profile.dart';
import 'tv_density.dart';

/// A top-level navigation destination and the screen it shows.
class _Destination {
  const _Destination(
    this.label,
    this.icon,
    this.selectedIcon,
    this.screen, {
    this.barlessOnTv = false,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget screen;

  /// The screen has no app bar on a television, and a band of controls
  /// [TvDensity.topBandHeight] tall across its top instead.
  final bool barlessOnTv;
}

/// Responsive navigation shell: a rail on wide layouts (desktop/tablet) and a
/// bottom bar on narrow ones (phones). A television always gets the rail,
/// whatever its reported width, since a remote has no way to reach a bottom
/// bar that is not part of the focus order the D-pad walks.
///
/// On a TV the rail and the body are separate [FocusTraversalGroup]s, so
/// Tab order treats the rail as one unit. Every tab's body sits in its own
/// [FocusScope], whose directional edge behaviour falls back to the parent
/// scope. Left from the body's first column finds nothing in the body and
/// lands on the rail; right from the rail finds the body's nearest tile.
/// Directional traversal is geometric and ignores the groups, so up and
/// down past the ends of the rail's menu would land on whatever tile lies
/// above or below. The rail swallows those two keys itself, so the menu
/// stops at its ends.
///
/// The tab's scope also lets a tile autofocus when its tab is shown while
/// the rail keeps a focused destination. (Autofocus only applies inside a
/// scope with no focused child of its own.) Each tab has a [FocusMemory],
/// so showing a tab puts focus on the tile it was on when the user left
/// it, or on the tab's first tile the first time.
///
/// A television keeps [TvDensity.overscan] of every edge clear. Sets crop
/// or curve away the outermost few percent of the panel, and a rail label
/// or a poster that falls in that band is simply not there for the viewer.
/// The band reaches the shell as `MediaQuery` padding (`TvMediaQuery`, so
/// that the pushed routes get it too) and the shell keeps out of all of it,
/// rail included, since it is the panel's edges that eat it.
///
/// It also draws the [SharingLight], the status light that says the
/// embedded server is using the connection while nothing is playing. It
/// lives here because this is the one place that can both read the
/// [SharingScope]'s monitor and tell that nobody could be watching anything
/// else: this route is the current one, so no player is over it. That is
/// where the polling is worth doing. On a television the remote reaches it
/// from the rail, and only from the rail (see `_lightNode` and `_onRailKey`
/// on the state below).
///
/// Selecting a destination with a pointer (a touch remote, a mouse) while
/// a tile holds focus is the D-pad's select with the step onto the rail
/// skipped, so the shell takes that step itself: it focuses the chosen
/// destination before switching. Otherwise the leaving tile's node, still
/// focused while its widget is torn down, is parked in the new tab's scope
/// and keeps the tab's tile from autofocusing. When that node is disposed,
/// focus falls on the bare scope, where nothing shows it.
///
/// **Back on Android comes down a ladder.** Android's navigation guidelines
/// expect Back to lead outward one step at a time. Each press takes the first
/// step that applies:
///
/// 1. Whatever the tab has open closes. That is a [BackRung]: Discover's
///    catalog and type, an open filter menu, the microphone while it listens.
/// 2. On a television, the remote moves from the tab's content to its rail
///    destination. From the sharing light it moves to the rail too.
/// 3. Any other tab goes back to the first one, Discover.
///
/// On Discover with nothing open, Back does nothing. Off Android, a Back that
/// reaches the shell does nothing at all. On a desktop it is a stray key or
/// mouse button, and closing the window is how the app is quit.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  /// The safe area the shell sits in on a television; see [RootShell].
  static const Key overscanKey = Key('tv-overscan');

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  /// One focus scope per tab (TV only); see [RootShell].
  late final List<FocusScopeNode> _tabScopes = [
    for (final d in _destinations)
      FocusScopeNode(
        debugLabel: '${d.label} tab',
        directionalTraversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
      ),
  ];

  /// The last focused tile of each tab (TV only); see [RootShell].
  final List<FocusMemoryStore> _tabMemories = [
    for (final _ in _destinations) FocusMemoryStore(),
  ];

  /// Above the rail (TV only), so the shell can reach its destinations'
  /// focus nodes: [NavigationRail] hands out none. Not focusable itself.
  final FocusNode _railNode = FocusNode(
    debugLabel: 'rail',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// The status light's focus node, owned here so the rail can put focus
  /// on it, and **skipped by traversal**. A light in the top right corner
  /// that directional traversal could land on would sit between an up or a
  /// right press and the poster it was meant for. That is the one thing an
  /// overlay on a television must never do. [_onRailKey] reaches it
  /// instead, up from the top of the rail.
  ///
  /// It is a television's node and nothing else's. Off one, [SharingLight]
  /// draws a plain button that takes no node from the shell, so this one is
  /// never attached to the tree at all. Tab does reach the light there, but
  /// through the button's own node. That is why the flag is set
  /// unconditionally and reads as if it were about both. The property is
  /// the one thing standing between a D-pad press and the light, so it is
  /// set where the node is made rather than where the light is drawn. Off a
  /// television it decides nothing.
  final FocusNode _lightNode = FocusNode(
    debugLabel: 'sharing light',
    skipTraversal: true,
  );

  /// Whether the light is drawn *and this node is what the remote would
  /// land on*. The node is in the focus tree exactly then: [SharingLight]
  /// builds nothing at all when nothing is going out, and off a television
  /// it builds a button that ignores this node. So this is false on a phone
  /// however much is going out. That costs nothing, because the only thing
  /// that asks is [_onRailKey], and a rail key is a television's.
  ///
  /// Asking the node rather than the monitor keeps this one question with
  /// one answer. A [FocusNode.requestFocus] on a node with no parent is
  /// also remembered and applied when it *is* next mounted. That would take
  /// the remote to a light that appeared ten minutes later.
  bool get _lightIsUp => _lightNode.parent != null;

  /// Which of the rail's destinations holds focus, or -1 for none (TV
  /// only); see [_onFocusMoved] and [_railIcon].
  int _railFocus = -1;

  /// The tab's own rungs of the Back ladder, asked before the shell takes
  /// a step of its own; see [RootShell].
  final BackRungs _rungs = BackRungs();

  /// The Material indicator pill behind a rail destination's icon, which
  /// is the box the focus ring is drawn on.
  static const Size _indicatorSize = Size(56, 32);

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusMoved);
  }

  /// Focus moved: work out whether it landed on a rail destination, and on
  /// which one.
  ///
  /// There is nothing narrower to listen to. [NavigationRail] hands out no
  /// nodes to attach an `onFocusChange` to. A move from one of its
  /// destinations to the next changes no node the shell owns: [_railNode]
  /// has focus below it throughout, so it is never notified. Off a
  /// television the rail is not under [_railNode] at all, so this settles
  /// on -1 and never calls [setState].
  void _onFocusMoved() {
    final focused = FocusManager.instance.primaryFocus;
    final index = focused == null
        ? -1
        : _railNode.traversalDescendants.toList().indexOf(focused);
    if (index != _railFocus && mounted) setState(() => _railFocus = index);
  }

  static const _destinations = <_Destination>[
    _Destination(
      'Discover',
      Icons.explore_outlined,
      Icons.explore,
      DiscoverScreen(),
      barlessOnTv: true,
    ),
    _Destination(
      'Search',
      Icons.search,
      Icons.search,
      SearchScreen(),
      barlessOnTv: true,
    ),
    _Destination(
      'Library',
      Icons.video_library_outlined,
      Icons.video_library,
      LibraryScreen(),
      barlessOnTv: true,
    ),
    _Destination(
      'Settings',
      Icons.settings_outlined,
      Icons.settings,
      SettingsScreen(),
    ),
  ];

  void _select(int i) {
    for (final memory in _tabMemories) {
      memory.held = false;
    }
    if (DeviceScope.isTv(context)) _railDestination(i)?.requestFocus();
    setState(() => _index = i);
  }

  /// The focus node of the rail's destination [i]: the destinations are the
  /// rail's focusable widgets, in order.
  FocusNode? _railDestination(int i) =>
      _railNode.traversalDescendants.elementAtOrNull(i);

  /// Up from the first destination and down from the last stay where they
  /// are (TV only); see [RootShell]. Every other key passes.
  ///
  /// There is one exception, which is how a remote reaches the status
  /// light: up from the first destination moves focus onto it while it is
  /// lit. That key did nothing before. The rail is reachable from every
  /// tab's body with one left press, and the light is out of the traversal
  /// altogether. So this is the whole of the path to it, and it costs the
  /// walk nothing when the light is not there.
  KeyEventResult _onRailKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus;
    if (focused == null) return KeyEventResult.ignored;
    final destinations = _railNode.traversalDescendants.toList();
    final i = destinations.indexOf(focused);
    if (i < 0) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final atEdge =
        (key == LogicalKeyboardKey.arrowUp && i == 0) ||
        (key == LogicalKeyboardKey.arrowDown && i == destinations.length - 1);
    if (key == LogicalKeyboardKey.arrowUp && i == 0 && _lightIsUp) {
      _lightNode.requestFocus();
      return KeyEventResult.handled;
    }
    return atEdge ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// The remote leaving the light: back to the destination it came from,
  /// which is the rail's first, since that is the only press that reaches
  /// the light at all.
  void _leaveLight() => _railDestination(0)?.requestFocus();

  /// One step down the shell's Back ladder; see [RootShell].
  void _back() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_rungs.anyActive) return;
    if (DeviceScope.isTv(context)) {
      if (_tabScopes[_index].hasFocus) {
        _railDestination(_index)?.requestFocus();
        return;
      }
      if (_lightNode.hasFocus) {
        _leaveLight();
        return;
      }
    }
    if (_index == 0) return;
    _select(0);
    // Back is a step outward, so the remote stays on the rail, where the next
    // Back leaves from. A select on the rail would take it to the tile
    // Discover remembers instead.
    _tabMemories[0].held = true;
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusMoved);
    for (final scope in _tabScopes) {
      scope.dispose();
    }
    _lightNode.dispose();
    _railNode.dispose();
    super.dispose();
  }

  /// A rail destination's icon, wearing the app's own focus ring on a
  /// television.
  ///
  /// The ring cannot be wrapped round a destination the way it is wrapped
  /// round a tile, because the rail hands out no node to watch. That is
  /// the same fact that put [_railNode] above it. So it is drawn where the
  /// shell already knows what is focused: [_railFocus] against [index].
  ///
  /// Only the ring is drawn, not the whole indicator. A destination is
  /// drawn as two pieces, an icon and a label under it, and only the icon
  /// has a box to go round. Dimming that half in [FocusEmphasis.bold] and
  /// leaving the label bright would say less than dimming nothing does.
  /// What bold does reach here is the ring's own width and the theme
  /// floor's fill. The rail's ink takes no overlay of its own, so it falls
  /// through to `ThemeData.focusColor` like every other list row.
  ///
  /// The box is the Material indicator pill's, so the ring lands on the
  /// pill the rail draws under a selected destination rather than hugging
  /// the glyph.
  Widget _railIcon(BuildContext context, int index, IconData icon) => FocusRing(
    focused: index == _railFocus,
    emphasis: FocusHighlight.emphasisOf(context),
    borderRadius: BorderRadius.all(Radius.circular(_indicatorSize.height / 2)),
    child: SizedBox.fromSize(
      size: _indicatorSize,
      child: Center(child: Icon(icon)),
    ),
  );

  /// [content] with the status light over its top right corner.
  ///
  /// The light sits inside the television's overscan band, since the
  /// [SafeArea] that keeps that band clear is put on outside this. It sits
  /// a toolbar's height down from the top, which is the one thing the shell
  /// can decide for every screen at once. A screen's own app bar is where
  /// it is likeliest to have put a button in this corner (the Library's
  /// "Sync now"). Off a television the light is a button itself and takes
  /// whatever press lands on it, so a light over that button would make it
  /// a control nobody can press.
  ///
  /// **Below that band it is over the screen's own content, and this is
  /// what it costs.** The shell cannot know what a screen draws there. The
  /// Library draws its filter row immediately under the app bar, and the
  /// light clips the right-hand end of that row's last chip on a phone
  /// whose row ends a chip at the edge.
  /// So the claim is not that the corner is empty, which no fixed position
  /// over somebody else's screen can promise. It is that **the light never
  /// takes a press meant for something else**: nothing an app bar draws is
  /// touched at all, and no control lower down has its middle under the
  /// light. The middle is where a press is aimed and where `tap` lands.
  /// `test/features/sharing_light_placement_test.dart` measures both on all
  /// four screens: at 1280x720 on a television, and at 360x800 and 320x800
  /// off one (the width most phones have, and the narrowest any does).
  ///
  /// **Whether a chip ends under the light depends on where the row wraps**,
  /// not on how narrow the phone is. The Library's filter row is a `Wrap`. At
  /// 400 wide its line break leaves a chip ending under the light; at 360 and
  /// 320 the break falls elsewhere and no chip does. So the five-screen sweeps
  /// at the two phone widths never meet the case the second rule exists for.
  /// That case is measured on its own, at 400 on the Library alone: the chip
  /// the light clips still takes its tap. A change to that row's chips or their
  /// order moves the break, so the 400 case checks first that it still has
  /// something to measure.
  ///
  /// A television has the easier half of that. The light takes no pointer
  /// there at all: it is reached from the rail and pressed with select. So
  /// what it clips is pixels, and a control under it stays where the D-pad
  /// finds it.
  ///
  /// **A screen with no app bar on a television** (Discover, Search, the
  /// Library) has a band of its own controls across the top instead. The
  /// light sits at that band's right end, centred on it, in the room the
  /// screen keeps clear there ([TvDensity.lightRoom]). A toolbar's height
  /// down would be over its first row of posters.
  Widget _withLight(
    Widget content, {
    required bool isTv,
    bool onBand = false,
  }) => Stack(
    children: [
      content,
      Positioned(
        top: onBand
            ? (TvDensity.topBandHeight - TvDensity.minTarget) / 2
            : kToolbarHeight,
        right: 0,
        child: SharingLight(
          focusNode: _lightNode,
          onLeave: isTv ? _leaveLight : null,
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    // The shell is the root route. A back gesture or key that reaches it pops
    // nothing, so the framework would ask the platform to exit
    // (SystemNavigator.pop). That quits the app on a desktop and finishes the
    // activity on Android, and neither is how this app is left. So the shell
    // never pops, and takes the press down its own ladder instead ([_back]).
    // Routes pushed on top (player, details) still pop back normally.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: BackRungs.scope(rungs: _rungs, child: _buildShell(context)),
    );
  }

  Widget _buildShell(BuildContext context) {
    final isTv = DeviceScope.isTv(context);
    final isWide = isTv || MediaQuery.sizeOf(context).width >= 720;
    final body = _destinations[_index].screen;

    if (isWide) {
      final rail = NavigationRail(
        selectedIndex: _index,
        onDestinationSelected: _select,
        labelType: NavigationRailLabelType.all,
        destinations: [
          for (final (i, d) in _destinations.indexed)
            NavigationRailDestination(
              icon: isTv ? _railIcon(context, i, d.icon) : Icon(d.icon),
              selectedIcon: isTv
                  ? _railIcon(context, i, d.selectedIcon)
                  : Icon(d.selectedIcon),
              label: Text(d.label),
            ),
        ],
      );
      // On a television the band comes down as `MediaQuery` padding from
      // `TvMediaQuery`, and the shell only has to keep out of it: the sides
      // of it round the whole row, and the top and bottom on either side of
      // the divider, so that the line between the rail and the screen runs
      // the full height of the panel rather than stopping at the band as a
      // third edge of a frame. It is a one-pixel rule, so a set that crops
      // it loses nothing.
      Widget clearOfTopAndBottom(Widget side) =>
          isTv ? SafeArea(left: false, right: false, child: side) : side;
      final row = Row(
        children: [
          clearOfTopAndBottom(
            isTv
                ? FocusTraversalGroup(
                    child: Focus(
                      focusNode: _railNode,
                      onKeyEvent: _onRailKey,
                      child: rail,
                    ),
                  )
                : rail,
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: clearOfTopAndBottom(
              _withLight(
                isTv
                    ? FocusTraversalGroup(
                        child: FocusScope(
                          node: _tabScopes[_index],
                          child: FocusMemory(
                            store: _tabMemories[_index],
                            child: body,
                          ),
                        ),
                      )
                    : body,
                isTv: isTv,
                onBand: isTv && _destinations[_index].barlessOnTv,
              ),
            ),
          ),
        ],
      );
      return Scaffold(
        body: isTv
            ? SafeArea(
                key: RootShell.overscanKey,
                top: false,
                bottom: false,
                child: row,
              )
            : row,
      );
    }

    return Scaffold(
      body: _withLight(body, isTv: isTv),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}
