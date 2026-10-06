import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../game/mcpe_client.dart';
import '../textures/texture_pack.dart';

/// Проигрывание звуков игры, импортированных из файла Minecraft PE (WAV в папке набора текстур).
class SoundManager {
  SoundManager(this.pack) {
    final digits = RegExp(r'\d+$');
    for (final name in pack.sounds) {
      _groups.putIfAbsent(name.replaceFirst(digits, ''), () => []).add(name);
    }
  }

  final TexturePack pack;

  /// Группы вариантов: "dig_stone" → [dig_stone1, dig_stone2, …].
  final Map<String, List<String>> _groups = {};
  final List<AudioPlayer> _players = [];
  final List<Future<void>> _ready = [];
  final math.Random _random = math.Random();
  int _next = 0;
  bool _disposed = false;

  static const int _poolSize = 8;

  /// Материалы без собственных звуков ломания или шагов звучат как похожие.
  static const Map<String, String> _fallback = {
    'ladder': 'wood',
    'itemframe': 'wood',
    'glass': 'stone',
    'metal': 'stone',
    'anvil': 'stone',
    'slime': 'stone',
  };

  int _player() {
    if (_players.length < _poolSize) {
      final player = AudioPlayer();
      // Звуки накладываются друг на друга и не забирают аудиофокус у других приложений.
      _ready.add(_configure(player));
      _players.add(player);
      return _players.length - 1;
    }
    return _next++ % _poolSize;
  }

  Future<void> _configure(AudioPlayer player) async {
    try {
      await player.setPlayerMode(PlayerMode.lowLatency);
      await player.setReleaseMode(ReleaseMode.stop);
      await player.setAudioContext(AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build());
    } on Exception catch (e) {
      debugPrint('Звук: не удалось настроить проигрыватель: $e');
    }
  }

  /// Случайный вариант звука [group] (например, "dig_stone").
  void play(String group, {double volume = 1}) {
    final names = _groups[group];
    if (_disposed || names == null || names.isEmpty || volume <= 0) return;
    final name = names[_random.nextInt(names.length)];
    unawaited(_start(_player(), name, volume.clamp(0.0, 1.0)));
  }

  Future<void> _start(int index, String name, double volume) async {
    final player = _players[index];
    try {
      await _ready[index];
      if (_disposed) return;
      await player.stop();
      await player.play(DeviceFileSource(pack.soundPath(name)), volume: volume);
    } on Exception catch (e) {
      debugPrint('Звук $name не проигран: $e');
    }
  }

  String _material(int blockId) => pack.blockSounds[blockId] ?? 'stone';

  String _resolve(String prefix, String material) {
    if (_groups.containsKey('$prefix$material')) return '$prefix$material';
    return '$prefix${_fallback[material] ?? 'stone'}';
  }

  void click() => play('random_click', volume: 0.6);

  void handle(GameSound sound) {
    final material = _material(sound.blockId);
    switch (sound.kind) {
      case SoundKind.breakBlock:
        play(material == 'glass' ? 'random_glass' : _resolve('dig_', material), volume: sound.volume);
      case SoundKind.placeBlock:
        play(_resolve('dig_', material), volume: sound.volume);
      case SoundKind.step:
      case SoundKind.hit:
        play(_resolve('step_', material), volume: sound.volume);
      case SoundKind.hurt:
        play('random_hurt', volume: sound.volume);
      case SoundKind.pickup:
        play('random_pop', volume: sound.volume);
    }
  }

  void dispose() {
    _disposed = true;
    for (final p in _players) {
      unawaited(p.dispose());
    }
    _players.clear();
    _ready.clear();
  }
}
