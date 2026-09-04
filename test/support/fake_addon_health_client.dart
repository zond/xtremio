import 'package:xtremio/features/addons/addon_health.dart';
import 'package:xtremio/features/addons/addon_health_client.dart';

/// An [AddonHealthClient] over a table held in memory, standing in for the
/// Rust side's counts.
///
/// [forgotten] records every key handed to [forget], which is how a test
/// checks that what crosses is the record's key and never the transport
/// URL it was hashed from.
class FakeAddonHealthClient implements AddonHealthClient {
  FakeAddonHealthClient({
    Map<String, Map<AddonResourceKind, AddonHealthRecord>>? addons,
    this.everyAnswerFailed = false,
    this.failing = false,
  }) : addons = {...?addons};

  /// What is "recorded", keyed by [addonHealthKey].
  final Map<String, Map<AddonResourceKind, AddonHealthRecord>> addons;

  bool everyAnswerFailed;

  /// One that throws from both sides: the screen goes on listing the addons
  /// with nothing said about any of them.
  final bool failing;

  final List<String> forgotten = [];
  int reads = 0;

  @override
  Future<AddonHealthReport> read() async {
    if (failing) throw StateError('no core');
    reads++;
    return AddonHealthReport(
      addons: {
        for (final entry in addons.entries) entry.key: {...entry.value},
      },
      everyAnswerFailed: everyAnswerFailed,
    );
  }

  @override
  Future<bool> forget(String key) async {
    if (failing) throw StateError('no core');
    forgotten.add(key);
    return addons.remove(key) != null;
  }
}
