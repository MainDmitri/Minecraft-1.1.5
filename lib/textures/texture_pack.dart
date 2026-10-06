import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:image/image.dart' as img;

import '../game/items.dart';
import 'block_names.dart';
import 'fsb.dart';

/// Порядок граней в разметке: −X, +X, −Y, +Y, −Z, +Z (как в построителе сетки).
const List<String> _faceKeys = ['west', 'east', 'down', 'up', 'north', 'south'];

/// Блоки, для которых берутся «carried»-текстуры: они уже окрашены и не требуют цвета биома.
const Set<String> _carriedBlocks = {'grass', 'leaves', 'leaves2', 'tallgrass', 'double_plant', 'vine', 'waterlily'};

const int atlasColumns = 32;
const int tileSize = 16;

String _stripComments(String s) {
  final out = StringBuffer();
  var inString = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (inString) {
      out.write(c);
      if (c == '\\' && i + 1 < s.length) {
        out.write(s[++i]);
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
      out.write(c);
    } else if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
      out.write('\n');
    } else {
      out.write(c);
    }
  }
  return out.toString();
}

class _Importer {
  _Importer(this.files);

  /// Файлы ресурс-пака: путь относительно папки vanilla → содержимое.
  final Map<String, Uint8List> files;

  final List<img.Image> tiles = [];
  final Map<String, int> _tileByKey = {};

  late final Map<String, dynamic> terrain;
  late final Map<String, dynamic> blocks;

  dynamic _json(String name) => jsonDecode(_stripComments(utf8.decode(files[name]!, allowMalformed: true)));

  img.Image? _loadImage(String path) {
    for (final ext in const ['.png', '.tga']) {
      final data = files['$path$ext'];
      if (data == null) continue;
      final decoded = ext == '.png' ? img.decodePng(data) : img.decodeTga(data);
      if (decoded == null) continue;
      var im = decoded.convert(numChannels: 4);
      // Анимированные текстуры — вертикальная лента кадров; берём первый кадр.
      if (im.height > im.width) im = img.copyCrop(im, x: 0, y: 0, width: im.width, height: im.width);
      if (im.width != tileSize) {
        im = img.copyResize(im, width: tileSize, height: tileSize, interpolation: img.Interpolation.nearest);
      }
      return im;
    }
    return null;
  }

  int _addTile(String key, img.Image Function() make) =>
      _tileByKey.putIfAbsent(key, () {
        tiles.add(make());
        return tiles.length - 1;
      });

  /// Плитка для записи из terrain_texture.json (строка или объект с path/overlay_color).
  int? _tileForEntry(dynamic entry, {required bool water}) {
    String? path;
    String? overlay;
    if (entry is String) {
      path = entry;
    } else if (entry is Map) {
      path = entry['path'] as String?;
      overlay = entry['overlay_color'] as String?;
    }
    if (path == null) return null;
    if (overlay != null && files.containsKey('${path}_carried.png')) {
      path = '${path}_carried';
      overlay = null;
    }
    final key = '$path|$overlay|$water';
    if (_tileByKey.containsKey(key)) return _tileByKey[key];
    final base = _loadImage(path);
    if (base == null) return null;
    return _addTile(key, () {
      var im = base;
      if (overlay != null) {
        // Полупрозрачная маска окрашивается и кладётся поверх земли.
        final dirt = _loadImage('textures/blocks/dirt') ?? img.Image(width: tileSize, height: tileSize, numChannels: 4);
        final c = int.parse(overlay.substring(1), radix: 16);
        final tr = (c >> 16) & 0xff, tg = (c >> 8) & 0xff, tb = c & 0xff;
        final out = img.Image.from(dirt);
        for (final p in base) {
          if (p.a == 0) continue;
          out.setPixelRgba(p.x, p.y, p.r * tr ~/ 255, p.g * tg ~/ 255, p.b * tb ~/ 255, 255);
        }
        im = out;
      }
      if (water) {
        final out = img.Image.from(im);
        for (final p in out) {
          p.a = 190;
        }
        im = out;
      }
      return im;
    });
  }

