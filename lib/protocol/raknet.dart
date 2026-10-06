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
  static const unconnectedPingOpenConnections = 0x02;
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
}

class Reliability {
  static const unreliable = 0;
  static const unreliableSequenced = 1;
  static const reliable = 2;
  static const reliableOrdered = 3;
  static const reliableSequenced = 4;
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
  final int messageIndex;
  final int sequenceIndex;
  final int orderIndex;
  final int orderChannel;
  final bool split;
  final int splitCount;
  final int splitId;
  final int splitIndex;

  int get size {
    var size = 3 + body.length;
    if (Reliability.isReliable(reliability)) size += 3;
    if (Reliability.isSequenced(reliability)) size += 3;
    if (Reliability.isOrdered(reliability)) size += 4;
    if (split) size += 10;
    return size;
  }

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
    final messageIndex = Reliability.isReliable(reliability) ? r.triadLE() : 0;
    final sequenceIndex = Reliability.isSequenced(reliability) ? r.triadLE() : 0;
    var orderIndex = 0, orderChannel = 0;
    if (Reliability.isOrdered(reliability)) {
      orderIndex = r.triadLE();
      orderChannel = r.byte();
    }
    var splitCount = 0, splitId = 0, splitIndex = 0;
    if (split) {
      splitCount = r.intBE();
      splitId = r.shortBE();
      splitIndex = r.intBE();
    }
    return _Frame(
      reliability: reliability,
      body: Uint8List.fromList(r.bytes(length)),
      messageIndex: messageIndex,
      sequenceIndex: sequenceIndex,
      orderIndex: orderIndex,
      orderChannel: orderChannel,
      split: split,
      splitCount: splitCount,
      splitId: splitId,
      splitIndex: splitIndex,
    );
  }
}

class _SentDatagram {
  _SentDatagram(this.frames, this.sentAt);

  final List<_Frame> frames;
  final DateTime sentAt;
}

class _OrderChannel {
  int expected = 0;
  final Map<int, Uint8List> pending = {};
  DateTime? gapSince;
  int highestSequence = -1;
}

/// Надёжная доставка RakNet для одного соединения: датаграммы, ACK/NACK,
/// повторная отправка, сборка разбитых пакетов и упорядочивание. Общая для клиента и сервера.
class RakConnection {
  RakConnection({required this.sendDatagram, required this.onMessage, required this.mtu});

  final void Function(Uint8List datagram) sendDatagram;

  /// Сообщение после сборки и упорядочивания (первый байт — ID).
  final void Function(Uint8List body) onMessage;
  final int mtu;

  static const _udpOverhead = 28;
  static const _datagramHeader = 4;
  static const _resendAfter = Duration(milliseconds: 1500);

  DateTime lastReceive = DateTime.now();

  int _sendSeq = 0;
  int _messageIndex = 0;
  int _orderIndex = 0;
  int _splitId = 0;
  final List<_Frame> _outQueue = [];
  final Map<int, _SentDatagram> _recovery = {};

  final Set<int> _ackQueue = {};
  final Set<int> _nackQueue = {};
  int _highestSeq = -1;
  final Set<int> _receivedSeqWindow = {};
  int _reliableWindowStart = 0;
  final Set<int> _reliableReceived = {};
  final Map<int, Map<int, Uint8List>> _splits = {};
  final List<_OrderChannel> _channels = List.generate(32, (_) => _OrderChannel());

  /// Датаграмма с ID 0x80..0xff.
  void handleDatagram(Uint8List data) {
    lastReceive = DateTime.now();
    final id = data[0];
    final r = BinaryReader(data, 1);
    if (id & 0x40 != 0) {
      for (final seq in _readRanges(r)) {
        _recovery.remove(seq);
      }
    } else if (id & 0x20 != 0) {
      for (final seq in _readRanges(r)) {
        final dg = _recovery.remove(seq);
        if (dg != null) _sendFrames(dg.frames);
      }
    } else {
      _handleFrameSet(r);
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
    _ackQueue.add(seq);
    if (_receivedSeqWindow.contains(seq) || (_highestSeq - seq) > 2048) return;
    _receivedSeqWindow.add(seq);
    if (_receivedSeqWindow.length > 4096) {
      _receivedSeqWindow.removeWhere((s) => s < _highestSeq - 2048);
    }
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
      if (f.splitCount > 4096 || f.splitIndex >= f.splitCount) return;
      final parts = _splits.putIfAbsent(f.splitId, () => {});
      parts[f.splitIndex] = f.body;
      if (parts.length < f.splitCount) return;
      final b = BytesBuilder(copy: false);
      for (var i = 0; i < f.splitCount; i++) {
        b.add(parts[i]!);
      }
      _splits.remove(f.splitId);
      _handleOrdered(_Frame(
        reliability: f.reliability,
        body: b.takeBytes(),
        orderIndex: f.orderIndex,
        orderChannel: f.orderChannel,
        sequenceIndex: f.sequenceIndex,
      ));
      return;
    }
    _handleOrdered(f);
  }

