/// How the installed addons have been answering, and the one rule that
/// turns that into something the owner of a profile can act on.
///
/// The Rust side (`rust/src/addon_health.rs`) **counts** and this side
/// **judges**: everything below is pure and takes its `now` as an
/// argument, so the rule can be argued with against a table of cases
/// instead of against a live network, and can be changed without touching
/// what is stored.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../../core/core.dart';

/// A resource kind a record is kept per, so an addon with good streams and
/// a dead catalog reads as exactly that.
///
/// The wire names are stremio-core's own, which is also what a manifest
/// declares in `resources`, so no translation table is needed.
enum AddonResourceKind {
  catalog('catalog', 'catalogs'),
  meta('meta', 'details'),
  stream('stream', 'streams'),
  subtitles('subtitles', 'subtitles');

  const AddonResourceKind(this.wire, this.label);

  /// The name this kind is stored and declared under.
  final String wire;

  /// What the evidence lines call it.
  final String label;

  /// The kind [wire] names, or null for a resource no record is kept for
  /// (`addon_catalog`, and whatever an addon invents).
  static AddonResourceKind? parse(String wire) {
    for (final kind in values) {
      if (kind.wire == wire) return kind;
    }
    return null;
  }

  /// The kinds a manifest's `resources` declare that a record is kept for,
  /// in this enum's order.
  static Set<AddonResourceKind> declaredBy(AddonManifest manifest) => {
    for (final kind in values)
      if (manifest.resourceNames.contains(kind.wire)) kind,
  };
}

/// What one addon has answered for one resource kind.
///
/// Three counts, never two: [empty] is a working addon that had nothing for
/// what was asked, which is not a fault. Folding it into [fail] is how a
/// public-domain catalog with nothing for this year's blockbuster becomes a
/// "broken" addon.
///
/// The counts are decayed floats as of [updated]; [decayedTo] ages them the
/// rest of the way. [lastOk] and [lastFail] ride along because no decayed
/// float can say *when* it last worked.
final class AddonHealthRecord {
  const AddonHealthRecord({
    this.ok = 0,
    this.empty = 0,
    this.fail = 0,
    this.lastOk,
    this.lastFail,
    required this.updated,
  });

  /// Answers that carried content.
  final double ok;

  /// Answers that were valid and empty.
  final double empty;

  /// Requests that did not get an answer.
  final double fail;

  final DateTime? lastOk;
  final DateTime? lastFail;

  /// When the counts were last aged, which is what [decayedTo] measures
  /// from.
  final DateTime updated;

  /// Everything observed for this kind: the `n` the thresholds are read
  /// against.
  double get observations => ok + empty + fail;

  /// The share of answers that carried content, or 0 when nothing has been
  /// observed.
  double get answeredRatio => observations == 0 ? 0 : ok / observations;

  /// The share of requests that did not get an answer, or 0 when nothing
  /// has been observed.
  double get failedRatio => observations == 0 ? 0 : fail / observations;

  /// The record aged to [now]. Idempotent, and a clock that went backwards
  /// ages nothing rather than inflating the counts — the same arithmetic
  /// `decay_factor` does on the Rust side, so the app and the file never
  /// disagree about how much an old count is still worth.
  AddonHealthRecord decayedTo(DateTime now) {
    final elapsed = now.difference(updated);
    if (elapsed <= Duration.zero) return this;
    final days = elapsed.inMicroseconds / Duration.microsecondsPerDay;
    final factor = math.pow(0.5, days / AddonHealth.halfLifeDays).toDouble();
    return AddonHealthRecord(
      ok: ok * factor,
      empty: empty * factor,
      fail: fail * factor,
      lastOk: lastOk,
      lastFail: lastFail,
      updated: now,
    );
  }

  /// One stored record, or null when it is not one this build understands.
  /// A record is derived and disposable, so losing one is cheaper than
  /// refusing to show the rest.
  static AddonHealthRecord? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final updated = _time(json['updated']);
    if (updated == null) return null;
    return AddonHealthRecord(
      ok: _count(json['ok']),
      empty: _count(json['empty']),
      fail: _count(json['fail']),
      lastOk: _time(json['lastOk']),
      lastFail: _time(json['lastFail']),
      updated: updated,
    );
  }

  static double _count(Object? value) =>
      value is num && value.isFinite && value > 0 ? value.toDouble() : 0;

  static DateTime? _time(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}

/// The four things that can be said about an installed addon.
enum AddonHealthVerdict {
  /// Something it is asked for fails at least half the time, and nothing it
  /// was asked has worked in a week.
  broken('Often unreachable'),

  /// Every kind it declares has been asked plenty and almost never had
  /// anything.
  useless('Rarely has anything'),

  /// Too little has been asked of it to say anything at all.
  notEnoughEvidence('Not used yet'),

  /// None of the above.
  useful('Working');

  const AddonHealthVerdict(this.label);

  /// What the chip says.
  final String label;
}

