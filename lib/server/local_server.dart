import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../game/items.dart';
import '../game/lang.dart';
import '../protocol/binary.dart';
import '../protocol/login.dart';
import '../protocol/packets.dart';
import '../world/blocks.dart';
import '../world/world.dart';
import 'generator.dart';
import 'raknet_server.dart';
import 'recipes.dart';
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
  final List<ServerItem> armor = List.generate(4, (_) => ServerItem.air);
  int heldIndex = 0;

  /// Нажат верстак: разрешены рецепты 3×3.
  bool craftingBig = false;

  /// Открытое окно сундука или печи.
  int? windowId;
  _Container? window;

  /// Незавершённая группа изменений слотов.
  _Transaction? transaction;

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

/// Сундук или печь в мире.
class _Container {
  _Container(this.furnace, this.x, this.y, this.z) : items = List.generate(furnace ? 3 : 27, (_) => ServerItem.air);

  final bool furnace;
  final int x, y, z;
  final List<ServerItem> items;
  final Set<_ServerPlayer> viewers = {};

  // Печь: оставшееся время горения, полное время текущего топлива, прогресс плавки (0..200).
  int burn = 0, maxBurn = 0, cook = 0;

  String get key => '$x,$y,$z';

  Map<String, dynamic> toJson() => {
        'type': furnace ? 'furnace' : 'chest',
        'items': [for (final i in items) i.toJson()],
        if (furnace) 'burn': [burn, maxBurn, cook],
      };

  static _Container fromJson(String key, Map<String, dynamic> j) {
    final pos = key.split(',').map(int.parse).toList();
    final c = _Container(j['type'] == 'furnace', pos[0], pos[1], pos[2]);
    final items = (j['items'] as List).map((e) => (e as List).cast<int>()).toList();
    for (var i = 0; i < c.items.length && i < items.length; i++) {
      c.items[i] = ServerItem(items[i][0], items[i][1], items[i][2]);
    }
    final burn = (j['burn'] as List?)?.cast<int>();
    if (burn != null && burn.length == 3) {
      c
        ..burn = burn[0]
        ..maxBurn = burn[1]
        ..cook = burn[2];
    }
    return c;
  }
}

/// Предмет, лежащий в мире.
class _ItemEntity {
  _ItemEntity(this.id, this.item, this.x, this.y, this.z, this.vx, this.vy, this.vz, this.pickupDelay);

  final int id;
  ServerItem item;
  double x, y, z, vx, vy, vz;
  int pickupDelay;
  int age = 0;
  bool onGround = false;

  int get chunkKeyValue => chunkKey(x.floor() >> 4, z.floor() >> 4);
}

/// Группа изменений слотов от клиента: применяется, когда предметы только переложены.
class _Transaction {
  final DateTime created = DateTime.now();

  /// (окно, слот) → (было, стало).
  final Map<(int, int), (ServerItem, ServerItem)> changes = {};

  bool get balanced {
    final total = <(int, int), int>{};
    for (final (old, now) in changes.values) {
      if (!old.isEmpty) total[(old.id, old.meta)] = (total[(old.id, old.meta)] ?? 0) + old.count;
      if (!now.isEmpty) total[(now.id, now.meta)] = (total[(now.id, now.meta)] ?? 0) - now.count;
    }
    return total.values.every((v) => v == 0);
  }
}

int _randomRange(math.Random rng, int min, int max) => min + rng.nextInt(max - min + 1);

