import 'dart:typed_data';

import '../textures/texture_pack.dart';
import 'blocks.dart';
import 'world.dart';

/// Направления граней: 0 −X, 1 +X, 2 −Y, 3 +Y, 4 −Z, 5 +Z, 6 — двусторонняя (растения).
const int faceCross = 6;

const List<double> _shade = [0.72, 0.72, 0.5, 1.0, 0.86, 0.86];

/// Видимые грани одной секции 16x16x16.
class SectionMesh {
  SectionMesh(this.cx, this.sy, this.cz, this.count, this.corners, this.centers, this.colors, this.dirs, this.uvs);

  final int cx;
  final int sy;
  final int cz;
  final int count;

  /// 12 чисел на грань: четыре вершины x, y, z.
  final Float32List corners;

  /// 3 числа на грань: центр.
  final Float32List centers;

  /// ARGB с учётом освещения грани (с текстурами — множитель яркости).
  final Int32List colors;
  final Uint8List dirs;

  /// 8 чисел на грань: координаты в пикселях атласа для четырёх вершин (только с текстурами).
  final Float32List? uvs;

  double get minX => cx * 16.0;
  double get minY => sy * 16.0;
  double get minZ => cz * 16.0;
}

class MeshBuilder {
  MeshBuilder(this.pack);

  final TexturePack? pack;
  final List<double> corners = [];
  final List<double> centers = [];
  final List<int> colors = [];
  final List<int> dirs = [];
  final List<double> uvs = [];

  /// [uv] — 8 чисел (u, v в долях плитки для каждой вершины), [tile] — плитка атласа.
  void face(List<double> c, int color, int dir, {List<double>? uv, int tile = 0}) {
    corners.addAll(c);
    centers
      ..add((c[0] + c[3] + c[6] + c[9]) / 4)
      ..add((c[1] + c[4] + c[7] + c[10]) / 4)
      ..add((c[2] + c[5] + c[8] + c[11]) / 4);
    colors.add(color);
    dirs.add(dir);
    final p = pack;
    if (p == null) return;
    final tx = p.tileX(tile), ty = p.tileY(tile);
    final local = uv ?? const [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5];
    for (var i = 0; i < 8; i += 2) {
      // Отступ внутрь плитки, чтобы не захватывать соседние.
      uvs
        ..add(tx + local[i].clamp(0.02, 0.98) * tileSize)
        ..add(ty + local[i + 1].clamp(0.02, 0.98) * tileSize);
    }
  }

  SectionMesh? build(int cx, int sy, int cz) {
    if (dirs.isEmpty) return null;
    return SectionMesh(
      cx,
      sy,
      cz,
      dirs.length,
      Float32List.fromList(corners),
      Float32List.fromList(centers),
      Int32List.fromList(colors),
      Uint8List.fromList(dirs),
      pack == null ? null : Float32List.fromList(uvs),
    );
  }
}

int _shadeColor(int argb, double k) {
  int ch(int shift) => (((argb >> shift) & 0xff) * k).round().clamp(0, 255);
  return (argb & 0xff000000) | (ch(16) << 16) | (ch(8) << 8) | ch(0);
}

/// Небольшой разброс яркости по координатам, чтобы соседние блоки без текстур различались.
double _jitter(int x, int y, int z) {
  var h = x * 73856093 ^ y * 19349663 ^ z * 83492791;
  h = (h ^ (h >> 13)) * 1274126177;
  return 0.94 + ((h >> 8) & 0xff) / 255.0 * 0.1;
}

/// Координаты текстуры (в долях плитки) для вершины грани [dir] по её смещению внутри блока.
List<double> blockFaceUv(int dir, List<double> c, double bx, double by, double bz) {
  final out = List<double>.filled(8, 0);
  for (var k = 0; k < 4; k++) {
    final rx = c[k * 3] - bx, ry = c[k * 3 + 1] - by, rz = c[k * 3 + 2] - bz;
    double u, v;
    switch (dir) {
      case 0:
        u = rz;
        v = 1 - ry;
      case 1:
        u = 1 - rz;
        v = 1 - ry;
      case 2:
      case 3:
        u = rx;
        v = rz;
      case 4:
        u = 1 - rx;
        v = 1 - ry;
      default:
        u = rx;
        v = 1 - ry;
    }
    out[k * 2] = u;
    out[k * 2 + 1] = v;
  }
  return out;
}

