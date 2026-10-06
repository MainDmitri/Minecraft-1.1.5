import 'dart:math' as math;

import 'blocks.dart';
import 'renderer.dart';
import 'world.dart';

const double eyeHeight = 1.62;
const double _halfWidth = 0.3;
const double _height = 1.8;

/// Результат луча из глаз: блок, грань (нумерация граней сервера) и точка попадания внутри блока.
class RayHit {
  RayHit(this.block, this.face, this.fx, this.fy, this.fz);

  final BlockPos block;

  /// 0 низ, 1 верх, 2 север (−Z), 3 юг (+Z), 4 запад (−X), 5 восток (+X).
  final int face;
  final double fx, fy, fz;

  BlockPos get adjacent {
    final b = block;
    return switch (face) {
      0 => BlockPos(b.x, b.y - 1, b.z),
      1 => BlockPos(b.x, b.y + 1, b.z),
      2 => BlockPos(b.x, b.y, b.z - 1),
      3 => BlockPos(b.x, b.y, b.z + 1),
      4 => BlockPos(b.x - 1, b.y, b.z),
      _ => BlockPos(b.x + 1, b.y, b.z),
    };
  }
}

/// Локальная физика игрока: шаг 50 мс, как тик сервера.
class PlayerController {
  /// Позиция ног.
  double x = 0, y = 0, z = 0;
  double vx = 0, vy = 0, vz = 0;
  double yaw = 0, pitch = 0;
  bool onGround = false;
  bool flying = false;
  bool inWater = false;

  /// Ввод: вперёд/назад и вбок в диапазоне −1..1.
  double forward = 0, strafe = 0;
  bool jump = false;
  bool descend = false;

  void setEyePosition(double ex, double ey, double ez) {
    x = ex;
    y = ey - eyeHeight;
    z = ez;
    vx = vy = vz = 0;
  }

  double get eyeY => y + eyeHeight;

  /// Пересекается ли тело игрока с твёрдыми блоками, если поставить ноги в (px, py, pz).
  bool collidesAt(World world, double px, double py, double pz) => _collides(world, px, py, pz);

  bool _collides(World world, double px, double py, double pz) {
    final x0 = (px - _halfWidth).floor(), x1 = (px + _halfWidth - 1e-6).floor();
    final y0 = py.floor(), y1 = (py + _height - 1e-6).floor();
    final z0 = (pz - _halfWidth).floor(), z1 = (pz + _halfWidth - 1e-6).floor();
    for (var bx = x0; bx <= x1; bx++) {
      for (var by = y0; by <= y1; by++) {
        for (var bz = z0; bz <= z1; bz++) {
          if (world.isSolid(bx, by, bz)) return true;
        }
      }
    }
    return false;
  }

  /// Сдвиг по одной оси с упором в твёрдые блоки. Возвращает фактический сдвиг.
  double _move(World world, int axis, double delta) {
    if (delta == 0) return 0;
    const steps = 4;
    final step = delta / steps;
    var moved = 0.0;
    for (var i = 0; i < steps; i++) {
      final nx = axis == 0 ? x + step : x, ny = axis == 1 ? y + step : y, nz = axis == 2 ? z + step : z;
      // Застрявший в блоках игрок (например, сервер поставил его внутрь дерева) может выйти вбок или вверх.
      final stuck = _collides(world, x, y, z);
      if (stuck && (axis != 1 || step > 0)) {
        x = nx;
        y = ny;
        z = nz;
        moved += step;
        continue;
      }
      if (_collides(world, nx, ny, nz)) {
        final px = x, py = y, pz = z;
        // Подходим вплотную к грани блока.
        if (axis == 1) {
          y = step < 0 ? ny.floor() + 1.0 : (ny + _height).floor() - _height;
        } else if (axis == 0) {
          x = step < 0 ? (nx - _halfWidth).floor() + 1 + _halfWidth : (nx + _halfWidth).floor() - _halfWidth;
        } else {
          z = step < 0 ? (nz - _halfWidth).floor() + 1 + _halfWidth : (nz + _halfWidth).floor() - _halfWidth;
        }
        if (_collides(world, x, y, z)) {
          x = px;
          y = py;
          z = pz;
        } else {
          moved += axis == 0 ? x - px : (axis == 1 ? y - py : z - pz);
        }
        return moved;
      }
      x = nx;
      y = ny;
      z = nz;
      moved += step;
    }
    return moved;
  }

