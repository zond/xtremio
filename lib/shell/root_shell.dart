import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/focus_emphasis.dart';
import '../features/board/board_screen.dart';
import '../features/discover/discover_screen.dart';
import '../features/library/library_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../widgets/focusable_tile.dart';
import 'device_profile.dart';
import 'tv_density.dart';

/// A top-level navigation destination and the screen it shows.
class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon, this.screen);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget screen;
}

/// Responsive navigation shell: a rail on wide layouts (desktop/tablet) and a
/// bottom bar on narrow ones (phones). A television always gets the rail,
/// whatever its reported width, since a remote has no way to reach a bottom
/// bar that is not part of the focus order the D-pad walks.
///
/// On a TV the rail and the body are separate [FocusTraversalGroup]s, so
/// Tab order treats the rail as one unit, and every tab's body sits in its
/// own [FocusScope] whose directional edge behaviour falls back to the
/// parent scope: left from the body's first column finds nothing in the
/// body and lands on the rail; right from the rail finds the body's nearest
/// tile. Directional traversal is geometric and ignores the groups, so up
/// and down past the ends of the rail's menu would land on whatever tile
/// lies above or below; the rail swallows those two keys itself, so the
/// menu stops at its ends.
///
/// The tab's scope also lets a tile autofocus when its tab is shown while
/// the rail keeps a focused destination (autofocus only applies inside a
/// scope with no focused child of its own): each tab has a [FocusMemory],
/// so showing a tab puts focus on the tile it was on when the user left
/// it, or on the tab's first tile the first time.
///
/// A television keeps [TvDensity.overscan] of every edge clear: sets crop
/// or curve away the outermost few percent of the panel, and a rail label
/// or a poster that falls in that band is simply not there for the viewer.
/// The band reaches the shell as `MediaQuery` padding (`TvMediaQuery`, so
/// that the pushed routes get it too) and the shell keeps out of all of it,
/// rail included, since it is the panel's edges that eat it.
///
/// Selecting a destination with a pointer (a touch remote, a mouse) while
/// a tile holds focus is the D-pad's select with the step onto the rail
/// skipped, so the shell takes that step itself: it focuses the chosen
/// destination before switching. Otherwise the leaving tile's node, still
/// focused while its widget is torn down, is parked in the new tab's scope
/// and keeps the tab's tile from autofocusing; and when it is disposed
/// focus falls on the bare scope, where nothing shows it.
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

  /// Which of the rail's destinations holds focus, or -1 for none (TV
  /// only); see [_onFocusMoved] and [_railIcon].
  int _railFocus = -1;

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
  /// nodes to attach an `onFocusChange` to, and a move from one of its
  /// destinations to the next changes no node the shell owns -- [_railNode]
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
    _Destination('Board', Icons.home_outlined, Icons.home, BoardScreen()),
    _Destination(
      'Discover',
      Icons.explore_outlined,
      Icons.explore,
      DiscoverScreen(),
    ),
    _Destination('Search', Icons.search, Icons.search, SearchScreen()),
    _Destination(
      'Library',
      Icons.video_library_outlined,
      Icons.video_library,
      LibraryScreen(),
    ),
    _Destination(
      'Settings',
      Icons.settings_outlined,
      Icons.settings,
      SettingsScreen(),
    ),
  ];

  void _select(int i) {
    if (DeviceScope.isTv(context)) _railDestination(i)?.requestFocus();
    setState(() => _index = i);
  }

  /// The focus node of the rail's destination [i]: the destinations are the
  /// rail's focusable widgets, in order.
  FocusNode? _railDestination(int i) =>
      _railNode.traversalDescendants.elementAtOrNull(i);

  /// Up from the first destination and down from the last stay where they
  /// are (TV only); see [RootShell]. Every other key passes.
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
    return atEdge ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusMoved);
    for (final scope in _tabScopes) {
      scope.dispose();
    }
    _railNode.dispose();
    super.dispose();
  }

  /// A rail destination's icon, wearing the app's own focus ring on a
  /// television.
  ///
  /// The ring cannot be wrapped round a destination the way it is wrapped
  /// round a tile, because the rail hands out no node to watch -- which is
  /// the same fact that put [_railNode] above it. So it is drawn where the
  /// shell already knows what is focused: [_railFocus] against [index].
  ///
  /// The ring, and not the whole indicator. A destination is drawn as two
  /// pieces, an icon and a label under it, and only the icon has a box to
  /// go round; dimming that half in [FocusEmphasis.bold] and leaving the
  /// label bright would say less than dimming nothing does. What bold does
  /// reach here is the ring's own width, and the theme floor's fill -- the
  /// rail's ink takes no overlay of its own and so falls through to
  /// `ThemeData.focusColor` like every other list row.
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

  @override
  Widget build(BuildContext context) {
    // The shell is the root route. Without this, a back gesture/key that
    // reaches it pops nothing and the framework asks the platform to exit
    // (SystemNavigator.pop), which on desktop quits the app. Quitting must
    // be deliberate (closing the window), so a stray back is a no-op here;
    // routes pushed on top (player, details) still pop back normally.
    return PopScope(canPop: false, child: _buildShell(context));
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
      final row = Row(
        children: [
          if (isTv)
            FocusTraversalGroup(
              child: Focus(
                focusNode: _railNode,
                onKeyEvent: _onRailKey,
                child: rail,
              ),
            )
          else
            rail,
          const VerticalDivider(width: 1),
          Expanded(
            child: isTv
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
          ),
        ],
      );
      return Scaffold(
        // The band itself comes down as `MediaQuery` padding from
        // `TvMediaQuery`, so the shell only has to keep out of it.
        body: isTv ? SafeArea(key: RootShell.overscanKey, child: row) : row,
      );
    }

    return Scaffold(
      body: body,
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
