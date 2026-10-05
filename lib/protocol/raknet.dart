import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'binary.dart';

final Uint8List rakMagic = Uint8List.fromList(const [
  0x00, 0xff, 0xff, 0x00, 0xfe, 0xfe, 0xfe, 0xfe, //
  0xfd, 0xfd, 0xfd, 0xfd, 0x12, 0x34, 0x56, 0x78,
]);

class RakId {
  static const connectedPing = 0x00;
  static const unconnectedPing = 0x01;
  static const connectedPong = 0x03;
  static const openConnectionRequest1 = 0x05;
  static const openConnectionReply1 = 0x06;
  static const openConnectionRequest2 = 0x07;
  static const openConnectionReply2 = 0x08;
  static const connectionRequest = 0x09;
  static const connectionRequestAccepted = 0x10;
  static const connectionAttemptFailed = 0x11;
  static const alreadyConnected = 0x12;
  static const newIncomingConnection = 0x13;
  static const noFreeIncomingConnections = 0x14;
  static const disconnectionNotification = 0x15;
  static const connectionBanned = 0x17;
  static const incompatibleProtocol = 0x19;
  static const ipRecentlyConnected = 0x1a;
  static const unconnectedPong = 0x1c;
  static const nack = 0xa0;
  static const ack = 0xc0;
}

class Reliability {
  static const unreliable = 0;
  static const unreliableSequenced = 1;
  static const reliable = 2;
  static const reliableOrdered = 3;
  static const reliableSequenced = 4;
  static const unreliableWithAck = 5;
  static const reliableWithAck = 6;
  static const reliableOrderedWithAck = 7;

  static bool isReliable(int r) =>
      r == reliable || r == reliableOrdered || r == reliableSequenced || r == reliableWithAck || r == reliableOrderedWithAck;

  static bool isSequenced(int r) => r == unreliableSequenced || r == reliableSequenced;

  static bool isOrdered(int r) =>
      r == unreliableSequenced || r == reliableOrdered || r == reliableSequenced || r == reliableOrderedWithAck;
}

class RakNetException implements Exception {
  RakNetException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _Frame {
  _Frame({
    required this.reliability,
    required this.body,
    this.messageIndex = 0,
    this.sequenceIndex = 0,
    this.orderIndex = 0,
    this.orderChannel = 0,
    this.split = false,
    this.splitCount = 0,
    this.splitId = 0,
    this.splitIndex = 0,
  });

  final int reliability;
  final Uint8List body;
  int messageIndex;
  int sequenceIndex;
  int orderIndex;
  int orderChannel;
  bool split;
  int splitCount;
  int splitId;
  int splitIndex;

  int get headerSize {
    var size = 3;
    if (Reliability.isReliable(reliability)) size += 3;
    if (Reliability.isSequenced(reliability)) size += 3;
    if (Reliability.isOrdered(reliability)) size += 4;
    if (split) size += 10;
    return size;
  }

  int get size => headerSize + body.length;

  void write(BinaryWriter w) {
    w.byte((reliability << 5) | (split ? 0x10 : 0));
    w.shortBE(body.length << 3);
    if (Reliability.isReliable(reliability)) w.triadLE(messageIndex);
    if (Reliability.isSequenced(reliability)) w.triadLE(sequenceIndex);
    if (Reliability.isOrdered(reliability)) {
      w.triadLE(orderIndex);
      w.byte(orderChannel);
    }
    if (split) {
      w.intBE(splitCount);
      w.shortBE(splitId);
      w.intBE(splitIndex);
    }
    w.bytes(body);
  }

  static _Frame read(BinaryReader r) {
    final flags = r.byte();
    final reliability = flags >> 5;
    final split = (flags & 0x10) != 0;
    final length = (r.shortBE() + 7) >> 3;
    final f = _Frame(reliability: reliability, body: Uint8List(0), split: split);
    if (Reliability.isReliable(reliability)) f.messageIndex = r.triadLE();
    if (Reliability.isSequenced(reliability)) f.sequenceIndex = r.triadLE();
    if (Reliability.isOrdered(reliability)) {
      f.orderIndex = r.triadLE();
      f.orderChannel = r.byte();
    }
    if (split) {
      f.splitCount = r.intBE();
      f.splitId = r.shortBE();
      f.splitIndex = r.intBE();
    }
    return _Frame(
      reliability: f.reliability,
      body: Uint8List.fromList(r.bytes(length)),
      messageIndex: f.messageIndex,
      sequenceIndex: f.sequenceIndex,
      orderIndex: f.orderIndex,
      orderChannel: f.orderChannel,
      split: f.split,
      splitCount: f.splitCount,
      splitId: f.splitId,
      splitIndex: f.splitIndex,
    );
  }
}

class _SentDatagram {
  _SentDatagram(this.frames, this.sentAt);

