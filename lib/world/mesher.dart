import 'dart:typed_data';

import 'blocks.dart';
import 'world.dart';

/// Направления граней: 0 −X, 1 +X, 2 −Y, 3 +Y, 4 −Z, 5 +Z, 6 — двусторонняя (растения).
const int faceCross = 6;

const List<double> _shade = [0.72, 0.72, 0.5, 1.0, 0.86, 0.86];

/// Видимые грани одной секции 16x16x16.
class SectionMesh {
  SectionMesh(this.cx, this.sy, this.cz, this.count, this.corners, this.centers, this.colors, this.dirs);

  final int cx;
  final int sy;
  final int cz;
  final int count;

  /// 12 чисел на грань: четыре вершины x, y, z.
  final Float32List corners;

  /// 3 числа на грань: центр.
  final Float32List centers;

  /// ARGB с учётом освещения грани.
  final Int32List colors;
  final Uint8List dirs;

  double get minX => cx * 16.0;
  double get minY => sy * 16.0;
  double get minZ => cz * 16.0;
}

class _Builder {
  final List<double> corners = [];
  final List<double> centers = [];
  final List<int> colors = [];
  final List<int> dirs = [];

  void face(List<double> c, int color, int dir) {
    corners.addAll(c);
    centers
      ..add((c[0] + c[3] + c[6] + c[9]) / 4)
      ..add((c[1] + c[4] + c[7] + c[10]) / 4)
      ..add((c[2] + c[5] + c[8] + c[11]) / 4);
    colors.add(color);
    dirs.add(dir);
  }
}

int _shadeColor(int argb, double k) {
  int ch(int shift) => (((argb >> shift) & 0xff) * k).round().clamp(0, 255);
  return (argb & 0xff000000) | (ch(16) << 16) | (ch(8) << 8) | ch(0);
}

/// Небольшой разброс яркости по координатам, чтобы соседние блоки различались.
double _jitter(int x, int y, int z) {
  var h = x * 73856093 ^ y * 19349663 ^ z * 83492791;
  h = (h ^ (h >> 13)) * 1274126177;
  return 0.94 + ((h >> 8) & 0xff) / 255.0 * 0.1;
}

/// Построение сетки секции. Возвращает null, если секция пустая.
SectionMesh? buildSectionMesh(World world, int cx, int sy, int cz) {
  final chunk = world.chunkAt(cx, cz);
  final section = chunk?.sections[sy];
  if (chunk == null || section == null) return null;

  final ids = section.ids;
  final baseX = cx * 16, baseY = sy * 16, baseZ = cz * 16;

  // Соседние секции для быстрого доступа на границах.
  final up = sy < 15 ? chunk.sections[sy + 1] : null;
  final down = sy > 0 ? chunk.sections[sy - 1] : null;
  final west = world.chunkAt(cx - 1, cz);
  final east = world.chunkAt(cx + 1, cz);
  final north = world.chunkAt(cx, cz - 1);
  final south = world.chunkAt(cx, cz + 1);

  /// ID соседа; -1 — чанк не загружен (грань не рисуется).
  int neighbor(int lx, int ly, int lz) {
    if (lx >= 0 && lx < 16 && lz >= 0 && lz < 16) {
      if (ly >= 0 && ly < 16) return ids[(lx << 8) | (lz << 4) | ly];
      if (ly < 0) {
        if (sy == 0) return -1;
        return down == null ? 0 : down.ids[(lx << 8) | (lz << 4) | 15];
      }
      if (sy == 15) return 0;
      return up == null ? 0 : up.ids[(lx << 8) | (lz << 4)];
    }
    final y = baseY + ly;
    if (lx < 0) return west == null ? -1 : west.id(15, y, lz);
    if (lx > 15) return east == null ? -1 : east.id(0, y, lz);
    if (lz < 0) return north == null ? -1 : north.id(lx, y, 15);
    return south == null ? -1 : south.id(lx, y, 0);
  }

  bool hidesFace(int self, BlockInfo selfInfo, int n) {
    if (n < 0) return true;
    if (n == self) return true;
    final ni = blockTable[n];
    if (selfInfo.shape == BlockShape.liquid && ni.shape == BlockShape.liquid) return true;
    return ni.opaque;
  }

  final b = _Builder();
  for (var lx = 0; lx < 16; lx++) {
    for (var lz = 0; lz < 16; lz++) {
      for (var ly = 0; ly < 16; ly++) {
        final id = ids[(lx << 8) | (lz << 4) | ly];
        if (id == 0) continue;
        final info = blockTable[id];
        if (info.shape == BlockShape.none) continue;
        final x = (baseX + lx).toDouble(), y = (baseY + ly).toDouble(), z = (baseZ + lz).toDouble();
        final meta = section.data(lx, ly, lz);
        final base = blockColor(id, meta);
        final j = _jitter(baseX + lx, baseY + ly, baseZ + lz);

        if (info.shape == BlockShape.cross) {
          final c = _shadeColor(base, 0.9 * j);
          b.face([x + 0.15, y, z + 0.15, x + 0.85, y, z + 0.85, x + 0.85, y + 0.9, z + 0.85, x + 0.15, y + 0.9, z + 0.15], c,
              faceCross);
          b.face([x + 0.85, y, z + 0.15, x + 0.15, y, z + 0.85, x + 0.15, y + 0.9, z + 0.85, x + 0.85, y + 0.9, z + 0.15], c,
              faceCross);
          continue;
        }

        var top = y + 1;
        if (info.shape == BlockShape.liquid) {
          final above = neighbor(lx, ly + 1, lz);
          if (above >= 0 && blockTable[above].shape != BlockShape.liquid) top = y + 0.875;
        }

        int col(int dir) {
          var c = base;
          if (dir == 3 && info.topColor != null) c = info.topColor!;
          if (dir == 2 && info.bottomColor != null) c = info.bottomColor!;
          return _shadeColor(c, _shade[dir] * j);
        }

        if (!hidesFace(id, info, neighbor(lx - 1, ly, lz))) {
          b.face([x, y, z, x, top, z, x, top, z + 1, x, y, z + 1], col(0), 0);
        }
        if (!hidesFace(id, info, neighbor(lx + 1, ly, lz))) {
          b.face([x + 1, y, z, x + 1, y, z + 1, x + 1, top, z + 1, x + 1, top, z], col(1), 1);
        }
        if (!hidesFace(id, info, neighbor(lx, ly - 1, lz))) {
          b.face([x, y, z, x, y, z + 1, x + 1, y, z + 1, x + 1, y, z], col(2), 2);
        }
        if (top < y + 1 || !hidesFace(id, info, neighbor(lx, ly + 1, lz))) {
          b.face([x, top, z, x + 1, top, z, x + 1, top, z + 1, x, top, z + 1], col(3), 3);
        }
        if (!hidesFace(id, info, neighbor(lx, ly, lz - 1))) {
          b.face([x, y, z, x + 1, y, z, x + 1, top, z, x, top, z], col(4), 4);
        }
        if (!hidesFace(id, info, neighbor(lx, ly, lz + 1))) {
          b.face([x, y, z + 1, x, top, z + 1, x + 1, top, z + 1, x + 1, y, z + 1], col(5), 5);
        }
      }
    }
  }
  if (b.dirs.isEmpty) return null;
  return SectionMesh(
    cx,
    sy,
    cz,
    b.dirs.length,
    Float32List.fromList(b.corners),
    Float32List.fromList(b.centers),
    Int32List.fromList(b.colors),
    Uint8List.fromList(b.dirs),
  );
}
