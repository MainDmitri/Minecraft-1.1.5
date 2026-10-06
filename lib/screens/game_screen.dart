import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../game/mcpe_client.dart';
import '../protocol/packets.dart';
import '../state/session_controller.dart';
import '../state/settings_store.dart';
import '../widgets/mc_text.dart';
import '../widgets/world_view.dart';

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  Timer? _overlayTimer;
  bool _showChat = false;

  @override
  void initState() {
    super.initState();
    // Заголовки и подсказки исчезают по времени — перерисовка раз в полсекунды.
    _overlayTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final c = context.read<SessionController>().client;
      if (c != null && [c.title, c.subtitle, c.actionBar, c.popup, c.tip].any((m) => m != null)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send(McpeClient c) {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    c.sendMessage(text);
    _input.clear();
    _focus.requestFocus();
  }

  static String _gamemodeName(int g) => switch (g) {
        0 => 'Выживание',
        1 => 'Творчество',
        2 => 'Приключение',
        3 => 'Наблюдатель',
        _ => 'Режим $g',
      };

  static String _timeOfDay(int ticks) {
    final t = ticks % 24000;
    final hours = (t ~/ 1000 + 6) % 24;
    final minutes = (t % 1000) * 60 ~/ 1000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
  }

  static String _phaseText(ConnectionPhase p) => switch (p) {
        ConnectionPhase.idle => 'Ожидание',
        ConnectionPhase.connecting => 'Подключение…',
        ConnectionPhase.loggingIn => 'Вход…',
        ConnectionPhase.spawning => 'Загрузка мира…',
        ConnectionPhase.playing => 'В игре',
        ConnectionPhase.disconnected => 'Отключено',
      };

  void _showPlayers(McpeClient c) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        final me = c.position;
        final list = c.players.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        return ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.person),
              title: Text('${c.nickname} (вы)'),
              subtitle: me == null ? null : Text('Координаты: $me'),
            ),
            for (final p in list.where((p) => p.name != c.nickname))
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: McText(p.name),
                subtitle: Text(_playerPosition(me, c, p)),
              ),
            if (list.where((p) => p.name != c.nickname).isEmpty)
              const ListTile(title: Text('Сервер не сообщил о других игроках')),
          ],
        );
      },
    );
  }

  static String _playerPosition(Vec3? me, McpeClient c, OnlinePlayer p) {
    Vec3? pos;
    for (final r in c.remotePlayers.values) {
      if (r.uniqueId == p.uniqueId || r.name == p.name) pos = r.position;
    }
    if (pos == null) return 'Далеко (вне зоны видимости)';
    if (me == null) return 'Координаты: $pos';
    final dx = pos.x - me.x, dy = pos.y - me.y, dz = pos.z - me.z;
    final dist = sqrt(dx * dx + dy * dy + dz * dz);
    return 'Координаты: $pos · ${dist.toStringAsFixed(0)} бл.';
  }

  void _showServerInfo(SessionController session) {
    final port = session.server?.port ?? 0;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          children: [
            Text('Сервер мира запущен на этом телефоне', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (!session.serverLan)
              const Text('Мир открыт только для вас. Чтобы друзья могли зайти, выйдите и запустите мир '
                  'кнопкой «Играть и открыть по сети».')
            else ...[
              const Text('Друзья в той же Wi-Fi сети: «Добавить сервер» → адрес и порт ниже '
                  '(в MCPE 1.1.5 — вкладка «Друзья» или «Серверы»).'),
              const SizedBox(height: 8),
              if (session.lanAddresses.isEmpty)
                const Text('Телефон не подключён к сети (нет IPv4-адреса Wi-Fi).')
              else
                for (final ip in session.lanAddresses)
                  ListTile(
                    leading: const Icon(Icons.wifi),
                    title: SelectableText('$ip:$port'),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: 'Копировать',
                      onPressed: () => Clipboard.setData(ClipboardData(text: '$ip:$port')),
                    ),
                  ),
              if (port != 19132)
                Text('Порт 19132 был занят, выбран порт $port — сообщите его друзьям.',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ],
            const Divider(height: 24),
            Text('Журнал', style: Theme.of(ctx).textTheme.titleSmall),
            if (session.serverLog.isEmpty) const Text('Пока пусто'),
            for (final line in session.serverLog.reversed) Text(line),
          ],
        ),
      ),
    );
  }

  void _showCommands(McpeClient c) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final commands = c.commands.all;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          builder: (_, scroll) => commands.isEmpty
              ? const Center(child: Text('Сервер не прислал список команд'))
              : ListView.builder(
                  controller: scroll,
                  itemCount: commands.length,
                  itemBuilder: (_, i) {
                    final cmd = commands[i];
                    return ListTile(
                      title: Text('/${cmd.name}'),
                      subtitle: Text([
                        if (cmd.description.isNotEmpty) stripFormatting(cmd.description),
                        ...cmd.usages,
                      ].join('\n')),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _input.text = '/${cmd.name} ';
                        _input.selection = TextSelection.collapsed(offset: _input.text.length);
                        _focus.requestFocus();
                      },
                    );
                  },
                ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final c = session.client;
    if (c == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);
    final playing = c.phase == ConnectionPhase.playing;
    final disconnected = c.phase == ConnectionPhase.disconnected;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            McText(c.startGame?.worldName.isNotEmpty == true ? c.startGame!.worldName : session.address, maxLines: 1),
            Text(_phaseText(c.phase), style: theme.textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () => _showPlayers(c),
            icon: Badge(
              label: Text('${c.players.values.where((p) => p.name != c.nickname).length + 1}'),
              child: const Icon(Icons.group),
            ),
            tooltip: 'Игроки',
          ),
          if (session.isHosting)
            IconButton(onPressed: () => _showServerInfo(session), icon: const Icon(Icons.dns), tooltip: 'Мой сервер'),
          IconButton(onPressed: () => _showCommands(c), icon: const Icon(Icons.terminal), tooltip: 'Команды'),
          IconButton(
            onPressed: () => setState(() => _showChat = !_showChat),
            icon: Icon(_showChat ? Icons.view_in_ar : Icons.forum),
            tooltip: _showChat ? 'Мир' : 'Весь чат',
          ),
          if (!disconnected)
            IconButton(onPressed: session.disconnect, icon: const Icon(Icons.logout), tooltip: 'Отключиться'),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_showChat && (playing || c.phase == ConnectionPhase.spawning)) _statusBar(c, theme),
            Expanded(
              child: Stack(
                children: [
                  if (_showChat || !playing)
                    _chat(c, theme)
                  else
                    WorldView(client: c, renderDistance: context.watch<SettingsStore>().renderDistance.toDouble()),
                  _overlays(c, theme),
                  if (c.dead && playing) _deathOverlay(c, theme),
                  if (disconnected) _disconnectedOverlay(session, c, theme),
                  if (!playing && !disconnected) _connectingOverlay(c, theme),
                ],
              ),
            ),
            if (_showChat || !playing) _inputBar(c, playing),
          ],
        ),
      ),
    );
  }

  Widget _statusBar(McpeClient c, ThemeData theme) {
    Widget chip(IconData icon, String text, {Color? color}) => Chip(
          avatar: Icon(icon, size: 18, color: color),
          label: Text(text),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          chip(Icons.favorite, '${c.health.toStringAsFixed(0)}/${c.maxHealth.toStringAsFixed(0)}', color: Colors.red),
          chip(Icons.restaurant, c.food.toStringAsFixed(0), color: Colors.brown),
          chip(Icons.star, 'Ур. ${c.xpLevel}', color: Colors.green),
          if (c.position != null) chip(Icons.place, c.position.toString()),
          chip(Icons.sports_esports, _gamemodeName(c.gamemode)),
          chip(Icons.schedule, _timeOfDay(c.worldTime)),
          chip(Icons.network_ping, '${c.latencyMs} мс'),
          if (c.encrypted) chip(Icons.lock, 'Шифрование'),
        ],
      ),
    );
  }

  Widget _chat(McpeClient c, ThemeData theme) {
    final lines = c.chat;
    return Container(
      color: const Color(0xFF1B1B1B),
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.all(8),
        itemCount: lines.length,
        itemBuilder: (_, i) {
          final line = lines[lines.length - 1 - i];
          final color = switch (line.kind) {
            ChatKind.chat => Colors.white,
            ChatKind.system => const Color(0xFFE0E0E0),
            ChatKind.local => const Color(0xFF9E9E9E),
            ChatKind.error => const Color(0xFFFF6E6E),
          };
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: McText(line.text, style: TextStyle(color: color, fontSize: 15)),
          );
        },
      ),
    );
  }

  Widget _overlays(McpeClient c, ThemeData theme) {
    String? text(ScreenMessage? m) => m != null && m.visible ? m.text : null;
    final title = text(c.title);
    final subtitle = text(c.subtitle);
    final bottom = [text(c.actionBar), text(c.popup), text(c.tip)].whereType<String>().toList();
    const shadow = [Shadow(blurRadius: 4, color: Colors.black)];
    return IgnorePointer(
      child: Column(
        children: [
          const SizedBox(height: 24),
          if (title != null)
            McText(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold, shadows: shadow)),
          if (subtitle != null)
            McText(subtitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, color: Colors.white, shadows: shadow)),
          const Spacer(),
          for (final b in bottom)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: McText(b, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Colors.white, shadows: shadow)),
            ),
        ],
      ),
    );
  }

  Widget _deathOverlay(McpeClient c, ThemeData theme) {
    return Container(
      color: const Color(0x99550000),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Вы погибли!', style: TextStyle(fontSize: 30, color: Colors.white, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: c.respawn, icon: const Icon(Icons.replay), label: const Text('Возродиться')),
        ],
      ),
    );
  }

  Widget _connectingOverlay(McpeClient c, ThemeData theme) {
    return Container(
      color: const Color(0xCC000000),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(_phaseText(c.phase), style: const TextStyle(color: Colors.white, fontSize: 18)),
        ],
      ),
    );
  }

  Widget _disconnectedOverlay(SessionController session, McpeClient c, ThemeData theme) {
    return Align(
      alignment: Alignment.topCenter,
      child: Card(
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Соединение закрыто', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              McText(session.error ?? c.disconnectReason ?? '', textAlign: TextAlign.center),
              if (session.versionHint != null) ...[
                const SizedBox(height: 8),
                Text(session.versionHint!, textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: session.reconnect,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Переподключиться'),
                  ),
                  OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('К серверам')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inputBar(McpeClient c, bool playing) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              enabled: playing,
              maxLength: 255,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(c),
              decoration: const InputDecoration(
                hintText: 'Сообщение или /команда',
                border: OutlineInputBorder(),
                counterText: '',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: playing ? () => _send(c) : null, icon: const Icon(Icons.send)),
        ],
      ),
    );
  }
}
