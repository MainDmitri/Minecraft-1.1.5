import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../game/mcpe_client.dart';
import '../protocol/packets.dart';
import '../state/session_controller.dart';
import '../state/settings_store.dart';
import '../state/texture_store.dart';
import '../textures/texture_pack.dart';
import '../widgets/mc_text.dart';
import '../widgets/mc_ui.dart';
import '../widgets/world_view.dart';

/// Игровой экран: полноэкранный режим в альбомной ориентации, как в MCPE.
class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  final GlobalKey<WorldViewState> _worldKey = GlobalKey();
  Timer? _overlayTimer;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
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
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  static String _phaseText(ConnectionPhase p) => switch (p) {
        ConnectionPhase.idle => 'Ожидание',
        ConnectionPhase.connecting => 'Подключение к серверу…',
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
        initialChildSize: 0.8,
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
              const Text('Друзья в той же Wi-Fi сети: «Добавить сервер» → адрес и порт ниже.'),
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
          initialChildSize: 0.8,
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
                        setState(() => _paused = false);
                        _worldKey.currentState?.openChat('/${cmd.name} ');
                      },
                    );
                  },
                ),
        );
      },
    );
  }

  void _leave(SessionController session) {
    session.disconnect();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final pack = context.watch<TextureStore>().pack;
    final settings = context.watch<SettingsStore>();
    final c = session.client;
    final playing = c != null && c.phase == ConnectionPhase.playing;
    final disconnected = c != null && c.phase == ConnectionPhase.disconnected;

    return PopScope(
      canPop: !playing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _paused = !_paused);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: true,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (playing)
              WorldView(
                key: _worldKey,
                client: c,
                renderDistance: settings.renderDistance.toDouble(),
                pack: pack,
                sounds: context.watch<TextureStore>().sounds,
                onPause: () => setState(() => _paused = true),
              ),
            if (c != null && playing) _overlays(c),
            if (c != null && playing && c.dead) _deathScreen(c, pack),
            if (c != null && playing && _paused && !c.dead) _pauseMenu(session, c, pack, settings),
            if (c == null || (!playing && !disconnected)) _loadingScreen(c, pack),
            if (disconnected) _disconnectedScreen(session, c, pack),
          ],
        ),
      ),
    );
  }

  Widget _overlays(McpeClient c) {
    String? text(ScreenMessage? m) => m != null && m.visible ? m.text : null;
    final title = text(c.title);
    final subtitle = text(c.subtitle);
    final bottom = [text(c.actionBar), text(c.popup), text(c.tip)].whereType<String>().toList();
    return IgnorePointer(
      child: Column(
        children: [
          const SizedBox(height: 48),
          if (title != null) McText(title, textAlign: TextAlign.center, style: mcTextStyle(40)),
          if (subtitle != null) McText(subtitle, textAlign: TextAlign.center, style: mcTextStyle(20)),
          const Spacer(),
          for (final b in bottom)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: McText(b, textAlign: TextAlign.center, style: mcTextStyle(16)),
            ),
          const SizedBox(height: 90),
        ],
      ),
    );
  }

  Widget _menuColumn(List<Widget> children) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final w in children) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: w),
            ],
          ),
        ),
      );

  Widget _pauseMenu(SessionController session, McpeClient c, TexturePack? pack, SettingsStore settings) {
    final distances = SettingsStore.renderDistances;
    final next = distances[(distances.indexOf(settings.renderDistance) + 1) % distances.length];
    final pos = c.position;
    const w = 200.0;
    Widget row(List<Widget> items) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              items[i],
            ],
          ],
        );
    return Container(
      color: const Color(0xAA000000),
      child: Stack(
        children: [
          _menuColumn([
            Text('Меню игры', style: mcTextStyle(20)),
            McButton(label: 'Вернуться в игру', width: 2 * w + 8, pack: pack, onTap: () => setState(() => _paused = false)),
            row([
              McButton(
                label: 'Чат',
                width: w,
                pack: pack,
                onTap: () {
                  setState(() => _paused = false);
                  _worldKey.currentState?.openChat();
                },
              ),
              McButton(label: 'Игроки', width: w, pack: pack, onTap: () => _showPlayers(c)),
            ]),
            row([
              McButton(label: 'Команды', width: w, pack: pack, onTap: () => _showCommands(c)),
              McButton(
                label: 'Прорисовка: ${settings.renderDistance}',
                width: w,
                pack: pack,
                onTap: () => settings.setRenderDistance(next),
              ),
            ]),
            if (session.isHosting)
              McButton(label: 'Мой сервер: вход по IP', width: 2 * w + 8, pack: pack, onTap: () => _showServerInfo(session)),
            McButton(
              label: session.isHosting ? 'Сохранить и выйти' : 'Отключиться',
              width: 2 * w + 8,
              pack: pack,
              onTap: () => _leave(session),
            ),
          ]),
          Positioned(
            left: 12,
            bottom: 8,
            child: Text(
              [
                if (pos != null) 'XYZ: ${pos.x.toStringAsFixed(1)} / ${pos.y.toStringAsFixed(1)} / ${pos.z.toStringAsFixed(1)}',
                'Пинг: ${c.latencyMs} мс',
                if (c.encrypted) 'Шифрование',
              ].join('   '),
              style: mcTextStyle(12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _deathScreen(McpeClient c, TexturePack? pack) => Container(
        color: const Color(0x99880000),
        child: _menuColumn([
          Text('Вы погибли!', style: mcTextStyle(36)),
          const SizedBox(height: 16),
          McButton(label: 'Возродиться', pack: pack, onTap: c.respawn),
          McButton(label: 'Главное меню', pack: pack, onTap: () => _leave(context.read<SessionController>())),
        ]),
      );

  Widget _loadingScreen(McpeClient? c, TexturePack? pack) => McDirtBackground(
        pack: pack,
        child: _menuColumn([
          Text(c == null ? 'Запуск…' : _phaseText(c.phase), style: mcTextStyle(22)),
          const SizedBox(height: 12),
          const SizedBox(width: 240, child: LinearProgressIndicator(color: Color(0xFF70D070), backgroundColor: Colors.black45)),
          const SizedBox(height: 24),
          McButton(label: 'Отмена', pack: pack, onTap: () => _leave(context.read<SessionController>())),
        ]),
      );

  Widget _disconnectedScreen(SessionController session, McpeClient? c, TexturePack? pack) => McDirtBackground(
        pack: pack,
        child: _menuColumn([
          Text('Соединение потеряно', style: mcTextStyle(22)),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: McText(session.error ?? c?.disconnectReason ?? '', textAlign: TextAlign.center, style: mcTextStyle(15)),
          ),
          if (session.versionHint != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Text(session.versionHint!, textAlign: TextAlign.center, style: mcTextStyle(13, color: const Color(0xFFFF8080))),
            ),
          const SizedBox(height: 8),
          if (!session.isHosting) McButton(label: 'Переподключиться', pack: pack, onTap: session.reconnect),
          McButton(label: 'Главное меню', pack: pack, onTap: () => Navigator.of(context).pop()),
        ]),
      );
}