const List<double> _crossUv = [0, 1, 1, 1, 1, 0, 0, 0];

/// Построение сетки секции. Возвращает null, если секция пустая.
SectionMesh? buildSectionMesh(World world, int cx, int sy, int cz, {TexturePack? pack}) {
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

  final b = MeshBuilder(pack);
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
        final j = pack == null ? _jitter(baseX + lx, baseY + ly, baseZ + lz) : 1.0;

        /// Цвет грани: с текстурой — только яркость, без текстуры — цвет блока.
        int col(int dir, int tile) {
          final k = (dir < 6 ? _shade[dir] : 0.9) * j;
          if (pack != null && tile > 0) {
            final g = (255 * k).round().clamp(0, 255);
            return 0xFF000000 | (g << 16) | (g << 8) | g;
          }
          var c = base;
          if (dir == 3 && info.topColor != null) c = info.topColor!;
          if (dir == 2 && info.bottomColor != null) c = info.bottomColor!;
          return _shadeColor(c, k);
        }

        int tileFor(int dir) {
          final p = pack;
          if (p == null) return 0;
          final t = p.tile(id, meta, dir);
          return t < 0 ? 0 : t;
        }

        if (info.shape == BlockShape.cross) {
          final t = tileFor(0);
          final c = col(faceCross, t);
          final lo = pack == null ? 0.15 : 0.0, hi = pack == null ? 0.85 : 1.0, h = pack == null ? 0.9 : 1.0;
          b.face([x + lo, y, z + lo, x + hi, y, z + hi, x + hi, y + h, z + hi, x + lo, y + h, z + lo], c, faceCross,
              uv: _crossUv, tile: t);
          b.face([x + hi, y, z + lo, x + lo, y, z + hi, x + lo, y + h, z + hi, x + hi, y + h, z + lo], c, faceCross,
              uv: _crossUv, tile: t);
          continue;
        }

        var top = y + 1;
        if (info.shape == BlockShape.liquid) {
          final above = neighbor(lx, ly + 1, lz);
          if (above >= 0 && blockTable[above].shape != BlockShape.liquid) top = y + 0.875;
        }

        void emit(int dir, List<double> corners) {
          final t = tileFor(dir);
          b.face(corners, col(dir, t), dir, uv: blockFaceUv(dir, corners, x, y, z), tile: t);
        }

        if (!hidesFace(id, info, neighbor(lx - 1, ly, lz))) {
          emit(0, [x, y, z, x, top, z, x, top, z + 1, x, y, z + 1]);
        }
        if (!hidesFace(id, info, neighbor(lx + 1, ly, lz))) {
          emit(1, [x + 1, y, z, x + 1, y, z + 1, x + 1, top, z + 1, x + 1, top, z]);
        }
        if (!hidesFace(id, info, neighbor(lx, ly - 1, lz))) {
          emit(2, [x, y, z, x, y, z + 1, x + 1, y, z + 1, x + 1, y, z]);
        }
        if (top < y + 1 || !hidesFace(id, info, neighbor(lx, ly + 1, lz))) {
          emit(3, [x, top, z, x + 1, top, z, x + 1, top, z + 1, x, top, z + 1]);
        }
        if (!hidesFace(id, info, neighbor(lx, ly, lz - 1))) {
          emit(4, [x, y, z, x + 1, y, z, x + 1, top, z, x, top, z]);
        }
        if (!hidesFace(id, info, neighbor(lx, ly, lz + 1))) {
          emit(5, [x, y, z + 1, x, top, z + 1, x + 1, top, z + 1, x + 1, y, z + 1]);
        }
      }
    }
  }
  return b.build(cx, sy, cz);
}
