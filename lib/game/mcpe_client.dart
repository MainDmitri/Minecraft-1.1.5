import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/binary.dart';
import '../protocol/crypto.dart';
import '../protocol/login.dart';
import '../protocol/packets.dart';
import '../protocol/raknet.dart';
import '../protocol/skin.dart';
import 'commands.dart';
import 'lang.dart';

enum ConnectionPhase { idle, connecting, loggingIn, spawning, playing, disconnected }

enum ChatKind { chat, system, local, error }

class ChatLine {
  ChatLine(this.text, this.kind) : time = DateTime.now();

  final String text;
  final ChatKind kind;
  final DateTime time;
}

class OnlinePlayer {
  OnlinePlayer(this.uuid, this.uniqueId, this.name);

  final String uuid;
  final int uniqueId;
  final String name;
  Vec3? position;
}

/// Сообщение на экране (заголовок, подзаголовок, всплывающая подсказка).
class ScreenMessage {
  ScreenMessage(this.text, this.until);

  final String text;
  final DateTime until;

  bool get visible => DateTime.now().isBefore(until);
}

class TransferTarget {
  TransferTarget(this.host, this.port);

  final String host;
  final int port;
}

/// Сетевой клиент MCPE 1.1.x (протокол 113).
class McpeClient {
  McpeClient({
    required this.host,
    required this.port,
    required this.nickname,
    required this.skin,
    required this.deviceModel,
    required this.languageCode,
    this.chunkRadius = 5,
  });

  final String host;
  final int port;
  final String nickname;
  final SkinData skin;
  final String deviceModel;
  final String languageCode;
  final int chunkRadius;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Срабатывает при любом изменении состояния.
  Stream<void> get changes => _changes.stream;

  RakNetClient? _rak;
  PacketCipher? _cipher;
  LoginData? _login;
  Completer<void>? _spawned;

  ConnectionPhase phase = ConnectionPhase.idle;
  String? disconnectReason;
  TransferTarget? transferTarget;
  bool encrypted = false;

  final List<ChatLine> chat = [];
  static const _chatLimit = 500;

  final Map<String, OnlinePlayer> players = {};
  final Map<int, int> _runtimeToUnique = {};
  final CommandRegistry commands = CommandRegistry();

  StartGameData? world;
  int? _runtimeId;
  Vec3? position;
  int gamemode = 0;
  int difficulty = 0;
  int worldTime = 0;
  double health = 20;
  double maxHealth = 20;
  double food = 20;
  int xpLevel = 0;
  bool dead = false;

  ScreenMessage? title;
  ScreenMessage? subtitle;
  ScreenMessage? actionBar;
  ScreenMessage? popup;
  ScreenMessage? tip;
  int _titleFadeIn = 10;
  int _titleStay = 70;
  int _titleFadeOut = 20;

  int get latencyMs => _rak?.latencyMs ?? 0;

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _addChat(String text, ChatKind kind) {
    chat.add(ChatLine(text, kind));
    if (chat.length > _chatLimit) chat.removeRange(0, chat.length - _chatLimit);
    _notify();
  }

  /// Подключение и вход. Завершается, когда игрок появился в мире.
  Future<void> connect() async {
    phase = ConnectionPhase.connecting;
    _notify();
    _spawned = Completer<void>();
    final rak = RakNetClient(host: host, port: port);
    _rak = rak;
    rak.onPacket = _onRakPacket;
    rak.onDisconnect = (reason) => _finish(reason);
    try {
      await rak.connect();
    } on RakNetException catch (e) {
      _finish(e.message);
      rethrow;
    } on SocketException catch (e) {
      final reason = 'Ошибка сети: ${e.message}';
      _finish(reason);
      throw RakNetException(reason);
    }
    phase = ConnectionPhase.loggingIn;
    _notify();
    _login = createLogin(
      nickname: nickname,
      serverAddress: '$host:$port',
      skin: skin,
      deviceModel: deviceModel,
      languageCode: languageCode,
    );
    _sendPacket(_login!.packet);
    await _spawned!.future.timeout(const Duration(seconds: 40), onTimeout: () {
      const reason = 'Сервер не завершил вход за 40 секунд';
      disconnect(reason);
      throw RakNetException(reason);
    });
  }

