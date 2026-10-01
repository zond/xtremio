import 'dart:async';
import 'dart:convert';
import 'dart:ui' show CheckedState, SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/diagnostics_log.dart';
import '../../features/details/meta_details_screen.dart';
import '../../features/diagnostics/diagnostics_report.dart' show redactSecrets;
import '../../features/player/player_screen.dart' show PlayerProbe;
import '../../src/rust/api/diagnostics.dart' as rust;

/// Builds the page `go details` pushes: the details screen the app's own
/// lists push, unless a test hands in something lighter.
typedef DetailsPageBuilder = Widget Function(
  String type,
  String id,
  String? videoId,
);

/// The commands an agent sends a running app through Flutter driver's
/// `requestData` (`tool/drive`, docs/DRIVING.md).
///
/// Every message is a JSON object with a `cmd` and the command's own
/// fields; every answer is a JSON object, `{"error": ...}` when the command
/// could not be done. It reads what is on screen from the semantics tree
/// -- what a screen reader is told, so the same labels a viewer reads -- and
/// acts through the semantics owner and the app's own navigator, never by
/// coordinates.
///
/// Only `lib/main_driver.dart` reaches this. Nothing in the app imports it,
/// so a build of `lib/main.dart` does not carry it.
class AppDriver {
  AppDriver({
    Future<void> Function()? settle,
    DetailsPageBuilder? details,
    List<String> Function()? logLines,
  }) : _settle = settle ?? settleFrames,
       _details = details ?? _metaDetails,
       _logLines = logLines ?? _coreLogLines;

  final Future<void> Function() _settle;
  final DetailsPageBuilder _details;
  final List<String> Function() _logLines;

  /// Kept for the life of the driver: the semantics tree is built only
  /// while somebody holds one of these.
  SemanticsHandle? _semantics;

  /// Turns semantics on. Called once at start-up; a command calls it too,
  /// so a handler built after the fact still sees a tree.
  void ensureSemantics() {
    _semantics ??= SemanticsBinding.instance.ensureSemantics();
  }

  void dispose() {
    _semantics?.dispose();
    _semantics = null;
  }