  void tick(World world) {
    if (!world.isLoaded(x.floor(), z.floor())) return;
    final feetId = world.blockId(x.floor(), y.floor(), z.floor());
    final headId = world.blockId(x.floor(), (y + 1).floor(), z.floor());
    inWater = blockTable[feetId].shape == BlockShape.liquid || blockTable[headId].shape == BlockShape.liquid;

    final yawRad = yaw * math.pi / 180;
    final sin = math.sin(yawRad), cos = math.cos(yawRad);
    var speed = flying ? 0.5 : (inWater ? 0.1 : 0.2158);
    final len = math.sqrt(forward * forward + strafe * strafe);
    if (len > 1) speed /= len;
    // Вперёд: (−sin, cos); вправо: (−cos, −sin).
    vx = (-sin * forward - cos * strafe) * speed;
    vz = (cos * forward - sin * strafe) * speed;

    if (flying) {
      vy = jump ? 0.4 : (descend ? -0.4 : 0);
    } else if (inWater) {
      if (jump) vy = 0.12;
    } else if (jump && onGround) {
      vy = 0.42;
    }

    final wantX = vx, wantZ = vz;
    final dyMoved = _move(world, 1, vy);
    final hitY = (dyMoved - vy).abs() > 1e-9;
    onGround = hitY && vy < 0;
    if (hitY) vy = 0;
    final dx = _move(world, 0, wantX);
    final dz = _move(world, 2, wantZ);

    // Гравитация после перемещения, как в игре: прыжок 0.42 даёт высоту 1.25 блока.
    if (!flying) {
      vy = inWater ? vy * 0.8 - 0.02 : (vy - 0.08) * 0.98;
    }

    // Автопрыжок, как на сенсорном управлении MCPE.
    final blocked = (dx - wantX).abs() > 1e-6 || (dz - wantZ).abs() > 1e-6;
    if (blocked && onGround && !flying && len > 0.3 && !_collides(world, x, y + 1.1, z)) {
      vy = 0.42;
      onGround = false;
    }
    if (y < -64) y = -64;
  }

  /// Луч из глаз до [maxDistance] блоков (обход по сетке).
  RayHit? raycast(World world, double maxDistance) {
    final yawRad = yaw * math.pi / 180, pitchRad = pitch * math.pi / 180;
    final dx = -math.sin(yawRad) * math.cos(pitchRad);
    final dy = -math.sin(pitchRad);
    final dz = math.cos(yawRad) * math.cos(pitchRad);
    final ox = x, oy = eyeY, oz = z;
    var bx = ox.floor(), by = oy.floor(), bz = oz.floor();
    final stepX = dx > 0 ? 1 : -1, stepY = dy > 0 ? 1 : -1, stepZ = dz > 0 ? 1 : -1;
    double boundary(double o, int b, int step) => step > 0 ? b + 1 - o : o - b;
    final tdx = dx == 0 ? double.infinity : 1 / dx.abs();
    final tdy = dy == 0 ? double.infinity : 1 / dy.abs();
    final tdz = dz == 0 ? double.infinity : 1 / dz.abs();
    var tmx = dx == 0 ? double.infinity : boundary(ox, bx, stepX) * tdx;
    var tmy = dy == 0 ? double.infinity : boundary(oy, by, stepY) * tdy;
    var tmz = dz == 0 ? double.infinity : boundary(oz, bz, stepZ) * tdz;
    var face = -1;
    var t = 0.0;
    while (t <= maxDistance) {
      final id = world.blockId(bx, by, bz);
      final info = blockTable[id];
      if (face >= 0 && id != 0 && info.shape != BlockShape.none && info.shape != BlockShape.liquid) {
        final hx = ox + dx * t - bx, hy = oy + dy * t - by, hz = oz + dz * t - bz;
        return RayHit(BlockPos(bx, by, bz), face, hx.clamp(0.0, 1.0), hy.clamp(0.0, 1.0), hz.clamp(0.0, 1.0));
      }
      if (tmx < tmy && tmx < tmz) {
        t = tmx;
        bx += stepX;
        tmx += tdx;
        face = stepX > 0 ? 4 : 5;
      } else if (tmy < tmz) {
        t = tmy;
        by += stepY;
        tmy += tdy;
        face = stepY > 0 ? 0 : 1;
      } else {
        t = tmz;
        bz += stepZ;
        tmz += tdz;
        face = stepZ > 0 ? 2 : 3;
      }
      if (by < 0 || by > 255) return null;
    }
    return null;
  }

  /// Пересекается ли блок с игроком (нельзя ставить блок в себя).
  bool intersects(BlockPos b) =>
      b.x + 1 > x - _halfWidth &&
      b.x < x + _halfWidth &&
      b.y + 1 > y &&
      b.y < y + _height &&
      b.z + 1 > z - _halfWidth &&
      b.z < z + _halfWidth;
}