  void _finish(String reason) {
    if (phase == ConnectionPhase.disconnected) return;
    phase = ConnectionPhase.disconnected;
    disconnectReason = reason;
    if (_spawned != null && !_spawned!.isCompleted) {
      _spawned!.completeError(RakNetException(reason));
    }
    _addChat(reason, ChatKind.error);
  }

  void disconnect([String reason = 'Вы отключились']) {
    _rak?.close(reason);
    _finish(reason);
  }

  void dispose() {
    disconnect('Сессия закрыта');
    _changes.close();
  }

  // ---------- Пакетный уровень ----------

  void _sendPacket(Uint8List packet) {
    final rak = _rak;
    if (rak == null || !rak.isConnected) return;
    final batch = BinaryWriter()..byteArray(packet);
    var data = Uint8List.fromList(ZLibCodec(level: 7).encode(batch.take()));
    final cipher = _cipher;
    if (cipher != null) data = cipher.encrypt(data);
    final out = Uint8List(data.length + 1)
      ..[0] = 0xfe
      ..setRange(1, data.length + 1, data);
    rak.send(out);
  }

  void _onRakPacket(Uint8List payload) {
    if (payload[0] != 0xfe) return;
    final List<Uint8List> packets = [];
    try {
      var data = Uint8List.sublistView(payload, 1);
      final cipher = _cipher;
      if (cipher != null) data = cipher.decrypt(data);
      final r = BinaryReader(Uint8List.fromList(ZLibCodec().decode(data)));
      while (!r.eof) {
        packets.add(r.byteArray());
      }
    } on FormatException catch (e) {
      disconnect('Ошибка протокола: ${e.message}');
      return;
    }
    for (final packet in packets) {
      if (packet.isEmpty) continue;
      try {
        _handlePacket(packet[0], BinaryReader(packet, 1));
      } on FormatException catch (e) {
        _addChat('Пропущен пакет 0x${packet[0].toRadixString(16)}: ${e.message}', ChatKind.error);
      }
    }
  }

  void _handlePacket(int id, BinaryReader r) {
    switch (id) {
      case PacketId.playStatus:
        _onPlayStatus(r.intBE());
        break;
      case PacketId.serverToClientHandshake:
        _onHandshake(r);
        break;
      case PacketId.disconnect:
        final hide = r.boolean();
        final message = hide || r.eof ? 'Сервер закрыл соединение' : translate(r.string(), const []);
        _rak?.close(message);
        _finish(message);
        break;
      case PacketId.resourcePacksInfo:
        _sendPacket(buildResourcePackResponse(3, const []));
        break;
      case PacketId.resourcePackStack:
        _sendPacket(buildResourcePackResponse(4, const []));
        break;
      case PacketId.startGame:
        _onStartGame(StartGameData.read(r));
        break;
      case PacketId.text:
        _onText(TextMessage.read(r));
        break;
      case PacketId.setTime:
        worldTime = r.varint();
        _notify();
        break;
      case PacketId.addPlayer:
        r.bytes(16);
        final name = r.string();
        final uniqueId = r.varint();
        final runtimeId = r.uvarint();
        final pos = Vec3.read(r);
        _runtimeToUnique[runtimeId] = uniqueId;
        for (final p in players.values) {
          if (p.uniqueId == uniqueId || (p.uniqueId == 0 && p.name == name)) p.position = pos;
        }
        _notify();
        break;
      case PacketId.removeEntity:
        final uniqueId = r.varint();
        _runtimeToUnique.removeWhere((_, u) => u == uniqueId);
        for (final p in players.values) {
          if (p.uniqueId == uniqueId) p.position = null;
        }
        _notify();
        break;
      case PacketId.movePlayer:
        final move = MovePlayerData.read(r);
        if (move.runtimeIdRaw == _runtimeId) {
          position = move.position;
        } else {
          final uniqueId = _runtimeToUnique[move.runtimeIdRaw];
          for (final p in players.values) {
            if (uniqueId != null && p.uniqueId == uniqueId) p.position = move.position;
          }
        }
        _notify();
        break;
      case PacketId.updateAttributes:
        final runtimeId = r.uvarint();
        if (runtimeId == _runtimeId) _onAttributes(readAttributes(r));
        break;
      case PacketId.respawn:
        position = Vec3.read(r);
        _notify();
        break;
      case PacketId.setDifficulty:
        difficulty = r.uvarint();
        _notify();
        break;
      case PacketId.setPlayerGameType:
        gamemode = r.varint();
        _notify();
        break;
      case PacketId.playerList:
        _onPlayerList(PlayerListUpdate.read(r));
        break;
      case PacketId.availableCommands:
        try {
          commands.load(r.string());
        } on FormatException {
          _addChat('Сервер прислал некорректный список команд', ChatKind.error);
        }
        _notify();
        break;
      case PacketId.transfer:
        final targetHost = r.string();
        final targetPort = r.shortLE();
        transferTarget = TransferTarget(targetHost, targetPort);
        final reason = 'Сервер перенаправляет на $targetHost:$targetPort';
        _rak?.close(reason);
        _finish(reason);
        break;
      case PacketId.setTitle:
        _onTitle(TitleData.read(r));
        break;
    }
  }

