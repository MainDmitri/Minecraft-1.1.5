import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'generator.dart';
import 'world_storage.dart';

class LocalWorldEntry {
  LocalWorldEntry(this.storage, this.meta);

  final WorldStorage storage;
  final WorldMeta meta;

  String get id => storage.dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
}

/// Локальные миры в папке приложения: `документы/worlds/<id>/`.
class WorldsRepository {
  Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/worlds');
    await dir.create(recursive: true);
    return dir;
  }

  Future<List<LocalWorldEntry>> list() async {
    final root = await _root();
    final result = <LocalWorldEntry>[];
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final storage = WorldStorage(e);
      try {
        result.add(LocalWorldEntry(storage, storage.readMeta()));
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }
    result.sort((a, b) => a.meta.name.toLowerCase().compareTo(b.meta.name.toLowerCase()));
    return result;
  }

  Future<LocalWorldEntry> create({required String name, required int seed, required int gamemode}) async {
    final root = await _root();
    final dir = Directory('${root.path}/${DateTime.now().millisecondsSinceEpoch}');
    final storage = WorldStorage(dir);
    final (sx, sy, sz) = TerrainGenerator(seed).findSpawn();
    final meta = WorldMeta(name: name, seed: seed, gamemode: gamemode, spawnX: sx, spawnY: sy, spawnZ: sz, time: 1000);
    storage.writeMeta(meta);
    return LocalWorldEntry(storage, meta);
  }

  Future<void> delete(LocalWorldEntry world) => world.storage.dir.delete(recursive: true);
}
