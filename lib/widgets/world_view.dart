import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../game/mcpe_client.dart';
import '../protocol/packets.dart';
import '../world/blocks.dart';
import '../world/player.dart';
import '../world/renderer.dart';
import 'mc_text.dart';

/// Цвет неба по времени суток (0 — рассвет, 6000 — полдень, 18000 — полночь).
int skyColorFor(int worldTime) {
  final t = worldTime % 24000;
  double day;
  if (t < 12000) {
    day = 1;
  } else if (t < 13800) {
    day = 1 - (t - 12000) / 1800;
  } else if (t < 22200) {
    day = 0;
  } else {
    day = (t - 22200) / 1800;
  }
  int lerp(int a, int b) => (a + (b - a) * day).round();
  return 0xFF000000 | (lerp(0x0B, 0x87) << 16) | (lerp(0x10, 0xB5) << 8) | lerp(0x26, 0xFF);
}

class _WorldPainter extends CustomPainter {
  _WorldPainter(this.client, this.renderer, this.renderDistance, Listenable repaint) : super(repaint: repaint);

  final McpeClient client;
  final WorldRenderer renderer;
  final double renderDistance;

  @override
  void paint(Canvas canvas, Size size) {
    final p = client.player;
    final alpha = (DateTime.now().difference(client.lastTick).inMicroseconds / 50000).clamp(0.0, 1.0);
    final x = client.prevX + (p.x - client.prevX) * alpha;
    final y = client.prevY + (p.y - client.prevY) * alpha;
    final z = client.prevZ + (p.z - client.prevZ) * alpha;
    renderer.update(client.level, x, y, z);
    final hit = p.raycast(client.level, client.isCreative ? 7 : 5);
    renderer.paint(
      canvas,
      size,
      Camera(x, y + eyeHeight, z, p.yaw, p.pitch),
      renderDistance: renderDistance,
      skyColor: skyColorFor(client.worldTime),
      entities: [
        for (final r in client.remotePlayers.values) EntityBox(r.position.x, r.position.y, r.position.z, r.name),
      ],
      target: hit?.block,
    );
  }

  @override
  bool shouldRepaint(_WorldPainter old) => old.client != client || old.renderDistance != renderDistance;
}

/// 3D-вид мира с сенсорным управлением.
class WorldView extends StatefulWidget {
  const WorldView({super.key, required this.client, required this.renderDistance});

  final McpeClient client;
  final double renderDistance;

  @override
  State<WorldView> createState() => _WorldViewState();
}

class _WorldViewState extends State<WorldView> with SingleTickerProviderStateMixin {
  final WorldRenderer _renderer = WorldRenderer();
  final ValueNotifier<int> _frame = ValueNotifier(0);
  late final Ticker _ticker;
  Offset? _stickOrigin;
  Offset _stick = Offset.zero;
  int? _lookPointer;

