import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderScreen(
    title: 'Discover',
    icon: Icons.explore,
    blurb: 'Browse and filter catalogs from your installed addons.',
  );
}
