import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../game/mcpe_client.dart';
import '../protocol/packets.dart';
import '../protocol/raknet.dart';
import '../protocol/skin.dart';
import '../server/local_server.dart';
import '../server/worlds.dart';

/// Текущая игровая сессия: подключение к серверу или к своему локальному миру.
class SessionController extends ChangeNotifier {
  McpeClient? client;
  StreamSubscription<void>? _sub;
  String? error;

  /// Версия сервера из ответа на запрос статуса (перед входом).
  ServerStatus? serverStatus;
  bool connecting = false;

  LocalServer? server;
  StreamSubscription<String>? _serverLog;
  bool serverLan = false;
  List<String> lanAddresses = const [];
  final List<String> serverLog = [];

  String _host = '';
  int _port = 19132;
  String _nickname = '';
  SkinData? _skin;

  String get address => '$_host:$_port';

  /// Пояснение, если сервер работает не на MCPE 1.1.x: такой сервер не примет вход по протоколу 113.
  String? get versionHint {
    final st = serverStatus;
    if (st == null || st.protocol == mcpeProtocol || st.protocol == 0) return null;
    return 'Сервер работает на версии ${st.version} (протокол ${st.protocol}), а этот клиент — на MCPE '
        '$mcpeVersion (протокол $mcpeProtocol). Такие версии несовместимы: сервер не понимает вход старого '
        'клиента и отключает его (например, с сообщением «Login timeout»). Нужен сервер 1.1.x или сервер '
        'с поддержкой старых версий.';
  }

  bool get isHosting => server != null;

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

  /// Запустить локальный мир и войти в него. [lan] — разрешить вход другим по IP.
  Future<void> hostWorld({
    required LocalWorldEntry world,
    required bool lan,
    required String nickname,
    required SkinData skin,
  }) async {
    await _stopServer();
    error = null;
    connecting = true;
    serverLog.clear();
    notifyListeners();
    final s = LocalServer(storage: world.storage, lan: lan);
    try {
      final port = await s.start();
      server = s;
      serverLan = lan;
      _serverLog = s.log.listen((line) {
        serverLog.add(line);
        if (serverLog.length > 100) serverLog.removeAt(0);
        notifyListeners();
      });
      lanAddresses = lan ? await localIpAddresses() : const [];
      await connect(host: '127.0.0.1', port: port, nickname: nickname, skin: skin);
    } on SocketException catch (e) {
      error = 'Не удалось запустить сервер: ${e.message}';
      connecting = false;
      notifyListeners();
    } on FileSystemException catch (e) {
      error = 'Не удалось прочитать мир: ${e.message}';
      connecting = false;
      notifyListeners();
    }
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
    serverStatus = null;
    if (!isHosting) {
      queryServer(_host, _port).then((st) {
        if (!identical(client, c)) return;
        serverStatus = st;
        notifyListeners();
      }, onError: (Object _) {});
    }
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

  Future<void> _stopServer() async {
    final s = server;
    server = null;
    await _serverLog?.cancel();
    _serverLog = null;
    if (s != null) await s.stop();
  }

  /// Выход на экран серверов: отключение и остановка своего сервера (мир сохраняется).
  Future<void> close() async {
    _closeClient();
    await _stopServer();
    error = null;
    connecting = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _closeClient();
    _stopServer();
    super.dispose();
  }
}
