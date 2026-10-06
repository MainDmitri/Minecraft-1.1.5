import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../textures/texture_pack.dart';
import 'mesher.dart';
import 'world.dart';

class Camera {
  Camera(this.x, this.y, this.z, this.yaw, this.pitch);

  /// Положение глаз.
  double x, y, z;

  /// Градусы, как в MCPE: yaw 0 — на юг (+Z), pitch > 0 — взгляд вниз.
  double yaw, pitch;

  static const double fovY = 70;
}

/// Другой игрок: позиция ног и ник.
class EntityBox {
  EntityBox(this.x, this.y, this.z, this.name);

  final double x, y, z;
  final String name;
}

/// Трещины на ломаемом блоке: стадия 0..9 и маска граней (бит на направление 0..5), которые видны.
class BreakOverlay {
  const BreakOverlay(this.pos, this.stage, this.faceMask);

  final BlockPos pos;
  final int stage;
  final int faceMask;
}

class BlockPos {
  const BlockPos(this.x, this.y, this.z);

  final int x, y, z;

  @override
  bool operator ==(Object other) => other is BlockPos && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);
}

final Float64List _identity = Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);

/// Программный 3D-рендер мира через Canvas.drawVertices (алгоритм художника).
class WorldRenderer {
  final Map<int, SectionMesh> _meshes = {};
  int _worldVersion = -1;
  TexturePack? _pack;

  // Буферы кадра (переиспользуются между кадрами).
  Int32List _refMesh = Int32List(1 << 14);
  Int32List _refFace = Int32List(1 << 14);
  Uint16List _refBucket = Uint16List(1 << 14);
  Int32List _order = Int32List(1 << 14);
  Float32List _pos = Float32List(1 << 16);
  Float32List _uv = Float32List(1 << 16);
  Int32List _col = Int32List(1 << 15);
  int _v = 0;
  final Int32List _bucketCount = Int32List(_buckets + 1);
  static const int _buckets = 4096;

  final Map<String, TextPainter> _labels = {};

  /// Смена набора текстур: сетки перестраиваются.
  void setPack(TexturePack? pack, World world) {
    if (identical(pack, _pack)) return;
    _pack = pack;
    _meshes.clear();
    for (final chunk in world.chunks.values) {
      for (var sy = 0; sy < 16; sy++) {
        world.dirtySections.add(World.sectionKey(chunk.x, sy, chunk.z));
      }
    }
  }

  /// Перестройка изменённых секций, не дольше [budget] за вызов. Ближние к игроку — первыми.
  void update(World world, double px, double py, double pz, {Duration budget = const Duration(milliseconds: 6)}) {
    if (_worldVersion != world.version) {
      _worldVersion = world.version;
      _meshes.removeWhere((_, m) => world.chunkAt(m.cx, m.cz) == null);
    }
    if (world.dirtySections.isEmpty) return;
    final sw = Stopwatch()..start();
    final pcx = px.floor() >> 4, pcy = py.floor() >> 4, pcz = pz.floor() >> 4;
    final keys = world.dirtySections.toList();
    int cxOf(int k) => ((k >> 28) << 40) >> 40;
    int czOf(int k) => (((k >> 4) & 0xffffff) << 40) >> 40;
    int distOf(int k) => (cxOf(k) - pcx).abs() + (czOf(k) - pcz).abs() + ((k & 15) - pcy).abs();
    keys.sort((a, b) => distOf(a).compareTo(distOf(b)));
    for (final k in keys) {
      if (sw.elapsed > budget) break;
      world.dirtySections.remove(k);
      final cx = cxOf(k), cz = czOf(k), sy = k & 15;
      if (world.chunkAt(cx, cz) == null) {
        _meshes.remove(k);
        continue;
      }
      final mesh = buildSectionMesh(world, cx, sy, cz, pack: _pack);
      if (mesh == null) {
        _meshes.remove(k);
      } else {
        _meshes[k] = mesh;
      }
    }
  }

  void clear() {
    _meshes.clear();
    _worldVersion = -1;
  }

  void _ensureRefs(int n) {
    if (n <= _refMesh.length) return;
    var size = _refMesh.length;
    while (size < n) {
      size *= 2;
    }
    _refMesh = Int32List(size)..setRange(0, _refMesh.length, _refMesh);
    _refFace = Int32List(size)..setRange(0, _refFace.length, _refFace);
    _refBucket = Uint16List(size)..setRange(0, _refBucket.length, _refBucket);
    _order = Int32List(size);
  }

