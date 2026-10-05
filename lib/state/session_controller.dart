import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../game/mcpe_client.dart';
import '../protocol/raknet.dart';
import '../protocol/skin.dart';

/// Текущая игровая сессия для экрана игры.
class SessionController extends ChangeNotifier {
  McpeClient? client;
  StreamSubscription<void>? _sub;
  String? error;
  bool connecting = false;

  String _host = '';
  int _port = 19132;
  String _nickname = '';
  SkinData? _skin;

  String get address => '$_host:$_port';

  Future<void> connect({
    required String host,
    required int port,
    required String nickname,
    required SkinData skin,
  }) async {
    _host = host;
    _port = port;
    _nickname = nickname;
    _skin = skin;
    await _start();
  }

  Future<void> reconnect() => _start();

  Future<void> _start() async {
    _closeClient();
    error = null;
    connecting = true;
    final c = McpeClient(
      host: _host,
      port: _port,
      nickname: _nickname,
      skin: _skin!,
      deviceModel: 'Android ${Platform.operatingSystemVersion}',
      languageCode: Platform.localeName.split('.').first,
    );
    client = c;
    _sub = c.changes.listen((_) => _onClientChanged(c));
    notifyListeners();
    try {
      await c.connect();
    } on RakNetException catch (e) {
      if (identical(client, c)) error = e.message;
    } on SocketException catch (e) {
      if (identical(client, c)) error = 'Ошибка сети: ${e.message}';
    } finally {
      if (identical(client, c)) {
        connecting = false;
        notifyListeners();
      }
    }
  }

  void _onClientChanged(McpeClient c) {
    if (!identical(client, c)) return;
    final target = c.transferTarget;
    if (target != null && c.phase == ConnectionPhase.disconnected) {
      c.transferTarget = null;
      _host = target.host;
      _port = target.port;
      scheduleMicrotask(_start);
    }
    notifyListeners();
  }

  void disconnect() {
    client?.disconnect();
    notifyListeners();
  }

  void _closeClient() {
    _sub?.cancel();
    _sub = null;
    client?.dispose();
    client = null;
  }

  void close() {
    _closeClient();
    error = null;
    connecting = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _closeClient();
    super.dispose();
  }
}