  int _variant(String textureName, int meta) {
    if (textureName.startsWith('leaves') || textureName.startsWith('log')) return meta & 3;
    if (textureName == 'sapling') return meta & 7;
    return meta;
  }

  int? _tile(String textureName, int meta, {required bool water}) {
    final data = terrain[textureName];
    if (data is! Map) return null;
    final t = data['textures'];
    if (t is List) {
      if (t.isEmpty) return null;
      final i = _variant(textureName, meta);
      return _tileForEntry(t[i < t.length ? i : 0], water: water);
    }
    return _tileForEntry(t, water: water);
  }

  /// Плитки трещин ломания (destroy_stage_0..9), если они есть в файле.
  final List<int> destroyTiles = [];

  /// Категория звука блока из blocks.json ("stone", "grass", "wood" …).
  final Map<int, String> blockSounds = {};

  /// Иконки предметов: "id:мета" (или "id:*") → плитка атласа.
  final Map<String, int> itemTiles = {};

  void _buildItems() {
    const emptyArmor = ['helmet', 'chestplate', 'leggings', 'boots'];
    for (var i = 0; i < 4; i++) {
      final path = 'textures/items/empty_armor_slot_${emptyArmor[i]}';
      final im = _loadImage(path);
      if (im != null) itemTiles['empty:$i'] = _addTile(path, () => im);
    }
    itemTable.forEach((id, info) {
      info.icons.forEach((meta, file) {
        final path = 'textures/items/$file';
        final key = '$id:${meta < 0 ? '*' : meta}';
        final existing = _tileByKey[path];
        if (existing != null) {
          itemTiles[key] = existing;
          return;
        }
        var im = _loadImage(path);
        if (im == null) return;
        if (file.startsWith('leather_')) {
          // Кожаная броня в файлах игры серая: цвет по умолчанию накладывается при отрисовке.
          final out = img.Image.from(im);
          for (final px in out) {
            px
              ..r = px.r * 0xA0 ~/ 255
              ..g = px.g * 0x65 ~/ 255
              ..b = px.b * 0x40 ~/ 255;
          }
          im = out;
        }
        final tileImage = im;
        itemTiles[key] = _addTile(path, () => tileImage);
      });
    });
  }

  Int16List build() {
    terrain = (_json('textures/terrain_texture.json') as Map)['texture_data'] as Map<String, dynamic>;
    blocks = _json('blocks.json') as Map<String, dynamic>;
    tiles.add(img.Image(width: tileSize, height: tileSize, numChannels: 4)..clear(img.ColorRgba8(255, 255, 255, 255)));
    final faces = Int16List(256 * 16 * 6)..fillRange(0, 256 * 16 * 6, -1);
    for (var i = 0; i < 10; i++) {
      final path = 'textures/environment/destroy_stage_$i';
      final im = _loadImage(path);
      if (im == null) break;
      destroyTiles.add(_addTile(path, () => im));
    }
    _buildItems();
    blockNames.forEach((id, name) {
      final def = blocks[name];
      if (def is! Map) return;
      final sound = def['sound'];
      if (sound is String) blockSounds[id] = sound;
      final tex = (_carriedBlocks.contains(name) ? def['carried_textures'] : null) ?? def['textures'];
      if (tex == null) return;
      final water = id >= 8 && id <= 9;
      for (var meta = 0; meta < 16; meta++) {
        for (var f = 0; f < 6; f++) {
          String? name0;
          if (tex is String) {
            name0 = tex;
          } else if (tex is Map) {
            final key = _faceKeys[f];
            name0 = (tex[key] ?? ((f == 2 || f == 3) ? null : tex['side']) ?? tex['up'] ?? tex['side']) as String?;
          }
          if (name0 == null) continue;
          final tile = _tile(name0, meta, water: water);
          if (tile != null) faces[(id * 16 + meta) * 6 + f] = tile;
        }
      }
    });
    return faces;
  }

