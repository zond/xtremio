import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

class BoardScreen extends StatelessWidget {
  const BoardScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderScreen(
    title: 'Board',
    icon: Icons.home,
    blurb: 'Continue watching and your addon catalogs will appear here.',
  );
}
