import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../game/items.dart';
import '../protocol/packets.dart';
import '../textures/texture_pack.dart';
import '../world/blocks.dart';
import 'mc_ui.dart';

final Expando<ui.ImageShader> _atlasShaders = Expando();

ui.ImageShader _shaderFor(ui.Image atlas) => _atlasShaders[atlas] ??= ui.ImageShader(
      atlas,
      TileMode.clamp,
      TileMode.clamp,
      Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
      filterQuality: FilterQuality.none,
    );

/// Блок в инвентаре — объёмный куб: верх, левая и правая грани с разной яркостью.
void _paintCube(Canvas canvas, Rect dst, TexturePack pack, int id, int meta) {
  final r = dst.deflate(dst.width * 0.06);
  final cx = r.center.dx, x0 = r.left, x1 = r.right, y0 = r.top, h = r.height;
  final top = Offset(cx, y0), right = Offset(x1, y0 + h * 0.25), mid = Offset(cx, y0 + h * 0.5), left = Offset(x0, y0 + h * 0.25);
  final leftBottom = Offset(x0, y0 + h * 0.75), bottom = Offset(cx, r.bottom), rightBottom = Offset(x1, y0 + h * 0.75);
  final positions = <Offset>[];
  final uvs = <Offset>[];
  final colors = <Color>[];
  void quad(List<Offset> p, int tile, Color c) {
    if (tile < 0) return;
    final u0 = pack.tileX(tile) + 0.01, v0 = pack.tileY(tile) + 0.01;
    final u1 = u0 + tileSize - 0.02, v1 = v0 + tileSize - 0.02;
    final t = [Offset(u0, v0), Offset(u1, v0), Offset(u1, v1), Offset(u0, v1)];
    for (final k in const [0, 1, 2, 0, 2, 3]) {
      positions.add(p[k]);
      uvs.add(t[k]);
      colors.add(c);
    }
  }

  quad([top, right, mid, left], pack.tile(id, meta, 3), Colors.white);
  quad([left, mid, bottom, leftBottom], pack.tile(id, meta, 5), const Color(0xFFCCCCCC));
  quad([mid, right, rightBottom, bottom], pack.tile(id, meta, 1), const Color(0xFF999999));
  if (positions.isEmpty) return;
  final vertices = ui.Vertices(ui.VertexMode.triangles, positions, textureCoordinates: uvs, colors: colors);
  canvas.drawVertices(
    vertices,
    BlendMode.modulate,
    Paint()
      ..shader = _shaderFor(pack.atlas)
      ..isAntiAlias = false,
  );
  vertices.dispose();
}

void _paintTile(Canvas canvas, Rect dst, TexturePack pack, int tile) => drawSprite(
    canvas, pack.atlas, Rect.fromLTWH(pack.tileX(tile), pack.tileY(tile), tileSize.toDouble(), tileSize.toDouble()), dst);

/// Значок предмета: объёмный блок, плоская иконка предмета из файла игры или (без текстур) цвет и название.
void paintItem(Canvas canvas, Rect dst, ItemStack item, TexturePack? pack, {bool count = true, int? shownCount}) {
  if (item.isEmpty) return;
  var drawn = false;
  if (pack != null) {
    final itemTile = item.id >= 256 ? pack.itemTile(item.id, item.meta) : -1;
    if (itemTile >= 0) {
      _paintTile(canvas, dst, pack, itemTile);
      drawn = true;
    } else if (item.id < 256) {
      final shape = blockTable[item.id].shape;
      if (shape == BlockShape.cube || shape == BlockShape.liquid) {
        _paintCube(canvas, dst, pack, item.id, item.meta);
        drawn = true;
      } else {
        final tile = pack.tile(item.id, item.meta, shape == BlockShape.cross ? 0 : 4);
        if (tile > 0) {
          _paintTile(canvas, dst, pack, tile);
          drawn = true;
        }
      }
    }
  }
  if (!drawn) {
    if (item.id < 256) {
      canvas.drawRect(dst.deflate(dst.width * 0.1), Paint()..color = Color(blockColor(item.id, item.meta) | 0xFF000000));
    } else {
      final name = itemTitle(item.id, item.meta);
      final tp = TextPainter(
        text: TextSpan(text: name.length > 4 ? name.substring(0, 4) : name, style: mcTextStyle(dst.height * 0.3)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: dst.width);
      tp.paint(canvas, dst.center - Offset(tp.width / 2, tp.height / 2));
    }
  }
  // Износ инструмента — полоска под значком, от зелёного к красному.
  final durability = maxDurabilityOf(item.id);
  if (durability > 0 && item.meta > 0) {
    final left = (1 - item.meta / durability).clamp(0.0, 1.0);
    final bar = Rect.fromLTWH(dst.left + dst.width * 0.12, dst.bottom - dst.height * 0.16, dst.width * 0.8, dst.height * 0.1);
    canvas.drawRect(bar, Paint()..color = Colors.black);
    canvas.drawRect(Rect.fromLTWH(bar.left, bar.top, bar.width * left, bar.height / 2),
        Paint()..color = HSVColor.fromAHSV(1, 120 * left, 1, 1).toColor());
  }
  final n = shownCount ?? item.count;
  if (count && n > 1) {
    final tp = TextPainter(
      text: TextSpan(text: '$n', style: mcTextStyle(dst.height * 0.45)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, dst.bottomRight - Offset(tp.width - dst.width * 0.05, tp.height - dst.height * 0.1));
  }
}
