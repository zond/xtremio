import 'package:flutter_test/flutter_test.dart';
import 'package:xtremio/core/core.dart';

import '../support/diagnostics_capture.dart';
import '../support/fake_drive_pairing_service.dart';

/// What the pairing job writes into the log ring.
void main() {
  // A uuid the way the service mints one. The whole of it is what a
  // pairing is collected with, so the whole of it is never in a line.
  const sessionId = 'f81d4fae-7dec-11d0-a765-00a0c91e6bf6';
  const prefix = 'f81d4fae';

  test('a pairing is logged by the first eight characters of its session '
      'id, never the whole id', () async {
    final lines = captureDiagnostics();
    final service = FakeDrivePairingService(answers: [fakeCollected()]);
    final account = await driveAccount(pairingService: service);
    final job = DrivePairingJob(account: account, service: service);

    await job.finish(
      sessionId: sessionId,
      serverAuthCode: 'not-a-code',
      fileIds: ['drive-file-1'],
    );
    expect(job.outcome, DrivePairingJobOutcome.linked);
    expect(
      lines.where((line) => line.contains('pairing:')),
      isNotEmpty,
      reason: 'the job wrote its lines',
    );
    expect(lines.where((line) => line.contains(sessionId)), isEmpty);
    expect(
      lines.where((line) => line.contains(prefix)),
      hasLength(lines.where((line) => line.contains('pairing:')).length),
      reason: 'every pairing line still joins up with the service: $lines',
    );
  });

  test('a pairing left behind is logged the same way, up to giving up on '
      'it', () async {
    final lines = captureDiagnostics();
    final service = FakeDrivePairingService(
      answers: [const DrivePairingUnreachable()],
    );
    final account = await driveAccount(pairingService: service);
    final job = DrivePairingJob(account: account, service: service);

    for (var i = 0; i <= DrivePairingJob.maxTries; i++) {
      await job.resume(sessionId);
    }
    expect(
      lines.where((line) => line.contains('giving up on $prefix')),
      hasLength(1),
      reason: '$lines',
    );
    expect(lines.where((line) => line.contains(sessionId)), isEmpty);
  });
}
