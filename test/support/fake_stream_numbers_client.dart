import 'dart:async';

import 'package:xtremio/core/core.dart';

/// [StreamNumbersReader] for widget tests: answers every ask with
/// [response] and records the URLs asked about. No FFI.
class FakeStreamNumbersClient implements StreamNumbersReader {
  /// What the next asks answer. Null plays a server that holds nothing of
  /// the stream -- an addon's direct link, a debrid URL -- which is what
  /// the panel draws no rows for, and so is the default: a test that wants
  /// rows says so.
  StreamNumbers? response;

  /// When set, every ask throws instead of answering: the server not
  /// running, which the panel has to draw exactly like nothing held.
  Object? failure;

  /// Every URL asked about, in order. A test reads it to say that the
  /// numbers on the panel were asked for the stream on screen, and that
  /// nothing was asked while nothing was reading them.
  final List<Uri> requests = [];

  /// When set, `streamNumbers` also appends `'held'` here: a log shared
  /// with the other fakes, for tests about the order of calls across them.
  List<String>? callLog;

  /// Holds every answer until [answer] is called, so a test can draw the
  /// frames the panel shows *while* an ask is out.
  bool holdAnswers = false;

  final List<Completer<StreamNumbers?>> _held = [];

  /// How many asks are out and waiting for [answer].
  int get heldCount => _held.length;

  /// Answers every held ask with what this client would answer now, so a
  /// test can change [response] after the ask went out and still say when
  /// the new numbers land.
  void answer() {
    final held = List.of(_held);
    _held.clear();
    for (final completer in held) {
      completer.complete(response);
    }
  }

  @override
  Future<StreamNumbers?> streamNumbers(Uri url) async {
    requests.add(url);
    callLog?.add('held');
    final failure = this.failure;
    if (failure != null) throw failure;
    if (!holdAnswers) return response;
    final completer = Completer<StreamNumbers?>();
    _held.add(completer);
    return completer.future;
  }
}
