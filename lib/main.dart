import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/core.dart';
import 'src/rust/frb_generated.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const XtremioBootstrap());
}

/// Loads the Rust library and boots stremio-core (with the embedded
/// stream-server) before showing the app; shows the failure otherwise.
class XtremioBootstrap extends StatefulWidget {
  const XtremioBootstrap({super.key});

  @override
  State<XtremioBootstrap> createState() => _XtremioBootstrapState();
}

class _XtremioBootstrapState extends State<XtremioBootstrap> {
  late final Future<(CoreClient, CoreInitInfo)> _boot = _bootCore();

  static Future<(CoreClient, CoreInitInfo)> _bootCore() async {
    await RustLib.init();
    final client = RustCoreClient();
    final Directory support = await getApplicationSupportDirectory();
    final Directory cache = await getApplicationCacheDirectory();
    final info = await client.init(support: support, cache: cache);
    return (client, info);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _boot,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _BootFailed(error: snapshot.error!);
        }
        final data = snapshot.data;
        if (data == null) return const _BootSplash();
        return XtremioApp(core: data.$1, initInfo: data.$2);
      },
    );
  }
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ColoredBox(
      color: Color(0xFF0E0B16),
      child: Center(child: CircularProgressIndicator()),
    ),
  );
}

class _BootFailed extends StatelessWidget {
  const _BootFailed({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 64),
              const SizedBox(height: 16),
              const Text('Xtremio could not start its core'),
              const SizedBox(height: 8),
              SelectableText('$error', textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    ),
  );
}
