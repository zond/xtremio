import 'package:flutter/material.dart';

import '../../widgets/placeholder_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderScreen(
    title: 'Library',
    icon: Icons.video_library,
    blurb: 'Your saved and followed titles, synced with your Stremio account.',
  );
}
