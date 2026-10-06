import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../protocol/binary.dart';
import '../protocol/raknet.dart';

class RakServerSession {
  RakServerSession(this.address, this.port, this.mtu);

  final InternetAddress address;
  final int port;
  final int mtu;
  late final RakConnection conn;
  bool connected = false;

  String get key => '${address.address}:$port';
}

/// RakNet-сервер для встроенного сервера MCPE 1.1.
class RakNetServer {
  RakNetServer({required this.motd, required this.onConnect, required this.onPacket, required this.onDisconnect});

  /// Строка ответа на поиск в локальной сети: "MCPE;имя;протокол;версия;онлайн;максимум".
  final String Function() motd;
  final void Function(RakServerSession session) onConnect;
  final void Function(RakServerSession session, Uint8List payload) onPacket;
  final void Function(RakServerSession session, String reason) onDisconnect;

  static const _timeout = Duration(seconds: 20);

  final int _guid = randomLong(Random.secure());
  final Map<String, RakServerSession> _sessions = {};
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  Timer? _tick;

  int get port => _socket?.port ?? 0;

  /// Запуск. [lan] — принимать подключения из сети (иначе только с этого устройства).
  /// Если порт занят, выбирается свободный.
  Future<int> start({required bool lan, int port = 19132}) async {
    final address = lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(address, port);
    } on SocketException {
      socket = await RawDatagramSocket.bind(address, 0);
    }
    socket.broadcastEnabled = true;
    _socket = socket;
    _sub = socket.listen(_onEvent);
    _tick = Timer.periodic(const Duration(milliseconds: 20), (_) => _update());
    return socket.port;
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    while (true) {
      final dg = _socket?.receive();
      if (dg == null) return;
      if (dg.data.isEmpty) continue;
      try {
        _handle(dg);
      } on FormatException {
        // Повреждённая датаграмма от клиента — пропускаем.
      } on RakNetException {
        // Неизвестный формат адреса — пропускаем.
      }
    }
  }

  void _sendRaw(Uint8List data, InternetAddress address, int port) => _socket?.send(data, address, port);

  void _handle(Datagram dg) {
    final data = dg.data;
    final id = data[0];
    final key = '${dg.address.address}:${dg.port}';
    if (id & 0x80 != 0) {
      _sessions[key]?.conn.handleDatagram(data);
      return;
    }
    final r = BinaryReader(data, 1);
    switch (id) {
      case RakId.unconnectedPing:
      case RakId.unconnectedPingOpenConnections:
        final time = r.longBE();
        final w = BinaryWriter()
          ..byte(RakId.unconnectedPong)
          ..longBE(time)
          ..longBE(_guid)
          ..bytes(rakMagic)
          ..rakString(motd());
        _sendRaw(w.take(), dg.address, dg.port);
        break;
      case RakId.openConnectionRequest1:
        final mtu = min(data.length + 28, 1492);
        final w = BinaryWriter()
          ..byte(RakId.openConnectionReply1)
          ..bytes(rakMagic)
          ..longBE(_guid)
          ..byte(0)
          ..shortBE(mtu);
        _sendRaw(w.take(), dg.address, dg.port);
        break;
      case RakId.openConnectionRequest2:
        r.skip(16);
        skipRakAddress(r);
        final mtu = min(r.shortBE(), 1492);
        var session = _sessions[key];
        if (session == null) {
          final s = RakServerSession(dg.address, dg.port, mtu);
          s.conn = RakConnection(
            sendDatagram: (d) => _sendRaw(d, s.address, s.port),
            onMessage: (body) => _onMessage(s, body),
            mtu: mtu,
          );
          _sessions[key] = s;
          session = s;
        }
        final w = BinaryWriter()
          ..byte(RakId.openConnectionReply2)
          ..bytes(rakMagic)
          ..longBE(_guid);
        writeRakAddress(w, dg.address, dg.port);
        w
          ..shortBE(session.mtu)
          ..byte(0);
        _sendRaw(w.take(), dg.address, dg.port);
        break;
    }
  }

  void _onMessage(RakServerSession s, Uint8List body) {
    final id = body[0];
    final r = BinaryReader(body, 1);
    switch (id) {
      case RakId.connectionRequest:
        r.longBE(); // GUID клиента
        final time = r.longBE();
        final w = BinaryWriter()..byte(RakId.connectionRequestAccepted);
        writeRakAddress(w, s.address, s.port);
        w.shortBE(0);
        for (var i = 0; i < 10; i++) {
          writeRakAddress(w, InternetAddress('0.0.0.0'), 0);
        }
        w
          ..longBE(time)
          ..longBE(DateTime.now().millisecondsSinceEpoch);
        s.conn.queue(w.take(), Reliability.reliable);
        s.conn.flush();
        return;
      case RakId.newIncomingConnection:
        if (!s.connected) {
          s.connected = true;
          onConnect(s);
        }
        return;
      case RakId.connectedPing:
        final w = BinaryWriter()
          ..byte(RakId.connectedPong)
          ..longBE(r.longBE())
          ..longBE(DateTime.now().millisecondsSinceEpoch);
        s.conn.queue(w.take(), Reliability.unreliable);
        return;
      case RakId.connectedPong:
        return;
      case RakId.disconnectionNotification:
        _remove(s, 'Игрок отключился');
        return;
    }
    if (id >= 0x80 && s.connected) onPacket(s, body);
  }

  /// Отправить прикладной пакет (обычно 0xFE + сжатый пакет игры).
  void send(RakServerSession s, Uint8List payload) {
    if (!_sessions.containsKey(s.key)) return;
    s.conn.queue(payload, Reliability.reliableOrdered);
    s.conn.flush();
  }

  /// Закрыть сессию с уведомлением клиента.
  void kick(RakServerSession s) {
    if (!_sessions.containsKey(s.key)) return;
    s.conn.queue(Uint8List.fromList(const [RakId.disconnectionNotification]), Reliability.reliableOrdered);
    s.conn.flush();
    _remove(s, 'Отключён сервером');
  }

  void _remove(RakServerSession s, String reason) {
    if (_sessions.remove(s.key) == null) return;
    if (s.connected) onDisconnect(s, reason);
  }

  void _update() {
    final now = DateTime.now();
    for (final s in _sessions.values.toList()) {
      if (now.difference(s.conn.lastReceive) > _timeout) {
        _remove(s, 'Таймаут соединения');
        continue;
      }
      s.conn.update();
    }
  }

  Future<void> stop() async {
    for (final s in _sessions.values.toList()) {
      kick(s);
    }
    _tick?.cancel();
    await _sub?.cancel();
    _socket?.close();
    _socket = null;
  }
}
