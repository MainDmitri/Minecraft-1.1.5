import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../game/lang.dart';
import '../protocol/binary.dart';
import '../protocol/login.dart';
import '../protocol/packets.dart';
import '../world/blocks.dart';
import '../world/world.dart';
import 'generator.dart';
import 'raknet_server.dart';
import 'server_packets.dart';
import 'world_storage.dart';

const double _eyeHeight = 1.62;

class _ServerPlayer {
  _ServerPlayer(this.session);

  final RakServerSession session;
  String name = '';
  Uint8List uuid = Uint8List(16);
  String skinId = 'Standard_Custom';
  Uint8List skin = Uint8List(64 * 32 * 4);
  int entityId = 0;
  bool loggedIn = false;
  bool joined = false;
  bool spawned = false;

  double x = 0, y = 0, z = 0, yaw = 0, pitch = 0;
  int gamemode = 0;
  bool flying = false;
  final List<ServerItem> inventory = List.generate(36, (_) => ServerItem.air);
  int heldIndex = 0;

  int chunkRadius = 4;
  final Set<int> sentChunks = {};
  final List<int> pendingChunks = [];
  int spawnChunksLeft = 0;

  int? breakX, breakY, breakZ;
  DateTime? breakStart;

  bool get creative => gamemode == 1;
  int get chunkX => x.floor() >> 4;
  int get chunkZ => z.floor() >> 4;
  ServerItem get held => inventory[heldIndex];
}

/// Блоки творческого инвентаря (ID и метаданные существуют в MCPE 1.1).
final List<List<int>> _creativeBlocks = [
  [1, 0], [1, 1], [1, 3], [1, 5], [2, 0], [3, 0], [4, 0], [5, 0], [5, 1], [5, 2], [5, 3], [5, 4], [5, 5], //
  [7, 0], [12, 0], [12, 1], [13, 0], [14, 0], [15, 0], [16, 0], [17, 0], [17, 1], [17, 2], [17, 3],
  [18, 0], [18, 1], [18, 2], [18, 3], [19, 0], [20, 0], [21, 0], [22, 0], [24, 0], [24, 1], [24, 2],
  for (var m = 0; m < 16; m++) [35, m],
  [41, 0], [42, 0], [45, 0], [46, 0], [47, 0], [48, 0], [49, 0], [56, 0], [57, 0], [58, 0], [61, 0],
  [73, 0], [79, 0], [80, 0], [81, 0], [82, 0], [86, 0], [87, 0], [88, 0], [89, 0], [91, 0], [98, 0], [98, 1],
  [98, 2], [98, 3], [103, 0], [110, 0], [112, 0], [121, 0], [129, 0], [133, 0], [152, 0], [153, 0], [155, 0],
  for (var m = 0; m < 16; m++) [159, m],
  [162, 0], [162, 1], [165, 0], [170, 0], [172, 0], [173, 0], [174, 0], [179, 0],
];

/// Время ломания голыми руками, секунды (упрощённо, без инструментов).
double _breakSeconds(int id) {
  switch (id) {
    case 0:
    case 31:
    case 37:
    case 38:
    case 6:
    case 50:
    case 59:
    case 83:
    case 175:
      return 0;
    case 18:
    case 161:
      return 0.3;
    case 20:
    case 102:
    case 89:
      return 0.45;
    case 2:
    case 3:
    case 12:
    case 13:
    case 60:
    case 82:
    case 88:
    case 110:
      return 0.9;
    case 35:
    case 24:
    case 179:
    case 80:
    case 81:
    case 86:
    case 103:
      return 1.2;
    case 1:
    case 98:
    case 155:
    case 159:
    case 172:
    case 48:
      return 2.25;
    case 4:
    case 5:
    case 17:
    case 162:
    case 45:
    case 47:
    case 58:
    case 61:
      return 3;
    case 14:
    case 15:
    case 16:
    case 21:
    case 56:
    case 73:
    case 129:
    case 153:
      return 4.5;
    case 41:
    case 42:
    case 57:
    case 133:
    case 152:
    case 173:
      return 6;
    case 49:
      return 10;
    default:
      return 1.5;
  }
}

