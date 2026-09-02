import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'core/core.dart';
import 'shell/root_shell.dart';

/// Root of the Xtremio application.
///
/// The UI is a thin layer: discovery/library/addon logic comes from
/// `stremio-core` (Rust, over FFI, reached through [core]) and playback
/// bytes from an embedded `stream-server`, with `media_kit`/libmpv doing the
/// actual video.
class XtremioApp extends StatefulWidget {
  const XtremioApp({super.key, required this.core, this.initInfo});

  final CoreClient core;
  final CoreInitInfo? initInfo;

  @override
  State<XtremioApp> createState() => _XtremioAppState();
}

class _XtremioAppState extends State<XtremioApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
  }

  Future<AppExitResponse> _onExitRequested() async {
    // Stop the engine and the embedded server before the process goes away
    // so library progress is flushed and the port is released.
    try {
      await widget.core.shutdown();
    } catch (_) {
      // Exiting anyway; nothing useful to do with the failure here.
    }
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7B5BF5),
      brightness: Brightness.dark,
    );

    return CoreScope(
      client: widget.core,
      initInfo: widget.initInfo,
      child: MaterialApp(
        title: 'Xtremio',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: colorScheme,
          scaffoldBackgroundColor: const Color(0xFF0E0B16),
        ),
        home: const RootShell(),
      ),
    );
  }
}
