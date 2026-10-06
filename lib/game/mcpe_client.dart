import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../protocol/binary.dart';
import '../protocol/crypto.dart';
import '../protocol/login.dart';
import '../protocol/packets.dart';
import '../protocol/raknet.dart';
import '../protocol/skin.dart';
import '../world/blocks.dart';
import '../world/player.dart';
import '../world/renderer.dart';
import '../world/world.dart';
import 'commands.dart';
import 'crafting.dart';
import 'items.dart';
import 'lang.dart';

enum ConnectionPhase { idle, connecting, loggingIn, spawning, playing, disconnected }

enum ChatKind { chat, system, local, error }

enum SoundKind { breakBlock, placeBlock, step, hit, hurt, pickup }

/// Слот: окно (0 — инвентарь, 0x78 — броня или ID открытого контейнера) и номер.
class SlotRef {
  const SlotRef(this.window, this.index);

  final int window;
  final int index;

  @override
  bool operator ==(Object other) => other is SlotRef && other.window == window && other.index == index;

  @override
  int get hashCode => Object.hash(window, index);
}

/// Открытое окно: сундук, печь (от сервера) или верстак (открывается клиентом, ID −1).
class OpenContainer {
  OpenContainer(this.windowId, this.type, this.pos, int size) : slots = List.filled(size, ItemStack.empty, growable: true);

  final int windowId;
  final int type;
  final BlockPos? pos;
  List<ItemStack> slots;

  /// Свойства окна (печь: 0 — прогресс плавки, 1 — остаток топлива, 2 — полное время топлива).
  final Map<int, int> data = {};
}

/// Предмет, лежащий в мире.
class ItemEntity {
  ItemEntity(this.uniqueId, this.item, this.position);

  final int uniqueId;
  final ItemStack item;
  Vec3 position;
}

/// Игровой звук: вид, блок (его материал определяет звук) и громкость 0..1.
class GameSound {
  const GameSound(this.kind, this.blockId, this.volume);

  final SoundKind kind;
  final int blockId;
  final double volume;
}

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
}

/// Другой игрок, видимый в мире (по AddPlayer). Позиция — ноги.
class RemotePlayer {
  RemotePlayer(this.uniqueId, this.name, this.position);

  final int uniqueId;
  final String name;
  Vec3 position;
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

/// Сетевой клиент MCPE 1.1.x (протокол 113) с миром и локальной физикой игрока.
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

  /// Срабатывает при изменении состояния, важного для интерфейса.
  Stream<void> get changes => _changes.stream;

  final StreamController<GameSound> _sounds = StreamController<GameSound>.broadcast();

  /// Звуки ломания, установки блоков, шагов и урона.
  Stream<GameSound> get sounds => _sounds.stream;

  RakNetClient? _rak;
  PacketCipher? _cipher;
  LoginData? _login;
  Completer<void>? _spawned;
  Timer? _tickTimer;
  int _tickCount = 0;

  ConnectionPhase phase = ConnectionPhase.idle;
  String? disconnectReason;
  TransferTarget? transferTarget;
  bool encrypted = false;

  final List<ChatLine> chat = [];
  static const _chatLimit = 500;

  final Map<String, OnlinePlayer> players = {};
  final Map<int, RemotePlayer> remotePlayers = {};
  final CommandRegistry commands = CommandRegistry();

  final World level = World();
  final PlayerController player = PlayerController();

  /// Время последнего тика физики — для плавной интерполяции камеры.
  DateTime lastTick = DateTime.now();
  double prevX = 0, prevY = 0, prevZ = 0;
  bool hasPosition = false;

  StartGameData? startGame;
  int? _runtimeId;
  int gamemode = 0;
  int difficulty = 0;
  int worldTime = 0;
  int serverChunkRadius = 5;
  double health = 20;
  double maxHealth = 20;
  double food = 20;
  int xpLevel = 0;
  bool dead = false;

  int _adventureFlags = 0;
  int _permission = 0;
  bool get allowFlight => (_adventureFlags & (1 << 6)) != 0;