/// Что выпадает при ломании в выживании.
ServerItem? _drop(int id, int meta) {
  switch (id) {
    case 2:
    case 60:
    case 110:
      return ServerItem(3, 0, 1);
    case 1:
      return ServerItem(meta == 0 ? 4 : 1, meta, 1);
    case 18:
    case 161:
    case 20:
    case 102:
    case 79:
    case 31:
    case 32:
    case 51:
    case 7:
      return null;
    case 17:
    case 162:
      return ServerItem(id, meta & 3, 1);
    default:
      return id > 0 && id < 256 ? ServerItem(id, meta, 1) : null;
  }
}

bool _replaceable(int id) =>
    id == 0 || id == 8 || id == 9 || id == 10 || id == 11 || id == 31 || id == 32 || id == 51 || id == 78 || id == 106;

/// Встроенный сервер MCPE 1.1 (протокол 113) для локального мира и игры по сети.
class LocalServer {
  LocalServer({required this.storage, required this.lan});

  final WorldStorage storage;
  final bool lan;

  static const int maxPlayers = 10;
  static const int maxChunkRadius = 6;

  late WorldMeta meta;
  late TerrainGenerator _gen;
  late RakNetServer _rak;
  final Map<int, Chunk> _chunks = {};
  final Set<int> _modified = {};
  final Map<int, Uint8List> _netCache = {};
  final Map<String, _ServerPlayer> _players = {};
  late Map<String, PlayerSave> _saves;
  int _nextEntityId = 1;
  int _tickCount = 0;
  Timer? _tick;
  int port = 0;

  /// Сообщения для журнала на экране хоста (подключения, ошибки).
  final StreamController<String> _log = StreamController.broadcast();
  Stream<String> get log => _log.stream;

  Iterable<_ServerPlayer> get _online => _players.values.where((p) => p.joined);

  int get onlineCount => _online.length;

  Future<int> start() async {
    meta = storage.readMeta();
    _gen = TerrainGenerator(meta.seed);
    _saves = storage.readPlayers();
    _rak = RakNetServer(
      motd: () => 'MCPE;${meta.name};$mcpeProtocol;$mcpeVersion;$onlineCount;$maxPlayers;0;${meta.name};'
          '${meta.gamemode == 1 ? 'Creative' : 'Survival'};1;$port;$port;',
      onConnect: (s) => _players[s.key] = _ServerPlayer(s),
      onPacket: _onPacket,
      onDisconnect: (s, reason) => _onDisconnect(s.key, reason),
    );
    port = await _rak.start(lan: lan);
    _tick = Timer.periodic(const Duration(milliseconds: 50), (_) => _onTick());
    return port;
  }

  Future<void> stop() async {
    _tick?.cancel();
    for (final p in _players.values.toList()) {
      _send(p, [spDisconnect('Сервер остановлен')]);
      _savePlayer(p);
    }
    _saveAll();
    await _rak.stop();
    await _log.close();
  }

  // ---------- Чанки и блоки ----------

  Chunk _chunk(int cx, int cz) {
    final key = chunkKey(cx, cz);
    final cached = _chunks[key];
    if (cached != null) return cached;
    Chunk chunk;
    try {
      chunk = storage.readChunk(cx, cz) ?? _gen.generate(cx, cz);
    } on FormatException {
      chunk = _gen.generate(cx, cz);
    }
    _chunks[key] = chunk;
    return chunk;
  }

  int _blockId(int x, int y, int z) => y < 0 || y > 255 ? 0 : _chunk(x >> 4, z >> 4).id(x & 15, y, z & 15);

  int _blockMeta(int x, int y, int z) {
    if (y < 0 || y > 255) return 0;
    final s = _chunk(x >> 4, z >> 4).sections[y >> 4];
    return s == null ? 0 : s.data(x & 15, y & 15, z & 15);
  }

  void _setBlock(int x, int y, int z, int id, int data) {
    if (y < 0 || y > 255) return;
    final cx = x >> 4, cz = z >> 4;
    _chunk(cx, cz).set(x & 15, y, z & 15, id, data);
    final key = chunkKey(cx, cz);
    _modified.add(key);
    _netCache.remove(key);
    final packet = spUpdateBlock(x, y, z, id, data);
    for (final p in _online) {
      if (p.sentChunks.contains(key)) _send(p, [packet]);
    }
  }

  void _saveAll() {
    for (final key in _modified) {
      final chunk = _chunks[key];
      if (chunk != null) storage.writeChunk(chunk);
    }
    _modified.clear();
    storage.writeMeta(meta);
    storage.writePlayers(_saves);
  }

