import 'package:xtremio/core/core.dart';

/// [KeepAwake] for widget tests: records every call, in order, and whether
/// the phone is being kept awake now. No platform channel.
class FakeKeepAwake implements KeepAwake {
  /// `hold` and `release`, in the order the screen called them.
  final List<String> calls = [];

  /// Whether the last call was a hold.
  bool get held => calls.isNotEmpty && calls.last == 'hold';

  @override
  Future<void> hold() async => calls.add('hold');

  @override
  Future<void> release() async => calls.add('release');
}