  static const double _stickRadius = 56;
  static const double _lookSensitivity = 0.25;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _frame.value++)..start();
  }

  @override
  void didUpdateWidget(WorldView old) {
    super.didUpdateWidget(old);
    if (old.client != widget.client) _renderer.clear();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    final p = widget.client.player;
    p.forward = p.strafe = 0;
    p.jump = p.descend = false;
    super.dispose();
  }

  void _setStick(Offset delta) {
    final d = delta.distance > _stickRadius ? delta / delta.distance * _stickRadius : delta;
    setState(() => _stick = d);
    final p = widget.client.player;
    p.forward = -d.dy / _stickRadius;
    p.strafe = d.dx / _stickRadius;
  }

  void _releaseStick() {
    setState(() {
      _stickOrigin = null;
      _stick = Offset.zero;
    });
    widget.client.player
      ..forward = 0
      ..strafe = 0;
  }

  Widget _holdButton(IconData icon, String tooltip, void Function(bool) onChange, {Color? color}) {
    return Listener(
      onPointerDown: (_) => onChange(true),
      onPointerUp: (_) => onChange(false),
      onPointerCancel: (_) => onChange(false),
      child: Tooltip(
        message: tooltip,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: (color ?? Colors.black).withValues(alpha: 0.35),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white54),
          ),
          child: Icon(icon, color: Colors.white, size: 30),
        ),
      ),
    );
  }

  Widget _tapButton(IconData icon, String tooltip, VoidCallback onTap, {bool active = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: active ? Colors.green.withValues(alpha: 0.6) : Colors.black.withValues(alpha: 0.35),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white54),
          ),
          child: Icon(icon, color: Colors.white, size: 26),
        ),
      ),
    );
  }

  Widget _slot(ItemStack item, bool selected, VoidCallback onTap) {
    final color = !item.isEmpty && item.id < 256 ? Color(blockColor(item.id, item.meta) | 0xFF000000) : null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        margin: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          border: Border.all(color: selected ? Colors.white : Colors.white24, width: selected ? 3 : 1),
        ),
        child: item.isEmpty
            ? null
            : Stack(
                children: [
                  Center(
                    child: color != null
                        ? Container(width: 22, height: 22, color: color)
                        : Text('#${item.id}', style: const TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                  if (item.count > 1)
                    Positioned(
                      right: 2,
                      bottom: 0,
                      child: Text('${item.count}',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                ],
              ),
      ),
    );
  }

  void _openCreativePalette() {
    final c = widget.client;
    final blocks = c.creativeItems.where((i) => i.id < 256 && blockTable[i.id].shape != BlockShape.none).toList();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => blocks.isEmpty
          ? const Padding(padding: EdgeInsets.all(24), child: Text('Сервер не прислал творческий инвентарь'))
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 48),
              itemCount: blocks.length,
              itemBuilder: (_, i) => _slot(blocks[i], false, () {
                c.takeCreativeItem(blocks[i]);
                Navigator.of(ctx).pop();
              }),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.client;
    final recent = c.chat.where((l) => DateTime.now().difference(l.time) < const Duration(seconds: 10)).toList();
    final shown = recent.length > 5 ? recent.sublist(recent.length - 5) : recent;
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      return Stack(
        children: [
          // 3D-вид и обзор: перетаскивание в любой свободной точке экрана.
          Positioned.fill(
            child: Listener(
              onPointerDown: (e) {
                if (e.localPosition.dx < size.width * 0.4 && e.localPosition.dy > size.height * 0.45) {
                  _stickOrigin ??= e.localPosition;
                } else {
                  _lookPointer ??= e.pointer;
                }
              },
              onPointerMove: (e) {
                if (e.pointer == _lookPointer) {
                  final p = c.player;
                  p.yaw = (p.yaw + e.delta.dx * _lookSensitivity) % 360;
                  p.pitch = (p.pitch + e.delta.dy * _lookSensitivity).clamp(-89.9, 89.9);
                } else if (_stickOrigin != null) {
                  _setStick(e.localPosition - _stickOrigin!);
                }
              },
              onPointerUp: (e) {
                if (e.pointer == _lookPointer) {
                  _lookPointer = null;
                } else {
                  _releaseStick();
                }
              },
              onPointerCancel: (e) {
                _lookPointer = null;
                _releaseStick();
              },
              child: CustomPaint(
                size: size,
                painter: _WorldPainter(c, _renderer, widget.renderDistance, _frame),
              ),
            ),
          ),
          // Прицел и прогресс ломания.
          IgnorePointer(
            child: Center(
              child: SizedBox(
                width: 36,
                height: 36,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Icon(Icons.add, color: Colors.white, size: 26),
                    ValueListenableBuilder<int>(
                      valueListenable: _frame,
                      builder: (_, _, _) {
                        final progress = c.breakProgress;
                        return progress == null
                            ? const SizedBox.shrink()
                            : CircularProgressIndicator(value: progress, strokeWidth: 3, color: Colors.white);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Джойстик.
          if (_stickOrigin != null)
            Positioned(
              left: _stickOrigin!.dx - _stickRadius,
              top: _stickOrigin!.dy - _stickRadius,
              child: IgnorePointer(
                child: Container(
                  width: _stickRadius * 2,
                  height: _stickRadius * 2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.12),
                    border: Border.all(color: Colors.white38),
                  ),
                  child: Transform.translate(
                    offset: _stick,
                    child: Center(
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.5)),
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            const Positioned(
              left: 24,
              bottom: 90,
              child: IgnorePointer(
                child: Text('Двигайтесь: проведите\nпальцем здесь', style: TextStyle(color: Colors.white54, fontSize: 12)),
              ),
            ),
          // Кнопки действий.
          Positioned(
            right: 16,
            bottom: 70,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  children: [
                    if (c.allowFlight)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: _tapButton(Icons.flight, 'Полёт', c.toggleFlight, active: c.player.flying),
                      ),
                    _tapButton(Icons.back_hand, 'Использовать / поставить блок', c.useItemOnBlock),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _holdButton(Icons.hardware, 'Ломать (удерживать)', c.setBreaking, color: Colors.red),
                    const SizedBox(width: 10),
                    Column(
                      children: [
                        _holdButton(Icons.keyboard_arrow_up, c.player.flying ? 'Вверх' : 'Прыжок', (v) => c.player.jump = v),
                        if (c.player.flying) ...[
                          const SizedBox(height: 8),
                          _holdButton(Icons.keyboard_arrow_down, 'Вниз', (v) => c.player.descend = v),
                        ],
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Хотбар.
          Positioned(
            left: 0,
            right: 0,
            bottom: 6,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < 9; i++)
                  _slot(i == c.selectedHotbar && c.isCreative ? c.heldItem : c.hotbarItem(i), i == c.selectedHotbar,
                      () => c.selectHotbar(i)),
                if (c.isCreative)
                  IconButton(
                    onPressed: _openCreativePalette,
                    icon: const Icon(Icons.grid_view, color: Colors.white),
                    tooltip: 'Блоки (творчество)',
                  ),
              ],
            ),
          ),
          // Последние сообщения чата.
          Positioned(
            left: 8,
            top: 8,
            right: size.width * 0.35,
            child: IgnorePointer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in shown)
                    Container(
                      color: Colors.black38,
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      child: McText(l.text, style: const TextStyle(color: Colors.white, fontSize: 13), maxLines: 2),
                    ),
                ],
              ),
            ),
          ),
          // Здоровье, голод, координаты.
          Positioned(
            right: 8,
            top: 8,
            child: IgnorePointer(
              child: Container(
                color: Colors.black38,
                padding: const EdgeInsets.all(6),
                child: DefaultTextStyle(
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('❤ ${c.health.toStringAsFixed(0)}/${c.maxHealth.toStringAsFixed(0)}   🍗 ${c.food.toStringAsFixed(0)}'),
                      if (c.position != null)
                        Text('XYZ ${c.player.x.toStringAsFixed(1)} ${c.player.y.toStringAsFixed(1)} ${c.player.z.toStringAsFixed(1)}'),
                      Text('Направление: ${_facing(c.player.yaw)}'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }

  static String _facing(double yaw) {
    final y = ((yaw % 360) + 360) % 360;
    const names = ['юг', 'запад', 'север', 'восток'];
    return names[((y + 45) / 90).floor() % 4];
  }
}
