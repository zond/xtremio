// Sends one command to a running driver session (lib/main_driver.dart) and
// prints the answer. Run through `tool/drive`, which finds the session's VM
// service URL; docs/DRIVING.md has the commands.
//
//   dart run tool/drive.dart --url <vm service url> [--json] <command> ...
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

const _usage = '''
usage: tool/drive [--json] <command>

  screen                          routes, tab and the semantics nodes on screen
  act <id> <action> [arg]         perform a semantics action (tap, longPress,
                                  scrollUp, scrollDown, increase, setText ...)
  find <text>... [--not <text>]   nodes whose text holds every <text>
  tap <text>... [--not <text>]    find, then tap the first match
  wait <text>... [--not <text>] [--timeout <s>]
                                  poll until something matches
  go library|discover|search|settings
  go details <type> <id> [videoId]
  go back                         Android's back button
  player                          what the player screen opened, and how it is doing
  log [n]                         the last n diagnostics lines (default 50)

--json prints the raw answer.''';

Future<void> main(List<String> argv) async {
  final args = [...argv];
  String? url;
  var json = false;
  for (var i = 0; i < args.length;) {
    if (args[i] == '--url' && i + 1 < args.length) {
      url = args[i + 1];
      args.removeRange(i, i + 2);
    } else if (args[i] == '--json') {
      json = true;
      args.removeAt(i);
    } else {
      i++;
    }
  }
  if (url == null || url == 'none' || args.isEmpty) {
    stderr.writeln(_usage);
    exitCode = url == 'none' ? 0 : 64;
    return;
  }
  final Map<String, Object?> message;
  try {
    message = _message(args);
  } on FormatException catch (error) {
    stderr.writeln('${error.message}\n\n$_usage');
    exitCode = 64;
    return;
  }

  // flutter_driver narrates every connection on stderr; a failure still
  // throws with its own message.
  driverLog = (_, _) {};
  final driver = await FlutterDriver.connect(
    dartVmServiceUrl: url,
    printCommunication: false,
    logCommunicationToFile: false,
  );
  try {
    final timeout = message['cmd'] == 'wait'
        ? Duration(seconds: (message['timeout'] as int? ?? 20) + 30)
        : const Duration(seconds: 60);
    final answer = jsonDecode(
      await driver.requestData(jsonEncode(message), timeout: timeout),
    ) as Map<String, dynamic>;
    if (json) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(answer));
    } else {
      stdout.write(_human(message['cmd']! as String, answer));
    }
    if (answer.containsKey('error')) exitCode = 1;
  } finally {
    await driver.close();
  }
}

Map<String, Object?> _message(List<String> args) {
  final cmd = args.first;
  final rest = args.sublist(1);
  switch (cmd) {
    case 'screen':
    case 'player':
      return {'cmd': cmd};
    case 'act':
      if (rest.length < 2) throw const FormatException('act <id> <action>');
      return {
        'cmd': 'act',
        'id': int.parse(rest[0]),
        'action': rest[1],
        if (rest.length > 2) 'arg': rest.sublist(2).join(' '),
      };
    case 'find':
    case 'tap':
    case 'wait':
      final text = <String>[];
      final not = <String>[];
      int? timeout;
      for (var i = 0; i < rest.length; i++) {
        if (rest[i] == '--not' && i + 1 < rest.length) {
          not.add(rest[++i]);
        } else if (rest[i] == '--timeout' && i + 1 < rest.length) {
          timeout = int.parse(rest[++i]);
        } else {
          text.add(rest[i]);
        }
      }
      if (text.isEmpty) throw FormatException('$cmd needs some text');
      return {'cmd': cmd, 'text': text, 'not': not, 'timeout': ?timeout};
    case 'go':
      if (rest.isEmpty) throw const FormatException('go where?');
      return {'cmd': 'go', 'args': rest};
    case 'log':
      return {'cmd': 'log', 'n': rest.isEmpty ? 50 : int.parse(rest.first)};
    default:
      throw FormatException('unknown command: $cmd');
  }
}

