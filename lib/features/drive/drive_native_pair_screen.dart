import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/core.dart';

/// The phone's half of a pairing, when the phone is running *this app*.
///
/// A television draws `https://<origin>/link?s=<session>` as a QR. A phone
/// without this app opens that in a browser and uses the web page, exactly
/// as before. A phone **with** this app gets the URL handed here instead,
/// because Android verified the app against `assetlinks.json` on a domain
/// this project serves — and this screen does the same job natively.
///
/// **Why bother, when the page already works.** The web Google Picker cannot
/// select more than one file on a phone: it gates selection on a Ctrl/Cmd
/// key, so a device with no keyboard holds exactly one
/// (issuetracker.google.com/issues/334994030, open since April 2024). The
/// native picker can — measured at seven files in one go. That is the whole
/// of the difference, and it is why the page is kept rather than replaced.
///
/// **Nothing is stored on this device.** The phone is not the device that
/// plays anything: it signs in, picks, and hands both halves to the session
/// the television is waiting on. The credential is a one-time code that
/// crosses this screen in a single field and is written down nowhere — not
/// in a log line, not in this state, not on the screen. The television
/// collects the refresh token from the service on its next poll, exactly as
/// it does for a browser pairing; nothing about that side changes.
///
/// **There is no polling here and no session to lose.** The pick either
/// reaches the service or it does not, and the answer is one sentence. A
/// viewer who backs out has spent nothing: the session is still waiting and
/// the television is still showing its code.
class DriveNativePairScreen extends StatefulWidget {
  const DriveNativePairScreen({
    super.key,
    required this.sessionId,
    this.picker = const MethodChannelDriveNativePicker(),
    this.service = const XtremioDrivePairingService(),
  });

  /// The session the television is waiting on, out of the link.
  final String sessionId;

  /// What runs the picker; a widget test hands in a fake rather than
  /// reaching a platform channel.
  final DriveNativePicker picker;

  /// Where the pick is handed over. Injected for the same reason.
  final DrivePairingService service;

  static const String title = 'Choose what to play';
  static const String pickingMessage = 'Opening Google Drive…';
  static const String handingOverMessage = 'Sending it to your television…';
  static const String cancelledMessage = 'Nothing was chosen.';
  static const String goneMessage =
      'That code has expired. Ask your television for a new one.';
  static const String refusedMessage =
      'Google would not confirm that. Try again from your television.';
  static const String unreachableMessage =
      'Could not reach the service. Check your connection and try again.';
  static const String unavailableMessage =
      'This phone cannot open the Google picker. Scan the code with your '
      'camera instead and use the web page.';
  static const String tryAgainLabel = 'Try again';
  static const String doneLabel = 'Done';

  /// What a finished pairing says, right for one file and for twenty.
  static String linkedMessage(int files) => files == 1
      ? 'One file is on its way to your television.'
      : '$files files are on their way to your television.';

  @override
  State<DriveNativePairScreen> createState() => _DriveNativePairScreenState();
}

enum _Stage { picking, handingOver, done, stopped }

class _DriveNativePairScreenState extends State<DriveNativePairScreen> {
  _Stage _stage = _Stage.picking;
  String _said = '';
  int _linked = 0;

  /// Latched, so that a picker answering twice — a resolution and a result,
  /// on a platform that has been known to deliver both — cannot spend the
  /// same one-time code twice.
  bool _handedOver = false;

  @override
  void initState() {
    super.initState();
    // Straight in: the viewer pressed a QR with their camera and is holding
    // the phone, so a screen that asks them to press *another* button first
    // is a step that exists only because it was easy to write.
    unawaited(_run());
  }

  Future<void> _run() async {
    if (_handedOver) return;
    setState(() {
      _stage = _Stage.picking;
      _said = '';
    });
    final picked = await widget.picker.pick();
    if (!mounted) return;
    switch (picked) {
      case DriveNativePickUnavailable():
        return _stop(DriveNativePairScreen.unavailableMessage);
      case DriveNativePickCancelled():
        return _stop(DriveNativePairScreen.cancelledMessage);
      case DriveNativePickFailed(:final reason):
        return _stop(reason);
      case DriveNativePicked(:final serverAuthCode, :final fileIds):
        if (_handedOver) return;
        _handedOver = true;
        setState(() => _stage = _Stage.handingOver);
        // One statement, from the pick into the service. The code is in no
        // field of this state and in no line of the log.
        final handover = await widget.service.handOverNativePick(
          sessionId: widget.sessionId,
          serverAuthCode: serverAuthCode,
          fileIds: fileIds,
        );
        if (!mounted) return;
        switch (handover) {
          case DrivePairingHandover.taken:
            setState(() {
              _stage = _Stage.done;
              _linked = fileIds.length;
            });
          case DrivePairingHandover.gone:
            _stop(DriveNativePairScreen.goneMessage);
          case DrivePairingHandover.refused:
            _stop(DriveNativePairScreen.refusedMessage);
          case DrivePairingHandover.unreachable:
            // The code is spent either way -- it went to Google or it did
            // not, and this side cannot tell -- so "try again" here means a
            // fresh pick, which `_handedOver` allows only because the pick
            // that follows mints a new code.
            _handedOver = false;
            _stop(DriveNativePairScreen.unreachableMessage);
        }
    }
  }

  void _stop(String said) => setState(() {
    _stage = _Stage.stopped;
    _said = said;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text(DriveNativePairScreen.title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              switch (_stage) {
                _Stage.picking => const _Waiting(
                  DriveNativePairScreen.pickingMessage,
                ),
                _Stage.handingOver => const _Waiting(
                  DriveNativePairScreen.handingOverMessage,
                ),
                _Stage.done => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 40,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      DriveNativePairScreen.linkedMessage(_linked),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
                _Stage.stopped => Text(
                  _said,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              },
              const SizedBox(height: 24),
              if (_stage == _Stage.stopped)
                FilledButton(
                  onPressed: () => unawaited(_run()),
                  child: const Text(DriveNativePairScreen.tryAgainLabel),
                ),
              if (_stage == _Stage.done || _stage == _Stage.stopped)
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text(DriveNativePairScreen.doneLabel),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting(this.said);

  final String said;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const CircularProgressIndicator(),
      const SizedBox(height: 16),
      Text(said, textAlign: TextAlign.center),
    ],
  );
}
