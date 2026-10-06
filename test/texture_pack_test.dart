import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mcpe_client/textures/texture_pack.dart';

List<int> solid(int r, int g, int b, {int w = 16, int h = 16, int a = 255}) =>
    img.encodePng(img.Image(width: w, height: h, numChannels: 4)..clear(img.ColorRgba8(r, g, b, a)));

/// Минимальный FSB5 (FADPCM, моно, 44100 Гц) с одним кадром тишины на 256 отсчётов.
List<int> silentFsb() {
  const header = 0x3c, frame = 0x8c;
  final b = ByteData(header + 8 + frame);
  for (var i = 0; i < 4; i++) {
    b.setUint8(i, 'FSB5'.codeUnitAt(i));
  }
  b
    ..setUint32(0x04, 1, Endian.little)
    ..setUint32(0x08, 1, Endian.little)
    ..setUint32(0x0c, 8, Endian.little)
    ..setUint32(0x14, frame, Endian.little)
    ..setUint32(0x18, 16, Endian.little)
    ..setUint64(header, (256 << 34) | (8 << 1), Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  testWidgets('Импорт ресурс-пака: разметка граней, варианты по мете, carried-текстуры', (tester) async {
    const root = 'app/assets/resource_packs/vanilla/';
    final archive = Archive();
    void add(String name, List<int> data) => archive.addFile(ArchiveFile(name, data.length, data));
    add('${root}blocks.json', utf8.encode('''{
      // комментарий, как в файлах игры
      "stone": { "textures": "stone", "sound": "stone" },
      "grass": {
        "textures": { "up": "grass_top", "down": "grass_bottom", "side": "grass_side" },
        "carried_textures": { "up": "grass_carried_top", "down": "grass_bottom", "side": "grass_carried" }
      },
      "wool": { "textures": "wool" },
      "water": { "textures": { "up": "still_water", "down": "still_water", "side": "still_water" } }
    }'''));
    add('${root}textures/terrain_texture.json', utf8.encode('''{
      "texture_data": {
        "stone": { "textures": "textures/blocks/stone" },
        "grass_carried_top": { "textures": "textures/blocks/grass_carried" },
        "grass_bottom": { "textures": ["textures/blocks/dirt"] },
        "grass_carried": { "textures": { "path": "textures/blocks/grass_side", "overlay_color": "#79c05a" } },
        "wool": { "textures": ["textures/blocks/wool_white", "textures/blocks/wool_orange"] },
        "still_water": { "textures": "textures/blocks/water_still" }
      }
    }'''));
    add('${root}textures/blocks/stone.png', solid(128, 128, 128));
    add('${root}textures/blocks/grass_carried.png', solid(0, 200, 0));
    add('${root}textures/blocks/dirt.png', solid(120, 80, 40));
    add('${root}textures/blocks/grass_side_carried.png', solid(90, 140, 60));
    add('${root}textures/blocks/grass_side.png', solid(200, 200, 200, a: 0));
    add('${root}textures/blocks/wool_white.png', solid(250, 250, 250));
    add('${root}textures/blocks/wool_orange.png', solid(240, 120, 20));
    add('${root}textures/blocks/water_still.png', solid(40, 80, 250, h: 64));

    add('${root}textures/environment/destroy_stage_0.png', solid(60, 60, 60));
    add('${root}textures/environment/destroy_stage_1.png', solid(70, 70, 70));
    add('${root}sounds/dig/stone1.fsb', silentFsb());

    final dir = Directory.systemTemp.createTempSync('pack');
    addTearDown(() => dir.deleteSync(recursive: true));
    final zip = File('${dir.path}/game.zip')..writeAsBytesSync(ZipEncoder().encode(archive));

    final pack = await tester.runAsync(() async {
      await importTexturePack(zip.path, '${dir.path}/out');
      return TexturePack.load('${dir.path}/out');
    });
    expect(pack, isNotNull);
    final p = pack!;

    // Грани: 0 −X, 1 +X, 2 низ, 3 верх, 4 −Z, 5 +Z.
    final grassTop = p.tile(2, 0, 3), grassSide = p.tile(2, 0, 0), grassBottom = p.tile(2, 0, 2);
    expect({grassTop, grassSide, grassBottom}.length, 3);
    expect(p.tile(2, 0, 5), grassSide);
    expect(p.tile(35, 0, 0), isNot(p.tile(35, 1, 0)));
    expect(p.tile(1, 0, 3), p.tile(1, 0, 0));

    final bytes = File('${dir.path}/out/atlas.png').readAsBytesSync();
    final atlas = img.decodePng(bytes)!;
    img.Pixel px(int tile) => atlas.getPixel(p.tileX(tile).toInt() + 8, p.tileY(tile).toInt() + 8);
    expect(px(grassTop).g, 200);
    expect(px(grassSide).r, 90); // взята уже окрашенная *_carried текстура
    expect(px(p.tile(35, 1, 0)).r, 240);
    final water = px(p.tile(9, 0, 3));
    expect(water.b, 250);
    expect(water.a, lessThan(255)); // вода полупрозрачная

    // Трещины, материал блока и звук, перекодированный в WAV.
    expect(p.destroyTiles, hasLength(2));
    expect(px(p.destroyTiles[1]).r, 70);
    expect(p.blockSounds[1], 'stone');
    expect(p.sounds, {'dig_stone1'});
    final wav = ByteData.sublistView(File(p.soundPath('dig_stone1')).readAsBytesSync());
    expect(wav.getUint32(24, Endian.little), 44100);
    expect(wav.getUint32(40, Endian.little), 256 * 2);
  });
}