/// Everything known about one addon's answers, plus [verdict].
final class AddonHealth {
  const AddonHealth({required this.declared, required this.records});

  /// Nothing known: an addon that declares nothing a record is kept for,
  /// and has none.
  static const AddonHealth unknown = AddonHealth(declared: {}, records: {});

  /// The kinds this addon's manifest declares that a record is kept for.
  /// The [useless] rule reads against these and not against what happens to
  /// have been observed, so an addon is never called useless for a kind it
  /// never claimed to serve.
  final Set<AddonResourceKind> declared;

  /// What has been observed, per kind. A declared kind that is absent here
  /// has *not been asked yet*, which is emphatically not zero: the pump
  /// only sees what a screen actually requested, so an unscrolled catalog
  /// is never observed at all.
  final Map<AddonResourceKind, AddonHealthRecord> records;

  /// How long a count takes to halve, matching `HALF_LIFE_DAYS` in
  /// `rust/src/addon_health.rs`.
  static const double halfLifeDays = 14;

  /// Below this many observations on every kind, nothing is said. The pump
  /// only sees what was asked, so "not enough evidence" is a first-class
  /// answer and not a placeholder.
  static const int minimumObservations = 5;

  /// The share of requests that must have failed, on some kind that has
  /// been asked [minimumObservations] times, for half of [broken].
  static const double brokenFailureRatio = 0.5;

  /// How long the addon must have gone without a single answer for the
  /// other half of [broken].
  static const Duration brokenSilence = Duration(days: 7);

  /// How often each declared kind must have been asked before [useless] can
  /// be said of it. Four times [minimumObservations]: calling an addon
  /// useless is a suggestion to uninstall it, and wants far more evidence
  /// than calling it unreachable.
  static const int uselessObservations = 20;

  /// The share of answers that must carry content for an addon to escape
  /// [useless]. Five percent is deliberately far below what a catalog
  /// addon manages: a stream specialist that answers one title in twenty is
  /// working exactly as intended, and only something answering almost
  /// nothing across *every* kind it declares is doing nothing for anyone.
  static const double uselessAnswerRatio = 0.05;

  /// Whether anything has been recorded at all.
  bool get isEmpty => records.isEmpty;

  /// When this addon last answered with content, whatever the kind, or null
  /// if it never has. Addon-wide on purpose: it is the "does this thing
  /// work at all" half of [broken], and an addon whose streams worked this
  /// morning is not unreachable because its catalog is dead.
  DateTime? get lastOk {
    DateTime? latest;
    for (final record in records.values) {
      final at = record.lastOk;
      if (at != null && (latest == null || at.isAfter(latest))) latest = at;
    }
    return latest;
  }

  /// The records aged to [now].
  Map<AddonResourceKind, AddonHealthRecord> decayedTo(DateTime now) => {
    for (final entry in records.entries) entry.key: entry.value.decayedTo(now),
  };

  /// The kind most has been asked of, which is what the [useful] chip
  /// summarises. Null when nothing has been observed.
  AddonResourceKind? busiestKind(DateTime now) {
    AddonResourceKind? busiest;
    var most = 0.0;
    for (final entry in decayedTo(now).entries) {
      if (entry.value.observations > most) {
        most = entry.value.observations;
        busiest = entry.key;
      }
    }
    return busiest;
  }

  /// **The rule.** One pure function, four outcomes, evaluated in order.
  ///
  /// - [AddonHealthVerdict.notEnoughEvidence] when no kind has been asked
  ///   [minimumObservations] times. Checked first, because every other
  ///   answer is a claim about an addon and none of them can be made from
  ///   four requests.
  /// - [AddonHealthVerdict.broken] when *some* kind has been asked
  ///   [minimumObservations] times and failed at least
  ///   [brokenFailureRatio] of them, **and** the addon as a whole has not
  ///   answered anything in [brokenSilence]. Both halves are required and
  ///   neither is enough: the ratio alone condemns an addon that is failing
  ///   right now but worked an hour ago (which is the network, not the
  ///   addon), and the silence alone condemns one that is simply rarely
  ///   asked.
  /// - [AddonHealthVerdict.useless] when every kind it *declares* has been
  ///   asked [uselessObservations] times and carried content in fewer than
  ///   [uselessAnswerRatio] of them. Every declared kind, so one live
  ///   resource rescues the addon; and a declared kind nothing has asked
  ///   for yet has an `n` of zero, which fails the threshold and keeps the
  ///   verdict off. An addon that declares no kind a record is kept for
  ///   can never be called useless, rather than being called it vacuously.
  /// - [AddonHealthVerdict.useful] otherwise. It is the default because
  ///   the cost of the two named verdicts is a wrongly uninstalled addon.
  AddonHealthVerdict verdict(DateTime now) {
    final aged = decayedTo(now);
    if (aged.values.every(
      (record) => record.observations < minimumObservations,
    )) {
      return AddonHealthVerdict.notEnoughEvidence;
    }
    final failing = aged.values.any(
      (record) =>
          record.observations >= minimumObservations &&
          record.failedRatio >= brokenFailureRatio,
    );
    final worked = lastOk;
    final silent = worked == null || now.difference(worked) > brokenSilence;
    if (failing && silent) return AddonHealthVerdict.broken;
    if (declared.isNotEmpty &&
        declared.every((kind) {
          final record = aged[kind];
          return record != null &&
              record.observations >= uselessObservations &&
              record.answeredRatio < uselessAnswerRatio;
        })) {
      return AddonHealthVerdict.useless;
    }
    return AddonHealthVerdict.useful;
  }
}