  final List<_Frame> frames;
  DateTime sentAt;
}

class _OrderChannel {
  int expected = 0;
  final Map<int, Uint8List> pending = {};
  DateTime? gapSince;
  int highestSequence = -1;
}

/// Информация о сервере из ответа на UnconnectedPing.
class ServerStatus {
  ServerStatus({
    required this.motd,
    required this.protocol,
    required this.version,
    required this.online,
    required this.max,
    required this.latencyMs,
    required this.raw,
  });

  final String motd;
  final int protocol;
  final String version;
  final int online;
  final int max;
  final int latencyMs;
  final String raw;

  static ServerStatus parse(String raw, int latencyMs) {
    final p = raw.split(';');
    int num(int i) => i < p.length ? int.tryParse(p[i].trim()) ?? 0 : 0;
    return ServerStatus(
      motd: p.length > 1 ? p[1] : raw,
      protocol: num(2),
      version: p.length > 3 ? p[3] : '',
      online: num(4),
      max: num(5),
      latencyMs: latencyMs,
      raw: raw,
    );
  }
}

Future<InternetAddress> resolveHost(String host) async {
  final parsed = InternetAddress.tryParse(host);
  if (parsed != null) {
    if (parsed.type != InternetAddressType.IPv4) {
      throw RakNetException('Поддерживаются только IPv4-адреса');
    }
    return parsed;
  }
  final list = await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
  if (list.isEmpty) {
    throw RakNetException('Не удалось найти адрес $host');
  }
  return list.first;
}

int _randomLong(Random rnd) => (rnd.nextInt(1 << 32) << 32) | rnd.nextInt(1 << 32);

void _writeAddress(BinaryWriter w, InternetAddress address, int port) {
  w.byte(4);
  for (final b in address.rawAddress) {
    w.byte(~b & 0xff);
  }
  w.shortBE(port);
}

void _skipAddress(BinaryReader r) {
  final version = r.byte();
  if (version == 4) {
    r.skip(6);
  } else if (version == 6) {
    r.skip(28);
  } else {
    throw RakNetException('Неизвестный формат адреса: $version');
  }
}

/// Запрос статуса сервера (MOTD, версия, игроки) без подключения.
Future<ServerStatus> queryServer(String host, int port, {Duration timeout = const Duration(seconds: 3)}) async {
  final address = await resolveHost(host);
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final rnd = Random.secure();
  final guid = _randomLong(rnd);
  final completer = Completer<ServerStatus>();
  final start = DateTime.now().millisecondsSinceEpoch;

  void sendPing() {
    final w = BinaryWriter()
      ..byte(RakId.unconnectedPing)
      ..longBE(DateTime.now().millisecondsSinceEpoch)
      ..bytes(rakMagic)
      ..longBE(guid);
    socket.send(w.take(), address, port);
  }

  final sub = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final dg = socket.receive();
    if (dg == null || dg.data.isEmpty || dg.data[0] != RakId.unconnectedPong) return;
    try {
      final r = BinaryReader(dg.data, 1);
      r.longBE();
      r.longBE();
      r.skip(16);
      final raw = r.rakString();
      if (!completer.isCompleted) {
        completer.complete(ServerStatus.parse(raw, DateTime.now().millisecondsSinceEpoch - start));
      }
    } catch (e) {
      if (!completer.isCompleted) completer.completeError(RakNetException('Некорректный ответ сервера: $e'));
    }
  });
  sendPing();
  final retry = Timer.periodic(const Duration(milliseconds: 700), (_) => sendPing());
  try {
    return await completer.future.timeout(timeout, onTimeout: () {
      throw RakNetException('Сервер не отвечает');
    });
  } finally {
    retry.cancel();
    await sub.cancel();
    socket.close();
  }
}

