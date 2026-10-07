import 'package:flutter/material.dart';

import '../core/internet_status.dart';

/// The Settings row for the app's [InternetStatus]: "Connected to the
/// internet", with the flag, country and public address, or "No internet
/// connection". Checked again on a press. Absent while the status is
/// [InternetUnknown], when there is nothing yet to say either way.
class InternetStatusTile extends StatelessWidget {
  const InternetStatusTile({super.key});

  static const String connected = 'Connected to the internet';
  static const String noConnection = 'No internet connection';

  @override
  Widget build(BuildContext context) {
    final check = InternetStatusScope.maybeOf(context);
    if (check == null) return const SizedBox.shrink();
    return switch (check.status) {
      InternetUnknown() => const SizedBox.shrink(),
      InternetOffline() => ListTile(
        key: const Key('internet-status'),
        leading: const Icon(Icons.cloud_off_outlined),
        title: const Text(noConnection),
        trailing: const Icon(Icons.refresh),
        onTap: check.recheck,
      ),
      InternetOnline(:final ip, :final country, :final flag) => ListTile(
        key: const Key('internet-status'),
        leading: flag == null
            ? const Icon(Icons.public)
            : Text(flag, style: const TextStyle(fontSize: 24)),
        title: const Text(connected),
        subtitle: Text(country == null ? ip : '$country · $ip'),
        trailing: const Icon(Icons.refresh),
        onTap: check.recheck,
      ),
    };
  }
}
