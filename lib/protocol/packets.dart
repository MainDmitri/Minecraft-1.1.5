import 'dart:typed_data';

import 'binary.dart';

/// Версия протокола MCPE 1.1.x (1.1.0 – 1.1.5).
const int mcpeProtocol = 113;
const String mcpeVersion = '1.1.5';

class PacketId {
  static const login = 0x01;
  static const playStatus = 0x02;
  static const serverToClientHandshake = 0x03;
  static const clientToServerHandshake = 0x04;
  static const disconnect = 0x05;
  static const resourcePacksInfo = 0x06;
  static const resourcePackStack = 0x07;
  static const resourcePackClientResponse = 0x08;
  static const text = 0x09;
  static const setTime = 0x0a;
  static const startGame = 0x0b;
  static const addPlayer = 0x0c;
  static const removeEntity = 0x0e;
  static const movePlayer = 0x13;
  static const removeBlock = 0x15;
  static const updateBlock = 0x16;
  static const levelEvent = 0x1a;
  static const updateAttributes = 0x1e;
  static const mobEquipment = 0x1f;
  static const useItem = 0x23;
  static const playerAction = 0x24;
  static const setSpawnPosition = 0x2b;
  static const respawn = 0x2d;
  static const containerSetSlot = 0x32;
  static const containerSetContent = 0x34;
  static const adventureSettings = 0x37;
  static const fullChunkData = 0x3a;
  static const setDifficulty = 0x3c;
  static const changeDimension = 0x3d;
  static const setPlayerGameType = 0x3e;
  static const playerList = 0x3f;
  static const requestChunkRadius = 0x45;
  static const chunkRadiusUpdated = 0x46;
  static const availableCommands = 0x4e;
  static const commandStep = 0x4f;
  static const transfer = 0x56;
  static const setTitle = 0x59;
}

class PlayStatus {
  static const loginSuccess = 0;
  static const loginFailedClient = 1;
  static const loginFailedServer = 2;
  static const playerSpawn = 3;
  static const loginFailedInvalidTenant = 4;
  static const loginFailedVanillaEdu = 5;
  static const loginFailedEduVanilla = 6;
}

class TextType {
  static const raw = 0;
  static const chat = 1;
  static const translation = 2;
  static const popup = 3;
  static const tip = 4;
  static const system = 5;
  static const whisper = 6;
  static const announcement = 7;
}

class PlayerActionType {
  static const startBreak = 0;
  static const abortBreak = 1;
  static const stopBreak = 2;
  static const respawn = 7;
}

class LevelEventId {
  static const blockStartBreak = 3600;
}

/// Предмет в слоте. [raw] — байты слота как их прислал сервер: при отправке обратно
/// сервер сравнивает предмет побайтно, поэтому он пересылается без изменений.
class ItemStack {
  ItemStack(this.id, this.meta, this.count, this.raw);

  final int id;
  final int meta;
  final int count;
  final Uint8List raw;

  static final ItemStack empty = ItemStack(0, 0, 0, Uint8List.fromList(const [0]));

  bool get isEmpty => id <= 0 || count <= 0;
}

ItemStack readItem(BinaryReader r) {
  final start = r.offset;
  final id = r.varint();
  if (id <= 0) {
    return ItemStack(0, 0, 0, Uint8List.fromList(r.data.sublist(start, r.offset)));
  }
  final aux = r.varint();
  final nbtLength = r.shortLE();
  if (nbtLength > 0) r.skip(nbtLength);
  final canPlaceOn = r.varint();
  for (var i = 0; i < canPlaceOn; i++) {
    r.string();
  }
  final canDestroy = r.varint();
  for (var i = 0; i < canDestroy; i++) {
    r.string();
  }
  return ItemStack(id, (aux >> 8) & 0x7fff, aux & 0xff, Uint8List.fromList(r.data.sublist(start, r.offset)));
}

class Vec3 {
  const Vec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  static Vec3 read(BinaryReader r) => Vec3(r.floatLE(), r.floatLE(), r.floatLE());

  @override
  String toString() => '${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}, ${z.toStringAsFixed(1)}';
}

/// Пакет игрового уровня: id + полезная нагрузка (в протоколе 113 без дополнительных байтов заголовка).
Uint8List encodePacket(int id, void Function(BinaryWriter w) body) {
  final w = BinaryWriter()..byte(id);
  body(w);
  return w.take();
}

class StartGameData {
  StartGameData({
    required this.uniqueId,
    required this.runtimeIdRaw,
    required this.playerGamemode,
    required this.position,
    required this.pitch,
    required this.yaw,
    required this.seed,
    required this.dimension,
    required this.worldGamemode,
    required this.difficulty,
    required this.commandsEnabled,
    required this.worldName,
    required this.time,
  });

  final int uniqueId;

