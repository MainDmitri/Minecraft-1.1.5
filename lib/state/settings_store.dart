import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/skin.dart';

class ServerEntry {
  ServerEntry({required this.name, required this.host, required this.port});

  final String name;
  final String host;
  final int port;

  String get address => '$host:$port';

  Map<String, dynamic> toJson() => {'name': name, 'host': host, 'port': port};

  static ServerEntry fromJson(Map<String, dynamic> j) =>
      ServerEntry(name: j['name'] as String, host: j['host'] as String, port: j['port'] as int);
}

/// Ник, список серверов и скин, сохраняются в shared_preferences.
class SettingsStore extends ChangeNotifier {
  static const _kNickname = 'nickname';
  static const _kServers = 'servers';
  static const _kSkin = 'skin_rgba';
  static const _kRenderDistance = 'render_distance';

  /// Допустимая дальность прорисовки в блоках.
  static const renderDistances = [16, 24, 32, 48, 64];

  SharedPreferences? _prefs;

  String nickname = '';
  List<ServerEntry> servers = [];
  SkinData skin = SkinData.generated();
  bool customSkin = false;
  int renderDistance = 32;
  bool loaded = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    nickname = prefs.getString(_kNickname) ?? '';
    final distance = prefs.getInt(_kRenderDistance);
    if (distance != null && renderDistances.contains(distance)) renderDistance = distance;
    final raw = prefs.getString(_kServers);
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      servers = list.map((e) => ServerEntry.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    }
    final skinB64 = prefs.getString(_kSkin);
    if (skinB64 != null) {
      final candidate = SkinData(Uint8List.fromList(base64.decode(skinB64)), 'Standard_Custom');
      if (candidate.isValid) {
        skin = candidate;
        customSkin = true;
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> setNickname(String value) async {
    nickname = value;
    await _prefs?.setString(_kNickname, value);
    notifyListeners();
  }

  Future<void> setRenderDistance(int value) async {
    renderDistance = value;
    await _prefs?.setInt(_kRenderDistance, value);
    notifyListeners();
  }

  Future<void> _saveServers() async {
    await _prefs?.setString(_kServers, jsonEncode(servers.map((s) => s.toJson()).toList()));
    notifyListeners();
  }

  Future<void> addServer(ServerEntry entry) async {
    servers = [...servers, entry];
    await _saveServers();
  }

  Future<void> updateServer(int index, ServerEntry entry) async {
    servers = [...servers]..[index] = entry;
    await _saveServers();
  }

  Future<void> removeServer(int index) async {
    servers = [...servers]..removeAt(index);
    await _saveServers();
  }

  Future<void> setSkinFromPng(Uint8List png) async {
    final data = SkinData.fromPng(png);
    skin = data;
    customSkin = true;
    await _prefs?.setString(_kSkin, base64.encode(data.rgba));
    notifyListeners();
  }

  Future<void> resetSkin() async {
    skin = SkinData.generated();
    customSkin = false;
    await _prefs?.remove(_kSkin);
    notifyListeners();
  }
}
