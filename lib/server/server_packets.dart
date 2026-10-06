import 'dart:typed_data';

import '../protocol/binary.dart';
import '../protocol/packets.dart';

/// Предмет на стороне сервера.
class ServerItem {
  ServerItem(this.id, this.meta, this.count);

  static ServerItem get air => ServerItem(0, 0, 0);

  final int id;
  final int meta;
  int count;

  bool get isEmpty => id <= 0 || count <= 0;

  void write(BinaryWriter w) {
    if (isEmpty) {
      w.varint(0);
      return;
    }
    w
      ..varint(id)
      ..varint(((meta & 0x7fff) << 8) | (count & 0xff))
      ..shortLE(0)
      ..varint(0)
      ..varint(0);
  }

  List<int> toJson() => [id, meta, count];
}

class ServerPacketId {
  static const setEntityData = 0x27;
  static const resourcePacksInfo = 0x06;
  static const resourcePackStack = 0x07;
  static const removeEntity = 0x0e;
}

Uint8List spPlayStatus(int status) => encodePacket(PacketId.playStatus, (w) => w.intBE(status));

Uint8List spDisconnect(String message) => encodePacket(PacketId.disconnect, (w) {
      w
        ..boolean(false)
        ..string(message);
    });

Uint8List spResourcePacksInfo() => encodePacket(ServerPacketId.resourcePacksInfo, (w) {
      w
        ..boolean(false)
        ..shortLE(0)
        ..shortLE(0);
    });

Uint8List spResourcePackStack() => encodePacket(ServerPacketId.resourcePackStack, (w) {
      w
        ..boolean(false)
        ..uvarint(0)
        ..uvarint(0);
    });

Uint8List spStartGame({
  required int entityId,
  required int gamemode,
  required double x,
  required double eyeY,
  required double z,
  required double yaw,
  required double pitch,
  required int seed,
  required int spawnX,
  required int spawnY,
  required int spawnZ,
  required String worldName,
  required int time,
}) =>
    encodePacket(PacketId.startGame, (w) {
      w
        ..varint(entityId)
        ..uvarint(entityId)
        ..varint(gamemode)
        ..floatLE(x)
        ..floatLE(eyeY)
        ..floatLE(z)
        ..floatLE(pitch)
        ..floatLE(yaw)
        ..varint(seed)
        ..varint(0) // измерение: верхний мир
        ..varint(1) // генератор: бесконечный
        ..varint(gamemode)
        ..varint(1) // сложность
        ..varint(spawnX)
        ..uvarint(spawnY)
        ..varint(spawnZ)
        ..boolean(true) // достижения отключены
        ..varint(-1) // цикл дня не остановлен
        ..boolean(false)
        ..floatLE(0)
        ..floatLE(0)
        ..boolean(true) // команды разрешены
        ..boolean(false)
        ..uvarint(0) // правила игры
        ..string('')
        ..string(worldName)
        ..string('')
        ..boolean(false)
        ..longLE(time);
    });

Uint8List spSetTime(int time) => encodePacket(PacketId.setTime, (w) => w.varint(time));

Uint8List spUpdateAttributes(int entityId, {required double health, required double food, required int level}) =>
    encodePacket(PacketId.updateAttributes, (w) {
      w
        ..uvarint(entityId)
        ..uvarint(5);
      void attr(String name, double min, double max, double value, double def) {
        w
          ..floatLE(min)
          ..floatLE(max)
          ..floatLE(value)
          ..floatLE(def)
          ..string(name);
      }

      attr('minecraft:health', 0, 20, health, 20);
      attr('minecraft:player.hunger', 0, 20, food, 20);
      attr('minecraft:movement', 0, 3.4028234663852886e38, 0.1, 0.1);
      attr('minecraft:player.level', 0, 24791, level.toDouble(), 0);
      attr('minecraft:player.experience', 0, 1, 0, 0);
    });

/// Метаданные игрока: флаги показа ника, воздух, ник, масштаб, размеры.
Uint8List entityMetadata(String name) {
  final w = BinaryWriter()..uvarint(8);
  const flags = (1 << 14) | (1 << 15) | (1 << 19) | (1 << 33); // ник виден, ник всегда, лазать, дышать
  w
    ..uvarint(0)
    ..uvarint(7)
    ..varint(flags);
  w
    ..uvarint(7)
    ..uvarint(1)
    ..shortLE(400);
  w
    ..uvarint(43)
    ..uvarint(1)
    ..shortLE(400);
  w
    ..uvarint(4)
    ..uvarint(4)
    ..string(name);
  w
    ..uvarint(38)
    ..uvarint(7)
    ..varint(-1);
  w
    ..uvarint(39)
    ..uvarint(3)
    ..floatLE(1);
  w
    ..uvarint(54)
    ..uvarint(3)
    ..floatLE(0.6);
  w
    ..uvarint(55)
    ..uvarint(3)
    ..floatLE(1.8);
  return w.take();
}

Uint8List spSetEntityData(int entityId, Uint8List metadata) => encodePacket(ServerPacketId.setEntityData, (w) {
      w
        ..uvarint(entityId)
        ..bytes(metadata);
    });

Uint8List spContainerSetContent(int window, int entityId, List<ServerItem> items, List<int> hotbar) =>
    encodePacket(PacketId.containerSetContent, (w) {
      w
        ..uvarint(window)
        ..varint(entityId)
        ..uvarint(items.length);
      for (final i in items) {
        i.write(w);
      }
      w.uvarint(hotbar.length);
      for (final h in hotbar) {
        w.varint(h);
      }
    });

