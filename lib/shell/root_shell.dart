import 'package:flutter/material.dart';

import '../features/board/board_screen.dart';
import '../features/discover/discover_screen.dart';
import '../features/library/library_screen.dart';
import '../features/settings/settings_screen.dart';

/// A top-level navigation destination and the screen it shows.
class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon, this.screen);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget screen;
}

/// Responsive navigation shell: a rail on wide layouts (desktop/tablet) and a
/// bottom bar on narrow ones (phones).
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const _destinations = <_Destination>[
    _Destination('Board', Icons.home_outlined, Icons.home, BoardScreen()),
    _Destination(
      'Discover',
      Icons.explore_outlined,
      Icons.explore,
      DiscoverScreen(),
    ),
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
  Widget build(BuildContext context) {
    // The shell is the root route. Without this, a back gesture/key that
    // reaches it pops nothing and the framework asks the platform to exit
    // (SystemNavigator.pop), which on desktop quits the app. Quitting must
    // be deliberate (closing the window), so a stray back is a no-op here;
    // routes pushed on top (player, details) still pop back normally.
    return PopScope(canPop: false, child: _buildShell(context));
  }

  Widget _buildShell(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 720;
    final body = _destinations[_index].screen;

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
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
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
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