  void _savePlayer(_ServerPlayer p) {
    if (!p.joined) return;
    _saves[p.name.toLowerCase()] = PlayerSave(
      x: p.x,
      y: p.y,
      z: p.z,
      yaw: p.yaw,
      pitch: p.pitch,
      gamemode: p.gamemode,
      inventory: p.inventory.map((i) => i.toJson()).toList(),
      heldSlot: p.heldIndex,
    );
  }

  // ---------- Отправка ----------

  void _send(_ServerPlayer p, List<Uint8List> packets, {int level = 7}) {
    final batch = BinaryWriter();
    for (final packet in packets) {
      batch.byteArray(packet);
    }
    final data = ZLibCodec(level: level).encode(batch.take());
    final out = Uint8List(data.length + 1)
      ..[0] = 0xfe
      ..setRange(1, data.length + 1, data);
    _rak.send(p.session, out);
  }

  void _broadcast(List<Uint8List> packets, {_ServerPlayer? except}) {
    for (final p in _online) {
      if (p != except) _send(p, packets);
    }
  }

  void _message(_ServerPlayer p, String text) => _send(p, [spText(text)]);

  // ---------- Приём ----------

  void _onPacket(RakServerSession s, Uint8List payload) {
    final p = _players[s.key];
    if (p == null || payload[0] != 0xfe) return;
    final packets = <Uint8List>[];
    try {
      final r = BinaryReader(Uint8List.fromList(ZLibCodec().decode(Uint8List.sublistView(payload, 1))));
      while (!r.eof) {
        packets.add(r.byteArray());
      }
    } on FormatException {
      _kick(p, 'Некорректные данные от клиента');
      return;
    }
    for (final packet in packets) {
      if (packet.isEmpty) continue;
      try {
        _handle(p, packet[0], BinaryReader(packet, 1));
      } on FormatException catch (e) {
        _log.add('Пакет 0x${packet[0].toRadixString(16)} от ${p.name}: ${e.message}');
      }
    }
  }

  void _kick(_ServerPlayer p, String reason) {
    _send(p, [spDisconnect(reason)]);
    _rak.kick(p.session);
  }

  void _handle(_ServerPlayer p, int id, BinaryReader r) {
    if (id == PacketId.login) {
      _onLogin(p, r);
      return;
    }
    if (!p.loggedIn) return;
    switch (id) {
      case PacketId.resourcePackClientResponse:
        final status = r.byte();
        if (status == 3) _send(p, [spResourcePackStack()]);
        if (status == 4 && !p.joined) _join(p);
        break;
      case PacketId.requestChunkRadius:
        p.chunkRadius = r.varint().clamp(2, maxChunkRadius);
        _send(p, [spChunkRadiusUpdated(p.chunkRadius)]);
        _orderChunks(p);
        break;
      case PacketId.movePlayer:
        if (!p.spawned) return;
        r.uvarint();
        final x = r.floatLE(), eyeY = r.floatLE(), z = r.floatLE();
        final pitch = r.floatLE(), yaw = r.floatLE();
        final oldChunk = chunkKey(p.chunkX, p.chunkZ);
        p
          ..x = x
          ..y = eyeY - _eyeHeight
          ..z = z
          ..pitch = pitch
          ..yaw = yaw;
        _broadcast([spMovePlayer(p.entityId, x, eyeY, z, yaw, pitch, 0)], except: p);
        if (chunkKey(p.chunkX, p.chunkZ) != oldChunk) _orderChunks(p);
        break;
      case PacketId.text:
        final type = r.byte();
        if (type != TextType.chat) return;
        r.string();
        final message = r.string().trim();
        if (message.isEmpty || message.length > 255) return;
        if (message.startsWith('/')) {
          _command(p, message.substring(1).split(' ').first, message.split(' ').skip(1).toList());
        } else {
          _broadcast([spText('<${p.name}> $message')]);
          _log.add('<${p.name}> $message');
        }
        break;
      case PacketId.commandStep:
        final name = r.string();
        r.string(); // перегрузка
        r.uvarint();
        r.uvarint();
        r.boolean();
        r.uvarint();
        final input = r.string();
        _command(p, name, _commandArgs(input));
        break;
      case PacketId.playerAction:
        r.uvarint();
        final action = r.varint();
        final x = r.varint(), y = r.uvarint(), z = r.varint();
        if (action == PlayerActionType.startBreak) {
          p
            ..breakX = x
            ..breakY = y
            ..breakZ = z
            ..breakStart = DateTime.now();
          final seconds = _breakSeconds(_blockId(x, y, z));
          if (!p.creative && seconds > 0) {
            _send(p, [spLevelEvent(LevelEventId.blockStartBreak, x.toDouble(), y.toDouble(), z.toDouble(), (65535 / (seconds * 20)).round())]);
          }
        } else if (action == PlayerActionType.abortBreak) {
          p.breakStart = null;
        }
        break;
      case PacketId.removeBlock:
        _onRemoveBlock(p, r.varint(), r.uvarint(), r.varint());
        break;
      case PacketId.useItem:
        _onUseItem(p, r);
        break;
      case PacketId.mobEquipment:
        r.uvarint();
        final item = readItem(r);
        r.byte();
        final hotbar = r.byte();
        if (hotbar > 8) return;
        p.heldIndex = hotbar;
        if (p.creative && item.id > 0) {
          p.inventory[hotbar] = ServerItem(item.id, item.meta, item.count > 0 ? item.count : 1);
          _send(p, [spContainerSetSlot(0, hotbar, p.inventory[hotbar])]);
        }
        _send(p, [spMobEquipment(p.entityId, p.held, hotbar + 9, hotbar)]);
        break;
      case PacketId.adventureSettings:
        final flags = r.uvarint();
        p.flying = p.creative && (flags & (1 << 9)) != 0;
        break;
    }
  }