  /// The `DataHandler` handed to `enableFlutterDriverExtension`.
  Future<String> handle(String? message) async {
    try {
      final decoded = jsonDecode(message ?? '{}');
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('a command is a JSON object');
      }
      return jsonEncode(await command(decoded));
    } catch (error) {
      return jsonEncode({'error': '$error'});
    }
  }

  /// One command, decoded.
  Future<Map<String, Object?>> command(Map<String, dynamic> message) async {
    ensureSemantics();
    final cmd = message['cmd'];
    switch (cmd) {
      case 'screen':
        return screen();
      case 'act':
        return act(_int(message['id']), '${message['action']}', message['arg']);
      case 'find':
        return {
          'nodes': find(_strings(message['text']), _strings(message['not'])),
        };
      case 'tap':
        return tap(_strings(message['text']), _strings(message['not']));
      case 'wait':
        return wait(
          _strings(message['text']),
          _strings(message['not']),
          Duration(seconds: message['timeout'] as int? ?? 20),
        );
      case 'go':
        return go(_strings(message['args']));
      case 'player':
        return player();
      case 'seek':
        return seek('${message['to']}');
      case 'log':
        return log(message['n'] as int? ?? 50);
      default:
        throw FormatException('unknown command: $cmd');
    }
  }

  // ---------------------------------------------------------------- screen

  /// The routes on the navigator's stack, the shell's tab, and every
  /// semantics node worth naming, grouped under the header above it.
  Map<String, Object?> screen() {
    final nodes = _nodes();
    final sections = <Map<String, Object?>>[];
    Map<String, Object?>? current;
    for (final node in nodes) {
      final roles = node['roles']! as List<String>;
      if (current == null || roles.contains('header')) {
        current = {
          'header': roles.contains('header') ? node['label'] : null,
          'nodes': <Map<String, Object?>>[],
        };
        sections.add(current);
      }
      (current['nodes']! as List<Map<String, Object?>>).add(node);
    }
    return {'routes': routes(), 'tab': _tab(), 'sections': sections};
  }

  /// Every node in traversal order that has something to say or to do:
  /// a label, value or hint, a role, or an action. Nodes merged into a
  /// parent are left out (the parent carries their text) and so are nodes
  /// with no area.
  List<Map<String, Object?>> _nodes() {
    final out = <Map<String, Object?>>[];
    for (final owner in _owners()) {
      final root = owner.rootSemanticsNode;
      if (root == null) continue;
      final ratio = _ratioFor(owner);
      void visit(SemanticsNode node, Matrix4 transform) {
        final Matrix4 here = node.transform == null
            ? transform
            : (transform.clone()..multiply(node.transform!));
        if (!node.isMergedIntoParent && !node.isInvisible) {
          final described = _describe(node, here, ratio);
          if (described != null) out.add(described);
        }
        // A node that merges its descendants speaks for them.
        if (node.mergeAllDescendantsIntoThisNode) return;
        for (final child in node.debugListChildrenInOrder(
          DebugSemanticsDumpOrder.traversalOrder,
        )) {
          visit(child, here);
        }
      }

      visit(root, Matrix4.identity());
    }
    return out;
  }

  Map<String, Object?>? _describe(
    SemanticsNode node,
    Matrix4 transform,
    double ratio,
  ) {
    final data = node.getSemanticsData();
    final roles = _roles(data);
    final actions = [
      for (final action in SemanticsAction.values)
        if (data.hasAction(action) && !_quietActions.contains(action))
          action.name,
    ];
    final label = data.label.trim();
    final value = data.value.trim();
    final hint = data.hint.trim();
    if (label.isEmpty &&
        value.isEmpty &&
        hint.isEmpty &&
        actions.isEmpty &&
        roles.every(_structuralRoles.contains)) {
      return null;
    }
    final rect = MatrixUtils.transformRect(transform, node.rect);
    return {
      'id': node.id,
      'label': label,
      if (value.isNotEmpty) 'value': value,
      if (hint.isNotEmpty) 'hint': hint,
      if (data.tooltip.isNotEmpty) 'tooltip': data.tooltip,
      'roles': roles,
      'actions': actions,
      'rect': [
        for (final v in [rect.left, rect.top, rect.width, rect.height])
          (v / ratio).round(),
      ],
    };
  }

  /// Actions every focusable node carries and nobody drives by hand.
  static const _quietActions = {
    SemanticsAction.didGainAccessibilityFocus,
    SemanticsAction.didLoseAccessibilityFocus,
  };

  /// Roles that alone do not make a node worth listing.
  static const _structuralRoles = {'scopesRoute', 'namesRoute', 'hidden'};

  static List<String> _roles(SemanticsData data) {
    final f = data.flagsCollection;
    return [
      if (f.isButton) 'button',
      if (f.isHeader) 'header',
      if (f.isTextField) 'textField',
      if (f.isLink) 'link',
      if (f.isImage) 'image',
      if (f.isSlider) 'slider',
      if (f.isObscured) 'obscured',
      if (f.isHidden) 'hidden',
      if (f.scopesRoute) 'scopesRoute',
      if (f.namesRoute) 'namesRoute',
      if (f.isToggled != Tristate.none)
        f.isToggled == Tristate.isTrue ? 'toggled:on' : 'toggled:off',
      if (f.isChecked != CheckedState.none)
        'checked:${f.isChecked == CheckedState.isTrue ? 'on' : 'off'}',
      if (f.isSelected == Tristate.isTrue) 'selected',
      if (f.isExpanded != Tristate.none)
        f.isExpanded == Tristate.isTrue ? 'expanded' : 'collapsed',
      if (f.isFocused == Tristate.isTrue) 'focused',
      if (f.isEnabled == Tristate.isFalse) 'disabled',
    ];
  }

  static Iterable<SemanticsOwner> _owners() sync* {
    for (final view in RendererBinding.instance.renderViews) {
      final owner = view.owner?.semanticsOwner;
      if (owner != null) yield owner;
    }
  }

  /// Device pixels per logical pixel for the view [owner] belongs to: the
  /// root node's rect is in device pixels, and a rect an agent reads is
  /// easier in the logical ones the layout is written in.
  static double _ratioFor(SemanticsOwner owner) {
    for (final view in RendererBinding.instance.renderViews) {
      if (view.owner?.semanticsOwner == owner) {
        return view.flutterView.devicePixelRatio;
      }
    }
    return 1;
  }

  // ------------------------------------------------------------------- act

  /// Performs [actionName] on node [id] through its semantics owner, waits
  /// for the screen to settle and answers the new [screen].
  Future<Map<String, Object?>> act(
    int id,
    String actionName,
    Object? arg,
  ) async {
    final action = SemanticsAction.values.firstWhere(
      (a) => a.name == actionName,
      orElse: () => throw FormatException('unknown action: $actionName'),
    );
    for (final owner in _owners()) {
      final node = owner.getSemanticsNode(id);
      if (node == null) continue;
      final data = node.getSemanticsData();
      if (!data.hasAction(action)) {
        throw StateError(
          'node $id (${data.label.trim()}) does not support $actionName; it '
          'supports ${[for (final a in SemanticsAction.values)
            if (data.hasAction(a)) a.name].join(', ')}',
        );
      }
      owner.performAction(id, action, arg);
      await _settle();
      return {'acted': id, 'action': actionName, ...screen()};
    }
    throw StateError('no semantics node $id on screen');
  }

  // ------------------------------------------------------------------ find

  /// Nodes whose label, value or hint holds every one of [all] and none
  /// of [none], ignoring case.
  List<Map<String, Object?>> find(List<String> all, List<String> none) {
    final wanted = [for (final t in all) t.toLowerCase()];
    final unwanted = [for (final t in none) t.toLowerCase()];
    return [
      for (final node in _nodes())
        if (_matches(node, wanted, unwanted)) node,
    ];
  }

  static bool _matches(
    Map<String, Object?> node,
    List<String> wanted,
    List<String> unwanted,
  ) {
    final text = [
      node['label'],
      node['value'],
      node['hint'],
      node['tooltip'],
    ].whereType<String>().join('\n').toLowerCase();
    return wanted.every(text.contains) && !unwanted.any(text.contains);
  }

  /// [find], then a tap on the first match that takes one.
  Future<Map<String, Object?>> tap(List<String> all, List<String> none) async {
    final matches = find(all, none);
    final tappable = [
      for (final node in matches)
        if ((node['actions']! as List).contains('tap')) node,
    ];
    if (tappable.isEmpty) {
      throw StateError(
        matches.isEmpty
            ? 'nothing on screen matches $all${none.isEmpty ? '' : ' without $none'}'
            : '${matches.length} nodes match but none takes a tap: '
                  '${matches.map((n) => n['id']).join(', ')}',
      );
    }
    final chosen = tappable.first;
    final result = await act(chosen['id']! as int, 'tap', null);
    return {'tapped': chosen['label'], 'matches': tappable.length, ...result};
  }

  /// Polls [find] until it answers something or [timeout] passes.
  Future<Map<String, Object?>> wait(
    List<String> all,
    List<String> none,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final nodes = find(all, none);
      if (nodes.isNotEmpty) return {'nodes': nodes};
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('nothing matched $all', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _settle();
    }
  }

  // -------------------------------------------------------------------- go

  /// Navigates with the app's own navigator and shell.
  Future<Map<String, Object?>> go(List<String> args) async {
    if (args.isEmpty) throw const FormatException('go where?');
    final where = args.first.toLowerCase();
    final navigator = _navigator();
    switch (where) {
      case 'back':
        // What Android's back button does: the app's own ladder, PopScope
        // and all.
        await _systemBack();
      case 'details':
        if (args.length < 3) {
          throw const FormatException('go details <type> <id> [videoId]');
        }
        final page = _details(
          args[1],
          args[2],
          args.length > 3 ? args[3] : null,
        );
        unawaited(
          navigator.push(MaterialPageRoute<void>(builder: (_) => page)),
        );
      default:
        final select = _tabSelector(where);
        navigator.popUntil((route) => route.isFirst);
        select();
    }
    await _settle();
    return screen();
  }

  /// Android's back button: the binding's own handler for the engine's
  /// `popRoute` message, so the app's PopScopes and back ladder decide.
  /// Protected and meant for tests, which is what a driver is; pushing the
  /// platform message through the channel buffers instead does the same on
  /// a device and never arrives under the test binding.
  static Future<void> _systemBack() =>
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      WidgetsBinding.instance.handlePopRoute();

  static Widget _metaDetails(String type, String id, String? videoId) =>
      MetaDetailsScreen(type: type, id: id, videoId: videoId);

  /// The app's one navigator: the key on the `MaterialApp` that carries
  /// one (the boot splash's has none).
  static NavigatorState _navigator() {
    NavigatorState? found;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is MaterialApp && widget.navigatorKey?.currentState != null) {
        found = widget.navigatorKey!.currentState;
        return;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    final navigator = found;
    if (navigator == null) throw StateError('the app has no navigator yet');
    return navigator;
  }

  /// The shell's destinations, by label: whichever of the bottom bar and
  /// the rail is built.
  static List<(String, ValueChanged<int>?)> _shellDestinations() {
    final out = <(String, ValueChanged<int>?)>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is NavigationBar) {
        for (final d in widget.destinations) {
          out.add((
            d is NavigationDestination ? d.label : '',
            widget.onDestinationSelected,
          ));
        }
        return;
      }
      if (widget is NavigationRail) {
        for (final d in widget.destinations) {
          final label = d.label;
          out.add((
            label is Text ? label.data ?? '' : '',
            widget.onDestinationSelected,
          ));
        }
        return;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return out;
  }

  static VoidCallback _tabSelector(String name) {
    final destinations = _shellDestinations();
    final index = destinations.indexWhere((d) => d.$1.toLowerCase() == name);
    if (index < 0) {
      throw FormatException(
        'no destination "$name"; the shell has '
        '${destinations.map((d) => d.$1).join(', ')}, and go also takes '
        'details and back',
      );
    }
    final select = destinations[index].$2;
    if (select == null) throw StateError('"$name" cannot be selected');
    return () => select(index);
  }

  /// The selected destination of the shell, if one is built.
  static String? _tab() {
    String? tab;
    void visit(Element element) {
      if (tab != null) return;
      final widget = element.widget;
      if (widget is NavigationBar) {
        final d = widget.destinations[widget.selectedIndex];
        tab = d is NavigationDestination ? d.label : null;
        return;
      }
      if (widget is NavigationRail) {
        final i = widget.selectedIndex;
        final label = i == null ? null : widget.destinations[i].label;
        tab = label is Text ? label.data : null;
        return;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return tab;
  }

  /// The routes the navigators hold, bottom first: each route's name (the
  /// app names the player and a few others), its type, the screen widget
  /// it shows, and whether it is the top one.
  static List<Map<String, Object?>> routes() {
    final out = <Map<String, Object?>>[];
    void visit(Element element) {
      // `_ModalScopeStatus` is the inherited widget every ModalRoute puts
      // above its page; it is private, so it is known by name.
      if (element.widget.runtimeType.toString() == '_ModalScopeStatus') {
        ModalRoute<dynamic>? route;
        element.visitChildren((child) => route ??= ModalRoute.of(child));
        final found = route;
        if (found != null) {
          out.add({
            'name': found.settings.name,
            'type': '${found.runtimeType}',
            'page': _pageName(element),
            'current': found.isCurrent,
          });
        }
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return out;
  }

  /// The first widget under [scope] whose type names a screen.
  static String? _pageName(Element scope) {
    String? name;
    void visit(Element element) {
      if (name != null) return;
      final type = '${element.widget.runtimeType}';
      if (type.endsWith('Screen') || type.endsWith('Shell')) {
        name = type;
        return;
      }
      element.visitChildren(visit);
    }

    scope.visitChildren(visit);
    return name;
  }

  // ---------------------------------------------------------------- player

  /// What every player screen up says about its playback ([PlayerProbe]).
  static Map<String, Object?> player() {
    final players = <Map<String, Object?>>[];
    void visit(Element element) {
      if (element is StatefulElement && element.state is PlayerProbe) {
        players.add((element.state as PlayerProbe).probe());
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return {'players': players};
  }

  /// Seeks the one player screen up to [to]: `h:mm:ss`, `m:ss`, plain
  /// seconds, or a percentage of the duration (`60%`). Answers [player]
  /// as it stands right after, so a script polls for where it lands.
  Map<String, Object?> seek(String to) {
    final probes = <PlayerProbe>[];
    void visit(Element element) {
      if (element is StatefulElement && element.state is PlayerProbe) {
        probes.add(element.state as PlayerProbe);
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    if (probes.length != 1) {
      throw StateError('${probes.length} player screens are up, not one');
    }
    final probe = probes.single;
    final Duration target;
    if (to.endsWith('%')) {
      final percent = double.parse(to.substring(0, to.length - 1));
      final durationMs = probe.probe()['durationMs']! as int;
      if (durationMs <= 0) throw StateError('no duration known yet');
      target = Duration(milliseconds: (durationMs * percent / 100).round());
    } else {
      var seconds = 0;
      for (final part in to.split(':')) {
        seconds = seconds * 60 + int.parse(part);
      }
      target = Duration(seconds: seconds);
    }
    probe.seekTo(target);
    return {'seekedTo': target.inMilliseconds, ...player()};
  }

  // ------------------------------------------------------------------- log

  /// The last [n] lines of the diagnostics ring, scrubbed the way a copied
  /// report is unless Verbose logging is on.
  Map<String, Object?> log(int n) {
    final lines = _logLines();
    final tail = lines.length <= n ? lines : lines.sublist(lines.length - n);
    return {
      'lines': [
        for (final line in tail)
          DiagnosticsLog.unredacted ? line : redactSecrets(line),
      ],
    };
  }

  static List<String> _coreLogLines() => rust.diagnosticsSnapshot().logLines;

  // --------------------------------------------------------------- helpers

  /// Waits until no frame is scheduled for a few polls in a row, or three
  /// seconds pass: an animation that never ends (a spinner) is not a
  /// reason to hang the driver.
  static Future<void> settleFrames() async {
    final binding = WidgetsBinding.instance;
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    var quiet = 0;
    while (quiet < 3 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (binding.hasScheduledFrame) {
        quiet = 0;
        await binding.endOfFrame;
      } else {
        quiet++;
      }
    }
  }

  static int _int(Object? value) => switch (value) {
    final int i => i,
    final String s => int.parse(s),
    _ => throw FormatException('not a node id: $value'),
  };

  static List<String> _strings(Object? value) => switch (value) {
    null => const [],
    final String s => [s],
    final List<dynamic> l => [for (final v in l) '$v'],
    _ => throw FormatException('not text: $value'),
  };
}