  void _ensureVerts(int extra) {
    final need = (_v + extra) * 2;
    if (need <= _pos.length) return;
    var size = _pos.length;
    while (size < need) {
      size *= 2;
    }
    _pos = Float32List(size)..setRange(0, _pos.length, _pos);
    _uv = Float32List(size)..setRange(0, _uv.length, _uv);
    _col = Int32List(size ~/ 2)..setRange(0, _col.length, _col);
  }

  SectionMesh _entityMesh(List<EntityBox> entities) {
    final b = MeshBuilder(_pack);
    for (final e in entities) {
      final x0 = e.x - 0.3, x1 = e.x + 0.3, y0 = e.y, y1 = e.y + 1.8, z0 = e.z - 0.3, z1 = e.z + 0.3;
      const body = 0xFF2E8BC0, head = 0xFFC58F6B;
      b
        ..face([x0, y0, z0, x0, y1, z0, x0, y1, z1, x0, y0, z1], 0xFF246C96, 0)
        ..face([x1, y0, z0, x1, y0, z1, x1, y1, z1, x1, y1, z0], 0xFF246C96, 1)
        ..face([x0, y0, z0, x0, y0, z1, x1, y0, z1, x1, y0, z0], 0xFF1B4F6E, 2)
        ..face([x0, y1, z0, x1, y1, z0, x1, y1, z1, x0, y1, z1], head, 3)
        ..face([x0, y0, z0, x1, y0, z0, x1, y1, z0, x0, y1, z0], body, 4)
        ..face([x0, y0, z1, x0, y1, z1, x1, y1, z1, x1, y0, z1], body, 5);
    }
    return b.build(0, 0, 0)!;
  }