String _human(String cmd, Map<String, dynamic> answer) {
  final out = StringBuffer();
  if (answer['error'] != null) {
    out.writeln('error: ${answer['error']}');
    return '$out';
  }
  if (answer['tapped'] != null) {
    out.writeln(
      'tapped "${_oneLine(answer['tapped'] as String)}" '
      '(${answer['matches']} tappable matches)',
    );
  } else if (answer['acted'] != null) {
    out.writeln('${answer['action']} on #${answer['acted']}');
  }
  if (answer['sections'] != null) _screen(out, answer);
  if (answer['nodes'] != null) {
    for (final node in answer['nodes'] as List) {
      out.writeln(_node(node as Map<String, dynamic>));
    }
  }
  if (answer['players'] != null) {
    final players = answer['players'] as List;
    if (players.isEmpty) out.writeln('no player screen is up');
    for (final player in players) {
      final p = player as Map<String, dynamic>;
      out
        ..writeln('opened:    ${p['opened']}')
        ..writeln('engine:    ${p['engineUrl']}')
        ..writeln('media id:  ${p['mediaId']}')
        ..writeln(
          'position:  ${_time(p['positionMs'] as int)} / '
          '${_time(p['durationMs'] as int)}  '
          '(buffer ${_time(p['bufferMs'] as int)})',
        )
        ..writeln(
          'state:     ${p['playing'] == true ? 'playing' : 'paused'}'
          '${p['buffering'] == true ? ', buffering' : ''}'
          '${p['positionStuck'] == true ? ', stuck' : ''}'
          '${p['mediaLoaded'] == true ? ', media loaded' : ', media not loaded'}'
          '${p['casting'] == true ? ', casting' : ''}'
          '${p['leaving'] == true ? ', leaving' : ''}',
        )
        ..writeln('engine error: ${p['engineError']}')
        ..writeln('open error:   ${p['openError']}');
    }
  }
  if (answer['lines'] != null) {
    for (final line in answer['lines'] as List) {
      out.writeln(line);
    }
  }
  return '$out';
}

void _screen(StringBuffer out, Map<String, dynamic> answer) {
  final routes = [
    for (final r in answer['routes'] as List)
      () {
        final route = r as Map<String, dynamic>;
        final name = route['page'] ?? route['name'] ?? route['type'];
        final named = route['name'] != null && route['name'] != name
            ? ' (${route['name']})'
            : '';
        return '$name$named${route['current'] == true ? ' *' : ''}';
      }(),
  ];
  out.writeln('routes: ${routes.join(' > ')}');
  if (answer['tab'] != null) out.writeln('tab: ${answer['tab']}');
  for (final s in answer['sections'] as List) {
    final section = s as Map<String, dynamic>;
    if (section['header'] != null) {
      out.writeln('== ${_oneLine(section['header'] as String)}');
    }
    for (final node in section['nodes'] as List) {
      out.writeln(_node(node as Map<String, dynamic>));
    }
  }
}

String _node(Map<String, dynamic> node) {
  final roles = (node['roles'] as List).cast<String>();
  final actions = (node['actions'] as List).cast<String>();
  final rect = (node['rect'] as List).cast<int>();
  final b = StringBuffer('  #${node['id']}');
  if (roles.isNotEmpty) b.write(' [${roles.join(',')}]');
  if ((node['label'] as String).isNotEmpty) {
    b.write(' "${_oneLine(node['label'] as String)}"');
  }
  if (node['value'] != null) {
    b.write(' = "${_oneLine(node['value'] as String)}"');
  }
  if (node['hint'] != null) {
    b.write(' (hint: ${_oneLine(node['hint'] as String)})');
  }
  if (node['tooltip'] != null) {
    b.write(' (tooltip: ${_oneLine(node['tooltip'] as String)})');
  }
  if (actions.isNotEmpty) b.write(' {${actions.join(',')}}');
  b.write(' @${rect[0]},${rect[1]} ${rect[2]}x${rect[3]}');
  return '$b';
}

String _oneLine(String text) => text.replaceAll(RegExp(r'\s*\n\s*'), ' | ');

String _time(int ms) {
  final d = Duration(milliseconds: ms);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}
