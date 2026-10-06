import 'dart:convert';

class CommandParam {
  CommandParam(this.name, this.type, this.optional, this.enumValues);

  final String name;
  final String type;
  final bool optional;
  final List<String> enumValues;

  String get usage {
    final inner = enumValues.isNotEmpty && enumValues.length <= 6 ? enumValues.join('|') : '$name: $type';
    return optional ? '[$inner]' : '<$inner>';
  }
}

class CommandOverload {
  CommandOverload(this.name, this.params);

  final String name;
  final List<CommandParam> params;
}

class CommandInfo {
  CommandInfo(this.name, this.description, this.aliases, this.overloads);

  final String name;
  final String description;
  final List<String> aliases;
  final List<CommandOverload> overloads;

  List<String> get usages => overloads.map((o) => '/$name ${o.params.map((p) => p.usage).join(' ')}'.trim()).toList();
}

/// Готовый к отправке вызов команды (CommandStepPacket протокола 113).
class CommandCall {
  CommandCall(this.command, this.overload, this.inputJson);

  final String command;
  final String overload;
  final String inputJson;
}

class CommandParseException implements Exception {
  CommandParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Список команд из AvailableCommandsPacket (JSON формата MCPE 1.1).
class CommandRegistry {
  final Map<String, CommandInfo> _commands = {};
  final Map<String, String> _aliases = {};

  bool get isEmpty => _commands.isEmpty;

  List<CommandInfo> get all => _commands.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  void load(String json) {
    _commands.clear();
    _aliases.clear();
    final decoded = jsonDecode(json);
    if (decoded is! Map) return;
    decoded.forEach((rawName, value) {
      if (value is! Map) return;
      final versions = value['versions'];
      Map? data;
      if (versions is List && versions.isNotEmpty && versions.first is Map) {
        data = versions.first as Map;
      } else if (versions is Map && versions.isNotEmpty) {
        final first = versions.values.first;
        if (first is Map) data = first;
      }
      if (data == null) return;
      final name = rawName.toString().toLowerCase();
      final aliases = <String>[
        for (final a in (data['aliases'] is List ? data['aliases'] as List : const [])) a.toString().toLowerCase(),
      ];
      final overloads = <CommandOverload>[];
      final rawOverloads = data['overloads'];
      if (rawOverloads is Map) {
        rawOverloads.forEach((oName, oValue) {
          final params = <CommandParam>[];
          if (oValue is Map) {
            final input = oValue['input'];
            final rawParams = input is Map ? input['parameters'] : null;
            if (rawParams is List) {
              for (final p in rawParams) {
                if (p is! Map) continue;
                final enumRaw = p['enum_values'];
                params.add(CommandParam(
                  p['name']?.toString() ?? 'arg',
                  p['type']?.toString() ?? 'string',
                  p['optional'] == true,
                  enumRaw is List ? enumRaw.map((e) => e.toString()).toList() : const [],
                ));
              }
            }
          }
          overloads.add(CommandOverload(oName.toString(), params));
        });
      }
      overloads.sort((a, b) {
        if (a.name == 'default') return -1;
        if (b.name == 'default') return 1;
        return a.params.length.compareTo(b.params.length);
      });
      _commands[name] = CommandInfo(name, data['description']?.toString() ?? '', aliases, overloads);
      for (final a in aliases) {
        _aliases[a] = name;
      }
    });
  }

  CommandInfo? find(String name) {
    final n = name.toLowerCase();
    return _commands[n] ?? (_aliases.containsKey(n) ? _commands[_aliases[n]] : null);
  }

  /// Разбор строки вида "/tp Steve 10 64 -5".
  CommandCall parse(String line) {
    final tokens = tokenize(line.startsWith('/') ? line.substring(1) : line);
    if (tokens.isEmpty) {
      throw CommandParseException('Пустая команда');
    }
    final name = tokens.first.toLowerCase();
    final args = tokens.sublist(1);
    final info = find(name);
    if (info == null || info.overloads.isEmpty) {
      // Сервер не прислал описание команды: аргументы передаются одной строкой, ответ даст сервер.
      return CommandCall(name, 'default', args.isEmpty ? 'null' : jsonEncode({'args': args.join(' ')}));
    }
    for (final overload in info.overloads) {
      final bound = _bind(overload.params, args);
      if (bound != null) {
        return CommandCall(info.name, overload.name, bound.isEmpty ? 'null' : jsonEncode(bound));
      }
    }
    throw CommandParseException('Неверные аргументы. Использование:\n${info.usages.join('\n')}');
  }

  static List<String> tokenize(String s) {
    final result = <String>[];
    final current = StringBuffer();
    var inQuotes = false;
    var hasToken = false;
    for (final ch in s.split('')) {
      if (ch == '"') {
        inQuotes = !inQuotes;
        hasToken = true;
      } else if (ch == ' ' && !inQuotes) {
        if (hasToken) {
          result.add(current.toString());
          current.clear();
          hasToken = false;
        }
      } else {
        current.write(ch);
        hasToken = true;
      }
    }
    if (hasToken) result.add(current.toString());
    return result;
  }

  static const _selectors = {
    '@p': 'nearestPlayer',
    '@a': 'allPlayers',
    '@r': 'randomPlayer',
    '@e': 'allEntities',
    '@s': 'self',
  };

  Map<String, dynamic>? _bind(List<CommandParam> params, List<String> args) {
    final out = <String, dynamic>{};
    var i = 0;
    for (final p in params) {
      if (i >= args.length) {
        if (p.optional) continue;
        return null;
      }
      switch (p.type) {
        case 'rawtext':
        case 'message':
          out[p.name] = args.sublist(i).join(' ');
          i = args.length;
          break;
        case 'int':
          final v = int.tryParse(args[i]);
          if (v == null) return null;
          out[p.name] = v;
          i++;
          break;
        case 'float':
        case 'value':
          final v = double.tryParse(args[i]);
          if (v == null) return null;
          out[p.name] = v;
          i++;
          break;
        case 'bool':
          final t = args[i].toLowerCase();
          if (t != 'true' && t != 'false') return null;
          out[p.name] = t == 'true';
          i++;
          break;
        case 'target':
          final t = args[i];
          if (t.startsWith('@')) {
            final selector = _selectors[t.toLowerCase()];
            if (selector == null) return null;
            out[p.name] = {'rules': <dynamic>[], 'selector': selector};
          } else {
            out[p.name] = {
              'rules': [
                {'inverted': false, 'name': 'name', 'value': t},
              ],
              'selector': 'nearestPlayer',
            };
          }
          i++;
          break;
        case 'blockpos':
        case 'position':
          if (i + 3 > args.length) return null;
          final pos = <String, dynamic>{};
          const axes = ['x', 'y', 'z'];
          for (var a = 0; a < 3; a++) {
            var t = args[i + a];
            final relative = t.startsWith('~');
            if (relative) t = t.substring(1);
            final v = t.isEmpty ? 0 : num.tryParse(t);
            if (v == null) return null;
            pos[axes[a]] = p.type == 'blockpos' ? v.floor() : v;
            if (relative) pos['relative${axes[a]}'] = true;
          }
          out[p.name] = pos;
          i += 3;
          break;
        case 'stringenum':
          final t = args[i];
          if (p.enumValues.isNotEmpty && !p.enumValues.any((e) => e.toLowerCase() == t.toLowerCase())) {
            return null;
          }
          out[p.name] = t;
          i++;
          break;
        default:
          out[p.name] = args[i];
          i++;
      }
    }
    if (i < args.length) return null;
    return out;
  }
}
