import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What sending bytes over the connection this device is on costs the
/// person who pays for it.
///
/// Two values and no "unknown", because every caller would have to decide
/// what an unknown costs anyway and there is only one safe answer: a link
/// nobody can vouch for is billed. So a failure to ask is [metered], and
/// the reasoning lives here rather than in each caller.
enum NetworkCost {
  /// Wi-Fi, ethernet, anything the owner has already paid a flat price
  /// for. Bytes sent over it cost nothing that arrives on a bill.
  unmetered,

  /// Mobile data, a tethered phone, a Wi-Fi the owner has marked metered
  /// -- and every connection we could not get an answer about, which is
  /// the whole reason there are two values and not three.
  metered;

  /// Whether anything optional may be sent over this connection at all.
  bool get isUnmetered => this == NetworkCost.unmetered;

  /// What the platform side puts on the wire ([NetworkCost.parse] reads
  /// it), spelled out here so both halves are looking at one list.
  String get wire => name;

  /// A reading from the platform. Anything that is not the exact spelling
  /// of [unmetered] -- a newer build's third value, a null, a number --
  /// reads as [metered]: an answer we cannot read is not an answer, and
  /// the direction to be wrong in is the one that costs a stranger some
  /// bandwidth rather than the owner money.
  static NetworkCost parse(Object? reading) =>
      reading == NetworkCost.unmetered.wire
      ? NetworkCost.unmetered
      : NetworkCost.metered;
}

/// Where [NetworkCost] readings come from.
///
/// A *stream* and not a call, which is the substantive decision here. The
/// alternative is to ask once, when something wants to know -- when a film
/// ends, say -- and the answer to that question expires the moment the
/// owner walks out of their front door: a phone that was on Wi-Fi when the
/// credits rolled is on mobile data ten minutes later, with the app never
/// touched and nothing to re-ask. That failure is the expensive direction.
/// The other way round is cheap: a policy of "no" carried home from the
/// train costs a stranger some bandwidth until the next reading, and a
/// reading arrives as soon as the network changes.
///
/// Behind an interface so a test can drive the readings by hand.
abstract interface class NetworkCostSource {
  /// What the connection costs now, re-emitted whenever it changes, and
  /// once as soon as it is listened to -- a device whose network never
  /// changes would otherwise never say anything at all, and the first
  /// reading is the one every policy is waiting for.
  ///
  /// It never emits an error: there is nothing a caller could do with one
  /// except assume [NetworkCost.metered], so that is emitted instead.
  Stream<NetworkCost> get costs;
}

/// [NetworkCostSource] over the `xtremio/network` event channel, which
/// `MainActivity` pushes on for exactly as long as this is subscribed to
/// (`NetworkCost.kt`, a `ConnectivityManager` default-network callback).
///
/// Only Android has anything to ask, and every other platform resolves
/// locally without a channel, the way `DeviceProfile.detect` does -- but
/// the answers here are not all the same, because what a platform *is*
/// decides what it can cost:
///
/// - **Android** is asked. It is the one platform this app runs on that
///   has a cellular radio, and it is the one that can answer.
/// - **iOS** is [NetworkCost.metered], flatly. It has the same radio and
///   nobody has written the platform side, so an iOS build shares nothing
///   between sessions. That is the safe direction, and it is a missing
///   half of this feature rather than a decision about iOS.
/// - **The desktops** (and Fuchsia) are [NetworkCost.unmetered]. There is
///   no API here to ask and no radio to worry about; a desktop is on the
///   line the building is on. The case this gets wrong is a laptop
///   tethered to a phone -- and off a television the setting this feeds
///   starts *off*, so nothing shares there until the owner says so.
class ChannelNetworkCost implements NetworkCostSource {
  const ChannelNetworkCost({this.channel = costChannel, this.platform});

  /// Where `MainActivity` pushes the reading from, registering its
  /// `ConnectivityManager.NetworkCallback` for exactly as long as this is
  /// subscribed to.
  static const EventChannel costChannel = EventChannel('xtremio/network');

  final EventChannel channel;

  /// The platform to resolve for; null asks the running one. Tests set it
  /// to walk the cases above without a channel each time.
  final TargetPlatform? platform;

  @override
  Stream<NetworkCost> get costs => switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android => _watched,
    TargetPlatform.iOS => Stream.value(NetworkCost.metered),
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => Stream.value(NetworkCost.unmetered),
  };

  /// The channel's readings, opening on [NetworkCost.metered] and
  /// corrected by the platform's own first reading, which arrives in the
  /// same breath (`MainActivity` pushes one as it registers).
  ///
  /// **The opening value is not a formality.** A `listen` that no platform
  /// side answers does not fail this stream: Flutter hands that exception
  /// to the error reporter and leaves the stream silent for ever, so a
  /// consumer waiting for its first reading would wait for ever with the
  /// server left on whatever it defaults to -- which is sharing. Until the
  /// platform has said something we do not know what the link costs, and
  /// not knowing is the expensive case. What it costs is one settings
  /// write at launch, made before anything could be sharing anyway.
  ///
  /// An error *event* -- a `PlatformException` the platform side pushed --
  /// is a different failure, and is turned into a reading here rather than
  /// passed on: there is nothing a consumer could do with one but assume
  /// the same thing.
  Stream<NetworkCost> get _watched async* {
    yield NetworkCost.metered;
    yield* channel.receiveBroadcastStream().cast<Object?>().transform(
      StreamTransformer<Object?, NetworkCost>.fromHandlers(
        handleData: (reading, sink) => sink.add(NetworkCost.parse(reading)),
        handleError: (error, stack, sink) {
          if (kDebugMode) debugPrint('network cost unavailable: $error');
          sink.add(NetworkCost.metered);
        },
      ),
    );
  }
}
