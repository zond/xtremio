import 'library.dart';

/// View over the `continue_watching_preview` field: library items with
/// progress (or new episodes), newest first, capped by the engine. Each item
/// is a `LibraryItem` with a `notifications` count flattened in
/// ([LibraryItemView.notifications]).
final class ContinueWatchingState {
  const ContinueWatchingState(this.items);

  final List<LibraryItemView> items;

  factory ContinueWatchingState.fromJson(Map<String, dynamic> json) =>
      ContinueWatchingState(LibraryItemView.listFromJson(json['items']));

  bool get isEmpty => items.isEmpty;
}
