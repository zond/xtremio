import 'package:flutter/material.dart';

import '../features/board/board_screen.dart';
import '../features/discover/discover_screen.dart';
import '../features/library/library_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../widgets/focusable_tile.dart';
import 'device_profile.dart';

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
/// tile. The scope also lets a tile autofocus when its tab is shown while
/// the rail keeps a focused destination (autofocus only applies inside a
/// scope with no focused child of its own): each tab has a [FocusMemory],
/// so showing a tab puts focus on the tile it was on when the user left
/// it, or on the tab's first tile the first time.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

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

  void _select(int i) => setState(() => _index = i);

  @override
  void dispose() {
    for (final scope in _tabScopes) {
      scope.dispose();
    }
    super.dispose();
  }

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
          for (final d in _destinations)
            NavigationRailDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: Text(d.label),
            ),
        ],
      );
      return Scaffold(
        body: Row(
          children: [
            if (isTv) FocusTraversalGroup(child: rail) else rail,
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
        ),
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
