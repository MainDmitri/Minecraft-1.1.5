import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../protocol/login.dart';
import '../protocol/packets.dart';
import '../protocol/raknet.dart';
import '../state/session_controller.dart';
import '../state/settings_store.dart';
import '../widgets/mc_text.dart';
import 'game_screen.dart';

class ServersScreen extends StatefulWidget {
  const ServersScreen({super.key});

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  final _nickController = TextEditingController();
  final Map<String, Future<ServerStatus>> _statuses = {};
  bool _nickInitialized = false;

  @override
  void dispose() {
    _nickController.dispose();
    super.dispose();
  }

  Future<ServerStatus> _status(ServerEntry s) =>
      _statuses.putIfAbsent(s.address, () => queryServer(s.host, s.port));

  void _refresh() => setState(_statuses.clear);

  Future<void> _editServer({ServerEntry? existing, int? index}) async {
    final result = await showDialog<ServerEntry>(
      context: context,
      builder: (_) => _ServerDialog(existing: existing),
    );
    if (result == null || !mounted) return;
    final store = context.read<SettingsStore>();
    if (index == null) {
      await store.addServer(result);
    } else {
      await store.updateServer(index, result);
    }
    _statuses.remove(result.address);
    if (mounted) setState(() {});
  }

  Future<void> _pickSkin() async {
    final messenger = ScaffoldMessenger.of(context);
    final store = context.read<SettingsStore>();
    final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['png']);
    if (picked == null) return;
    try {
      await store.setSkinFromPng(await picked.readAsBytes());
      messenger.showSnackBar(const SnackBar(content: Text('Скин сохранён')));
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _join(ServerEntry s) async {
    final store = context.read<SettingsStore>();
    final nick = _nickController.text.trim();
    final nickError = validateNickname(nick);
    if (nickError != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(nickError)));
      return;
    }
    await store.setNickname(nick);
    if (!mounted) return;
    final session = context.read<SessionController>();
    session.connect(host: s.host, port: s.port, nickname: nick, skin: store.skin);
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GameScreen()));
    session.close();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    if (!store.loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_nickInitialized) {
      _nickController.text = store.nickname;
      _nickInitialized = true;
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('MCPE $mcpeVersion — серверы'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: 'Обновить статус'),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editServer(),
        icon: const Icon(Icons.add),
        label: const Text('Сервер'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          TextField(
            controller: _nickController,
            maxLength: 16,
            decoration: const InputDecoration(
              labelText: 'Ник',
              helperText: '3–16 символов: латиница, цифры, «_», пробел',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person),
            ),
            onSubmitted: (v) => store.setNickname(v.trim()),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.checkroom),
              title: Text(store.customSkin ? 'Свой скин (${store.skin.height == 64 ? '64×64' : '64×32'})' : 'Стандартный скин клиента'),
              subtitle: const Text('PNG 64×32 или 64×64'),
              trailing: Wrap(
                children: [
                  if (store.customSkin)
                    IconButton(onPressed: store.resetSkin, icon: const Icon(Icons.restart_alt), tooltip: 'Сбросить'),
                  IconButton(onPressed: _pickSkin, icon: const Icon(Icons.upload_file), tooltip: 'Выбрать PNG'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (store.servers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Добавьте сервер MCPE 1.1.x (протокол $mcpeProtocol): адрес и порт, обычно 19132.',
                textAlign: TextAlign.center,
              ),
            ),
          for (var i = 0; i < store.servers.length; i++) _serverTile(store, i),
        ],
      ),
    );
  }

  Widget _serverTile(SettingsStore store, int index) {
    final s = store.servers[index];
    return Card(
      child: InkWell(
        onTap: () => _join(s),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FutureBuilder<ServerStatus>(
            future: _status(s),
            builder: (context, snap) {
              final theme = Theme.of(context);
              Widget statusLine;
              if (snap.connectionState != ConnectionState.done) {
                statusLine = const Text('Опрос сервера…');
              } else if (snap.hasError) {
                statusLine = Text('Нет ответа: ${snap.error}', style: TextStyle(color: theme.colorScheme.error));
              } else {
                final st = snap.data!;
                final compatible = st.protocol == mcpeProtocol;
                statusLine = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    McText(st.motd, maxLines: 2),
                    const SizedBox(height: 4),
                    Text(
                      'Версия ${st.version} (протокол ${st.protocol}) · ${st.online}/${st.max} · ${st.latencyMs} мс',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (!compatible)
                      Text(
                        'Сервер не для 1.1.x — вход, скорее всего, не удастся',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                      ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.name, style: theme.textTheme.titleMedium),
                        Text(s.address, style: theme.textTheme.bodySmall),
                        const SizedBox(height: 6),
                        statusLine,
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'edit') _editServer(existing: s, index: index);
                      if (v == 'delete') store.removeServer(index);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Изменить')),
                      PopupMenuItem(value: 'delete', child: Text('Удалить')),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ServerDialog extends StatefulWidget {
  const _ServerDialog({this.existing});

  final ServerEntry? existing;

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _host = TextEditingController(text: widget.existing?.host ?? '');
  late final _port = TextEditingController(text: (widget.existing?.port ?? 19132).toString());

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final host = _host.text.trim();
    Navigator.of(context).pop(ServerEntry(
      name: _name.text.trim().isEmpty ? host : _name.text.trim(),
      host: host,
      port: int.parse(_port.text.trim()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Новый сервер' : 'Сервер'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Название')),
            TextFormField(
              controller: _host,
              decoration: const InputDecoration(labelText: 'Адрес (IP или домен)'),
              keyboardType: TextInputType.url,
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Укажите адрес' : null,
            ),
            TextFormField(
              controller: _port,
              decoration: const InputDecoration(labelText: 'Порт'),
              keyboardType: TextInputType.number,
              validator: (v) {
                final p = int.tryParse(v?.trim() ?? '');
                return p == null || p < 1 || p > 65535 ? 'Порт 1–65535' : null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton(onPressed: _save, child: const Text('Сохранить')),
      ],
    );
  }
}