  /// «Сырое» значение VarLong: серверы 2017 года кодируют runtime ID по-разному
  /// (со знаком и без), поэтому значение хранится как есть и так же отправляется обратно.
  final int runtimeIdRaw;
  final int playerGamemode;
  final Vec3 position;
  final double pitch;
  final double yaw;
  final int seed;
  final int dimension;
  final int worldGamemode;
  final int difficulty;
  final bool commandsEnabled;
  final String worldName;
  final int time;

  static StartGameData read(BinaryReader r) {
    final uniqueId = r.varint();
    final runtimeIdRaw = r.uvarint();
    final playerGamemode = r.varint();
    final position = Vec3.read(r);
    final pitch = r.floatLE();
    final yaw = r.floatLE();
    final seed = r.varint();
    final dimension = r.varint();
    r.varint(); // генератор
    final worldGamemode = r.varint();
    final difficulty = r.varint();
    r.varint(); // спавн X
    r.uvarint(); // спавн Y
    r.varint(); // спавн Z
    r.boolean(); // достижения отключены
    final dayCycleStopTime = r.varint();
    r.boolean(); // режим Education
    r.floatLE(); // дождь
    r.floatLE(); // молния
    final commandsEnabled = r.boolean();
    var worldName = '';
    var time = dayCycleStopTime >= 0 ? dayCycleStopTime : -1;
    try {
      r.boolean(); // обязательные текстуры
      final rules = r.uvarint();
      for (var i = 0; i < rules; i++) {
        r.string();
        final type = r.uvarint();
        switch (type) {
          case 1:
            r.boolean();
            break;
          case 2:
            r.uvarint();
            break;
          case 3:
            r.floatLE();
            break;
        }
      }
      r.string(); // levelId
      worldName = r.string();
      r.string(); // premiumWorldTemplateId
      r.boolean();
      final tick = r.longLE();
      if (time < 0) time = tick % 24000;
    } on FormatException {
      // Хвост пакета у разных серверов отличается; основные поля уже прочитаны.
    }
    return StartGameData(
      uniqueId: uniqueId,
      runtimeIdRaw: runtimeIdRaw,
      playerGamemode: playerGamemode,
      position: position,
      pitch: pitch,
      yaw: yaw,
      seed: seed,
      dimension: dimension,
      worldGamemode: worldGamemode,
      difficulty: difficulty,
      commandsEnabled: commandsEnabled,
      worldName: worldName,
      time: time < 0 ? 0 : time,
    );
  }
}

class TextMessage {
  TextMessage({required this.type, required this.source, required this.message, required this.parameters});

  final int type;
  final String source;
  final String message;
  final List<String> parameters;

  static TextMessage read(BinaryReader r) {
    final type = r.byte();
    var source = '';
    var message = '';
    final params = <String>[];
    switch (type) {
      case TextType.popup:
      case TextType.chat:
      case TextType.whisper:
      case TextType.announcement:
        source = r.string();
        message = r.string();
        break;
      case TextType.raw:
      case TextType.tip:
      case TextType.system:
        message = r.string();
        break;
      case TextType.translation:
        message = r.string();
        final count = r.uvarint();
        for (var i = 0; i < count; i++) {
          params.add(r.string());
        }
        break;
    }
    return TextMessage(type: type, source: source, message: message, parameters: params);
  }
}

class Attribute {
  Attribute(this.name, this.min, this.max, this.value);

  final String name;
  final double min;
  final double max;
  final double value;
}

List<Attribute> readAttributes(BinaryReader r) {
  final count = r.uvarint();
  final list = <Attribute>[];
  for (var i = 0; i < count; i++) {
    final min = r.floatLE();
    final max = r.floatLE();
    final value = r.floatLE();
    r.floatLE(); // значение по умолчанию
    final name = r.string();
    list.add(Attribute(name, min, max, value));
  }
  return list;
}

class PlayerListEntry {
  PlayerListEntry(this.uuid, this.uniqueId, this.name);

  final String uuid;
  final int uniqueId;
  final String name;
}

