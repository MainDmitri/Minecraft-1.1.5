import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/binary.dart';
import '../world/blocks.dart';
import '../world/world.dart';

/// Данные FullChunkDataPacket протокола 113 (как у серверов того времени).
Uint8List encodeChunkForNetwork(Chunk chunk) {
  var count = 0;
  for (var i = 15; i >= 0; i--) {
    if (chunk.sections[i] != null) {
      count = i + 1;
      break;
    }
  }
  // Высота столбца и небесный свет: 15 над самым верхним непрозрачным блоком, 0 ниже.
  final heights = Uint8List(256);
  for (var x = 0; x < 16; x++) {
    for (var z = 0; z < 16; z++) {
      var top = 0;
      for (var y = count * 16 - 1; y >= 0; y--) {
        final id = chunk.id(x, y, z);
        if (id != 0 && blockTable[id].opaque) {
          top = y + 1;
          break;
        }
      }
      heights[(z << 4) | x] = top > 255 ? 255 : top;
    }
  }
  final w = BinaryWriter()..byte(count);
  for (var s = 0; s < count; s++) {
    final section = chunk.sections[s];
    w.byte(0);
    if (section == null) {
      w
        ..bytes(Uint8List(4096))
        ..bytes(Uint8List(2048));
    } else {
      w
        ..bytes(section.ids)
        ..bytes(section.meta);
    }
    final sky = Uint8List(2048);
    for (var x = 0; x < 16; x++) {
      for (var z = 0; z < 16; z++) {
        final top = heights[(z << 4) | x];
        for (var y = 0; y < 16; y += 2) {
          final wy = s * 16 + y;
          final lo = wy >= top ? 15 : 0;
          final hi = wy + 1 >= top ? 15 : 0;
          sky[(x << 7) | (z << 3) | (y >> 1)] = lo | (hi << 4);
        }
      }
    }
    w
      ..bytes(sky)
      ..bytes(Uint8List(2048)); // свет от блоков
  }
  w
    ..bytes(heights)
    ..bytes(Uint8List(256))
    ..bytes(Uint8List.fromList(List.filled(256, 1))) // биом: равнины
    ..byte(0)
    ..varint(0);
  return w.take();
}

/// Сохранение изменённого чанка: маска секций + ID и метаданные, сжато zlib.
Uint8List encodeChunkForStorage(Chunk chunk) {
  var mask = 0;
  for (var i = 0; i < 16; i++) {
    if (chunk.sections[i] != null) mask |= 1 << i;
  }
  final w = BinaryWriter()
    ..byte(1)
    ..shortBE(mask);
  for (var i = 0; i < 16; i++) {
    final s = chunk.sections[i];
    if (s == null) continue;
    w
      ..bytes(s.ids)
      ..bytes(s.meta);
  }
  return Uint8List.fromList(ZLibCodec(level: 6).encode(w.take()));
}

Chunk decodeChunkFromStorage(int cx, int cz, Uint8List data) {
  final r = BinaryReader(Uint8List.fromList(ZLibCodec().decode(data)));
  final version = r.byte();
  if (version != 1) throw FormatException('Неизвестная версия чанка: $version');
  final mask = r.shortBE();
  final chunk = Chunk(cx, cz);
  for (var i = 0; i < 16; i++) {
    if (mask & (1 << i) == 0) continue;
    chunk.sections[i] = ChunkSection.from(Uint8List.fromList(r.bytes(4096)), Uint8List.fromList(r.bytes(2048)));
  }
  return chunk;
}

class WorldMeta {
  WorldMeta({
    required this.name,
    required this.seed,
    required this.gamemode,
    required this.spawnX,
    required this.spawnY,
    required this.spawnZ,
    this.time = 0,
  });

  String name;
  final int seed;
  int gamemode;
  int spawnX, spawnY, spawnZ;
  int time;

  Map<String, dynamic> toJson() => {
        'name': name,
        'seed': seed,
        'gamemode': gamemode,
        'spawn': [spawnX, spawnY, spawnZ],
        'time': time,
      };

  static WorldMeta fromJson(Map<String, dynamic> j) {
    final spawn = (j['spawn'] as List).cast<int>();
    return WorldMeta(
      name: j['name'] as String,
      seed: j['seed'] as int,
      gamemode: j['gamemode'] as int,
      spawnX: spawn[0],
      spawnY: spawn[1],
      spawnZ: spawn[2],
      time: j['time'] as int? ?? 0,
    );
  }
}

/// Сохранённые данные игрока.
class PlayerSave {
  PlayerSave({
    required this.x,
    required this.y,
    required this.z,
    required this.yaw,
    required this.pitch,
    required this.gamemode,
    required this.inventory,
    required this.heldSlot,
  });

  final double x, y, z, yaw, pitch;
  final int gamemode;

  /// 36 слотов: [id, meta, count].
  final List<List<int>> inventory;
  final int heldSlot;

  Map<String, dynamic> toJson() => {
        'pos': [x, y, z],
        'rot': [yaw, pitch],
        'gamemode': gamemode,
        'inventory': inventory,
        'held': heldSlot,
      };

  static PlayerSave fromJson(Map<String, dynamic> j) {
    final pos = (j['pos'] as List).map((e) => (e as num).toDouble()).toList();
    final rot = (j['rot'] as List).map((e) => (e as num).toDouble()).toList();
    return PlayerSave(
      x: pos[0],
      y: pos[1],
      z: pos[2],
      yaw: rot[0],
      pitch: rot[1],
      gamemode: j['gamemode'] as int,
      inventory: (j['inventory'] as List).map((e) => (e as List).cast<int>()).toList(),
      heldSlot: j['held'] as int,
    );
  }
}

/// Папка локального мира: world.json, players.json и изменённые чанки в chunks/.
class WorldStorage {
  WorldStorage(this.dir);

  final Directory dir;

  File get _metaFile => File('${dir.path}/world.json');
  File get _playersFile => File('${dir.path}/players.json');
  Directory get _chunksDir => Directory('${dir.path}/chunks');

  WorldMeta readMeta() => WorldMeta.fromJson(jsonDecode(_metaFile.readAsStringSync()) as Map<String, dynamic>);

  void writeMeta(WorldMeta meta) {
    dir.createSync(recursive: true);
    _metaFile.writeAsStringSync(jsonEncode(meta.toJson()));
  }

  Map<String, PlayerSave> readPlayers() {
    if (!_playersFile.existsSync()) return {};
    final raw = jsonDecode(_playersFile.readAsStringSync()) as Map<String, dynamic>;
    return raw.map((k, v) => MapEntry(k, PlayerSave.fromJson(v as Map<String, dynamic>)));
  }

  void writePlayers(Map<String, PlayerSave> players) {
    _playersFile.writeAsStringSync(jsonEncode(players.map((k, v) => MapEntry(k, v.toJson()))));
  }

  File _chunkFile(int cx, int cz) => File('${_chunksDir.path}/$cx.$cz.bin');

  Chunk? readChunk(int cx, int cz) {
    final f = _chunkFile(cx, cz);
    if (!f.existsSync()) return null;
    return decodeChunkFromStorage(cx, cz, f.readAsBytesSync());
  }

  void writeChunk(Chunk chunk) {
    _chunksDir.createSync(recursive: true);
    _chunkFile(chunk.x, chunk.z).writeAsBytesSync(encodeChunkForStorage(chunk));
  }
}