/// Every addon's record as the Rust side holds it, plus whether the
/// connection rather than the addons is the problem.
final class AddonHealthReport {
  const AddonHealthReport({
    required this.addons,
    required this.everyAnswerFailed,
  });

  /// Nothing read yet, and nothing known.
  static const AddonHealthReport empty = AddonHealthReport(
    addons: {},
    everyAnswerFailed: false,
  );

  /// Keyed by [addonHealthKey].
  final Map<String, Map<AddonResourceKind, AddonHealthRecord>> addons;

  /// Whether every answer since the app started has failed — which is a
  /// statement about this device's connection and not about any addon. An
  /// all-failed sweep is recorded against nobody, so it leaves no trace in
  /// the counts and has to be carried separately.
  final bool everyAnswerFailed;

  /// What `addon_health_report` returns.
  static AddonHealthReport fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return empty;
    final addons = <String, Map<AddonResourceKind, AddonHealthRecord>>{};
    final stored = json['addons'];
    if (stored is Map<String, dynamic>) {
      for (final entry in stored.entries) {
        final kinds = entry.value;
        if (kinds is! Map<String, dynamic>) continue;
        final records = <AddonResourceKind, AddonHealthRecord>{};
        for (final kind in kinds.entries) {
          final parsed = AddonResourceKind.parse(kind.key);
          final record = AddonHealthRecord.fromJson(kind.value);
          if (parsed != null && record != null) records[parsed] = record;
        }
        if (records.isNotEmpty) addons[entry.key] = records;
      }
    }
    return AddonHealthReport(
      addons: addons,
      everyAnswerFailed: json['everyAnswerFailed'] == true,
    );
  }

  /// What is known about [addon], or **null for a protected addon**.
  ///
  /// Refusing here rather than in the widget is deliberate: Cinemeta and
  /// the streaming server's local addon cannot be uninstalled, so a verdict
  /// about them is advice nobody can take, and the local addon's answers
  /// are this app's own two stubs rather than anything on the network. The
  /// Rust side already declines to record against them; this is the second
  /// half of the same rule, so a bad release on either side cannot put a
  /// label on one.
  AddonHealth? healthOf(AddonDescriptor addon) {
    if (addon.isProtected) return null;
    return AddonHealth(
      declared: AddonResourceKind.declaredBy(addon.manifest),
      records: addons[addonHealthKey(addon.transportUrl)] ?? const {},
    );
  }
}

/// Default ports the Rust `url` crate leaves out of a serialized URL, and
/// therefore out of a key.
const Map<String, int> _defaultPorts = {
  'http': 80,
  'https': 443,
  'ws': 80,
  'wss': 443,
  'ftp': 21,
};

/// The key one addon's records are held under: `host[:port]#` and the first
/// twelve hex characters of `sha256(transportUrl)`.
///
/// This mirrors `key_for` in `rust/src/addon_health.rs`, and the mirroring
/// is the point: **the transport URL never leaves the profile.** A manifest
/// URL can carry a debrid API key, which `AGENTS.md` puts in the class of
/// things that are never written down or passed on, so the app hashes the
/// URL it already holds rather than handing it across the boundary to be
/// hashed there. The digest still keeps two configurations of one addon
/// apart, because it is taken over the whole URL, query included.
///
/// [transportUrl] is hashed exactly as the profile stores it, byte for
/// byte, and is never re-normalized here: the profile's string is already
/// `Url::as_str()`'s output, so normalizing again could only introduce a
/// difference. One known limit: a non-ASCII host, which the `url` crate
/// punycodes and `Uri` does not, would give a readable half the two sides
/// spell differently — such an addon reads as "not used yet" rather than
/// showing another addon's history.
String addonHealthKey(String transportUrl) {
  final digest = sha256
      .convert(utf8.encode(transportUrl))
      .toString()
      .substring(0, 12);
  final url = Uri.tryParse(transportUrl);
  if (url == null || url.host.isEmpty) return 'unknown#$digest';
  // `host_str` keeps an IPv6 literal's brackets; `Uri.host` drops them.
  final host = url.host.contains(':') ? '[${url.host}]' : url.host;
  final port = url.hasPort && url.port != _defaultPorts[url.scheme]
      ? ':${url.port}'
      : '';
  return '$host$port#$digest';
}
