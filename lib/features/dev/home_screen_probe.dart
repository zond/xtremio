import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The developer probe of the Google TV home screen's "Continue watching"
/// row, over the `xtremio/watch_next` channel (`WatchNextChannel.kt`).
///
/// Whether Google TV shows Watch Next entries from an app that did not come
/// from the Play Store is the open question, and only an entry this app
/// inserts can answer it: one inserted from `adb shell` belongs to the
/// shell. So one row inserts a fixed entry and the other takes it out; what
/// the home screen then shows is the answer (docs/ANDROID.md, "Home-screen
/// probe"). It is a probe, not the feature: nothing else writes to the row.
///
/// Android only (the Settings screen asks); a phone answers that it has no
/// TV provider.
class HomeScreenProbeTiles extends StatelessWidget {
  const HomeScreenProbeTiles({
    super.key,
    this.channel = const MethodChannel('xtremio/watch_next'),
  });

  final MethodChannel channel;

  static const String insertTitle = 'Insert a home-screen probe';
  static const String removeTitle = 'Remove the home-screen probe';

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ListTile(
        leading: const Icon(Icons.live_tv_outlined),
        title: const Text(insertTitle),
        subtitle: const Text(
          'Puts one test entry in Continue watching on the TV home screen',
        ),
        onTap: () => _ask(context, 'insertProbe'),
      ),
      ListTile(
        leading: const Icon(Icons.tv_off_outlined),
        title: const Text(removeTitle),
        subtitle: const Text('Takes the test entry out again'),
        onTap: () => _ask(context, 'removeProbe'),
      ),
    ],
  );

  /// The channel answers a sentence either way; only a channel that is not
  /// there or fails outright gets one of ours.
  Future<void> _ask(BuildContext context, String method) async {
    final messenger = ScaffoldMessenger.of(context);
    String answer;
    try {
      answer =
          await channel.invokeMethod<String>(method) ??
          'The probe gave no answer.';
    } on MissingPluginException {
      answer = 'This build has no home-screen probe.';
    } on PlatformException catch (error) {
      answer = 'The probe failed: ${error.code}.';
    }
    messenger.showSnackBar(SnackBar(content: Text(answer)));
  }
}
