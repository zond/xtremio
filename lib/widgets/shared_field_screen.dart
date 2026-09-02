import 'package:flutter/material.dart';

import '../core/core.dart';

/// Which screen a shared core field belongs to: the one that dispatched its
/// last `Load`.
///
/// Two screens can read one field at the same time — a genre chip opens
/// Discover, whose posters open a second details screen; a popping route
/// stays in the tree for its transition while the screen beneath is already
/// tappable — so the field is owned by whichever screen dispatched the last
/// `Load` ([claim]), and only the owner unloads it on dispose ([release]): a
/// screen popping off above one that has already taken the field back leaves
/// it alone.
abstract final class SharedFieldOwnership {
  static final Map<CoreField, Object> _owners = {};

  /// [owner] dispatched a `Load` of [field].
  static void claim(CoreField field, Object owner) => _owners[field] = owner;

  /// Unloads [field] through [client] if [owner] still owns it.
  static void release(CoreField field, Object owner, CoreClient? client) {
    if (_owners[field] != owner) return;
    _owners.remove(field);
    client?.dispatch(CoreActions.unload(field));
  }
}

/// A screen rendering one shared core field, parsed as [S], that another
/// screen (typically a second instance of the same one) can load while this
/// one is still on the stack.
///
/// The screen keeps the last state that was its own ([isOwnState]) and
/// renders that while covered; [trackRoute], called from
/// `didChangeDependencies`, subscribes to the route's status through
/// [ModalRoute.of] and, when the screen is current again and the field holds
/// something else, asks for [reloadField] (a route that left the field alone,
/// the player say, costs nothing). Every `Load` goes through [claimField] and
/// dispose through [releaseField], so only the field's owner unloads it.
mixin SharedFieldScreen<T extends StatefulWidget, S> on State<T> {
  CoreField get sharedField;
  CoreClient? get coreClient;

  /// The notifier of [sharedField]; [onFieldChanged] is its listener.
  CoreFieldNotifier? get fieldNotifier;

  S parseField(Map<String, dynamic> json);

  /// Whether [state] is this screen's, rather than another screen's or the
  /// unloaded field.
  bool isOwnState(S state);

  /// Dispatches this screen's `Load` again, with the selection it had.
  void reloadField();

  /// A new own state is in (and rendered).
  void didReceiveOwnState(S state) {}

  /// The field's last state that was this screen's — what is rendered, also
  /// while another screen holds the field.
  S? ownState;
  Map<String, dynamic>? _ownJson;

  /// Whether this screen's route is on top; a covered screen ignores the
  /// field and reloads it when it is current again.
  bool _isCurrent = true;

  /// Call right before dispatching a `Load` of [sharedField].
  void claimField() => SharedFieldOwnership.claim(sharedField, this);

  /// Call from `dispose`: unloads the field if this screen still owns it.
  void releaseField() =>
      SharedFieldOwnership.release(sharedField, this, coreClient);

  /// Call from `didChangeDependencies`, after the field is set up.
  void trackRoute() {
    // `ModalRoute.of` subscribes to the route's status, so this runs again
    // when another route is pushed over this one and when that route pops.
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (isCurrent &&
        !_isCurrent &&
        !identical(fieldNotifier?.value, _ownJson)) {
      reloadField();
    }
    _isCurrent = isCurrent;
  }

  void onFieldChanged() {
    final json = fieldNotifier?.value;
    if (json == null) return;
    final state = parseField(json);
    // Another screen's state (or the field unloaded): keep rendering our own.
    if (!isOwnState(state)) return;
    _ownJson = json;
    ownState = state;
    if (mounted) setState(() {});
    didReceiveOwnState(state);
  }
}
