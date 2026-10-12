import 'package:flutter/material.dart';

import '../core/internet_status.dart';
import 'explained.dart';

/// The Settings row for the app's [InternetStatus]: "Connected to the
/// internet", with the flag, country and public address, or "No internet
/// connection". Checked again on a press. Absent while the status is
/// [InternetUnknown], when there is nothing yet to say either way.
///
/// The country and address under the title are state, so they stay on the
/// row. What the row is for is its [explanation] ([Explained]).
class InternetStatusTile extends StatelessWidget {
  const InternetStatusTile({super.key});

  static const String connected = 'Connected to the internet';
  static const String noConnection = 'No internet connection';

  static const String explanation =
      'Whether Xtremio reaches the internet. When it does, this shows the '
      'country and address it is seen from. Press the row to check again.';

  @override
  Widget build(BuildContext context) {
    final check = InternetStatusScope.maybeOf(context);
    if (check == null) return const SizedBox.shrink();
    return switch (check.status) {
      InternetUnknown() => const SizedBox.shrink(),
      InternetOffline() => Explained(
        title: noConnection,
        explanation: explanation,
        child: ListTile(
          key: const Key('internet-status'),
          leading: const ExplainIcon(Icon(Icons.cloud_off_outlined)),
          title: const Text(noConnection),
          trailing: const Icon(Icons.refresh),
          onTap: check.recheck,
        ),
      ),
      InternetOnline(:final ip, :final country, :final flag) => Explained(
        title: connected,
        explanation: explanation,
        child: ListTile(
          key: const Key('internet-status'),
          leading: ExplainIcon(
            flag == null
                ? const Icon(Icons.public)
                : Text(flag, style: const TextStyle(fontSize: 24)),
          ),
          title: const Text(connected),
          subtitle: Text(country == null ? ip : '$country · $ip'),
          trailing: const Icon(Icons.refresh),
          onTap: check.recheck,
        ),
      ),
    };
  }
}