  img.Image atlas() {
    final rows = (tiles.length + atlasColumns - 1) ~/ atlasColumns;
    final out = img.Image(width: atlasColumns * tileSize, height: rows * tileSize, numChannels: 4);
    for (var i = 0; i < tiles.length; i++) {
      img.compositeImage(out, tiles[i],
          dstX: (i % atlasColumns) * tileSize, dstY: (i ~/ atlasColumns) * tileSize, blend: img.BlendMode.direct);
    }
    return out;
  }
}

const Set<String> _extraFiles = {
  'textures/gui/gui.png',
  'textures/gui/icons.png',
  'textures/entity/steve.png',
  'sounds/random/click.fsb',
  'sounds/random/hurt.fsb',
  'sounds/random/pop.fsb',
  'sounds/random/glass1.fsb',
  'sounds/random/glass2.fsb',
  'sounds/random/glass3.fsb',
};

/// Импорт текстур из APK Minecraft PE 1.1 или архива с его распакованными файлами.
/// Выполняется в отдельном изоляте; результат сохраняется в [outDir]. Возвращает число текстур.
Future<int> importTexturePack(String sourcePath, String outDir) => Isolate.run(() {
      final input = InputFileStream(sourcePath);
      try {
        final archive = ZipDecoder().decodeStream(input);
        const marker = 'resource_packs/vanilla/';
        String? prefix;
        for (final f in archive.files) {
          if (f.name.endsWith('${marker}blocks.json')) {
            prefix = f.name.substring(0, f.name.length - 'blocks.json'.length);
            break;
          }
        }
        if (prefix == null) {
          throw const FormatException('В файле нет ресурсов Minecraft (resource_packs/vanilla/blocks.json)');
        }
        final files = <String, Uint8List>{};
        for (final f in archive.files) {
          if (!f.isFile || !f.name.startsWith(prefix)) continue;
          final rel = f.name.substring(prefix.length);
          if (rel == 'blocks.json' ||
              rel == 'textures/terrain_texture.json' ||
              rel.startsWith('textures/blocks/') ||
              rel.startsWith('textures/environment/') ||
              rel.startsWith('textures/items/') ||
              rel.startsWith('sounds/dig/') ||
              rel.startsWith('sounds/step/') ||
              _extraFiles.contains(rel)) {
            files[rel] = f.readBytes()!;
          }
        }
        if (!files.containsKey('textures/terrain_texture.json')) {
          throw const FormatException('В файле нет textures/terrain_texture.json');
        }
        final importer = _Importer(files);
        final faces = importer.build();
        final dir = Directory(outDir)..createSync(recursive: true);
        File('${dir.path}/atlas.png').writeAsBytesSync(img.encodePng(importer.atlas()));
        File('${dir.path}/faces.bin').writeAsBytesSync(faces.buffer.asUint8List());
        void copy(String rel, String name) {
          final data = files[rel];
          final target = File('${dir.path}/$name');
          if (data != null) {
            target.writeAsBytesSync(data);
          } else if (target.existsSync()) {
            target.deleteSync();
          }
        }

        copy('textures/gui/gui.png', 'gui.png');
        copy('textures/gui/icons.png', 'icons.png');
        copy('textures/environment/sun.png', 'sun.png');
        copy('textures/environment/moon_phases.png', 'moon.png');
        copy('textures/entity/steve.png', 'steve.png');

        // Звуки: FSB5 (FADPCM) → WAV.
        final soundsDir = Directory('${dir.path}/sounds');
        if (soundsDir.existsSync()) soundsDir.deleteSync(recursive: true);
        soundsDir.createSync();
        final soundFiles = <String>[];
        for (final e in files.entries) {
          if (!e.key.startsWith('sounds/') || !e.key.endsWith('.fsb')) continue;
          final name = e.key.substring('sounds/'.length, e.key.length - 4).replaceAll('/', '_');
          try {
            File('${soundsDir.path}/$name.wav').writeAsBytesSync(decodeFsb5(e.value).toWav());
            soundFiles.add(name);
          } on FormatException {
            // Звук в другом кодеке — пропускаем.
          }
        }
        File('${dir.path}/pack.json').writeAsStringSync(jsonEncode({
          'destroy': importer.destroyTiles,
          'blockSounds': importer.blockSounds.map((k, v) => MapEntry('$k', v)),
          'items': importer.itemTiles,
          'sounds': soundFiles,
        }));
        return importer.tiles.length;
      } finally {
        input.closeSync();
      }
    });