  void _handleOrdered(_Frame f) {
    if (!Reliability.isOrdered(f.reliability)) {
      if (f.body.isNotEmpty) onMessage(f.body);
      return;
    }
    final ch = _channels[f.orderChannel & 31];
    if (Reliability.isSequenced(f.reliability)) {
      if (f.sequenceIndex > ch.highestSequence) {
        ch.highestSequence = f.sequenceIndex;
        if (f.body.isNotEmpty) onMessage(f.body);
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
      if (body.isNotEmpty) onMessage(body);
    }
    ch.gapSince = ch.pending.isEmpty ? null : (ch.gapSince ?? DateTime.now());
  }

  /// Поставить сообщение в очередь отправки.
  void queue(Uint8List body, int reliability) {
    final maxBody = mtu - _udpOverhead - _datagramHeader - 20;
    final orderIndex = Reliability.isOrdered(reliability) ? _orderIndex++ : 0;
    if (body.length <= maxBody) {
      _outQueue.add(_Frame(
        reliability: reliability,
        body: body,
        messageIndex: Reliability.isReliable(reliability) ? _messageIndex++ : 0,
        orderIndex: orderIndex,
      ));
      return;
    }
    // Большие сообщения делятся на части; части всегда надёжные.
    final splitReliability = Reliability.isReliable(reliability)
        ? reliability
        : (Reliability.isOrdered(reliability) ? Reliability.reliableOrdered : Reliability.reliable);
    final chunk = maxBody - 10;
    final count = (body.length + chunk - 1) ~/ chunk;
    final id = _splitId++ & 0xffff;
    for (var i = 0; i < count; i++) {
      final start = i * chunk;
      _outQueue.add(_Frame(
        reliability: splitReliability,
        body: Uint8List.sublistView(body, start, min(start + chunk, body.length)),
        messageIndex: _messageIndex++,
        orderIndex: orderIndex,
        split: true,
        splitCount: count,
        splitId: id,
        splitIndex: i,
      ));
    }
  }

  /// Отправить накопленные сообщения.
  void flush() {
    if (_outQueue.isEmpty) return;
    final maxSize = mtu - _udpOverhead - _datagramHeader;
    var batch = <_Frame>[];
    var size = 0;
    for (final f in _outQueue) {
      if (batch.isNotEmpty && size + f.size > maxSize) {
        _sendFrames(batch);
        batch = <_Frame>[];
        size = 0;
      }
      batch.add(f);
      size += f.size;
    }
    if (batch.isNotEmpty) _sendFrames(batch);
    _outQueue.clear();
  }

  void _sendFrames(List<_Frame> frames) {
    final seq = _sendSeq++ & 0xffffff;
    final w = BinaryWriter()
      ..byte(0x84)
      ..triadLE(seq);
    for (final f in frames) {
      f.write(w);
    }
    sendDatagram(w.take());
    final reliableFrames = frames.where((f) => Reliability.isReliable(f.reliability)).toList();
    if (reliableFrames.isNotEmpty) _recovery[seq] = _SentDatagram(reliableFrames, DateTime.now());
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
    sendDatagram(w.take());
  }

  /// Периодическая работа: подтверждения, повторы, пропуски в упорядочивании.
  void update() {
    _sendAckNack(0xc0, _ackQueue);
    _sendAckNack(0xa0, _nackQueue);
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
    final stale = _recovery.entries.where((e) => now.difference(e.value.sentAt) > _resendAfter).toList();
    for (final e in stale) {
      _recovery.remove(e.key);
      _sendFrames(e.value.frames);
    }
    flush();
  }
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
  });

  final String motd;
  final int protocol;
  final String version;
  final int online;
  final int max;
  final int latencyMs;

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

int randomLong(Random rnd) => (rnd.nextInt(1 << 32) << 32) | rnd.nextInt(1 << 32);

void writeRakAddress(BinaryWriter w, InternetAddress address, int port) {
  w.byte(4);
  for (final b in address.rawAddress) {
    w.byte(~b & 0xff);
  }
  w.shortBE(port);
}

