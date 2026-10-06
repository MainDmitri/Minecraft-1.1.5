import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../audio/sound_manager.dart';
import '../textures/texture_pack.dart';

/// Текстуры, импортированные пользователем из своего файла Minecraft PE 1.1.
class TextureStore extends ChangeNotifier {
  TexturePack? pack;

  /// Звуки из того же файла игры (null, если их нет).
  SoundManager? sounds;
  bool busy = false;
  String? error;

  Future<String> _dir() async => '${(await getApplicationDocumentsDirectory()).path}/texture_pack';

  void _setPack(TexturePack? value) {
    sounds?.dispose();
    pack = value;
    sounds = value != null && value.sounds.isNotEmpty ? SoundManager(value) : null;
  }

  Future<void> load() async {
    try {
      _setPack(await TexturePack.load(await _dir()));
    } on Exception catch (e) {
      error = 'Не удалось загрузить текстуры: $e';
    }
    notifyListeners();
  }

  /// Импорт из APK или zip-архива с ресурсами игры.
  Future<void> importFrom(String path) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final dir = await _dir();
      await importTexturePack(path, dir);
      _setPack(await TexturePack.load(dir));
    } on FormatException catch (e) {
      error = e.message;
    } on FileSystemException catch (e) {
      error = 'Ошибка чтения файла: ${e.message}';
    } on Exception catch (e) {
      error = 'Не удалось импортировать текстуры: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    sounds?.dispose();
    super.dispose();
  }

  Future<void> remove() async {
    final dir = Directory(await _dir());
    if (dir.existsSync()) await dir.delete(recursive: true);
    _setPack(null);
    notifyListeners();
  }
}
