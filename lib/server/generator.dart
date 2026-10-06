import 'dart:math' as math;

import '../world/world.dart';

/// Генератор мира: холмистая равнина с водой, пляжами, деревьями, травой и рудами.
/// Результат зависит только от зерна и координат чанка.
class TerrainGenerator {
  TerrainGenerator(this.seed);

  final int seed;

  static const int seaLevel = 62;

  int _hash(int x, int z, int salt) {
    var h = (seed * 0x5DEECE66D) ^ (x * 0x27d4eb2d) ^ (z * 0x165667b1) ^ (salt * 0x9E3779B9);
    h = (h ^ (h >>> 15)) * 0x2c1b3c6d;
    h = (h ^ (h >>> 12)) * 0x297a2d39;
    h ^= h >>> 15;
    return h & 0x7fffffff;
  }

  double _unit(int x, int z, int salt) => _hash(x, z, salt) / 0x7fffffff;

  double _noise(double x, double z, int salt) {
    final x0 = x.floor(), z0 = z.floor();
    final fx = x - x0, fz = z - z0;
    double smooth(double t) => t * t * (3 - 2 * t);
    final sx = smooth(fx), sz = smooth(fz);
    double corner(int cx, int cz) => _unit(cx, cz, salt) * 2 - 1;
    final a = corner(x0, z0) + (corner(x0 + 1, z0) - corner(x0, z0)) * sx;
    final b = corner(x0, z0 + 1) + (corner(x0 + 1, z0 + 1) - corner(x0, z0 + 1)) * sx;
    return a + (b - a) * sz;
  }

  int heightAt(int x, int z) {
    final continent = _noise(x / 160, z / 160, 1);
    final hills = _noise(x / 48, z / 48, 2);
    final detail = _noise(x / 14, z / 14, 3);
    final h = 67 + continent * 12 + hills * (6 + 6 * math.max(0, continent)) + detail * 1.6;
    return h.round().clamp(8, 120);
  }

  Chunk generate(int cx, int cz) {
    final chunk = Chunk(cx, cz);
    final heights = List<int>.filled(256, 0);
    for (var lx = 0; lx < 16; lx++) {
      for (var lz = 0; lz < 16; lz++) {
        final x = cx * 16 + lx, z = cz * 16 + lz;
        final h = heightAt(x, z);
        heights[(lz << 4) | lx] = h;
        final beach = h <= seaLevel + 1;
        for (var y = 0; y <= h; y++) {
          int id;
          if (y == 0) {
            id = 7;
          } else if (y < h - 3) {
            id = _ore(x, y, z);
          } else if (y < h) {
            id = beach ? 12 : 3;
          } else {
            id = beach ? (h < seaLevel - 3 ? 13 : 12) : 2;
          }
          chunk.set(lx, y, lz, id, 0);
        }
        for (var y = h + 1; y <= seaLevel; y++) {
          chunk.set(lx, y, lz, 9, 0);
        }
        if (!beach) {
          final r = _unit(x, z, 7);
          if (r < 0.10) {
            chunk.set(lx, h + 1, lz, 31, 1); // трава
          } else if (r < 0.11) {
            chunk.set(lx, h + 1, lz, 37, 0); // одуванчик
          } else if (r < 0.115) {
            chunk.set(lx, h + 1, lz, 38, 0); // мак
          }
        }
      }
    }
    // Деревья — только внутри чанка, чтобы не зависеть от соседей.
    for (var lx = 2; lx < 14; lx++) {
      for (var lz = 2; lz < 14; lz++) {
        final x = cx * 16 + lx, z = cz * 16 + lz;
        final h = heights[(lz << 4) | lx];
        if (h <= seaLevel + 1 || _unit(x, z, 11) > 0.012 || h > 110) continue;
        _tree(chunk, lx, h + 1, lz, 4 + _hash(x, z, 12) % 3, _hash(x, z, 13) % 3 == 0 ? 2 : 0);
      }
    }
    return chunk;
  }

  int _ore(int x, int y, int z) {
    final r = _unit(x * 31 + y, z * 17 - y, 21);
    if (y < 16 && r < 0.0012) return 56; // алмаз
    if (y < 32 && r < 0.003) return 14; // золото
    if (y < 48 && r < 0.008) return 15; // железо
    if (r < 0.018) return 16; // уголь
    if (r < 0.03) return 13; // гравий
    return 1;
  }

  void _tree(Chunk chunk, int lx, int y, int lz, int height, int woodMeta) {
    for (var dy = 0; dy < height; dy++) {
      chunk.set(lx, y + dy, lz, 17, woodMeta);
    }
    final top = y + height;
    for (var dy = -2; dy <= 1; dy++) {
      final radius = dy >= 0 ? 1 : 2;
      for (var dx = -radius; dx <= radius; dx++) {
        for (var dz = -radius; dz <= radius; dz++) {
          if (dx == 0 && dz == 0 && dy < 0) continue;
          if (radius == 2 && dx.abs() == 2 && dz.abs() == 2) continue;
          if (chunk.id(lx + dx, top + dy, lz + dz) == 0) {
            chunk.set(lx + dx, top + dy, lz + dz, 18, woodMeta);
          }
        }
      }
    }
  }

  /// Безопасная точка появления: верх суши около (0, 0).
  (int, int, int) findSpawn() {
    for (var r = 0; r < 256; r += 8) {
      for (var dx = -r; dx <= r; dx += 8) {
        for (final dz in [-r, r]) {
          final h = heightAt(dx, dz);
          if (h > seaLevel + 1) return (dx, h + 1, dz);
        }
      }
    }
    return (0, heightAt(0, 0) + 1, 0);
  }
}