  // Инвентарь.
  List<ItemStack> inventory = [];
  List<int> hotbarLinks = List.filled(9, -1);
  List<ItemStack> creativeItems = [];
  int selectedHotbar = 0;
  ItemStack heldItem = ItemStack.empty;
  List<ItemStack> armor = List.filled(4, ItemStack.empty);

  /// Рецепты, присланные сервером.
  List<CraftingRecipe> recipes = [];
  List<FurnaceRecipe> furnaceRecipes = [];

  /// Открытое окно (сундук, печь, верстак) или null.
  OpenContainer? container;

  /// Предметы на земле по runtime ID.
  final Map<int, ItemEntity> itemEntities = {};

  // Ломание блока.
  bool _breakHeld = false;
  DateTime _nextBreakAt = DateTime(0);
  BlockPos? breakingBlock;
  int _breakFace = 0;
  DateTime? _breakStart;
  Duration? _breakDuration;

  // Звуки: пройденное расстояние до следующего шага, ожидаемая установка блока, последний сломанный блок.
  double _walked = 0;
  BlockPos? _placeAt;
  BlockPos? _placeAgainst;
  DateTime _placeTime = DateTime(0);
  BlockPos? _lastBroken;
  DateTime _lastBrokenTime = DateTime(0);

  // Последняя отправленная позиция.
  double _sentX = 0, _sentY = 0, _sentZ = 0, _sentYaw = 0, _sentPitch = 0;

  ScreenMessage? title;
  ScreenMessage? subtitle;
  ScreenMessage? actionBar;
  ScreenMessage? popup;
  ScreenMessage? tip;
  int _titleFadeIn = 10;
  int _titleStay = 70;
  int _titleFadeOut = 20;

  int get latencyMs => _rak?.latencyMs ?? 0;

  bool get isCreative => gamemode == 1;

  /// Позиция ног игрока.
  Vec3? get position => hasPosition ? Vec3(player.x, player.y, player.z) : null;