/// RakNet-клиент (протокол MCPE 1.1).
class RakNetClient {
  RakNetClient({
    required this.host,
    required this.port,
    this.onPacket,
    this.onDisconnect,
    this.rakProtocol = 8,
  });

  final String host;
  final int port;
  int rakProtocol;

  /// Пакет прикладного уровня (обычно начинается с 0xFE).
  void Function(Uint8List payload)? onPacket;

  /// Соединение закрыто (по инициативе сервера, по таймауту или локально).
  void Function(String reason)? onDisconnect;

  static const _mtuCandidates = [1492, 1200, 576];
  static const _udpOverhead = 28;
  static const _datagramHeader = 4;
  static const _resendAfter = Duration(milliseconds: 1500);
  static const _timeout = Duration(seconds: 20);

  final Random _rnd = Random.secure();
  late final int _guid = _randomLong(_rnd);

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  late InternetAddress _address;
  int _mtu = 576;
  int? _cookie;
  bool _connected = false;
  bool _closed = false;
  Completer<void>? _connectCompleter;
  Completer<void>? _offlineStep;
  int _offlineState = 0;

  Timer? _tick;
  Timer? _pingTimer;
  DateTime _lastReceive = DateTime.now();

  // Отправка
  int _sendSeq = 0;
  int _messageIndex = 0;
  int _orderIndex = 0;
  int _splitId = 0;
  final List<_Frame> _outQueue = [];
  final Map<int, _SentDatagram> _recovery = {};

  // Приём
  final Set<int> _ackQueue = {};
  final Set<int> _nackQueue = {};
  int _highestSeq = -1;
  final Set<int> _receivedSeqWindow = {};
  int _reliableWindowStart = 0;
  final Set<int> _reliableReceived = {};
  final Map<int, Map<int, Uint8List>> _splits = {};
  final Map<int, int> _splitCounts = {};
  final List<_OrderChannel> _channels = List.generate(32, (_) => _OrderChannel());

  int latencyMs = 0;

  bool get isConnected => _connected;

  Future<void> connect({Duration timeout = const Duration(seconds: 15)}) async {
    _address = await resolveHost(host);
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sub = _socket!.listen(_onSocketEvent);
    _connectCompleter = Completer<void>();
    _lastReceive = DateTime.now();

    final watchdog = Timer(timeout, () {
      if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
        _connectCompleter!.completeError(RakNetException('Время ожидания подключения истекло'));
      }
    });

