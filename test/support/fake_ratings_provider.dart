import 'dart:async';

import 'package:xtremio/core/core.dart';
import 'package:xtremio/features/ratings/xtremio_ratings.dart';

/// A provider that answers what a test tells it to, and counts asks.
class FakeRatingsProvider implements RatingsProvider {
  FakeRatingsProvider(this.answer);

  /// The next answer: [TitleRatings], a [Completer] the test finishes, or
  /// an exception to throw.
  Object answer;

  final List<String> asked = [];

  @override
  Future<TitleRatings> ratings({
    required String type,
    required String id,
  }) async {
    asked.add('$type/$id');
    final answer = this.answer;
    if (answer is TitleRatings) return answer;
    if (answer is Completer<TitleRatings>) return answer.future;
    throw answer;
  }
}