void skipRakAddress(BinaryReader r) {
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
  final guid = randomLong(Random.secure());
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
    } on FormatException catch (e) {
      if (!completer.isCompleted) completer.completeError(RakNetException('Некорректный ответ сервера: ${e.message}'));
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
  RakNetClient({required this.host, required this.port, this.onPacket, this.onDisconnect});

  final String host;
  final int port;
  int rakProtocol = 8;

  /// Пакет прикладного уровня (обычно начинается с 0xFE).
  void Function(Uint8List payload)? onPacket;

  /// Соединение закрыто (по инициативе сервера, по таймауту или локально).
  void Function(String reason)? onDisconnect;

  static const _mtuCandidates = [1492, 1200, 576];
  static const _udpOverhead = 28;
  static const _timeout = Duration(seconds: 20);

  final Random _rnd = Random.secure();
  late final int _guid = randomLong(_rnd);

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
  RakConnection? _conn;

  Timer? _tick;
  Timer? _pingTimer;

  int latencyMs = 0;

  bool get isConnected => _connected;

  Future<void> connect({Duration timeout = const Duration(seconds: 15)}) async {
    _address = await resolveHost(host);
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sub = _socket!.listen(_onSocketEvent);
    _connectCompleter = Completer<void>();

    final watchdog = Timer(timeout, () => _failConnect('Время ожидания подключения истекло'));
    try {
      await _openConnection();
      final conn = RakConnection(
        sendDatagram: (d) => _socket?.send(d, _address, port),
        onMessage: _handleMessage,
        mtu: _mtu,
      );
      _conn = conn;
      _tick = Timer.periodic(const Duration(milliseconds: 20), (_) => _update());
      final w = BinaryWriter()
        ..byte(RakId.connectionRequest)
        ..longBE(_guid)
        ..longBE(DateTime.now().millisecondsSinceEpoch)
        ..byte(0);
      conn.queue(w.take(), Reliability.reliable);
      conn.flush();
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
        _offlineState = 1;
        _offlineStep = Completer<void>();
        final w = BinaryWriter()
          ..byte(RakId.openConnectionRequest1)
          ..bytes(rakMagic)
          ..byte(rakProtocol);
        w.bytes(Uint8List(mtu - _udpOverhead - w.length));
        _socket!.send(w.take(), _address, port);
        if (await _waitStep(const Duration(milliseconds: 600))) {
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
      writeRakAddress(w, _address, port);
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
      await Future.any([_offlineStep!.future, _connectCompleter!.future]).timeout(d);
      if (_connectCompleter!.isCompleted && !_offlineStep!.isCompleted) {
        await _connectCompleter!.future;
      }
      return _offlineStep!.isCompleted;
    } on TimeoutException {
      return false;
    }
  }

  void _sendConnectedPing() {
    final w = BinaryWriter()
      ..byte(RakId.connectedPing)
      ..longBE(DateTime.now().millisecondsSinceEpoch);
    _conn?.queue(w.take(), Reliability.unreliable);
  }

  /// Отправить прикладной пакет.
  void send(Uint8List payload, {int reliability = Reliability.reliableOrdered}) {
    final conn = _conn;
    if (!_connected || _closed || conn == null) return;
    conn.queue(payload, reliability);
    conn.flush();
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
      if (dg.port != port || dg.address.address != _address.address || dg.data.isEmpty) continue;
      try {
        _handleDatagram(dg.data);
      } on FormatException {
        // Повреждённая датаграмма: потерянные данные будут запрошены через NACK.
      } on RakNetException {
        // Неизвестный формат адреса в служебном пакете.
      }
    }
  }

  void _handleDatagram(Uint8List data) {
    final id = data[0];
    if (id & 0x80 != 0) {
      if (_offlineState >= 3) _conn?.handleDatagram(data);
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
        skipRakAddress(r);
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

  void _handleMessage(Uint8List body) {
    final id = body[0];
    final r = BinaryReader(body, 1);
    switch (id) {
      case RakId.connectedPing:
        final w = BinaryWriter()
          ..byte(RakId.connectedPong)
          ..longBE(r.longBE())
          ..longBE(DateTime.now().millisecondsSinceEpoch);
        _conn?.queue(w.take(), Reliability.unreliable);
        return;
      case RakId.connectedPong:
        final sent = r.longBE();
        final now = DateTime.now().millisecondsSinceEpoch;
        if (sent > 0 && sent <= now) latencyMs = now - sent;
        return;
      case RakId.connectionRequestAccepted:
        if (_connected) return;
        final w = BinaryWriter()..byte(RakId.newIncomingConnection);
        writeRakAddress(w, _address, port);
        for (var i = 0; i < 10; i++) {
          writeRakAddress(w, InternetAddress('0.0.0.0'), 0);
        }
        w
          ..longBE(DateTime.now().millisecondsSinceEpoch)
          ..longBE(DateTime.now().millisecondsSinceEpoch);
        _conn?.queue(w.take(), Reliability.reliableOrdered);
        _conn?.flush();
        _connected = true;
        if (_connectCompleter != null && !_connectCompleter!.isCompleted) _connectCompleter!.complete();
        return;
      case RakId.connectionAttemptFailed:
        _failConnect('Сервер отклонил подключение');
        return;
      case RakId.disconnectionNotification:
        _close('Сервер закрыл соединение', notifyServer: false);
        return;
    }
    if (id >= 0x80 && _connected) onPacket?.call(body);
  }

  void _update() {
    if (_closed) return;
    final conn = _conn;
    if (conn == null) return;
    if (DateTime.now().difference(conn.lastReceive) > _timeout) {
      _close('Сервер перестал отвечать (таймаут)', notifyServer: false);
      return;
    }
    conn.update();
  }

  /// Закрыть соединение с уведомлением сервера.
  void close([String reason = 'Отключено']) => _close(reason, notifyServer: true);

  void _close(String reason, {required bool notifyServer}) {
    if (_closed) return;
    if (notifyServer && _connected) {
      _conn?.queue(Uint8List.fromList(const [RakId.disconnectionNotification]), Reliability.reliableOrdered);
      _conn?.flush();
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