    try {
      await _openConnection();
      _tick = Timer.periodic(const Duration(milliseconds: 20), (_) => _update());
      _sendConnectionRequest();
      await _connectCompleter!.future;
      _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) => _sendConnectedPing());
    } catch (e) {
      _shutdown();
      rethrow;
    } finally {
      watchdog.cancel();
    }
  }

  Future<void> _openConnection() async {
    for (final mtu in _mtuCandidates) {
      for (var attempt = 0; attempt < 4; attempt++) {
        if (_connectCompleter!.isCompleted) {
          await _connectCompleter!.future;
        }
        _offlineState = 1;
        _offlineStep = Completer<void>();
        final w = BinaryWriter()
          ..byte(RakId.openConnectionRequest1)
          ..bytes(rakMagic)
          ..byte(rakProtocol);
        final padding = mtu - _udpOverhead - w.length;
        w.bytes(Uint8List(padding));
        _socket!.send(w.take(), _address, port);
        final ok = await _waitStep(const Duration(milliseconds: 600));
        if (ok) {
          return _openConnection2();
        }
      }
    }
    throw RakNetException('Сервер не отвечает на запрос подключения');
  }

  Future<void> _openConnection2() async {
    for (var attempt = 0; attempt < 6; attempt++) {
      _offlineState = 2;
      _offlineStep = Completer<void>();
      final w = BinaryWriter()
        ..byte(RakId.openConnectionRequest2)
        ..bytes(rakMagic);
      final cookie = _cookie;
      if (cookie != null) {
        w
          ..intBE(cookie)
          ..byte(0); // клиент не отвечает на криптографический вызов
      }
      _writeAddress(w, _address, port);
      w
        ..shortBE(_mtu)
        ..longBE(_guid);
      _socket!.send(w.take(), _address, port);
      if (await _waitStep(const Duration(milliseconds: 800))) {
        _offlineState = 3;
        return;
      }
    }
    throw RakNetException('Сервер не завершил открытие соединения');
  }

  Future<bool> _waitStep(Duration d) async {
    try {
      await Future.any([
        _offlineStep!.future,
        _connectCompleter!.future,
      ]).timeout(d);
      if (_connectCompleter!.isCompleted && !_offlineStep!.isCompleted) {
        await _connectCompleter!.future;
      }
      return _offlineStep!.isCompleted;
    } on TimeoutException {
      return false;
    }
  }

  void _sendConnectionRequest() {
    final w = BinaryWriter()
      ..byte(RakId.connectionRequest)
      ..longBE(_guid)
      ..longBE(DateTime.now().millisecondsSinceEpoch)
      ..byte(0);
    _queue(w.take(), Reliability.reliable);
  }

  void _sendConnectedPing() {
    final w = BinaryWriter()
      ..byte(RakId.connectedPing)
      ..longBE(DateTime.now().millisecondsSinceEpoch);
    _queue(w.take(), Reliability.unreliable);
  }

  /// Отправить прикладной пакет.
  void send(Uint8List payload, {int reliability = Reliability.reliableOrdered}) {
    if (!_connected || _closed) return;
    _queue(payload, reliability);
    _flush();
  }

  void _failConnect(String message) {
    if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
      _connectCompleter!.completeError(RakNetException(message));
    }
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    while (true) {
      final dg = _socket?.receive();
      if (dg == null) return;
      if (dg.port != port || dg.address.address != _address.address) continue;
      if (dg.data.isEmpty) continue;
      _lastReceive = DateTime.now();
      try {
        _handleDatagram(dg.data);
      } catch (_) {
        // Повреждённая датаграмма: игнорируется, потерянные данные будут запрошены через NACK.
      }
    }
  }

  void _handleDatagram(Uint8List data) {
    final id = data[0];
    if (id & 0x80 != 0) {
      if (_offlineState < 3) return;
      if (id & 0x40 != 0) {
        _handleAck(BinaryReader(data, 1));
      } else if (id & 0x20 != 0) {
        _handleNack(BinaryReader(data, 1));
      } else {
        _handleFrameSet(BinaryReader(data, 1));
      }
      return;
    }
    final r = BinaryReader(data, 1);
    switch (id) {
      case RakId.openConnectionReply1:
        if (_offlineState != 1) return;
        r.skip(16);
        r.longBE();
        final security = r.boolean();
        // Новые серверы присылают cookie (защита от подмены адреса); его нужно вернуть в запросе 2.
        // Полноценная RakNet-безопасность с ключами передаёт больше данных и не поддерживается.
        if (security && r.remaining != 6) {
          _failConnect('Сервер требует RakNet-безопасность с ключами, она не поддерживается');
          return;
        }
        _cookie = security ? r.intBE() : null;
        _mtu = min(r.shortBE(), 1492);
        if (!_offlineStep!.isCompleted) _offlineStep!.complete();
        break;
      case RakId.openConnectionReply2:
        if (_offlineState != 2) return;
        r.skip(16);
        r.longBE();
        _skipAddress(r);
        _mtu = min(r.shortBE(), _mtu);
        if (!_offlineStep!.isCompleted) _offlineStep!.complete();
        break;
      case RakId.incompatibleProtocol:
        final serverProtocol = r.byte();
        if (serverProtocol != rakProtocol) {
          rakProtocol = serverProtocol;
        } else {
          _failConnect('Несовместимая версия RakNet');
        }
        break;
      case RakId.alreadyConnected:
        _failConnect('Сервер считает, что вы уже подключены. Повторите через несколько секунд');
        break;
      case RakId.noFreeIncomingConnections:
        _failConnect('На сервере нет свободных мест');
        break;
      case RakId.connectionBanned:
        _failConnect('Ваш IP заблокирован на сервере');
        break;
      case RakId.ipRecentlyConnected:
        _failConnect('Слишком частые подключения. Подождите и повторите');
        break;
    }
  }

  void _handleAck(BinaryReader r) {
    for (final seq in _readRanges(r)) {
      _recovery.remove(seq);
    }
  }

  void _handleNack(BinaryReader r) {
    for (final seq in _readRanges(r)) {
      final dg = _recovery.remove(seq);
      if (dg != null) {
        _sendDatagram(dg.frames);
      }
    }
  }

  List<int> _readRanges(BinaryReader r) {
    final count = r.shortBE();
    final result = <int>[];
    for (var i = 0; i < count; i++) {
      final single = r.boolean();
      final start = r.triadLE();
      final end = single ? start : r.triadLE();
      for (var s = start; s <= end && s - start < 4096; s++) {
        result.add(s);
      }
    }
    return result;
  }

  void _handleFrameSet(BinaryReader r) {
    final seq = r.triadLE();
    if (_receivedSeqWindow.contains(seq) || (_highestSeq - seq) > 2048) {
      _ackQueue.add(seq);
      return;
    }
    _receivedSeqWindow.add(seq);
    if (_receivedSeqWindow.length > 4096) {
      _receivedSeqWindow.removeWhere((s) => s < _highestSeq - 2048);
    }
    _ackQueue.add(seq);
    _nackQueue.remove(seq);
    if (seq > _highestSeq) {
      for (var missing = _highestSeq + 1; missing < seq; missing++) {
        if (!_receivedSeqWindow.contains(missing)) _nackQueue.add(missing);
      }
      _highestSeq = seq;
    }
    while (!r.eof) {
      _handleFrame(_Frame.read(r));
    }
  }

  void _handleFrame(_Frame f) {
    if (Reliability.isReliable(f.reliability)) {
      final idx = f.messageIndex;
      if (idx < _reliableWindowStart || _reliableReceived.contains(idx)) return;
      _reliableReceived.add(idx);
      while (_reliableReceived.remove(_reliableWindowStart)) {
        _reliableWindowStart++;
      }
    }

    if (f.split) {
      final parts = _splits.putIfAbsent(f.splitId, () => {});
      _splitCounts[f.splitId] = f.splitCount;
      if (f.splitCount > 4096 || f.splitIndex >= f.splitCount) return;
      parts[f.splitIndex] = f.body;
      if (parts.length < f.splitCount) return;
      final b = BytesBuilder(copy: false);
      for (var i = 0; i < f.splitCount; i++) {
        b.add(parts[i]!);
      }
      _splits.remove(f.splitId);
      _splitCounts.remove(f.splitId);
      _handleOrdered(
        _Frame(
          reliability: f.reliability,
          body: b.takeBytes(),
          orderIndex: f.orderIndex,
          orderChannel: f.orderChannel,
          sequenceIndex: f.sequenceIndex,
        ),
      );
      return;
    }
    _handleOrdered(f);
  }

  void _handleOrdered(_Frame f) {
    if (!Reliability.isOrdered(f.reliability)) {
      _handlePacket(f.body);
      return;
    }
    final ch = _channels[f.orderChannel & 31];
    if (Reliability.isSequenced(f.reliability)) {
      if (f.sequenceIndex > ch.highestSequence) {
        ch.highestSequence = f.sequenceIndex;
        _handlePacket(f.body);
      }
      return;
    }
    if (f.orderIndex < ch.expected) return;
    ch.pending[f.orderIndex] = f.body;
    _drainChannel(ch);
  }

  void _drainChannel(_OrderChannel ch) {
    while (ch.pending.containsKey(ch.expected)) {
      final body = ch.pending.remove(ch.expected)!;
      ch.expected++;
      _handlePacket(body);
    }
    ch.gapSince = ch.pending.isEmpty ? null : (ch.gapSince ?? DateTime.now());
  }

  void _checkOrderGaps() {
    final now = DateTime.now();
    for (final ch in _channels) {
      final since = ch.gapSince;
      if (since == null || ch.pending.isEmpty) continue;
      // Индекс так и не пришёл (некоторые серверы начинают нумерацию не с нуля) — переходим к следующему имеющемуся.
      if (now.difference(since) > const Duration(milliseconds: 700)) {
        ch.expected = ch.pending.keys.reduce(min);
        ch.gapSince = null;
        _drainChannel(ch);
      }
    }
  }

  void _handlePacket(Uint8List body) {
    if (body.isEmpty) return;
    final id = body[0];
    final r = BinaryReader(body, 1);
    switch (id) {
      case RakId.connectedPing:
        final time = r.longBE();
        final w = BinaryWriter()
          ..byte(RakId.connectedPong)
          ..longBE(time)
          ..longBE(DateTime.now().millisecondsSinceEpoch);
        _queue(w.take(), Reliability.unreliable);
        return;
      case RakId.connectedPong:
        final sent = r.longBE();
        final now = DateTime.now().millisecondsSinceEpoch;
        if (sent > 0 && sent <= now) latencyMs = now - sent;
        return;
      case RakId.connectionRequestAccepted:
        if (_connected) return;
        final w = BinaryWriter()..byte(RakId.newIncomingConnection);
        _writeAddress(w, _address, port);
        for (var i = 0; i < 10; i++) {
          _writeAddress(w, InternetAddress('0.0.0.0'), 0);
        }
        w
          ..longBE(DateTime.now().millisecondsSinceEpoch)
          ..longBE(DateTime.now().millisecondsSinceEpoch);
        _queue(w.take(), Reliability.reliableOrdered);
        _connected = true;
        _flush();
        if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
          _connectCompleter!.complete();
        }
        return;
      case RakId.connectionAttemptFailed:
        _failConnect('Сервер отклонил подключение');
        return;
      case RakId.disconnectionNotification:
        _failConnect('Сервер закрыл соединение');
        _close('Сервер закрыл соединение', notifyServer: false);
        return;
    }
    if (id >= 0x80 && _connected) {
      onPacket?.call(body);
    }
  }

  void _queue(Uint8List body, int reliability) {
    final maxBody = _mtu - _udpOverhead - _datagramHeader - 20;
    final ordered = Reliability.isOrdered(reliability);
    final orderIndex = ordered ? _orderIndex++ : 0;
    if (body.length <= maxBody) {
      _outQueue.add(_Frame(
        reliability: reliability,
        body: body,
        messageIndex: Reliability.isReliable(reliability) ? _messageIndex++ : 0,
        orderIndex: orderIndex,
      ));
      return;
    }
    // Большие пакеты делятся на части; разбитые пакеты должны быть надёжными.
    final splitReliability = reliability == Reliability.unreliable
        ? Reliability.reliable
        : (reliability == Reliability.unreliableSequenced ? Reliability.reliableSequenced : reliability);
    final chunk = maxBody - 10;
    final count = (body.length + chunk - 1) ~/ chunk;
    final id = _splitId++ & 0xffff;
    for (var i = 0; i < count; i++) {
      final start = i * chunk;
      final end = min(start + chunk, body.length);
      _outQueue.add(_Frame(
        reliability: splitReliability,
        body: Uint8List.sublistView(body, start, end),
        messageIndex: _messageIndex++,
        orderIndex: orderIndex,
        split: true,
        splitCount: count,
        splitId: id,
        splitIndex: i,
      ));
    }
  }

  void _flush() {
    if (_outQueue.isEmpty || _socket == null) return;
    final maxSize = _mtu - _udpOverhead - _datagramHeader;
    var batch = <_Frame>[];
    var size = 0;
    for (final f in _outQueue) {
      if (batch.isNotEmpty && size + f.size > maxSize) {
        _sendDatagram(batch);
        batch = <_Frame>[];
        size = 0;
      }
      batch.add(f);
      size += f.size;
    }
    if (batch.isNotEmpty) _sendDatagram(batch);
    _outQueue.clear();
  }

  void _sendDatagram(List<_Frame> frames) {
    final seq = _sendSeq++ & 0xffffff;
    final w = BinaryWriter()
      ..byte(0x84)
      ..triadLE(seq);
    for (final f in frames) {
      f.write(w);
    }
    _socket?.send(w.take(), _address, port);
    final reliableFrames = frames.where((f) => Reliability.isReliable(f.reliability)).toList();
    if (reliableFrames.isNotEmpty) {
      _recovery[seq] = _SentDatagram(reliableFrames, DateTime.now());
    }
  }

  void _sendAckNack(int id, Set<int> seqs) {
    if (seqs.isEmpty) return;
    final sorted = seqs.toList()..sort();
    seqs.clear();
    final records = BinaryWriter();
    var count = 0;
    var start = sorted.first;
    var last = sorted.first;
    void emit() {
      if (start == last) {
        records
          ..byte(1)
          ..triadLE(start);
      } else {
        records
          ..byte(0)
          ..triadLE(start)
          ..triadLE(last);
      }
      count++;
    }

    for (var i = 1; i < sorted.length; i++) {
      final s = sorted[i];
      if (s == last + 1) {
        last = s;
      } else {
        emit();
        start = last = s;
      }
    }
    emit();
    final w = BinaryWriter()
      ..byte(id)
      ..shortBE(count)
      ..bytes(records.take());
    _socket?.send(w.take(), _address, port);
  }

  void _update() {
    if (_closed) return;
    final now = DateTime.now();
    if (now.difference(_lastReceive) > _timeout) {
      _failConnect('Сервер перестал отвечать');
      _close('Сервер перестал отвечать (таймаут)', notifyServer: false);
      return;
    }
    _sendAckNack(RakId.ack, _ackQueue);
    _sendAckNack(RakId.nack, _nackQueue);
    _checkOrderGaps();
    final stale = _recovery.entries.where((e) => now.difference(e.value.sentAt) > _resendAfter).toList();
    for (final e in stale) {
      _recovery.remove(e.key);
      _sendDatagram(e.value.frames);
    }
    _flush();
  }

  /// Закрыть соединение с уведомлением сервера.
  void close([String reason = 'Отключено']) => _close(reason, notifyServer: true);

  void _close(String reason, {required bool notifyServer}) {
    if (_closed) return;
    if (notifyServer && _connected) {
      _queue(Uint8List.fromList(const [RakId.disconnectionNotification]), Reliability.reliableOrdered);
      _flush();
    }
    final wasConnected = _connected;
    _failConnect(reason);
    _shutdown();
    if (wasConnected) onDisconnect?.call(reason);
  }

  void _shutdown() {
    _closed = true;
    _connected = false;
    _tick?.cancel();
    _pingTimer?.cancel();
    _sub?.cancel();
    _socket?.close();
    _socket = null;
  }
}