  void _onLogin(_ServerPlayer p, BinaryReader r) {
    if (p.loggedIn) return;
    final protocol = r.intBE();
    if (protocol != mcpeProtocol) {
      _send(p, [spPlayStatus(protocol < mcpeProtocol ? PlayStatus.loginFailedClient : PlayStatus.loginFailedServer)]);
      _kick(p, 'Нужна версия MCPE 1.1.x (протокол $mcpeProtocol), у вас протокол $protocol');
      return;
    }
    r.byte(); // издание
    final inner = BinaryReader(r.byteArray());
    final chain = utf8.decode(inner.bytes(inner.intLE()));
    final clientJwt = utf8.decode(inner.bytes(inner.intLE()));
    Map<String, dynamic> payloadOf(String jwt) {
      final parts = jwt.split('.');
      if (parts.length < 2) throw const FormatException('Некорректный JWT');
      var b = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      while (b.length % 4 != 0) {
        b += '=';
      }
      return jsonDecode(utf8.decode(base64.decode(b))) as Map<String, dynamic>;
    }

    String? name, identity;
    for (final token in (jsonDecode(chain)['chain'] as List).cast<String>()) {
      final extra = payloadOf(token)['extraData'];
      if (extra is Map) {
        name = extra['displayName'] as String? ?? name;
        identity = extra['identity'] as String? ?? identity;
      }
    }
    final client = payloadOf(clientJwt);
    if (name == null || validateNickname(name) != null) {
      _kick(p, translate('disconnectionScreen.invalidName', const []));
      return;
    }
    if (_online.any((o) => o.name.toLowerCase() == name!.toLowerCase())) {
      _kick(p, 'Игрок с ником $name уже на сервере');
      return;
    }
    if (onlineCount >= maxPlayers) {
      _kick(p, translate('disconnectionScreen.serverFull', const []));
      return;
    }
    final skinB64 = client['SkinData'] as String?;
    final skin = skinB64 == null ? null : base64.decode(skinB64);
    if (skin != null && (skin.length == 64 * 32 * 4 || skin.length == 64 * 64 * 4)) p.skin = skin;
    p.skinId = client['SkinId'] as String? ?? p.skinId;
    p.name = name;
    final hex = (identity ?? offlineUuid(name)).replaceAll('-', '');
    if (hex.length == 32) {
      p.uuid = Uint8List.fromList([for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
    }
    p.loggedIn = true;
    _send(p, [spPlayStatus(PlayStatus.loginSuccess), spResourcePacksInfo()]);
  }

  void _join(_ServerPlayer p) {
    p.joined = true;
    p.entityId = _nextEntityId++;
    final save = _saves[p.name.toLowerCase()];
    if (save != null) {
      p
        ..x = save.x
        ..y = save.y
        ..z = save.z
        ..yaw = save.yaw
        ..pitch = save.pitch
        ..gamemode = save.gamemode
        ..heldIndex = save.heldSlot.clamp(0, 8);
      for (var i = 0; i < 36 && i < save.inventory.length; i++) {
        final it = save.inventory[i];
        p.inventory[i] = ServerItem(it[0], it[1], it[2]);
      }
    } else {
      p
        ..x = meta.spawnX + 0.5
        ..y = meta.spawnY.toDouble()
        ..z = meta.spawnZ + 0.5
        ..gamemode = meta.gamemode;
    }
    _send(p, [
      spStartGame(
        entityId: p.entityId,
        gamemode: p.gamemode,
        x: p.x,
        eyeY: p.y + _eyeHeight,
        z: p.z,
        yaw: p.yaw,
        pitch: p.pitch,
        seed: meta.seed,
        spawnX: meta.spawnX,
        spawnY: meta.spawnY,
        spawnZ: meta.spawnZ,
        worldName: meta.name,
        time: meta.time,
      ),
      spSetTime(meta.time),
      spUpdateAttributes(p.entityId, health: 20, food: 20, level: 0),
      spSetEntityData(p.entityId, entityMetadata(p.name)),
      _creativeContent(p),
      spAvailableCommands(_commandsJson),
      spPlayerListAdd([for (final o in _online) _record(o)]),
    ]);
    _broadcast([spPlayerListAdd([_record(p)])], except: p);
    _log.add('${p.name} подключается (${p.session.address.address})');
    _orderChunks(p);
  }

  PlayerListRecord _record(_ServerPlayer p) => PlayerListRecord(p.uuid, p.entityId, p.name, p.skinId, p.skin);

  Uint8List _creativeContent(_ServerPlayer p) => spContainerSetContent(
        0x79,
        p.entityId,
        p.creative ? [for (final b in _creativeBlocks) ServerItem(b[0], b[1], 1)] : const [],
        const [],
      );

  Uint8List _inventoryContent(_ServerPlayer p) => spContainerSetContent(
        0,
        p.entityId,
        [...p.inventory, for (var i = 0; i < 9; i++) ServerItem.air],
        [for (var i = 0; i < 9; i++) i + 9],
      );

  void _firstSpawn(_ServerPlayer p) {
    p.spawned = true;
    _send(p, [
      spAdventureSettings(creative: p.creative, flying: p.flying, op: true),
      _inventoryContent(p),
      spMobEquipment(p.entityId, p.held, p.heldIndex + 9, p.heldIndex),
      spSetTime(meta.time),
      spRespawn(p.x, p.y + _eyeHeight, p.z),
      spPlayStatus(PlayStatus.playerSpawn),
    ]);
    final joinMessage = spTranslation('§e%multiplayer.player.joined', [p.name]);
    _broadcast([joinMessage]);
    for (final o in _online) {
      if (o == p || !o.spawned) continue;
      _send(p, [_addPlayer(o)]);
      _send(o, [_addPlayer(p)]);
    }
  }

  Uint8List _addPlayer(_ServerPlayer p) => spAddPlayer(
        uuid: p.uuid,
        name: p.name,
        entityId: p.entityId,
        x: p.x,
        y: p.y,
        z: p.z,
        yaw: p.yaw,
        pitch: p.pitch,
        metadata: entityMetadata(p.name),
      );

  void _onDisconnect(String key, String reason) {
    final p = _players.remove(key);
    if (p == null || !p.joined) return;
    _savePlayer(p);
    storage.writePlayers(_saves);
    _broadcast([spRemoveEntity(p.entityId), spPlayerListRemove(p.uuid), spTranslation('§e%multiplayer.player.left', [p.name])]);
    _log.add('${p.name} отключается: $reason');
  }

  void _orderChunks(_ServerPlayer p) {
    final cx = p.chunkX, cz = p.chunkZ, r = p.chunkRadius;
    final wanted = <int>[];
    final distances = <int, int>{};
    for (var dx = -r; dx <= r; dx++) {
      for (var dz = -r; dz <= r; dz++) {
        final d = dx * dx + dz * dz;
        if (d > r * r) continue;
        final key = chunkKey(cx + dx, cz + dz);
        distances[key] = d;
        if (!p.sentChunks.contains(key)) wanted.add(key);
      }
    }
    wanted.sort((a, b) => distances[a]!.compareTo(distances[b]!));
    p.pendingChunks
      ..clear()
      ..addAll(wanted);
    p.sentChunks.removeWhere((k) => !distances.containsKey(k));
    if (!p.spawned) {
      p.spawnChunksLeft = wanted.where((k) => distances[k]! <= 4).length;
    }
  }

  void _sendChunks(Stopwatch budget) {
    for (final p in _online) {
      var sent = 0;
      while (p.pendingChunks.isNotEmpty && sent < 4 && budget.elapsedMilliseconds < 12) {
        final key = p.pendingChunks.removeAt(0);
        final cx = key >> 32;
        final cz = (key << 32) >> 32;
        final data = _netCache.putIfAbsent(key, () => encodeChunkForNetwork(_chunk(cx, cz)));
        _send(p, [spFullChunk(cx, cz, data)], level: 6);
        p.sentChunks.add(key);
        sent++;
        if (!p.spawned) {
          final dx = cx - p.chunkX, dz = cz - p.chunkZ;
          if (dx * dx + dz * dz <= 4) p.spawnChunksLeft--;
        }
      }
      if (!p.spawned && p.joined && p.spawnChunksLeft <= 0 && p.sentChunks.isNotEmpty) _firstSpawn(p);
    }
  }

  void _onTick() {
    _tickCount++;
    meta.time++;
    _sendChunks(Stopwatch()..start());
    if (_tickCount % 200 == 0) _broadcast([spSetTime(meta.time)]);
    if (_tickCount % 1200 == 0) {
      for (final p in _online) {
        _savePlayer(p);
      }
      _saveAll();
    }
    // Чанки, которые никто не видит и которые сохранены, выгружаются из памяти.
    if (_tickCount % 600 == 0) {
      final keep = <int>{
        for (final p in _online) ...[...p.sentChunks, ...p.pendingChunks],
      };
      _chunks.removeWhere((k, _) => !keep.contains(k) && !_modified.contains(k));
      _netCache.removeWhere((k, _) => !keep.contains(k));
    }
  }

  // ---------- Блоки ----------

  bool _inReach(_ServerPlayer p, int x, int y, int z) {
    final dx = x + 0.5 - p.x, dy = y + 0.5 - (p.y + _eyeHeight), dz = z + 0.5 - p.z;
    final reach = p.creative ? 13 : 8;
    return dx * dx + dy * dy + dz * dz <= reach * reach;
  }

  void _resendBlock(_ServerPlayer p, int x, int y, int z) =>
      _send(p, [spUpdateBlock(x, y, z, _blockId(x, y, z), _blockMeta(x, y, z))]);

  void _onRemoveBlock(_ServerPlayer p, int x, int y, int z) {
    final id = _blockId(x, y, z);
    if (!p.spawned || id == 0 || !_inReach(p, x, y, z)) {
      _resendBlock(p, x, y, z);
      return;
    }
    if (!p.creative) {
      final seconds = _breakSeconds(id);
      final started = p.breakStart;
      final sameBlock = p.breakX == x && p.breakY == y && p.breakZ == z;
      final elapsed = started == null ? 0 : DateTime.now().difference(started).inMilliseconds;
      if (id == 7 || (seconds > 0 && (!sameBlock || elapsed < seconds * 1000 * 0.75))) {
        _resendBlock(p, x, y, z);
        return;
      }
      final drop = _drop(id, _blockMeta(x, y, z));
      if (drop != null) _give(p, drop);
    }
    p.breakStart = null;
    final meta = _blockMeta(x, y, z);
    _setBlock(x, y, z, 0, 0);
    // Остальные игроки рядом видят и слышат разрушение блока.
    final destroy = spLevelEvent(LevelEventId.particleDestroy, x + 0.5, y + 0.5, z + 0.5, id | (meta << 8));
    final key = chunkKey(x >> 4, z >> 4);
    for (final other in _online) {
      if (other != p && other.sentChunks.contains(key)) _send(other, [destroy]);
    }
  }

  void _give(_ServerPlayer p, ServerItem item) {
    var slot = p.inventory.indexWhere((i) => i.id == item.id && i.meta == item.meta && i.count < 64);
    if (slot < 0) slot = p.inventory.indexWhere((i) => i.isEmpty);
    if (slot < 0) return;
    final current = p.inventory[slot];
    p.inventory[slot] = current.isEmpty ? item : (current..count += item.count);
    _send(p, [spContainerSetSlot(0, slot, p.inventory[slot])]);
    if (slot == p.heldIndex) _send(p, [spMobEquipment(p.entityId, p.held, p.heldIndex + 9, p.heldIndex)]);
  }

  void _onUseItem(_ServerPlayer p, BinaryReader r) {
    final x = r.varint(), y = r.uvarint(), z = r.varint();
    r.uvarint(); // блок, по которому кликнули
    final face = r.varint();
    if (!p.spawned || face < 0 || face > 5) return;
    final (tx, ty, tz) = switch (face) {
      0 => (x, y - 1, z),
      1 => (x, y + 1, z),
      2 => (x, y, z - 1),
      3 => (x, y, z + 1),
      4 => (x - 1, y, z),
      _ => (x + 1, y, z),
    };
    final held = p.held;
    final placeable = !held.isEmpty && held.id < 256 && blockTable[held.id].shape != BlockShape.none;
    final blocked = _online.any((o) =>
        tx + 1 > o.x - 0.3 && tx < o.x + 0.3 && ty + 1 > o.y && ty < o.y + 1.8 && tz + 1 > o.z - 0.3 && tz < o.z + 0.3);
    if (!placeable || !_replaceable(_blockId(tx, ty, tz)) || !_inReach(p, tx, ty, tz) || blocked || ty < 0 || ty > 255) {
      _resendBlock(p, tx, ty, tz);
      return;
    }
    _setBlock(tx, ty, tz, held.id, held.meta);
    if (!p.creative) {
      held.count--;
      if (held.count <= 0) p.inventory[p.heldIndex] = ServerItem.air;
      _send(p, [
        spContainerSetSlot(0, p.heldIndex, p.held),
        spMobEquipment(p.entityId, p.held, p.heldIndex + 9, p.heldIndex),
      ]);
    }
  }

  // ---------- Команды ----------

  static final String _commandsJson = jsonEncode({
    for (final c in _commandDefs.entries)
      c.key: {
        'versions': [
          {
            'aliases': <String>[],
            'description': c.value.$1,
            'overloads': {
              for (final o in c.value.$2.entries)
                o.key: {
                  'input': {'parameters': o.value},
                  'output': {'format_strings': <String>[]},
                },
            },
            'permission': 'any',
          },
        ],
      },
  });

  static final Map<String, (String, Map<String, List<Map<String, dynamic>>>)> _commandDefs = {
    'help': ('Список команд', {'default': []}),
    'list': ('Игроки онлайн', {'default': []}),
    'seed': ('Зерно мира', {'default': []}),
    'time': (
      'Изменить время суток',
      {
        'default': [
          {'name': 'mode', 'type': 'stringenum', 'optional': false, 'enum_type': 'mode', 'enum_values': ['set', 'add']},
          {'name': 'value', 'type': 'int', 'optional': false},
        ],
      }
    ),
    'gamemode': (
      'Режим игры: 0 — выживание, 1 — творчество',
      {
        'default': [
          {'name': 'mode', 'type': 'int', 'optional': false},
        ],
      }
    ),
    'tp': (
      'Телепорт к координатам или к игроку',
      {
        'default': [
          {'name': 'destination', 'type': 'blockpos', 'optional': false},
        ],
        'player': [
          {'name': 'player', 'type': 'target', 'optional': false},
        ],
      }
    ),
    'say': (
      'Сообщение всем игрокам',
      {
        'default': [
          {'name': 'message', 'type': 'rawtext', 'optional': false},
        ],
      }
    ),
    'setworldspawn': ('Сделать текущую позицию точкой появления', {'default': []}),
  };

  /// Аргументы из JSON CommandStepPacket в порядке параметров.
  List<String> _commandArgs(String json) {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    if (decoded is! Map) return const [];
    final out = <String>[];
    for (final v in decoded.values) {
      if (v is Map && v.containsKey('x')) {
        out.addAll(['${v['x']}', '${v['y']}', '${v['z']}']);
      } else if (v is Map && v['rules'] is List && (v['rules'] as List).isNotEmpty) {
        out.add('${((v['rules'] as List).first as Map)['value']}');
      } else if (v is Map && v['selector'] != null) {
        out.add('@${v['selector']}');
      } else if (v != null) {
        out.addAll(v.toString().split(' ').where((s) => s.isNotEmpty));
      }
    }
    return out;
  }

  void _command(_ServerPlayer p, String name, List<String> args) {
    if (!p.spawned) return;
    switch (name.toLowerCase()) {
      case 'help':
        _message(p, '§2Команды: ${_commandDefs.keys.map((c) => '/$c').join(', ')}');
        break;
      case 'list':
        _message(p, 'Онлайн $onlineCount/$maxPlayers: ${_online.map((o) => o.name).join(', ')}');
        break;
      case 'seed':
        _message(p, 'Зерно мира: ${meta.seed}');
        break;
      case 'time':
        final value = args.length > 1 ? int.tryParse(args[1]) : null;
        if (value == null || (args[0] != 'set' && args[0] != 'add')) {
          _message(p, '§cИспользование: /time <set|add> <число>');
          return;
        }
        meta.time = args[0] == 'set' ? value : meta.time + value;
        _broadcast([spSetTime(meta.time)]);
        _message(p, 'Время установлено: ${meta.time % 24000}');
        break;
      case 'gamemode':
        final mode = args.isEmpty ? null : int.tryParse(args[0]) ?? (args[0].startsWith('c') ? 1 : (args[0].startsWith('s') ? 0 : null));
        if (mode == null || (mode != 0 && mode != 1)) {
          _message(p, '§cИспользование: /gamemode <0|1>');
          return;
        }
        p.gamemode = mode;
        p.flying = false;
        _send(p, [
          spSetPlayerGameType(mode),
          spAdventureSettings(creative: p.creative, flying: false, op: true),
          _creativeContent(p),
          _inventoryContent(p),
        ]);
        _message(p, 'Режим игры: ${mode == 1 ? 'творчество' : 'выживание'}');
        break;
      case 'tp':
        double? tx, ty, tz;
        if (args.length >= 3) {
          tx = double.tryParse(args[0]);
          ty = double.tryParse(args[1]);
          tz = double.tryParse(args[2]);
        } else if (args.length == 1) {
          final target = _online.where((o) => o.name.toLowerCase() == args[0].toLowerCase()).firstOrNull;
          if (target != null) {
            tx = target.x;
            ty = target.y;
            tz = target.z;
          }
        }
        if (tx == null || ty == null || tz == null) {
          _message(p, '§cИспользование: /tp <x> <y> <z> или /tp <игрок>');
          return;
        }
        p
          ..x = tx
          ..y = ty
          ..z = tz;
        _send(p, [spMovePlayer(p.entityId, tx, ty + _eyeHeight, tz, p.yaw, p.pitch, 1)]);
        _broadcast([spMovePlayer(p.entityId, tx, ty + _eyeHeight, tz, p.yaw, p.pitch, 0)], except: p);
        _orderChunks(p);
        _message(p, 'Телепорт: ${tx.toStringAsFixed(1)} ${ty.toStringAsFixed(1)} ${tz.toStringAsFixed(1)}');
        break;
      case 'say':
        if (args.isEmpty) return;
        _broadcast([spText('§d[${p.name}] ${args.join(' ')}')]);
        break;
      case 'setworldspawn':
        meta
          ..spawnX = p.x.floor()
          ..spawnY = p.y.floor()
          ..spawnZ = p.z.floor();
        storage.writeMeta(meta);
        _message(p, 'Точка появления: ${meta.spawnX} ${meta.spawnY} ${meta.spawnZ}');
        break;
      default:
        _message(p, '§c${translate('commands.generic.unknown', const [])}');
    }
  }
}

/// IPv4-адреса устройства в локальной сети (для подключения друзей).
Future<List<String>> localIpAddresses() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
  return [
    for (final i in interfaces)
      for (final a in i.addresses)
        if (!a.isLoopback) a.address,
  ];
}

/// Новое зерно мира из текста (число или строка).
int seedFromText(String text) {
  final t = text.trim();
  if (t.isEmpty) return math.Random.secure().nextInt(1 << 31);
  return int.tryParse(t) ?? t.codeUnits.fold<int>(0, (h, c) => (h * 31 + c) & 0x7fffffff);
}