  void _onPlayStatus(int status) {
    switch (status) {
      case PlayStatus.loginSuccess:
        _addChat('Вход выполнен, загрузка мира…', ChatKind.local);
        break;
      case PlayStatus.playerSpawn:
        phase = ConnectionPhase.playing;
        _addChat('Вы в игре', ChatKind.local);
        if (_spawned != null && !_spawned!.isCompleted) _spawned!.complete();
        break;
      case PlayStatus.loginFailedClient:
        disconnect('Сервер работает на более новой версии, чем MCPE 1.1.x');
        break;
      case PlayStatus.loginFailedServer:
        disconnect('Сервер работает на более старой версии, чем MCPE 1.1.x');
        break;
      case PlayStatus.loginFailedInvalidTenant:
      case PlayStatus.loginFailedVanillaEdu:
      case PlayStatus.loginFailedEduVanilla:
        disconnect('Сервер предназначен для Education Edition');
        break;
    }
  }

  void _onHandshake(BinaryReader r) {
    final login = _login;
    if (login == null) return;
    try {
      final first = r.string();
      Uint8List serverKeyDer;
      Uint8List salt;
      if (first.contains('.')) {
        // Формат JWT: ключ сервера в заголовке x5u, соль в поле salt.
        final parts = first.split('.');
        final header = jsonDecode(utf8.decode(b64DecodeLoose(parts[0]))) as Map;
        final payload = jsonDecode(utf8.decode(b64DecodeLoose(parts[1]))) as Map;
        serverKeyDer = b64DecodeLoose(header['x5u'] as String);
        salt = b64DecodeLoose(payload['salt'] as String);
      } else {
        // Формат протокола 113: две строки — публичный ключ и соль.
        serverKeyDer = b64DecodeLoose(first);
        salt = b64DecodeLoose(r.string());
      }
      final serverKey = IdentityKey.decodePublicKeyDer(serverKeyDer);
      final secret = login.key.sharedSecret(serverKey);
      _cipher = PacketCipher.fromHandshake(salt, secret);
      encrypted = true;
      _sendPacket(buildClientToServerHandshake());
      _addChat('Соединение зашифровано', ChatKind.local);
    } on FormatException catch (e) {
      disconnect('Не удалось включить шифрование: ${e.message}');
    }
  }

  void _onStartGame(StartGameData data) {
    world = data;
    _runtimeId = data.runtimeIdRaw;
    position = data.position;
    gamemode = data.playerGamemode;
    difficulty = data.difficulty;
    worldTime = data.time;
    phase = ConnectionPhase.spawning;
    _sendPacket(buildRequestChunkRadius(chunkRadius));
    _notify();
  }

