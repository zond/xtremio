import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../src/rust/api/addon_health.dart' as rust;
import 'addon_health.dart';

/// Where the Addons screen gets the record from, and how it drops one.
///
/// An interface so widget tests can hand the screen a table instead of
/// reaching FFI, the way `PrefsClient` and `DownloadsClient` do.
abstract interface class AddonHealthClient {
  /// Every addon's counts as the Rust side holds them *now*, not as the
  /// preferences file last saw them: the file is up to a flush behind, and
  /// a list that says "not used yet" about an addon used a minute ago is
  /// worse than no list.
  Future<AddonHealthReport> read();

  /// Drops everything recorded about one addon, by its [addonHealthKey].
  /// Answers whether there was anything to drop.
  Future<bool> forget(String key);
}

/// [AddonHealthClient] over FFI.
class RustAddonHealthClient implements AddonHealthClient {
  const RustAddonHealthClient();

  @override
  Future<AddonHealthReport> read() async =>
      AddonHealthReport.fromJson(jsonDecode(rust.addonHealthReport()));

  @override
  Future<bool> forget(String key) => rust.addonHealthForget(key: key);
}

/// Hands [AddonHealthClient] down the tree.
///
/// Optional on purpose: with no scope above it the Addons screen shows no
/// verdicts at all rather than empty ones, which is the honest reading of
/// "nothing can tell us how these addons have been answering".
class AddonHealthScope extends InheritedWidget {
  const AddonHealthScope({
    super.key,
    required this.client,
    required super.child,
  });

  final AddonHealthClient client;

  static AddonHealthClient? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AddonHealthScope>()?.client;

  @override
  bool updateShouldNotify(AddonHealthScope oldWidget) =>
      client != oldWidget.client;
}

/// The report the Addons screen is looking at, read once when the screen
/// mounts and again after a record is forgotten.
///
/// A [ChangeNotifier] rather than a poll: the counts change while the
/// viewer is browsing, not while they are staring at this list, and a list
/// whose numbers move under a finger that is about to tap Uninstall is
/// worse than one that is a minute old. A read that fails leaves the last
/// report standing — the record is a convenience, and a screen that cannot
/// say how an addon has been answering still lists the addons.
class AddonHealthNotifier extends ChangeNotifier {
  AddonHealthNotifier(this.client);

  final AddonHealthClient? client;

  /// What was last read, or **null until something has been**: no client, a
  /// read still in flight, a read that failed. Null is not
  /// [AddonHealthReport.empty] — that one says every addon has been asked
  /// nothing, which is a claim, and this says nothing at all.
  AddonHealthReport? get report => _report;
  AddonHealthReport? _report;

  Future<void> load() async {
    final client = this.client;
    if (client == null) return;
    try {
      final report = await client.read();
      if (_disposed) return;
      _report = report;
      notifyListeners();
    } catch (error) {
      if (kDebugMode) debugPrint('addon health unavailable: $error');
    }
  }

  /// Forgets one addon's record and reads the rest back.
  Future<void> forget(String key) async {
    final client = this.client;
    if (client == null) return;
    try {
      await client.forget(key);
    } catch (error) {
      if (kDebugMode) debugPrint('addon health not forgotten: $error');
    }
    await load();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
