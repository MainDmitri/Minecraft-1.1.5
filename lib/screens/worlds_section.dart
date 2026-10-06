import 'package:flutter/material.dart';

import '../server/local_server.dart';
import '../server/worlds.dart';

/// Список локальных миров с созданием, удалением и запуском.
class WorldsSection extends StatefulWidget {
  const WorldsSection({super.key, required this.onPlay});

  /// Запуск мира; [lan] — открыть для игроков в сети.
  final Future<void> Function(LocalWorldEntry world, bool lan) onPlay;

  @override
  State<WorldsSection> createState() => _WorldsSectionState();
}

class _WorldsSectionState extends State<WorldsSection> {
  final WorldsRepository _repo = WorldsRepository();
  late Future<List<LocalWorldEntry>> _worlds = _repo.list();

  void _reload() => setState(() => _worlds = _repo.list());

  Future<void> _create() async {
    final result = await showDialog<(String, String, int)>(context: context, builder: (_) => const _CreateWorldDialog());
    if (result == null) return;
    await _repo.create(name: result.$1, seed: seedFromText(result.$2), gamemode: result.$3);
    _reload();
  }

  Future<void> _delete(LocalWorldEntry w) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить мир?'),
        content: Text('«${w.meta.name}» будет удалён без возможности восстановления.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.delete(w);
    _reload();
  }

  Future<void> _play(LocalWorldEntry w) async {
    final lan = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('Играть одному'),
              subtitle: const Text('Мир доступен только на этом устройстве'),
              onTap: () => Navigator.of(ctx).pop(false),
            ),
            ListTile(
              leading: const Icon(Icons.wifi),
              title: const Text('Играть и открыть по сети'),
              subtitle: const Text('Друзья в той же Wi-Fi сети заходят по IP телефона, порт 19132'),
              onTap: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      ),
    );
    if (lan == null) return;
    await widget.onPlay(w, lan);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Локальные миры', style: theme.textTheme.titleMedium)),
            TextButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: const Text('Создать')),
          ],
        ),
        FutureBuilder<List<LocalWorldEntry>>(
          future: _worlds,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator());
            }
            if (snap.hasError) {
              return Text('Не удалось прочитать миры: ${snap.error}', style: TextStyle(color: theme.colorScheme.error));
            }
            final worlds = snap.data!;
            if (worlds.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Создайте мир, чтобы играть одному или вместе с друзьями по Wi-Fi.'),
              );
            }
            return Column(
              children: [
                for (final w in worlds)
                  Card(
                    child: ListTile(
                      leading: Icon(w.meta.gamemode == 1 ? Icons.brush : Icons.forest),
                      title: Text(w.meta.name),
                      subtitle: Text('${w.meta.gamemode == 1 ? 'Творчество' : 'Выживание'} · зерно ${w.meta.seed}'),
                      onTap: () => _play(w),
                      trailing: IconButton(
                        onPressed: () => _delete(w),
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Удалить',
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _CreateWorldDialog extends StatefulWidget {
  const _CreateWorldDialog();

  @override
  State<_CreateWorldDialog> createState() => _CreateWorldDialogState();
}

class _CreateWorldDialogState extends State<_CreateWorldDialog> {
  final _name = TextEditingController(text: 'Мой мир');
  final _seed = TextEditingController();
  int _gamemode = 1;

  @override
  void dispose() {
    _name.dispose();
    _seed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Новый мир'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Название'), maxLength: 32),
          TextField(
            controller: _seed,
            decoration: const InputDecoration(labelText: 'Зерно (необязательно)', helperText: 'Число или текст; пусто — случайное'),
          ),
          const SizedBox(height: 12),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('Творчество'), icon: Icon(Icons.brush)),
              ButtonSegment(value: 0, label: Text('Выживание'), icon: Icon(Icons.forest)),
            ],
            selected: {_gamemode},
            onSelectionChanged: (v) => setState(() => _gamemode = v.first),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop((name, _seed.text, _gamemode));
          },
          child: const Text('Создать'),
        ),
      ],
    );
  }
}