  void _onText(TextMessage m) {
    switch (m.type) {
      case TextType.chat:
        _addChat(m.source.isEmpty ? m.message : '<${m.source}> ${m.message}', ChatKind.chat);
        break;
      case TextType.whisper:
        _addChat('${m.source} шепчет вам: ${m.message}', ChatKind.chat);
        break;
      case TextType.announcement:
        _addChat('[${m.source}] ${m.message}', ChatKind.chat);
        break;
      case TextType.translation:
        _addChat(translate(m.message, m.parameters), ChatKind.system);
        break;
      case TextType.popup:
        popup = ScreenMessage(translate(m.message, const []), DateTime.now().add(const Duration(seconds: 3)));
        _notify();
        break;
      case TextType.tip:
        tip = ScreenMessage(translate(m.message, const []), DateTime.now().add(const Duration(seconds: 3)));
        _notify();
        break;
      default:
        _addChat(translate(m.message, const []), ChatKind.system);
    }
  }

  void _onAttributes(List<Attribute> list) {
    for (final a in list) {
      switch (a.name) {
        case 'minecraft:health':
          health = a.value;
          maxHealth = a.max;
          final wasDead = dead;
          dead = a.value <= 0;
          if (dead && !wasDead) _addChat('Вы погибли', ChatKind.local);
          break;
        case 'minecraft:player.hunger':
          food = a.value;
          break;
        case 'minecraft:player.level':
          xpLevel = a.value.round();
          break;
      }
    }
    _notify();
  }

  void _onPlayerList(PlayerListUpdate u) {
    if (u.add) {
      for (final e in u.entries) {
        final existing = players[e.uuid];
        players[e.uuid] = OnlinePlayer(e.uuid, e.uniqueId, e.name)..position = existing?.position;
      }
    } else {
      for (final uuid in u.removed) {
        players.remove(uuid);
      }
    }
    _notify();
  }

  void _onTitle(TitleData t) {
    Duration ticks(int n) => Duration(milliseconds: n * 50);
    DateTime until() => DateTime.now().add(ticks(_titleFadeIn + _titleStay + _titleFadeOut));
    switch (t.type) {
      case TitleData.clear:
        title = subtitle = actionBar = null;
        break;
      case TitleData.reset:
        title = subtitle = actionBar = null;
        _titleFadeIn = 10;
        _titleStay = 70;
        _titleFadeOut = 20;
        break;
      case TitleData.title:
        title = ScreenMessage(translate(t.text, const []), until());
        break;
      case TitleData.subtitle:
        subtitle = ScreenMessage(translate(t.text, const []), until());
        break;
      case TitleData.actionBar:
        actionBar = ScreenMessage(translate(t.text, const []), until());
        break;
      case TitleData.times:
        _titleFadeIn = t.fadeIn;
        _titleStay = t.stay;
        _titleFadeOut = t.fadeOut;
        break;
    }
    _notify();
  }

  // ---------- Действия игрока ----------

  /// Отправить сообщение в чат или команду (строка начинается с '/').
  void sendMessage(String text) {
    final message = text.trim();
    if (message.isEmpty || phase != ConnectionPhase.playing) return;
    if (dead) {
      _addChat('Вы погибли: сначала нажмите «Возродиться»', ChatKind.error);
      return;
    }
    if (message.startsWith('/')) {
      try {
        final call = commands.parse(message);
        _sendPacket(buildCommandStep(
          command: call.command,
          overload: call.overload,
          clientId: _login?.clientRandomId ?? 0,
          inputJson: call.inputJson,
        ));
        _addChat(message, ChatKind.local);
      } on CommandParseException catch (e) {
        _addChat(e.message, ChatKind.error);
      }
      return;
    }
    _sendPacket(buildChat(nickname, message));
  }

  void respawn() {
    final id = _runtimeId;
    if (id == null || !dead) return;
    final pos = position ?? const Vec3(0, 0, 0);
    _sendPacket(buildPlayerAction(id, PlayerActionType.respawn, pos.x.floor(), pos.y.floor(), pos.z.floor()));
  }
}