/// Что выпадает при ломании блока в выживании.
List<ServerItem> _drops(int id, int meta, int toolId, math.Random rng) {
  if (!canHarvest(id, toolId)) return const [];
  final shears = toolId == 359;
  ServerItem one(int i, [int m = 0, int n = 1]) => ServerItem(i, m, n);
  switch (id) {
    case 1:
      return [meta == 0 ? one(4) : one(1, meta)];
    case 2:
    case 60:
    case 110:
      return [one(3)];
    case 16:
      return [one(263)];
    case 56:
      return [one(264)];
    case 21:
      return [one(351, 4, _randomRange(rng, 4, 8))];
    case 73:
    case 74:
      return [one(331, 0, _randomRange(rng, 4, 5))];
    case 129:
      return [one(388)];
    case 153:
      return [one(406)];
    case 89:
      return [one(348, 0, _randomRange(rng, 2, 4))];
    case 82:
      return [one(337, 0, 4)];
    case 80:
      return [one(332, 0, 4)];
    case 78:
      return [one(332)];
    case 47:
      return [one(340, 0, 3)];
    case 103:
      return [one(360, 0, _randomRange(rng, 3, 7))];
    case 13:
      return [rng.nextInt(10) == 0 ? one(318) : one(13)];
    case 18:
    case 161:
      if (shears) return [one(id, meta & 3)];
      return [
        if (rng.nextInt(20) == 0) one(6, id == 18 ? meta & 3 : 4 + (meta & 1)),
        if (id == 18 && (meta & 3) == 0 && rng.nextInt(200) == 0) one(260),
      ];
    case 31:
      if (shears) return [one(31, meta)];
      return [if (rng.nextInt(8) == 0) one(295)];
    case 17:
    case 162:
      return [one(id, meta & 3)];
    case 62:
      return [one(61)];
    case 43:
      return [one(44, meta & 7, 2)];
    case 44:
    case 158:
      return [one(id, meta & 7)];
    case 83:
      return [one(338)];
    case 20:
    case 102:
    case 79:
    case 174:
    case 7:
    case 30:
    case 51:
    case 52:
    case 26:
    case 64:
    case 71:
    case 59:
    case 92:
      return const [];
    default:
      return id > 0 && id < 256 ? [one(id, meta)] : const [];
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
  int _nextWindow = 1;
  int _tickCount = 0;
  final math.Random _rng = math.Random();
  final Map<String, _Container> _containers = {};
  final Map<int, _ItemEntity> _items = {};
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
    try {
      storage.readContainers().forEach((k, v) => _containers[k] = _Container.fromJson(k, v as Map<String, dynamic>));
    } on FormatException {
      _log.add('Не удалось прочитать containers.json');
    }
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
    storage.writeContainers({for (final c in _containers.values) c.key: c.toJson()});
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
      armor: p.armor.map((i) => i.toJson()).toList(),
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
          final seconds = breakSeconds(_blockId(x, y, z), p.held.id);
          if (!p.creative && seconds > 0 && seconds.isFinite) {
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
      case PacketId.containerSetSlot:
        final window = r.byte();
        final slot = r.varint();
        r.varint(); // слот хотбара
        final item = readItem(r);
        _onSetSlot(p, window, slot, ServerItem(item.id, item.meta, item.count));
        break;
      case PacketId.craftingEvent:
        _onCrafting(p, r);
        break;
      case PacketId.dropItem:
        r.byte();
        readItem(r);
        _onDrop(p);
        break;
      case PacketId.containerClose:
        final window = r.byte();
        if (window != 0) p.craftingBig = false;
        if (window == p.windowId) _closeWindow(p, notify: false);
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
      for (var i = 0; i < 4 && i < save.armor.length; i++) {
        final it = save.armor[i];
        p.armor[i] = ServerItem(it[0], it[1], it[2]);
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
      spCraftingData(),
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
      spContainerSetContent(ContainerIds.armor, p.entityId, p.armor, const []),
      spMobEquipment(p.entityId, p.held, p.heldIndex + 9, p.heldIndex),
      spSetTime(meta.time),
      spRespawn(p.x, p.y + _eyeHeight, p.z),
      spPlayStatus(PlayStatus.playerSpawn),
    ]);
    final joinMessage = spTranslation('§e%multiplayer.player.joined', [p.name]);
    _broadcast([joinMessage]);
    for (final o in _online) {
      if (o == p || !o.spawned) continue;
      _send(p, [_addPlayer(o), spMobArmorEquipment(o.entityId, o.armor)]);
      _send(o, [_addPlayer(p), spMobArmorEquipment(p.entityId, p.armor)]);
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
    _closeWindow(p, notify: false);
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
        _send(p, [
          spFullChunk(cx, cz, data),
          for (final e in _items.values)
            if (e.chunkKeyValue == key) spAddItemEntity(e.id, e.item, e.x, e.y, e.z, e.vx, e.vy, e.vz),
        ], level: 6);
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
    _tickItems();
    _tickFurnaces();
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
    final meta = _blockMeta(x, y, z);
    final tool = p.held;
    if (!p.creative) {
      final seconds = breakSeconds(id, tool.id);
      final started = p.breakStart;
      final sameBlock = p.breakX == x && p.breakY == y && p.breakZ == z;
      final elapsed = started == null ? 0 : DateTime.now().difference(started).inMilliseconds;
      if (!seconds.isFinite || (seconds > 0 && (!sameBlock || elapsed < seconds * 1000 * 0.75))) {
        _resendBlock(p, x, y, z);
        return;
      }
      for (final drop in _drops(id, meta, tool.id, _rng)) {
        _spawnItem(drop, x + 0.5, y + 0.3, z + 0.5,
            vx: (_rng.nextDouble() - 0.5) * 0.1, vy: 0.2, vz: (_rng.nextDouble() - 0.5) * 0.1);
      }
      _damageTool(p, id);
    }
    p.breakStart = null;
    final container = _containers.remove('$x,$y,$z');
    if (container != null) {
      for (final viewer in container.viewers.toList()) {
        _closeWindow(viewer);
      }
      for (final item in container.items) {
        if (!item.isEmpty) _spawnItem(item, x + 0.5, y + 0.5, z + 0.5, vx: (_rng.nextDouble() - 0.5) * 0.2, vy: 0.2, vz: (_rng.nextDouble() - 0.5) * 0.2);
      }
    }
    _setBlock(x, y, z, 0, 0);
    // Остальные игроки рядом видят и слышат разрушение блока.
    final destroy = spLevelEvent(LevelEventId.particleDestroy, x + 0.5, y + 0.5, z + 0.5, id | (meta << 8));
    final key = chunkKey(x >> 4, z >> 4);
    for (final other in _online) {
      if (other != p && other.sentChunks.contains(key)) _send(other, [destroy]);
    }
  }

  /// Износ инструмента после ломания блока.
  void _damageTool(_ServerPlayer p, int blockId) {
    final tool = p.held;
    final info = toolInfo[tool.id];
    if (info == null || blockRule(blockId).hardness == 0) return;
    final damage = tool.meta + (info.type == ToolType.sword ? 2 : 1);
    p.inventory[p.heldIndex] = damage >= info.durability ? ServerItem.air : ServerItem(tool.id, damage, 1);
    _send(p, [
      spContainerSetSlot(0, p.heldIndex, p.held),
      spMobEquipment(p.entityId, p.held, p.heldIndex + 9, p.heldIndex),
    ]);
  }

  /// Положить предмет в инвентарь; возвращает, сколько не поместилось.
  int _give(_ServerPlayer p, ServerItem item) {
    var left = item.count;
    final max = maxStackOf(item.id);
    final changed = <int>{};
    for (var pass = 0; pass < 2 && left > 0; pass++) {
      for (var i = 0; i < 36 && left > 0; i++) {
        final cur = p.inventory[i];
        if (pass == 0 && !cur.isEmpty && cur.id == item.id && cur.meta == item.meta && cur.count < max) {
          final add = math.min(left, max - cur.count);
          cur.count += add;
          left -= add;
          changed.add(i);
        } else if (pass == 1 && cur.isEmpty) {
          final add = math.min(left, max);
          p.inventory[i] = ServerItem(item.id, item.meta, add);
          left -= add;
          changed.add(i);
        }
      }
    }
    _send(p, [for (final i in changed) spContainerSetSlot(0, i, p.inventory[i])]);
    if (changed.contains(p.heldIndex)) _send(p, [spMobEquipment(p.entityId, p.held, p.heldIndex + 9, p.heldIndex)]);
    return left;
  }

  // ---------- Предметы в мире ----------

  void _spawnItem(ServerItem item, double x, double y, double z,
      {double vx = 0, double vy = 0, double vz = 0, int delay = 10}) {
    if (item.isEmpty) return;
    final e = _ItemEntity(_nextEntityId++, ServerItem(item.id, item.meta, item.count), x, y, z, vx, vy, vz, delay);
    _items[e.id] = e;
    final packet = spAddItemEntity(e.id, e.item, x, y, z, vx, vy, vz);
    for (final p in _online) {
      if (p.spawned && p.sentChunks.contains(e.chunkKeyValue)) _send(p, [packet]);
    }
  }

  bool _solidAt(double x, double y, double z) {
    final id = _blockId(x.floor(), y.floor(), z.floor());
    return id != 0 && blockTable[id].solid;
  }

  void _removeItem(_ItemEntity e) {
    _items.remove(e.id);
    final packet = spRemoveEntity(e.id);
    for (final p in _online) {
      if (p.sentChunks.contains(e.chunkKeyValue)) _send(p, [packet]);
    }
  }

  void _tickItems() {
    for (final e in _items.values.toList()) {
      e.age++;
      if (e.age > 6000 || e.y < -10) {
        _removeItem(e);
        continue;
      }
      if (e.pickupDelay > 0) e.pickupDelay--;
      final ox = e.x, oy = e.y, oz = e.z;
      if (!e.onGround || e.vx.abs() + e.vz.abs() > 0.001) {
        e.vy -= 0.04;
        final ny = e.y + e.vy;
        if (e.vy < 0 && _solidAt(e.x, ny, e.z)) {
          e
            ..y = ny.floor() + 1.0
            ..vy = 0
            ..onGround = true;
        } else {
          e
            ..y = ny
            ..onGround = false;
        }
        final nx = e.x + e.vx, nz = e.z + e.vz;
        if (!_solidAt(nx, e.y + 0.1, e.z)) {
          e.x = nx;
        } else {
          e.vx = 0;
        }
        if (!_solidAt(e.x, e.y + 0.1, nz)) {
          e.z = nz;
        } else {
          e.vz = 0;
        }
        final friction = e.onGround ? 0.5 : 0.98;
        e
          ..vx *= friction
          ..vz *= friction;
        // Предмет внутри блока выталкивается вверх.
        if (_solidAt(e.x, e.y + 0.1, e.z)) {
          e
            ..y = e.y.floor() + 1.0
            ..vy = 0;
        }
      } else if (!_solidAt(e.x, e.y - 0.05, e.z)) {
        e.onGround = false;
      }
      if ((e.x - ox).abs() + (e.y - oy).abs() + (e.z - oz).abs() > 0.001) {
        final packet = spMoveEntity(e.id, e.x, e.y, e.z, onGround: e.onGround);
        for (final p in _online) {
          if (p.sentChunks.contains(e.chunkKeyValue)) _send(p, [packet]);
        }
      }
      if (e.pickupDelay > 0) continue;
      for (final p in _online) {
        if (!p.spawned) continue;
        final dx = p.x - e.x, dz = p.z - e.z, dy = e.y - p.y;
        if (dx * dx + dz * dz > 1.5 * 1.5 || dy < -1 || dy > 2) continue;
        final left = _give(p, e.item);
        if (left == e.item.count) continue;
        final take = spTakeItemEntity(e.id, p.entityId);
        for (final o in _online) {
          if (o.sentChunks.contains(e.chunkKeyValue)) _send(o, [take]);
        }
        _removeItem(e);
        if (left > 0) _spawnItem(ServerItem(e.item.id, e.item.meta, left), e.x, e.y, e.z, delay: 0);
        break;
      }
    }
  }

  void _onDrop(_ServerPlayer p) {
    final item = p.held;
    if (!p.spawned || item.isEmpty) return;
    p.inventory[p.heldIndex] = ServerItem.air;
    _send(p, [spContainerSetSlot(0, p.heldIndex, p.held), spMobEquipment(p.entityId, p.held, p.heldIndex + 9, p.heldIndex)]);
    final yaw = p.yaw * math.pi / 180, pitch = p.pitch * math.pi / 180;
    final dx = -math.sin(yaw) * math.cos(pitch), dz = math.cos(yaw) * math.cos(pitch), dy = -math.sin(pitch);
    _spawnItem(item, p.x, p.y + 1.3, p.z, vx: dx * 0.3, vy: dy * 0.3 + 0.1, vz: dz * 0.3, delay: 40);
  }

  // ---------- Инвентарь, крафт, окна ----------

  List<ServerItem>? _slotsOf(_ServerPlayer p, int window) {
    if (window == ContainerIds.inventory) return p.inventory;
    if (window == ContainerIds.armor) return p.armor;
    if (window == p.windowId) return p.window?.items;
    return null;
  }

  void _resync(_ServerPlayer p) {
    p.transaction = null;
    _send(p, [
      _inventoryContent(p),
      spContainerSetContent(ContainerIds.armor, p.entityId, p.armor, const []),
      spMobEquipment(p.entityId, p.held, p.heldIndex + 9, p.heldIndex),
      if (p.window != null && p.windowId != null) spContainerSetContent(p.windowId!, p.entityId, p.window!.items, const []),
    ]);
  }

  void _onSetSlot(_ServerPlayer p, int window, int slot, ServerItem item) {
    final list = _slotsOf(p, window);
    if (!p.spawned || list == null || slot < 0 || slot >= (window == ContainerIds.inventory ? 36 : list.length)) return;
    final current = list[slot];
    if (current.id == item.id && current.meta == item.meta && current.count == item.count) return;
    if (item.count > maxStackOf(item.id) ||
        (window == ContainerIds.armor && !item.isEmpty && armorSlotOf(item.id) != slot)) {
      _resync(p);
      return;
    }
    if (p.creative && window == ContainerIds.inventory) {
      // В творчестве предметы берутся из творческого инвентаря без баланса.
      list[slot] = item.isEmpty ? ServerItem.air : item;
      if (slot == p.heldIndex) _send(p, [spMobEquipment(p.entityId, p.held, p.heldIndex + 9, p.heldIndex)]);
      return;
    }
    var tx = p.transaction;
    if (tx == null || DateTime.now().difference(tx.created) > const Duration(seconds: 8)) {
      if (tx != null) _resync(p);
      tx = p.transaction = _Transaction();
    }
    final key = (window, slot);
    final old = tx.changes[key]?.$1 ?? current;
    tx.changes[key] = (old, item);
    if (!tx.balanced) return;
    p.transaction = null;
    var armorChanged = false;
    final touched = <_Container>{};
    for (final e in tx.changes.entries) {
      final target = _slotsOf(p, e.key.$1);
      if (target == null) continue;
      final now = e.value.$2;
      target[e.key.$2] = now.isEmpty ? ServerItem.air : ServerItem(now.id, now.meta, now.count);
      if (e.key.$1 == ContainerIds.armor) armorChanged = true;
      if (e.key.$1 == p.windowId && p.window != null) touched.add(p.window!);
    }
    _send(p, [spMobEquipment(p.entityId, p.held, p.heldIndex + 9, p.heldIndex)]);
    if (armorChanged) _broadcast([spMobArmorEquipment(p.entityId, p.armor)], except: p);
    for (final c in touched) {
      for (final viewer in c.viewers) {
        if (viewer == p || viewer.windowId == null) continue;
        _send(viewer, [spContainerSetContent(viewer.windowId!, viewer.entityId, c.items, const [])]);
      }
    }
  }

  void _onCrafting(_ServerPlayer p, BinaryReader r) {
    r.byte(); // окно
    r.varint(); // тип
    final uuid = r.bytes(16);
    final input = [for (var n = r.uvarint(), i = 0; i < n && i < 128; i++) readItem(r)];
    final output = [for (var n = r.uvarint(), i = 0; i < n && i < 128; i++) readItem(r)];
    final recipe = recipeByUuid(uuid);
    if (!p.spawned || recipe == null || output.isEmpty || (recipe.big && !p.craftingBig) || input.length < 9) {
      _resync(p);
      return;
    }
    final items = [for (var i = 0; i < 9; i++) input[i].isEmpty ? null : input[i]];
    var ok = true;
    if (!recipe.shapeless) {
      for (var y = 0; y < 3 && ok; y++) {
        for (var x = 0; x < 3; x++) {
          final ing = recipe.at(x, y);
          final item = items[y * 3 + x];
          if ((ing == null) != (item == null) || (ing != null && !ingredientMatches(ing, item!.id, item.meta))) {
            ok = false;
            break;
          }
        }
      }
    } else {
      final needed = [...recipe.cells];
      for (final item in items.whereType<ItemStack>()) {
        final k = needed.indexWhere((n) => n != null && ingredientMatches(n, item.id, item.meta));
        if (k < 0) {
          ok = false;
          break;
        }
        needed.removeAt(k);
      }
      if (needed.isNotEmpty) ok = false;
    }
    final out = output.first;
    if (!ok || out.id != recipe.result.id || out.meta != recipe.result.meta || out.count != recipe.result.count) {
      _resync(p);
      return;
    }
    // Ингредиенты забираются из инвентаря.
    final used = List<int>.filled(36, 0);
    for (final item in items.whereType<ItemStack>()) {
      var found = false;
      for (var i = 0; i < 36; i++) {
        final inv = p.inventory[i];
        if (!inv.isEmpty && inv.id == item.id && inv.meta == item.meta && inv.count - used[i] >= 1) {
          used[i]++;
          found = true;
          break;
        }
      }
      if (!found) {
        _resync(p);
        return;
      }
    }
    final changed = <Uint8List>[];
    for (var i = 0; i < 36; i++) {
      if (used[i] == 0) continue;
      final inv = p.inventory[i];
      p.inventory[i] = inv.count > used[i] ? ServerItem(inv.id, inv.meta, inv.count - used[i]) : ServerItem.air;
      changed.add(spContainerSetSlot(0, i, p.inventory[i]));
    }
    _send(p, changed);
    final left = _give(p, recipe.result);
    if (left > 0) _spawnItem(ServerItem(recipe.result.id, recipe.result.meta, left), p.x, p.y + 1.3, p.z, delay: 40);
    _send(p, [spMobEquipment(p.entityId, p.held, p.heldIndex + 9, p.heldIndex)]);
  }

  void _openWindow(_ServerPlayer p, _Container c) {
    _closeWindow(p);
    final id = _nextWindow;
    _nextWindow = _nextWindow >= 99 ? 1 : _nextWindow + 1;
    p
      ..windowId = id
      ..window = c;
    c.viewers.add(p);
    _send(p, [
      spContainerOpen(id, c.furnace ? WindowType.furnace : WindowType.container, c.x, c.y, c.z, p.entityId),
      spContainerSetContent(id, p.entityId, c.items, const []),
      if (c.furnace) ...[
        spContainerSetData(id, 0, c.cook),
        spContainerSetData(id, 1, c.burn),
        spContainerSetData(id, 2, c.maxBurn),
      ],
    ]);
  }

  void _closeWindow(_ServerPlayer p, {bool notify = true}) {
    final id = p.windowId;
    p.window?.viewers.remove(p);
    p
      ..window = null
      ..windowId = null
      ..transaction = null;
    if (id != null && notify) _send(p, [spContainerClose(id)]);
  }

  void _tickFurnaces() {
    for (final c in _containers.values) {
      if (!c.furnace) continue;
      final input = c.items[0], fuel = c.items[1], out = c.items[2];
      final result = input.isEmpty ? null : smeltResult(input.id, input.meta);
      final canSmelt = result != null &&
          (out.isEmpty || (out.id == result.id && out.meta == result.meta && out.count + result.count <= maxStackOf(out.id)));
      final wasBurning = c.burn > 0;
      var slotsChanged = false;
      if (c.burn > 0) c.burn--;
      if (c.burn == 0 && canSmelt && !fuel.isEmpty) {
        final ticks = fuelTicks(fuel.id, fuel.meta);
        if (ticks > 0) {
          c
            ..burn = ticks
            ..maxBurn = ticks;
          if (fuel.id == 325) {
            c.items[1] = ServerItem(325, 0, 1);
          } else {
            c.items[1] = fuel.count > 1 ? ServerItem(fuel.id, fuel.meta, fuel.count - 1) : ServerItem.air;
          }
          slotsChanged = true;
        }
      }
      if (c.burn > 0 && canSmelt) {
        c.cook++;
        if (c.cook >= 200) {
          c.cook = 0;
          c.items[0] = input.count > 1 ? ServerItem(input.id, input.meta, input.count - 1) : ServerItem.air;
          c.items[2] = out.isEmpty ? ServerItem(result.id, result.meta, result.count) : ServerItem(out.id, out.meta, out.count + result.count);
          slotsChanged = true;
        }
      } else if (c.cook > 0) {
        c.cook = math.max(0, c.cook - 2);
      }
      final burning = c.burn > 0;
      if (burning != wasBurning) {
        final id = _blockId(c.x, c.y, c.z);
        if (id == 61 || id == 62) _setBlock(c.x, c.y, c.z, burning ? 62 : 61, _blockMeta(c.x, c.y, c.z));
      }
      for (final v in c.viewers) {
        final w = v.windowId;
        if (w == null) continue;
        _send(v, [
          if (slotsChanged) spContainerSetContent(w, v.entityId, c.items, const []),
          if (slotsChanged || _tickCount % 5 == 0) ...[
            spContainerSetData(w, 0, c.cook),
            spContainerSetData(w, 1, c.burn),
            spContainerSetData(w, 2, c.maxBurn),
          ],
        ]);
      }
    }
  }

  /// Направление «лицом к игроку» для печи и сундука (мета 2..5).
  int _facingMeta(_ServerPlayer p) {
    final yaw = ((p.yaw % 360) + 360) % 360;
    if (yaw >= 45 && yaw < 135) return 5;
    if (yaw >= 135 && yaw < 225) return 3;
    if (yaw >= 225 && yaw < 315) return 4;
    return 2;
  }

  void _onUseItem(_ServerPlayer p, BinaryReader r) {
    final x = r.varint(), y = r.uvarint(), z = r.varint();
    r.uvarint(); // блок, по которому кликнули
    final face = r.varint();
    if (!p.spawned || face < 0 || face > 5) return;
    // Блоки, которые открываются нажатием: верстак, сундук, печь.
    final target = _blockId(x, y, z);
    if (_inReach(p, x, y, z)) {
      if (target == 58) {
        p.craftingBig = true;
        return;
      }
      if (target == 54 || target == 61 || target == 62) {
        _openWindow(p, _containers.putIfAbsent('$x,$y,$z', () => _Container(target != 54, x, y, z)));
        return;
      }
    }
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
    final facing = held.id == 54 || held.id == 61;
    _setBlock(tx, ty, tz, held.id, facing ? _facingMeta(p) : held.meta);
    if (facing) _containers['$tx,$ty,$tz'] = _Container(held.id == 61, tx, ty, tz);
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
    'give': (
      'Выдать предмет: /give <ID> [количество] [мета]',
      {
        'default': [
          {'name': 'item', 'type': 'int', 'optional': false},
          {'name': 'amount', 'type': 'int', 'optional': true},
          {'name': 'data', 'type': 'int', 'optional': true},
        ],
      }
    ),
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
      case 'give':
        final id = args.isEmpty ? null : int.tryParse(args[0]);
        final amount = args.length > 1 ? int.tryParse(args[1]) ?? 1 : 1;
        final data = args.length > 2 ? int.tryParse(args[2]) ?? 0 : 0;
        if (id == null || id <= 0 || id > 511 || amount < 1 || amount > 640) {
          _message(p, '§cИспользование: /give <ID> [количество] [мета]');
          return;
        }
        final left = _give(p, ServerItem(id, data, amount));
        if (left > 0) _spawnItem(ServerItem(id, data, left), p.x, p.y + 1.3, p.z, delay: 40);
        _message(p, 'Выдано: ${itemTitle(id, data)} ×$amount');
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