  /// Доля завершения ломания (0..1) или null.
  double? get breakProgress {
    final start = _breakStart, duration = _breakDuration;
    if (breakingBlock == null || start == null) return null;
    if (duration == null) return 0;
    if (duration == Duration.zero) return 1;
    return (DateTime.now().difference(start).inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  ItemStack hotbarItem(int index) {
    final link = hotbarLinks[index];
    final slot = link - 9;
    if (link < 9 || slot >= inventory.length) return ItemStack.empty;
    return inventory[slot];
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _sound(SoundKind kind, int blockId, [double volume = 1]) {
    if (!_sounds.isClosed && volume > 0) _sounds.add(GameSound(kind, blockId, volume));
  }

  /// Громкость звука в точке по расстоянию до игрока (слышно до 16 блоков).
  double _volumeAt(double x, double y, double z) {
    final dx = x - player.x, dy = y - player.y, dz = z - player.z;
    return (1 - math.sqrt(dx * dx + dy * dy + dz * dz) / 16).clamp(0.0, 1.0);
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
    // Ошибку ожидания появления в мире получает connect(); если вход сорвался раньше, её никто не ждёт.
    _spawned!.future.ignore();
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
    _tickTimer?.cancel();
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
    _tickTimer?.cancel();
    _changes.close();
    _sounds.close();
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
        remotePlayers[runtimeId] = RemotePlayer(uniqueId, name, pos);
        _notify();
        break;
      case PacketId.removeEntity:
        final uniqueId = r.varint();
        remotePlayers.removeWhere((_, p) => p.uniqueId == uniqueId);
        itemEntities.removeWhere((_, e) => e.uniqueId == uniqueId);
        _notify();
        break;
      case PacketId.addItemEntity:
        final uniqueId = r.varint();
        final runtimeId = r.uvarint();
        final item = readItem(r);
        itemEntities[runtimeId] = ItemEntity(uniqueId, item, Vec3.read(r));
        break;
      case PacketId.moveEntity:
        final runtimeId = r.uvarint();
        final entity = itemEntities[runtimeId];
        if (entity != null) entity.position = Vec3.read(r);
        break;
      case PacketId.takeItemEntity:
        final target = r.uvarint();
        final taker = r.uvarint();
        final taken = itemEntities.remove(target);
        if (taken != null && taker == _runtimeId) _sound(SoundKind.pickup, 0, 0.5);
        break;
      case PacketId.mobArmorEquipment:
        final runtimeId = r.uvarint();
        final slots = [for (var i = 0; i < 4; i++) readItem(r)];
        if (runtimeId == _runtimeId) {
          armor = slots;
          _notify();
        }
        break;
      case PacketId.containerOpen:
        final window = r.byte();
        final type = r.byte();
        final x = r.varint(), y = r.uvarint(), z = r.varint();
        container = OpenContainer(window, type, BlockPos(x, y, z), type == WindowType.furnace ? 3 : 27);
        _notify();
        break;
      case PacketId.containerClose:
        final window = r.byte();
        if (container?.windowId == window) {
          container = null;
          _notify();
        }
        break;
      case PacketId.containerSetData:
        final window = r.byte();
        final property = r.varint();
        final value = r.varint();
        final c = container;
        if (c != null && c.windowId == window) {
          c.data[property] = value;
          _notify();
        }
        break;
      case PacketId.craftingData:
        final data = readCraftingData(r);
        recipes = data.recipes;
        furnaceRecipes = data.furnace;
        _notify();
        break;
      case PacketId.movePlayer:
        final move = MovePlayerData.read(r);
        if (move.runtimeIdRaw == _runtimeId) {
          _teleport(move.position);
        } else {
          final remote = remotePlayers[move.runtimeIdRaw];
          if (remote != null) {
            remote.position = Vec3(move.position.x, move.position.y - eyeHeight, move.position.z);
          }
        }
        break;
      case PacketId.updateBlock:
        final x = r.varint(), y = r.uvarint(), z = r.varint();
        final blockId = r.uvarint();
        final flagsMeta = r.uvarint();
        final previous = level.blockId(x, y, z);
        level.setBlock(x, y, z, blockId, flagsMeta & 0x0f);
        _onBlockChanged(BlockPos(x, y, z), previous, blockId);
        break;
      case PacketId.levelEvent:
        _onLevelEvent(r.varint(), Vec3.read(r), r.varint());
        break;
      case PacketId.updateAttributes:
        final runtimeId = r.uvarint();
        if (runtimeId == _runtimeId) _onAttributes(readAttributes(r));
        break;
      case PacketId.mobEquipment:
        final runtimeId = r.uvarint();
        final item = readItem(r);
        r.byte(); // слот инвентаря
        final selected = r.byte();
        if (runtimeId == _runtimeId || runtimeId == 0) {
          heldItem = item;
          if (selected < 9) selectedHotbar = selected;
          _notify();
        }
        break;
      case PacketId.respawn:
        _teleportAmbiguous(Vec3.read(r));
        break;
      case PacketId.containerSetSlot:
        final window = r.byte();
        final slot = r.varint();
        r.varint(); // слот хотбара
        final item = readItem(r);
        if (slot >= 0 && _putSlot(SlotRef(window, slot), item)) {
          _refreshHeld();
          _notify();
        }
        break;
      case PacketId.containerSetContent:
        _onContainerContent(r);
        break;
      case PacketId.adventureSettings:
        _adventureFlags = r.uvarint();
        _permission = r.uvarint();
        if (!allowFlight) player.flying = false;
        _notify();
        break;
      case PacketId.fullChunkData:
        final cx = r.varint(), cz = r.varint();
        level.putChunk(Chunk.parse(cx, cz, r.byteArray()));
        _resolveSpawn();
        break;
      case PacketId.changeDimension:
        level.clear();
        remotePlayers.clear();
        break;
      case PacketId.setDifficulty:
        difficulty = r.uvarint();
        _notify();
        break;
      case PacketId.setPlayerGameType:
        gamemode = r.varint();
        if (gamemode != 1) player.flying = false;
        _notify();
        break;
      case PacketId.playerList:
        _onPlayerList(PlayerListUpdate.read(r));
        break;
      case PacketId.chunkRadiusUpdated:
        serverChunkRadius = r.varint();
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

  void _onContainerContent(BinaryReader r) {
    final window = r.uvarint();
    r.uvarint(); // ID сущности
    final count = r.uvarint();
    final items = <ItemStack>[];
    for (var i = 0; i < count; i++) {
      items.add(readItem(r));
    }
    final hotbarCount = r.eof ? 0 : r.uvarint();
    final hotbar = <int>[];
    for (var i = 0; i < hotbarCount; i++) {
      hotbar.add(r.varint());
    }
    if (window == ContainerIds.inventory) {
      inventory = [...items, for (var i = items.length; i < 36; i++) ItemStack.empty];
      if (hotbar.isNotEmpty) {
        hotbarLinks = List.generate(9, (i) => i < hotbar.length ? hotbar[i] : -1);
      }
      _refreshHeld();
    } else if (window == ContainerIds.armor) {
      armor = [for (var i = 0; i < 4; i++) i < items.length ? items[i] : ItemStack.empty];
    } else if (container?.windowId == window) {
      container!.slots = items;
    } else if (window == ContainerIds.creative) {
      creativeItems = items.where((i) => !i.isEmpty).toList();
    }
    _notify();
  }

  void _onPlayStatus(int status) {
    switch (status) {
      case PlayStatus.loginSuccess:
        break;
      case PlayStatus.playerSpawn:
        phase = ConnectionPhase.playing;
        _tickTimer?.cancel();
        _tickTimer = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
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
    startGame = data;
    _runtimeId = data.runtimeIdRaw;
    level.clear();
    remotePlayers.clear();
    player.yaw = data.yaw;
    player.pitch = data.pitch;
    _teleportAmbiguous(data.position);
    gamemode = data.playerGamemode;
    difficulty = data.difficulty;
    worldTime = data.time;
    phase = ConnectionPhase.spawning;
    _sendPacket(buildRequestChunkRadius(chunkRadius));
    _notify();
  }

  Vec3? _ambiguousSpawn;

  /// StartGame и Respawn: PocketMine присылает координаты глаз, Nukkit — ног.
  /// Сначала считаем их глазами; когда чанк загружен, проверяем, не оказался ли игрок в блоках.
  void _teleportAmbiguous(Vec3 pos) {
    _teleport(pos);
    _ambiguousSpawn = pos;
    _resolveSpawn();
  }

  void _resolveSpawn() {
    final pos = _ambiguousSpawn;
    if (pos == null || !level.isLoaded(pos.x.floor(), pos.z.floor())) return;
    _ambiguousSpawn = null;
    if (player.collidesAt(level, pos.x, pos.y - eyeHeight, pos.z) && !player.collidesAt(level, pos.x, pos.y, pos.z)) {
      _teleport(Vec3(pos.x, pos.y + eyeHeight, pos.z));
    }
  }

  /// Позиция от сервера (координаты глаз).
  void _teleport(Vec3 eye) {
    _ambiguousSpawn = null;
    player.setEyePosition(eye.x, eye.y, eye.z);
    prevX = player.x;
    prevY = player.y;
    prevZ = player.z;
    _sentX = player.x;
    _sentY = player.y;
    _sentZ = player.z;
    hasPosition = true;
    _notify();
  }

  void _onBlockChanged(BlockPos pos, int previous, int current) {
    if (current == 0 || current == previous) return;
    final recent = DateTime.now().difference(_placeTime) < const Duration(seconds: 2);
    if (recent && (pos == _placeAt || pos == _placeAgainst)) {
      _placeAt = _placeAgainst = null;
      _sound(SoundKind.placeBlock, current);
    }
  }

  void _onLevelEvent(int event, Vec3 pos, int data) {
    if (event == LevelEventId.particleDestroy) {
      // Блок сломал другой игрок (свой уже озвучен при ломании).
      final p = BlockPos(pos.x.floor(), pos.y.floor(), pos.z.floor());
      final own = p == _lastBroken && DateTime.now().difference(_lastBrokenTime) < const Duration(seconds: 2);
      if (!own) _sound(SoundKind.breakBlock, data & 0xff, _volumeAt(pos.x, pos.y, pos.z));
      return;
    }
    final b = breakingBlock;
    if (event != LevelEventId.blockStartBreak || b == null || data <= 0) return;
    if (pos.x.floor() == b.x && pos.y.floor() == b.y && pos.z.floor() == b.z) {
      _breakDuration = Duration(milliseconds: (65535 / data * 50).round());
    }
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
          if (hasPosition && a.value < health && a.value > 0) _sound(SoundKind.hurt, 0);
          health = a.value;
          maxHealth = a.max;
          final wasDead = dead;
          dead = a.value <= 0;
          if (dead && !wasDead) {
            _addChat('Вы погибли', ChatKind.local);
            setBreaking(false);
          }
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
        players[e.uuid] = OnlinePlayer(e.uuid, e.uniqueId, e.name);
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

  // ---------- Игровой цикл ----------

  void _tick() {
    if (phase != ConnectionPhase.playing || !hasPosition) return;
    _tickCount++;
    prevX = player.x;
    prevY = player.y;
    prevZ = player.z;
    lastTick = DateTime.now();
    if (!dead) {
      player.tick(level);
      _footsteps();
      _sendMovement();
      _updateBreaking();
    }
    if (_tickCount % 40 == 0) {
      level.unloadFar(player.x.floor() >> 4, player.z.floor() >> 4, serverChunkRadius + 3);
    }
    if (_tickCount % 5 == 0) _notify();
  }

  /// Звук шага примерно каждые полтора блока ходьбы по земле.
  void _footsteps() {
    if (!player.onGround || player.flying || player.inWater) {
      _walked = 0;
      return;
    }
    final dx = player.x - prevX, dz = player.z - prevZ;
    _walked += math.sqrt(dx * dx + dz * dz);
    if (_walked < 1.6) return;
    _walked = 0;
    final below = level.blockId(player.x.floor(), (player.y - 0.2).floor(), player.z.floor());
    if (below != 0) _sound(SoundKind.step, below, 0.3);
  }

  void _sendMovement() {
    final id = _runtimeId;
    if (id == null) return;
    final moved = (player.x - _sentX).abs() > 1e-3 || (player.y - _sentY).abs() > 1e-3 || (player.z - _sentZ).abs() > 1e-3;
    final turned = (player.yaw - _sentYaw).abs() > 0.5 || (player.pitch - _sentPitch).abs() > 0.5;
    if (!moved && !turned) return;
    _sentX = player.x;
    _sentY = player.y;
    _sentZ = player.z;
    _sentYaw = player.yaw;
    _sentPitch = player.pitch;
    _sendPacket(buildMovePlayer(id, Vec3(player.x, player.eyeY, player.z), player.pitch, _normalizedYaw, player.onGround));
  }

  double get _normalizedYaw {
    final y = player.yaw % 360;
    return y < 0 ? y + 360 : y;
  }

  double get _reach => isCreative ? 7 : 5;

  // ---------- Действия игрока ----------

  /// Кнопка «ломать» нажата или отпущена.
  void setBreaking(bool pressed) {
    if (pressed) {
      if (phase != ConnectionPhase.playing || dead) return;
      _breakHeld = true;
      _beginBreak();
      return;
    }
    _breakHeld = false;
    final id = _runtimeId;
    final b = breakingBlock;
    if (b != null && id != null) {
      _sendPacket(buildPlayerAction(id, PlayerActionType.abortBreak, b.x, b.y, b.z, face: _breakFace));
    }
    breakingBlock = null;
    _breakStart = null;
    _notify();
  }

  void _beginBreak() {
    final id = _runtimeId;
    final hit = player.raycast(level, _reach);
    if (id == null || hit == null) {
      breakingBlock = null;
      return;
    }
    breakingBlock = hit.block;
    _breakFace = hit.face;
    _breakStart = DateTime.now();
    _breakDuration = isCreative ? Duration.zero : null;
    _sendPacket(buildPlayerAction(id, PlayerActionType.startBreak, hit.block.x, hit.block.y, hit.block.z, face: hit.face));
  }

  void _updateBreaking() {
    final b = breakingBlock;
    final id = _runtimeId;
    if (!_breakHeld || id == null) return;
    final now = DateTime.now();
    if (b == null) {
      if (now.isAfter(_nextBreakAt)) _beginBreak();
      return;
    }
    final hit = player.raycast(level, _reach);
    if (hit == null || hit.block != b) {
      _sendPacket(buildPlayerAction(id, PlayerActionType.abortBreak, b.x, b.y, b.z, face: _breakFace));
      _beginBreak();
      return;
    }
    final elapsed = now.difference(_breakStart!);
    // Сервер не прислал время ломания — значит, блок ломается мгновенно.
    if (_breakDuration == null && elapsed > const Duration(milliseconds: 400)) _breakDuration = Duration.zero;
    final duration = _breakDuration;
    if (duration == null || elapsed < duration) {
      if (_tickCount % 4 == 0) _sound(SoundKind.hit, level.blockId(b.x, b.y, b.z), 0.25);
      return;
    }
    _sound(SoundKind.breakBlock, level.blockId(b.x, b.y, b.z));
    _lastBroken = b;
    _lastBrokenTime = now;
    _sendPacket(buildPlayerAction(id, PlayerActionType.stopBreak, b.x, b.y, b.z, face: _breakFace));
    _sendPacket(buildRemoveBlock(b.x, b.y, b.z));
    level.setBlock(b.x, b.y, b.z, 0, 0);
    breakingBlock = null;
    _breakStart = null;
    // В творчестве блоки ломаются мгновенно — пауза, чтобы не снести всё подряд.
    _nextBreakAt = now.add(Duration(milliseconds: isCreative ? 250 : 0));
  }

  /// Использовать предмет в руке на блок (поставить блок, открыть дверь и т. п.).
  void useItemOnBlock() {
    final id = _runtimeId;
    if (id == null || phase != ConnectionPhase.playing || dead) return;
    final hit = player.raycast(level, _reach);
    if (hit == null) return;
    final item = heldItem;
    if (!item.isEmpty && item.id < 256 && blockTable[item.id].solid && player.intersects(hit.adjacent)) return;
    final target = level.blockId(hit.block.x, hit.block.y, hit.block.z);
    if (target != 58) {
      _placeAt = hit.adjacent;
      _placeAgainst = hit.block;
      _placeTime = DateTime.now();
    }
    _sendPacket(buildUseItem(
      x: hit.block.x,
      y: hit.block.y,
      z: hit.block.z,
      targetBlockId: level.blockId(hit.block.x, hit.block.y, hit.block.z),
      face: hit.face,
      fx: hit.fx,
      fy: hit.fy,
      fz: hit.fz,
      eye: Vec3(player.x, player.eyeY, player.z),
      hotbarSlot: selectedHotbar,
      item: item,
    ));
    // Верстак в 1.1 открывается самим клиентом; сервер после нажатия разрешает крафт 3×3.
    if (target == 58) {
      container = OpenContainer(-1, WindowType.workbench, hit.block, 0);
      _notify();
    }
  }

  void selectHotbar(int index) {
    final id = _runtimeId;
    if (id == null || index < 0 || index > 8) return;
    final link = hotbarLinks[index];
    final item = hotbarItem(index);
    selectedHotbar = index;
    heldItem = item;
    _sendPacket(buildMobEquipment(id, item, link < 9 ? 255 : link, index));
    _notify();
  }

  /// Творчество: взять предмет из творческого инвентаря в выбранный слот хотбара.
  void takeCreativeItem(ItemStack item) {
    final id = _runtimeId;
    if (id == null || !isCreative) return;
    heldItem = item;
    _sendPacket(buildMobEquipment(id, item, selectedHotbar + 9, selectedHotbar));
    _notify();
  }

  void toggleFlight() {
    if (!allowFlight) return;
    player.flying = !player.flying;
    final flags = player.flying ? _adventureFlags | (1 << 9) : _adventureFlags & ~(1 << 9);
    _adventureFlags = flags;
    _sendPacket(buildAdventureSettings(flags, _permission));
    _notify();
  }

  // ---------- Инвентарь ----------

  List<ItemStack>? _slotList(int window) {
    if (window == ContainerIds.inventory) return inventory;
    if (window == ContainerIds.armor) return armor;
    final c = container;
    return c != null && c.windowId == window && window >= 0 ? c.slots : null;
  }

  bool _putSlot(SlotRef ref, ItemStack item) {
    final list = _slotList(ref.window);
    if (list == null) return false;
    if (ref.index >= list.length) {
      if (ref.window != ContainerIds.inventory) return false;
      inventory = [...inventory, ...List.filled(ref.index + 1 - inventory.length, ItemStack.empty)];
      inventory[ref.index] = item;
      return true;
    }
    list[ref.index] = item;
    return true;
  }

  ItemStack itemAt(SlotRef ref) {
    final list = _slotList(ref.window);
    return list != null && ref.index < list.length ? list[ref.index] : ItemStack.empty;
  }

  /// Слот инвентаря, привязанный к позиции хотбара, или −1.
  int hotbarSlotIndex(int position) {
    final link = hotbarLinks[position];
    return link < 9 ? -1 : link - 9;
  }

  void _refreshHeld() {
    if (isCreative && heldItem.id > 0 && hotbarItem(selectedHotbar).isEmpty) return;
    heldItem = hotbarItem(selectedHotbar);
  }

  /// Изменение слотов: отправляется на сервер одной группой (сервер принимает её, если
  /// предметы только переложены, а не созданы), локально применяется сразу.
  void setSlots(List<(SlotRef, ItemStack)> changes) {
    if (phase != ConnectionPhase.playing || dead) return;
    for (final (ref, item) in changes) {
      if (!_putSlot(ref, item)) continue;
      _sendPacket(buildContainerSetSlot(ref.window, ref.index, item));
    }
    _refreshHeld();
    _notify();
  }

  /// Скрафтить найденный рецепт: сервер сам заберёт ингредиенты из инвентаря и выдаст результат.
  void craft(CraftMatch match) {
    if (phase != ConnectionPhase.playing || dead) return;
    final workbench = container?.type == WindowType.workbench;
    _sendPacket(buildCraftingEvent(
      window: ContainerIds.inventory,
      type: workbench ? 1 : 0,
      uuid: match.recipe.uuid,
      input: match.input,
      output: [match.recipe.result],
    ));
  }

  /// Выбросить стопку из слота инвентаря. Сервер выбрасывает предмет из руки,
  /// поэтому стопка сначала перекладывается в выбранный слот хотбара.
  void dropSlot(int slot) {
    if (phase != ConnectionPhase.playing || dead) return;
    final item = itemAt(SlotRef(ContainerIds.inventory, slot));
    final hand = hotbarSlotIndex(selectedHotbar);
    if (item.isEmpty || hand < 0) return;
    if (slot != hand) {
      final inHand = itemAt(SlotRef(ContainerIds.inventory, hand));
      setSlots([(SlotRef(ContainerIds.inventory, slot), inHand), (SlotRef(ContainerIds.inventory, hand), item)]);
    }
    _sendPacket(buildDropItem(item));
    _putSlot(SlotRef(ContainerIds.inventory, hand), ItemStack.empty);
    _refreshHeld();
    _notify();
  }

  /// Закрыть сундук, печь или верстак.
  void closeContainer() {
    final c = container;
    if (c == null) return;
    if (c.windowId >= 0) _sendPacket(buildContainerClose(c.windowId));
    container = null;
    _notify();
  }

  /// Сколько предметов такого типа есть в инвентаре.
  int countInInventory(ItemStack type) {
    var n = 0;
    for (var i = 0; i < inventory.length && i < 36; i++) {
      if (inventory[i].sameType(type)) n += inventory[i].count;
    }
    return n;
  }

  int maxStack(ItemStack item) => maxStackOf(item.id);

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
    _sendPacket(buildPlayerAction(id, PlayerActionType.respawn, player.x.floor(), player.y.floor(), player.z.floor()));
  }
}
