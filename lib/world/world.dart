import 'dart:typed_data';

import '../protocol/binary.dart';
import 'blocks.dart';

/// Секция 16x16x16 в сетевом порядке MCPE 1.1: индекс (x << 8) | (z << 4) | y.
class ChunkSection {
  ChunkSection() : ids = Uint8List(4096), meta = Uint8List(2048);

  ChunkSection.from(this.ids, this.meta);

  final Uint8List ids;
  final Uint8List meta;

  /// Есть ли в секции хоть один видимый блок.
  bool get isEmpty {
    for (var i = 0; i < 4096; i++) {
      if (ids[i] != 0) return false;
    }
    return true;
  }

  int id(int x, int y, int z) => ids[(x << 8) | (z << 4) | y];

  int data(int x, int y, int z) {
    final b = meta[(x << 7) | (z << 3) | (y >> 1)];
    return (y & 1) == 0 ? b & 0x0f : b >> 4;
  }

  void set(int x, int y, int z, int id, int data) {
    ids[(x << 8) | (z << 4) | y] = id;
    final i = (x << 7) | (z << 3) | (y >> 1);
    meta[i] = (y & 1) == 0 ? (meta[i] & 0xf0) | (data & 0x0f) : (meta[i] & 0x0f) | ((data & 0x0f) << 4);
  }
}

class Chunk {
  Chunk(this.x, this.z);

  final int x;
  final int z;
  final List<ChunkSection?> sections = List.filled(16, null);

  /// Разбор данных FullChunkDataPacket протокола 113.
  static Chunk parse(int cx, int cz, Uint8List data) {
    final chunk = Chunk(cx, cz);
    final r = BinaryReader(data);
    final count = r.byte();
    for (var i = 0; i < count && i < 16; i++) {
      r.byte(); // версия формата секции
      final ids = Uint8List.fromList(r.bytes(4096));
      final meta = Uint8List.fromList(r.bytes(2048));
      r.skip(4096); // небесный и блочный свет
      final section = ChunkSection.from(ids, meta);
      chunk.sections[i] = section.isEmpty ? null : section;
    }
    return chunk;
  }

  int id(int x, int y, int z) {
    if (y < 0 || y > 255) return 0;
    final s = sections[y >> 4];
    return s == null ? 0 : s.id(x, y & 15, z);
  }

  void set(int x, int y, int z, int id, int data) {
    if (y < 0 || y > 255) return;
    final s = sections[y >> 4] ??= ChunkSection();
    s.set(x, y & 15, z, id, data);
  }
}

int chunkKey(int cx, int cz) => ((cx & 0xffffffff) << 32) | (cz & 0xffffffff);

/// Загруженная часть мира. Хранит чанки и номера изменённых секций для перестройки сетки.
class World {
  final Map<int, Chunk> chunks = {};

  /// Ключ секции: chunkKey и номер секции; меняется при загрузке чанков и обновлении блоков.
  final Set<int> dirtySections = {};
  int version = 0;

  static int sectionKey(int cx, int sy, int cz) => ((cx & 0xffffff) << 28) | ((cz & 0xffffff) << 4) | sy;

  Chunk? chunkAt(int cx, int cz) => chunks[chunkKey(cx, cz)];

  bool isLoaded(int wx, int wz) => chunks.containsKey(chunkKey(wx >> 4, wz >> 4));

  int blockId(int wx, int wy, int wz) {
    final c = chunks[chunkKey(wx >> 4, wz >> 4)];
    return c == null ? 0 : c.id(wx & 15, wy, wz & 15);
  }

  /// Твёрдый блок для столкновений. Незагруженные чанки считаются твёрдыми, чтобы не упасть сквозь мир.
  bool isSolid(int wx, int wy, int wz) {
    if (wy < 0) return true;
    if (wy > 255) return false;
    final c = chunks[chunkKey(wx >> 4, wz >> 4)];
    if (c == null) return true;
    return blockTable[c.id(wx & 15, wy, wz & 15)].solid;
  }

  void putChunk(Chunk chunk) {
    chunks[chunkKey(chunk.x, chunk.z)] = chunk;
    for (var sy = 0; sy < 16; sy++) {
      _markColumn(chunk.x, chunk.z, sy);
    }
    // Соседние чанки: их граничные грани теперь могут быть скрыты.
    for (final d in const [
      [1, 0],
      [-1, 0],
      [0, 1],
      [0, -1],
    ]) {
      if (chunks.containsKey(chunkKey(chunk.x + d[0], chunk.z + d[1]))) {
        for (var sy = 0; sy < 16; sy++) {
          _markColumn(chunk.x + d[0], chunk.z + d[1], sy);
        }
      }
    }
    version++;
  }

  void _markColumn(int cx, int cz, int sy) => dirtySections.add(sectionKey(cx, sy, cz));

  void setBlock(int wx, int wy, int wz, int id, int data) {
    final cx = wx >> 4, cz = wz >> 4;
    final c = chunks[chunkKey(cx, cz)];
    if (c == null || wy < 0 || wy > 255) return;
    c.set(wx & 15, wy, wz & 15, id, data);
    final sy = wy >> 4;
    dirtySections.add(sectionKey(cx, sy, cz));
    final lx = wx & 15, ly = wy & 15, lz = wz & 15;
    if (lx == 0) dirtySections.add(sectionKey(cx - 1, sy, cz));
    if (lx == 15) dirtySections.add(sectionKey(cx + 1, sy, cz));
    if (lz == 0) dirtySections.add(sectionKey(cx, sy, cz - 1));
    if (lz == 15) dirtySections.add(sectionKey(cx, sy, cz + 1));
    if (ly == 0 && sy > 0) dirtySections.add(sectionKey(cx, sy - 1, cz));
    if (ly == 15 && sy < 15) dirtySections.add(sectionKey(cx, sy + 1, cz));
    version++;
  }

  /// Выгрузка чанков дальше [radius] чанков от игрока.
  void unloadFar(int pcx, int pcz, int radius) {
    final remove = <int>[];
    chunks.forEach((key, c) {
      if ((c.x - pcx).abs() > radius || (c.z - pcz).abs() > radius) remove.add(key);
    });
    for (final k in remove) {
      chunks.remove(k);
    }
    if (remove.isNotEmpty) version++;
  }

  void clear() {
    chunks.clear();
    dirtySections.clear();
    version++;
  }
}
