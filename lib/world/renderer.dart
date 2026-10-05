import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

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

class BlockPos {
  const BlockPos(this.x, this.y, this.z);

  final int x, y, z;

  @override
  bool operator ==(Object other) => other is BlockPos && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);
}

/// Программный 3D-рендер мира через Canvas.drawVertices (алгоритм художника).
class WorldRenderer {
  final Map<int, SectionMesh> _meshes = {};
  int _worldVersion = -1;

  // Буферы кадра (переиспользуются между кадрами).
  Int32List _refMesh = Int32List(1 << 14);
  Int32List _refFace = Int32List(1 << 14);
  Uint16List _refBucket = Uint16List(1 << 14);
  Int32List _order = Int32List(1 << 14);
  Float32List _pos = Float32List(1 << 16);
  Int32List _col = Int32List(1 << 15);
  final Int32List _bucketCount = Int32List(_buckets + 1);
  static const int _buckets = 4096;

  final Map<String, TextPainter> _labels = {};

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
      final mesh = buildSectionMesh(world, cx, sy, cz);
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

  void _ensureVerts(int n) {
    if (n * 2 <= _pos.length) return;
    var size = _pos.length;
    while (size < n * 2) {
      size *= 2;
    }
    _pos = Float32List(size)..setRange(0, _pos.length, _pos);
    _col = Int32List(size ~/ 2)..setRange(0, _col.length, _col);
  }

  SectionMesh _entityMesh(List<EntityBox> entities) {
    final corners = <double>[], centers = <double>[], colors = <int>[], dirs = <int>[];
    void face(List<double> c, int color, int dir) {
      corners.addAll(c);
      centers
        ..add((c[0] + c[6]) / 2)
        ..add((c[1] + c[7]) / 2)
        ..add((c[2] + c[8]) / 2);
      colors.add(color);
      dirs.add(dir);
    }

    for (final e in entities) {
      final x0 = e.x - 0.3, x1 = e.x + 0.3, y0 = e.y, y1 = e.y + 1.8, z0 = e.z - 0.3, z1 = e.z + 0.3;
      const body = 0xFF2E8BC0, head = 0xFFC58F6B;
      face([x0, y0, z0, x0, y1, z0, x0, y1, z1, x0, y0, z1], 0xFF246C96, 0);
      face([x1, y0, z0, x1, y0, z1, x1, y1, z1, x1, y1, z0], 0xFF246C96, 1);
      face([x0, y0, z0, x0, y0, z1, x1, y0, z1, x1, y0, z0], 0xFF1B4F6E, 2);
      face([x0, y1, z0, x1, y1, z0, x1, y1, z1, x0, y1, z1], head, 3);
      face([x0, y0, z0, x1, y0, z0, x1, y1, z0, x0, y1, z0], body, 4);
      face([x0, y0, z1, x0, y1, z1, x1, y1, z1, x1, y0, z1], body, 5);
    }
    return SectionMesh(0, 0, 0, dirs.length, Float32List.fromList(corners), Float32List.fromList(centers),
        Int32List.fromList(colors), Uint8List.fromList(dirs));
  }

  void paint(
    Canvas canvas,
    Size size,
    Camera cam, {
    required double renderDistance,
    required int skyColor,
    List<EntityBox> entities = const [],
    BlockPos? target,
  }) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Color(skyColor));

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

    // Проекция и сборка треугольников.
    _ensureVerts(n * 9);
    var v = 0;
    final skyR = (skyColor >> 16) & 0xff, skyG = (skyColor >> 8) & 0xff, skyB = skyColor & 0xff;
    final fogStart = r * 0.6, fogLen = r * 0.4;
    final px = Float64List(5), py = Float64List(5), pz = Float64List(5);
    final qx = Float64List(4), qy = Float64List(4), qz = Float64List(4);

    for (var oi = 0; oi < n; oi++) {
      final ref = _order[oi];
      final m = meshes[_refMesh[ref]];
      final fi = _refFace[ref];
      final c = m.corners;
      final base = fi * 12;
      var behind = 0;
      for (var k = 0; k < 4; k++) {
        final dx = c[base + k * 3] - ex, dy = c[base + k * 3 + 1] - ey, dz = c[base + k * 3 + 2] - ez;
        qx[k] = dx * rx + dz * rz;
        qy[k] = dx * ux + dy * uy + dz * uz;
        qz[k] = dx * fx + dy * fy + dz * fz;
        if (qz[k] < near) behind++;
      }
      if (behind == 4) continue;

      var count = 0;
      if (behind == 0) {
        for (var k = 0; k < 4; k++) {
          px[k] = qx[k];
          py[k] = qy[k];
          pz[k] = qz[k];
        }
        count = 4;
      } else {
        // Отсечение многоугольника ближней плоскостью.
        for (var k = 0; k < 4; k++) {
          final k2 = (k + 1) & 3;
          final aIn = qz[k] >= near, bIn = qz[k2] >= near;
          if (aIn) {
            px[count] = qx[k];
            py[count] = qy[k];
            pz[count] = qz[k];
            count++;
          }
          if (aIn != bIn) {
            final t = (near - qz[k]) / (qz[k2] - qz[k]);
            px[count] = qx[k] + (qx[k2] - qx[k]) * t;
            py[count] = qy[k] + (qy[k2] - qy[k]) * t;
            pz[count] = near;
            count++;
          }
        }
        if (count < 3) continue;
      }

      // Туман по расстоянию.
      final ci = fi * 3;
      final dx = m.centers[ci] - ex, dy = m.centers[ci + 1] - ey, dz = m.centers[ci + 2] - ez;
      final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
      var color = m.colors[fi];
      if (dist > fogStart) {
        final t = ((dist - fogStart) / fogLen).clamp(0.0, 1.0);
        int mix(int ch, int sky) => (ch + (sky - ch) * t).round();
        color = (color & 0xff000000) |
            (mix((color >> 16) & 0xff, skyR) << 16) |
            (mix((color >> 8) & 0xff, skyG) << 8) |
            mix(color & 0xff, skyB);
      }

      for (var k = 0; k < count; k++) {
        final inv = focal / pz[k];
        px[k] = halfW + px[k] * inv;
        py[k] = halfH - py[k] * inv;
      }
      for (var t = 1; t < count - 1; t++) {
        _pos[v * 2] = px[0];
        _pos[v * 2 + 1] = py[0];
        _col[v++] = color;
        _pos[v * 2] = px[t];
        _pos[v * 2 + 1] = py[t];
        _col[v++] = color;
        _pos[v * 2] = px[t + 1];
        _pos[v * 2 + 1] = py[t + 1];
        _col[v++] = color;
      }
    }

    if (v > 0) {
      final vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        Float32List.sublistView(_pos, 0, v * 2),
        colors: Int32List.sublistView(_col, 0, v),
      );
      canvas.drawVertices(vertices, BlendMode.dst, Paint()..isAntiAlias = false);
      vertices.dispose();
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
}
