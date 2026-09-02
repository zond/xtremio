import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderScreen(
    title: 'Settings',
    icon: Icons.settings,
    blurb: 'Account, addons, streaming server, and player preferences.',
  );
}