  void paint(
    Canvas canvas,
    Size size,
    Camera cam, {
    required double renderDistance,
    required int skyColor,
    List<EntityBox> entities = const [],
    BlockPos? target,
    BreakOverlay? breaking,
    int? worldTime,
    double light = 1,
  }) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Color(skyColor));
    final pack = _pack;

    final yaw = cam.yaw * math.pi / 180, pitch = cam.pitch * math.pi / 180;
    final sinY = math.sin(yaw), cosY = math.cos(yaw), sinP = math.sin(pitch), cosP = math.cos(pitch);
    final fx = -sinY * cosP, fy = -sinP, fz = cosY * cosP;
    final rx = -cosY, rz = -sinY;
    final ux = -rz * fy, uy = rz * fx - rx * fz, uz = rx * fy;
    final ex = cam.x, ey = cam.y, ez = cam.z;
    final halfW = size.width / 2, halfH = size.height / 2;
    final tanY = math.tan(Camera.fovY * math.pi / 360);
    final focal = halfH / tanY;
    final tanX = halfW / focal;
    final r = renderDistance, r2 = r * r;
    const near = 0.05;
    const sectionRadius = 14.0;
    final kx = math.sqrt(1 + tanX * tanX) * sectionRadius;
    final ky = math.sqrt(1 + tanY * tanY) * sectionRadius;

    if (pack != null && worldTime != null) {
      _paintSkyBodies(canvas, pack, worldTime, (dx, dy, dz) {
        final zc = dx * fx + dy * fy + dz * fz;
        if (zc < near) return null;
        final inv = focal / zc;
        return Offset(halfW + (dx * rx + dz * rz) * inv, halfH - (dx * ux + dy * uy + dz * uz) * inv);
      });
    }

    final meshes = <SectionMesh>[];
    for (final m in _meshes.values) {
      final dx = m.minX + 8 - ex, dy = m.minY + 8 - ey, dz = m.minZ + 8 - ez;
      if (dx * dx + dy * dy + dz * dz > (r + sectionRadius) * (r + sectionRadius)) continue;
      final cz = dx * fx + dy * fy + dz * fz;
      if (cz < -sectionRadius) continue;
      final cx = dx * rx + dz * rz;
      final cy = dx * ux + dy * uy + dz * uz;
      if (cx.abs() - kx > cz * tanX) continue;
      if (cy.abs() - ky > cz * tanY) continue;
      meshes.add(m);
    }
    if (entities.isNotEmpty) meshes.add(_entityMesh(entities));

    // Отбор граней.
    var n = 0;
    for (var mi = 0; mi < meshes.length; mi++) {
      final m = meshes[mi];
      final centers = m.centers, dirs = m.dirs;
      _ensureRefs(n + m.count);
      for (var i = 0; i < m.count; i++) {
        final cxw = centers[i * 3], cyw = centers[i * 3 + 1], czw = centers[i * 3 + 2];
        switch (dirs[i]) {
          case 0:
            if (ex >= cxw) continue;
          case 1:
            if (ex <= cxw) continue;
          case 2:
            if (ey >= cyw) continue;
          case 3:
            if (ey <= cyw) continue;
          case 4:
            if (ez >= czw) continue;
          case 5:
            if (ez <= czw) continue;
        }
        final dx = cxw - ex, dy = cyw - ey, dz = czw - ez;
        final d2 = dx * dx + dy * dy + dz * dz;
        if (d2 > r2) continue;
        final depth = dx * fx + dy * fy + dz * fz;
        if (depth < -1) continue;
        if (depth > 1 && (dx * rx + dz * rz).abs() > depth * tanX + 1) continue;
        _refMesh[n] = mi;
        _refFace[n] = i;
        _refBucket[n] = (math.sqrt(d2) / r * (_buckets - 1)).toInt();
        n++;
      }
    }

    // Сортировка подсчётом: от дальних к ближним.
    _bucketCount.fillRange(0, _bucketCount.length, 0);
    for (var i = 0; i < n; i++) {
      _bucketCount[_buckets - 1 - _refBucket[i]]++;
    }
    var acc = 0;
    for (var b = 0; b < _buckets; b++) {
      final c = _bucketCount[b];
      _bucketCount[b] = acc;
      acc += c;
    }
    for (var i = 0; i < n; i++) {
      final b = _buckets - 1 - _refBucket[i];
      _order[_bucketCount[b]++] = i;
    }

    _v = 0;
    final skyR = (skyColor >> 16) & 0xff, skyG = (skyColor >> 8) & 0xff, skyB = skyColor & 0xff;
    final fogStart = r * 0.6, fogLen = r * 0.4;
    final px = Float64List(5), py = Float64List(5), pz = Float64List(5), pu = Float64List(5), pv = Float64List(5);
    final qx = Float64List(4), qy = Float64List(4), qz = Float64List(4), qu = Float64List(4), qv = Float64List(4);

    /// Четырёхугольник в координатах камеры (q*), с отсечением ближней плоскостью и проекцией.
    void emitQuad(int color) {
      var behind = 0;
      for (var k = 0; k < 4; k++) {
        if (qz[k] < near) behind++;
      }
      if (behind == 4) return;
      var count = 0;
      if (behind == 0) {
        for (var k = 0; k < 4; k++) {
          px[k] = qx[k];
          py[k] = qy[k];
          pz[k] = qz[k];
          pu[k] = qu[k];
          pv[k] = qv[k];
        }
        count = 4;
      } else {
        for (var k = 0; k < 4; k++) {
          final k2 = (k + 1) & 3;
          final aIn = qz[k] >= near, bIn = qz[k2] >= near;
          if (aIn) {
            px[count] = qx[k];
            py[count] = qy[k];
            pz[count] = qz[k];
            pu[count] = qu[k];
            pv[count] = qv[k];
            count++;
          }
          if (aIn != bIn) {
            final t = (near - qz[k]) / (qz[k2] - qz[k]);
            px[count] = qx[k] + (qx[k2] - qx[k]) * t;
            py[count] = qy[k] + (qy[k2] - qy[k]) * t;
            pz[count] = near;
            pu[count] = qu[k] + (qu[k2] - qu[k]) * t;
            pv[count] = qv[k] + (qv[k2] - qv[k]) * t;
            count++;
          }
        }
        if (count < 3) return;
      }
      for (var k = 0; k < count; k++) {
        final inv = focal / pz[k];
        px[k] = halfW + px[k] * inv;
        py[k] = halfH - py[k] * inv;
      }
      _ensureVerts((count - 2) * 3);
      for (var t = 1; t < count - 1; t++) {
        for (final k in [0, t, t + 1]) {
          _pos[_v * 2] = px[k];
          _pos[_v * 2 + 1] = py[k];
          _uv[_v * 2] = pu[k];
          _uv[_v * 2 + 1] = pv[k];
          _col[_v++] = color;
        }
      }
    }

    final wx = Float64List(4), wy = Float64List(4), wz = Float64List(4), wu = Float64List(4), wv = Float64List(4);

    /// Грань [fi] сетки [m]; вблизи делится на части: аффинное наложение текстуры иначе заметно искажает её.
    void emitFace(SectionMesh m, int fi, int color, double dist) {
      final c = m.corners;
      final uvs = m.uvs;
      final base = fi * 12;
      for (var k = 0; k < 4; k++) {
        wx[k] = c[base + k * 3] - ex;
        wy[k] = c[base + k * 3 + 1] - ey;
        wz[k] = c[base + k * 3 + 2] - ez;
        wu[k] = uvs == null ? 0 : uvs[fi * 8 + k * 2];
        wv[k] = uvs == null ? 0 : uvs[fi * 8 + k * 2 + 1];
      }
      final splits = uvs != null && dist < 3 ? 4 : (uvs != null && dist < 6 ? 2 : 1);
      for (var si = 0; si < splits; si++) {
        for (var sj = 0; sj < splits; sj++) {
          for (var k = 0; k < 4; k++) {
            final s = (si + ((k == 1 || k == 2) ? 1 : 0)) / splits;
            final t = (sj + (k >= 2 ? 1 : 0)) / splits;
            // Билинейная интерполяция по вершинам 0-1-2-3.
            double bil(Float64List a) => (a[0] * (1 - s) + a[1] * s) * (1 - t) + (a[3] * (1 - s) + a[2] * s) * t;
            final ax = bil(wx), ay = bil(wy), az = bil(wz);
            qx[k] = ax * rx + az * rz;
            qy[k] = ax * ux + ay * uy + az * uz;
            qz[k] = ax * fx + ay * fy + az * fz;
            qu[k] = bil(wu);
            qv[k] = bil(wv);
          }
          emitQuad(color);
        }
      }
    }

    /// Вывод накопленных треугольников на холст.
    void flush(BlendMode canvasBlend) {
      if (_v == 0) return;
      final vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        Float32List.sublistView(_pos, 0, _v * 2),
        textureCoordinates: pack == null ? null : Float32List.sublistView(_uv, 0, _v * 2),
        colors: Int32List.sublistView(_col, 0, _v),
      );
      final paint = Paint()
        ..isAntiAlias = false
        ..blendMode = canvasBlend;
      if (pack != null) {
        paint.shader = ui.ImageShader(
          pack.atlas,
          TileMode.clamp,
          TileMode.clamp,
          _identity,
          filterQuality: FilterQuality.none,
        );
      }
      canvas.drawVertices(vertices, pack == null ? BlendMode.dst : BlendMode.modulate, paint);
      vertices.dispose();
      _v = 0;
    }

    for (var oi = 0; oi < n; oi++) {
      final ref = _order[oi];
      final m = meshes[_refMesh[ref]];
      final fi = _refFace[ref];
      final ci = fi * 3;
      final dx = m.centers[ci] - ex, dy = m.centers[ci + 1] - ey, dz = m.centers[ci + 2] - ez;
      final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
      var color = m.colors[fi];
      if (light < 1) {
        // Ночью мир темнее.
        int dim(int shift) => (((color >> shift) & 0xff) * light).round() << shift;
        color = (color & 0xff000000) | dim(16) | dim(8) | dim(0);
      }
      if (dist > fogStart) {
        final t = ((dist - fogStart) / fogLen).clamp(0.0, 1.0);
        if (pack != null) {
          // С текстурами туман — растворение в небе через прозрачность.
          final a = (((color >> 24) & 0xff) * (1 - t)).round();
          color = (a << 24) | (color & 0x00ffffff);
        } else {
          int mix(int ch, int sky) => (ch + (sky - ch) * t).round();
          color = (color & 0xff000000) |
              (mix((color >> 16) & 0xff, skyR) << 16) |
              (mix((color >> 8) & 0xff, skyG) << 8) |
              mix(color & 0xff, skyB);
        }
      }

      emitFace(m, fi, color, dist);
    }
    flush(BlendMode.srcOver);

    // Трещины поверх ломаемого блока.
    if (pack != null && breaking != null && pack.destroyTiles.isNotEmpty) {
      final tile = pack.destroyTiles[breaking.stage.clamp(0, pack.destroyTiles.length - 1)];
      final b = MeshBuilder(pack);
      final bx = breaking.pos.x.toDouble(), by = breaking.pos.y.toDouble(), bz = breaking.pos.z.toDouble();
      const e = 0.004;
      final x0 = bx - e, y0 = by - e, z0 = bz - e, x1 = bx + 1 + e, y1 = by + 1 + e, z1 = bz + 1 + e;
      final faces = [
        [x0, y0, z0, x0, y1, z0, x0, y1, z1, x0, y0, z1],
        [x1, y0, z0, x1, y0, z1, x1, y1, z1, x1, y1, z0],
        [x0, y0, z0, x0, y0, z1, x1, y0, z1, x1, y0, z0],
        [x0, y1, z0, x1, y1, z0, x1, y1, z1, x0, y1, z1],
        [x0, y0, z0, x1, y0, z0, x1, y1, z0, x0, y1, z0],
        [x0, y0, z1, x0, y1, z1, x1, y1, z1, x1, y0, z1],
      ];
      final facing = [ex < x0, ex > x1, ey < y0, ey > y1, ez < z0, ez > z1];
      for (var dir = 0; dir < 6; dir++) {
        if (facing[dir] && breaking.faceMask & (1 << dir) != 0) {
          b.face(faces[dir], 0xFFFFFFFF, dir, uv: blockFaceUv(dir, faces[dir], bx, by, bz), tile: tile);
        }
      }
      final mesh = b.build(0, 0, 0);
      if (mesh != null) {
        final dx = bx + 0.5 - ex, dy = by + 0.5 - ey, dz = bz + 0.5 - ez;
        final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
        for (var fi = 0; fi < mesh.count; fi++) {
          emitFace(mesh, fi, 0xFFFFFFFF, dist);
        }
        flush(BlendMode.multiply);
      }
    }

    Offset? project(double wx, double wy, double wz) {
      final dx = wx - ex, dy = wy - ey, dz = wz - ez;
      final zc = dx * fx + dy * fy + dz * fz;
      if (zc < near) return null;
      final inv = focal / zc;
      return Offset(halfW + (dx * rx + dz * rz) * inv, halfH - (dx * ux + dy * uy + dz * uz) * inv);
    }

    if (target != null) {
      final outline = Paint()
        ..color = const Color(0xCC000000)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final x0 = target.x.toDouble(), y0 = target.y.toDouble(), z0 = target.z.toDouble();
      final pts = [
        for (final p in const [
          [0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1], //
          [0, 1, 0], [1, 1, 0], [1, 1, 1], [0, 1, 1],
        ])
          project(x0 + p[0] * 1.002 - 0.001, y0 + p[1] * 1.002 - 0.001, z0 + p[2] * 1.002 - 0.001),
      ];
      const edges = [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7];
      for (var i = 0; i < edges.length; i += 2) {
        final a = pts[edges[i]], b = pts[edges[i + 1]];
        if (a != null && b != null) canvas.drawLine(a, b, outline);
      }
    }

    for (final e in entities) {
      final dx = e.x - ex, dz = e.z - ez;
      if (dx * dx + dz * dz > r2) continue;
      final p = project(e.x, e.y + 2.1, e.z);
      if (p == null) continue;
      final label = _labels.putIfAbsent(
        e.name,
        () => TextPainter(
          text: TextSpan(
            text: e.name,
            style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 13, backgroundColor: Color(0x88000000)),
          ),
          textDirection: TextDirection.ltr,
        )..layout(),
      );
      label.paint(canvas, p - Offset(label.width / 2, label.height));
    }
  }

  /// Солнце и луна (текстуры из файла игры) по времени суток, с аддитивным смешиванием, как в Minecraft.
  void _paintSkyBodies(Canvas canvas, TexturePack pack, int worldTime, Offset? Function(double, double, double) project) {
    var f = (worldTime % 24000) / 24000 - 0.25;
    if (f < 0) f += 1;
    f += ((1 - (math.cos(f * math.pi) + 1) / 2) - f) / 3;
    final a = f * 2 * math.pi;
    // Полдень — над головой, восход на востоке (+X), закат на западе.
    final dx = -math.sin(a), dy = math.cos(a);
    final tx = math.cos(a), ty = math.sin(a);

    void body(ui.Image image, Rect src, double sign, double half) {
      final cx = dx * sign * 100, cy = dy * sign * 100;
      final pts = <Offset>[];
      for (final (s, t) in const [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]) {
        final p = project(cx + tx * s * half, cy + ty * s * half, t * half);
        if (p == null) return;
        pts.add(p);
      }
      final uv = [src.topLeft, src.topRight, src.bottomRight, src.bottomLeft];
      final vertices = ui.Vertices(
        ui.VertexMode.triangles,
        [pts[0], pts[1], pts[2], pts[0], pts[2], pts[3]],
        textureCoordinates: [uv[0], uv[1], uv[2], uv[0], uv[2], uv[3]],
      );
      final paint = Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.ImageShader(image, TileMode.clamp, TileMode.clamp, _identity,
            filterQuality: FilterQuality.none);
      canvas.drawVertices(vertices, BlendMode.dst, paint);
      vertices.dispose();
    }

    final sun = pack.sun, moon = pack.moon;
    if (sun != null) body(sun, Rect.fromLTWH(0, 0, sun.width.toDouble(), sun.height.toDouble()), 1, 30);
    if (moon != null) {
      final phase = (worldTime ~/ 24000) % 8;
      final w = moon.width / 4, h = moon.height / 2;
      body(moon, Rect.fromLTWH((phase % 4) * w, (phase ~/ 4) * h, w, h), -1, 20);
    }
  }
}