/// Загруженный набор текстур: атлас блоков, спрайты интерфейса, небо, скин и звуки.
class TexturePack {
  TexturePack._(this.dir, this.atlas, this.faces, this.gui, this.icons, this.sun, this.moon, this.steveSkinPng,
      this.destroyTiles, this.blockSounds, this.sounds, this._itemTiles);

  final String dir;
  final ui.Image atlas;

  /// Плитка атласа для (ID, мета, грань) или −1.
  final Int16List faces;
  final ui.Image? gui;
  final ui.Image? icons;
  final ui.Image? sun;

  /// Фазы луны: 4×2 кадра.
  final ui.Image? moon;
  final Uint8List? steveSkinPng;
  final List<int> destroyTiles;
  final Map<int, String> blockSounds;

  /// Имена звуков (например, "dig_stone1"), сохранённых как WAV в папке sounds.
  final Set<String> sounds;

  String soundPath(String name) => '$dir/sounds/$name.wav';

  final Map<String, int> _itemTiles;

  /// Плитка пустого слота брони (0 шлем … 3 ботинки) или −1.
  int emptyArmorTile(int slot) => _itemTiles['empty:$slot'] ?? -1;

  /// Плитка иконки предмета (ID ≥ 256) или −1.
  int itemTile(int id, int meta) => _itemTiles['$id:$meta'] ?? _itemTiles['$id:*'] ?? _itemTiles['$id:0'] ?? -1;

  int tile(int id, int meta, int face) {
    final t = faces[((id & 255) * 16 + (meta & 15)) * 6 + face];
    if (t >= 0 || meta == 0) return t;
    return faces[(id & 255) * 16 * 6 + face];
  }

  /// Левый верхний угол плитки в пикселях атласа.
  double tileX(int tile) => (tile % atlasColumns) * tileSize.toDouble();
  double tileY(int tile) => (tile ~/ atlasColumns) * tileSize.toDouble();

  static Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  static Future<TexturePack?> load(String dir) async {
    final atlasFile = File('$dir/atlas.png');
    final facesFile = File('$dir/faces.bin');
    if (!atlasFile.existsSync() || !facesFile.existsSync()) return null;
    final atlas = await _decode(await atlasFile.readAsBytes());
    final faces = Int16List.view((await facesFile.readAsBytes()).buffer);
    Future<ui.Image?> image(String name) async {
      final f = File('$dir/$name');
      return f.existsSync() ? _decode(await f.readAsBytes()) : null;
    }

    final steve = File('$dir/steve.png');
    final meta = File('$dir/pack.json');
    final info = meta.existsSync() ? jsonDecode(await meta.readAsString()) as Map<String, dynamic> : const <String, dynamic>{};
    return TexturePack._(
      dir,
      atlas,
      faces,
      await image('gui.png'),
      await image('icons.png'),
      await image('sun.png'),
      await image('moon.png'),
      steve.existsSync() ? await steve.readAsBytes() : null,
      [for (final t in (info['destroy'] as List? ?? const [])) t as int],
      {
        for (final e in ((info['blockSounds'] as Map?) ?? const {}).entries) int.parse(e.key as String): e.value as String,
      },
      {for (final n in (info['sounds'] as List? ?? const [])) n as String},
      {for (final e in ((info['items'] as Map?) ?? const {}).entries) e.key as String: e.value as int},
    );
  }
}