String readUuid(BinaryReader r) {
  final b = r.bytes(16);
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

class PlayerListUpdate {
  PlayerListUpdate(this.add, this.entries, this.removed);

  final bool add;
  final List<PlayerListEntry> entries;
  final List<String> removed;

  static PlayerListUpdate read(BinaryReader r) {
    final type = r.byte();
    final count = r.uvarint();
    final entries = <PlayerListEntry>[];
    final removed = <String>[];
    for (var i = 0; i < count; i++) {
      final uuid = readUuid(r);
      if (type == 0) {
        final uniqueId = r.varint();
        final name = r.string();
        r.string(); // id скина
        r.byteArray(); // данные скина
        entries.add(PlayerListEntry(uuid, uniqueId, name));
      } else {
        removed.add(uuid);
      }
    }
    return PlayerListUpdate(type == 0, entries, removed);
  }
}

class MovePlayerData {
  MovePlayerData(this.runtimeIdRaw, this.position, this.pitch, this.yaw, this.mode);

  final int runtimeIdRaw;
  final Vec3 position;
  final double pitch;
  final double yaw;
  final int mode;

  static MovePlayerData read(BinaryReader r) {
    final id = r.uvarint();
    final pos = Vec3.read(r);
    final pitch = r.floatLE();
    final yaw = r.floatLE();
    r.floatLE(); // поворот головы/тела
    final mode = r.byte();
    return MovePlayerData(id, pos, pitch, yaw, mode);
  }
}

class TitleData {
  TitleData(this.type, this.text, this.fadeIn, this.stay, this.fadeOut);

  static const clear = 0;
  static const reset = 1;
  static const title = 2;
  static const subtitle = 3;
  static const actionBar = 4;
  static const times = 5;

  final int type;
  final String text;
  final int fadeIn;
  final int stay;
  final int fadeOut;

  static TitleData read(BinaryReader r) =>
      TitleData(r.varint(), r.string(), r.varint(), r.varint(), r.varint());
}

// ---------- Пакеты клиента ----------

Uint8List buildLoginPacket(Uint8List chainJson, Uint8List clientDataJwt) {
  final inner = BinaryWriter()
    ..intLE(chainJson.length)
    ..bytes(chainJson)
    ..intLE(clientDataJwt.length)
    ..bytes(clientDataJwt);
  return encodePacket(PacketId.login, (w) {
    w
      ..intBE(mcpeProtocol)
      ..byte(0) // издание: Pocket
      ..byteArray(inner.take());
  });
}

Uint8List buildClientToServerHandshake() => encodePacket(PacketId.clientToServerHandshake, (_) {});

Uint8List buildResourcePackResponse(int status, List<String> packIds) =>
    encodePacket(PacketId.resourcePackClientResponse, (w) {
      w
        ..byte(status)
        ..shortLE(packIds.length);
      for (final id in packIds) {
        w.string(id);
      }
    });

Uint8List buildRequestChunkRadius(int radius) => encodePacket(PacketId.requestChunkRadius, (w) => w.varint(radius));

Uint8List buildChat(String source, String message) => encodePacket(PacketId.text, (w) {
      w
        ..byte(TextType.chat)
        ..string(source)
        ..string(message);
    });

Uint8List buildPlayerAction(int runtimeIdRaw, int action, int x, int y, int z, {int face = 0}) =>
    encodePacket(PacketId.playerAction, (w) {
      w
        ..uvarint(runtimeIdRaw)
        ..varint(action)
        ..varint(x)
        ..uvarint(y < 0 ? 0 : y)
        ..varint(z)
        ..varint(face);
    });

Uint8List buildAdventureSettings(int flags, int permission) => encodePacket(PacketId.adventureSettings, (w) {
      w
        ..uvarint(flags)
        ..uvarint(permission);
    });

/// Позиция игрока: [eye] — координаты глаз.
Uint8List buildMovePlayer(int runtimeIdRaw, Vec3 eye, double pitch, double yaw, bool onGround) =>
    encodePacket(PacketId.movePlayer, (w) {
      w
        ..uvarint(runtimeIdRaw)
        ..floatLE(eye.x)
        ..floatLE(eye.y)
        ..floatLE(eye.z)
        ..floatLE(pitch)
        ..floatLE(yaw)
        ..floatLE(yaw)
        ..byte(0)
        ..boolean(onGround)
        ..uvarint(0);
    });

Uint8List buildRemoveBlock(int x, int y, int z) => encodePacket(PacketId.removeBlock, (w) {
      w
        ..varint(x)
        ..uvarint(y)
        ..varint(z);
    });

Uint8List buildUseItem({
  required int x,
  required int y,
  required int z,
  required int targetBlockId,
  required int face,
  required double fx,
  required double fy,
  required double fz,
  required Vec3 eye,
  required int hotbarSlot,
  required ItemStack item,
}) =>
    encodePacket(PacketId.useItem, (w) {
      w
        ..varint(x)
        ..uvarint(y)
        ..varint(z)
        ..uvarint(targetBlockId)
        ..varint(face)
        ..floatLE(fx)
        ..floatLE(fy)
        ..floatLE(fz)
        ..floatLE(eye.x)
        ..floatLE(eye.y)
        ..floatLE(eye.z)
        ..byte(hotbarSlot)
        ..bytes(item.raw);
    });

Uint8List buildMobEquipment(int runtimeIdRaw, ItemStack item, int inventorySlot, int hotbarSlot) =>
    encodePacket(PacketId.mobEquipment, (w) {
      w
        ..uvarint(runtimeIdRaw)
        ..bytes(item.raw)
        ..byte(inventorySlot)
        ..byte(hotbarSlot)
        ..byte(0);
    });

Uint8List buildCommandStep({
  required String command,
  required String overload,
  required int clientId,
  required String inputJson,
}) =>
    encodePacket(PacketId.commandStep, (w) {
      w
        ..string(command)
        ..string(overload)
        ..uvarint(0)
        ..uvarint(0)
        ..boolean(true)
        ..uvarint(clientId)
        ..string(inputJson)
        ..string('null')
        ..bytes(const [0, 0, 0]);
    });