Uint8List spContainerSetSlot(int window, int slot, ServerItem item) => encodePacket(PacketId.containerSetSlot, (w) {
      w
        ..byte(window)
        ..varint(slot)
        ..varint(0);
      item.write(w);
      w.byte(0);
    });

Uint8List spMobEquipment(int entityId, ServerItem item, int inventorySlot, int hotbarSlot) =>
    encodePacket(PacketId.mobEquipment, (w) {
      w.uvarint(entityId);
      item.write(w);
      w
        ..byte(inventorySlot)
        ..byte(hotbarSlot)
        ..byte(0);
    });

Uint8List spAvailableCommands(String json) => encodePacket(PacketId.availableCommands, (w) {
      w
        ..string(json)
        ..string('');
    });

class PlayerListRecord {
  PlayerListRecord(this.uuid, this.entityId, this.name, this.skinId, this.skin);

  final Uint8List uuid;
  final int entityId;
  final String name;
  final String skinId;
  final Uint8List skin;
}

Uint8List spPlayerListAdd(List<PlayerListRecord> records) => encodePacket(PacketId.playerList, (w) {
      w
        ..byte(0)
        ..uvarint(records.length);
      for (final r in records) {
        w
          ..bytes(r.uuid)
          ..varint(r.entityId)
          ..string(r.name)
          ..string(r.skinId)
          ..byteArray(r.skin);
      }
    });

Uint8List spPlayerListRemove(Uint8List uuid) => encodePacket(PacketId.playerList, (w) {
      w
        ..byte(1)
        ..uvarint(1)
        ..bytes(uuid);
    });

Uint8List spAddPlayer({
  required Uint8List uuid,
  required String name,
  required int entityId,
  required double x,
  required double y,
  required double z,
  required double yaw,
  required double pitch,
  required Uint8List metadata,
}) =>
    encodePacket(PacketId.addPlayer, (w) {
      w
        ..bytes(uuid)
        ..string(name)
        ..varint(entityId)
        ..uvarint(entityId)
        ..floatLE(x)
        ..floatLE(y)
        ..floatLE(z)
        ..floatLE(0)
        ..floatLE(0)
        ..floatLE(0)
        ..floatLE(pitch)
        ..floatLE(yaw)
        ..floatLE(yaw)
        ..varint(0) // предмет в руке
        ..bytes(metadata);
    });

Uint8List spRemoveEntity(int entityId) => encodePacket(ServerPacketId.removeEntity, (w) => w.varint(entityId));

Uint8List spMovePlayer(int entityId, double x, double eyeY, double z, double yaw, double pitch, int mode) =>
    encodePacket(PacketId.movePlayer, (w) {
      w
        ..uvarint(entityId)
        ..floatLE(x)
        ..floatLE(eyeY)
        ..floatLE(z)
        ..floatLE(pitch)
        ..floatLE(yaw)
        ..floatLE(yaw)
        ..byte(mode)
        ..boolean(false)
        ..uvarint(0);
      if (mode == 2) {
        w
          ..intLE(0)
          ..intLE(0);
      }
    });

Uint8List spFullChunk(int cx, int cz, Uint8List data) => encodePacket(PacketId.fullChunkData, (w) {
      w
        ..varint(cx)
        ..varint(cz)
        ..byteArray(data);
    });

Uint8List spUpdateBlock(int x, int y, int z, int id, int meta) => encodePacket(PacketId.updateBlock, (w) {
      w
        ..varint(x)
        ..uvarint(y)
        ..varint(z)
        ..uvarint(id)
        ..uvarint((0xb << 4) | (meta & 0x0f));
    });

Uint8List spLevelEvent(int event, double x, double y, double z, int data) => encodePacket(PacketId.levelEvent, (w) {
      w
        ..varint(event)
        ..floatLE(x)
        ..floatLE(y)
        ..floatLE(z)
        ..varint(data);
    });

Uint8List spText(String message) => encodePacket(PacketId.text, (w) {
      w
        ..byte(TextType.raw)
        ..string(message);
    });

Uint8List spTranslation(String key, List<String> params) => encodePacket(PacketId.text, (w) {
      w
        ..byte(TextType.translation)
        ..string(key)
        ..uvarint(params.length);
      for (final p in params) {
        w.string(p);
      }
    });

Uint8List spChunkRadiusUpdated(int radius) => encodePacket(PacketId.chunkRadiusUpdated, (w) => w.varint(radius));

Uint8List spAdventureSettings({required bool creative, required bool flying, required bool op}) =>
    encodePacket(PacketId.adventureSettings, (w) {
      var flags = 1 << 5; // автопрыжок
      if (creative) flags |= 1 << 6;
      if (creative && flying) flags |= 1 << 9;
      w
        ..uvarint(flags)
        ..uvarint(op ? 1 : 0);
    });

Uint8List spSetPlayerGameType(int gamemode) => encodePacket(PacketId.setPlayerGameType, (w) => w.varint(gamemode));

Uint8List spRespawn(double x, double eyeY, double z) => encodePacket(PacketId.respawn, (w) {
      w
        ..floatLE(x)
        ..floatLE(eyeY)
        ..floatLE(z);
    });
