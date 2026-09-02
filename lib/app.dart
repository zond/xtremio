import 'package:flutter/material.dart';

import 'shell/root_shell.dart';

/// Root of the Xtremio application.
///
/// The UI is a thin layer: discovery/library/addon logic will come from
/// `stremio-core` (Rust, over FFI) and playback bytes from an embedded
/// `stream-server`, with `media_kit`/libmpv doing the actual video.
class XtremioApp extends StatelessWidget {
  const XtremioApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7B5BF5),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'Xtremio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF0E0B16),
      ),
      home: const RootShell(),
    );
  }
}
