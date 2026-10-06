import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../audio/sound_manager.dart';
import '../game/mcpe_client.dart';
import '../protocol/packets.dart';
import '../textures/texture_pack.dart';
import '../world/blocks.dart';
import '../world/player.dart';
import '../world/renderer.dart';
import 'mc_text.dart';
import 'mc_ui.dart';

/// Доля дневного света 0..1 по времени суток (0 — рассвет, 6000 — полдень, 18000 — полночь).
double daylightFor(int worldTime) {
  final t = worldTime % 24000;
  if (t < 12000) return 1;
  if (t < 13800) return 1 - (t - 12000) / 1800;
  if (t < 22200) return 0;
  return (t - 22200) / 1800;
}

/// Цвет неба по времени суток.
int skyColorFor(int worldTime) {
  final day = daylightFor(worldTime);
  int lerp(int a, int b) => (a + (b - a) * day).round();
  return 0xFF000000 | (lerp(0x0B, 0x7B) << 16) | (lerp(0x10, 0xA9) << 8) | lerp(0x26, 0xFF);
}

enum _Pad { up, left, center, right, down, flyDown }

/// Расположение элементов интерфейса, как в MCPE: масштаб [s] — пикселей экрана на пиксель GUI.
class _Layout {
  _Layout(this.size, {required bool flying, required bool creative}) : s = math.max(2.0, size.height / 190) {
    final cell = 26 * s;
    final origin = Offset(8 * s, size.height - 3 * cell - 6 * s);
    pad = {
      _Pad.up: Rect.fromLTWH(origin.dx + cell, origin.dy, cell, cell),
      _Pad.left: Rect.fromLTWH(origin.dx, origin.dy + cell, cell, cell),
      _Pad.center: Rect.fromLTWH(origin.dx + cell, origin.dy + cell, cell, cell),
      _Pad.right: Rect.fromLTWH(origin.dx + 2 * cell, origin.dy + cell, cell, cell),
      _Pad.down: Rect.fromLTWH(origin.dx + cell, origin.dy + 2 * cell, cell, cell),
      if (flying) _Pad.flyDown: Rect.fromLTWH(origin.dx + 2 * cell, origin.dy + 2 * cell, cell, cell),
    };
    dpadArea = Rect.fromLTWH(origin.dx, origin.dy, 3 * cell, 3 * cell);
    hotbar = Rect.fromLTWH((size.width - 182 * s) / 2, size.height - 22 * s, 182 * s, 22 * s);
    palette = creative ? Rect.fromLTWH(hotbar.right + 4 * s, hotbar.top + 2 * s, 18 * s, 18 * s) : null;
    pause = Rect.fromLTWH(size.width - 22 * s, 4 * s, 18 * s, 18 * s);
    chat = Rect.fromLTWH(pause.left - 22 * s, 4 * s, 18 * s, 18 * s);
  }

  final Size size;
  final double s;
  late final Map<_Pad, Rect> pad;
  late final Rect dpadArea;
  late final Rect hotbar;
  late final Rect? palette;
  late final Rect pause;
  late final Rect chat;

  Rect slot(int i) => Rect.fromLTWH(hotbar.left + (3 + 20 * i) * s, hotbar.top + 3 * s, 16 * s, 16 * s);

  int? slotAt(Offset p) {
    if (!hotbar.inflate(4 * s).contains(p)) return null;
    return ((p.dx - hotbar.left - s) / (20 * s)).floor().clamp(0, 8);
  }
}

/// Значок предмета: текстура блока из атласа или цвет блока.
void paintItem(Canvas canvas, Rect dst, ItemStack item, TexturePack? pack, {bool count = true}) {
  if (item.isEmpty) return;
  if (item.id < 256) {
    final info = blockTable[item.id];
    final tile = pack?.tile(item.id, item.meta, info.shape == BlockShape.cross ? 0 : 4) ?? -1;
    if (pack != null && tile > 0) {
      drawSprite(canvas, pack.atlas,
          Rect.fromLTWH(pack.tileX(tile), pack.tileY(tile), tileSize.toDouble(), tileSize.toDouble()), dst);
    } else {
      canvas.drawRect(dst.deflate(dst.width * 0.1), Paint()..color = Color(blockColor(item.id, item.meta) | 0xFF000000));
    }
  } else {
    final tp = TextPainter(
      text: TextSpan(text: '#${item.id}', style: mcTextStyle(dst.height * 0.35)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, dst.center - Offset(tp.width / 2, tp.height / 2));
  }
  if (count && item.count > 1) {
    final tp = TextPainter(
      text: TextSpan(text: '${item.count}', style: mcTextStyle(dst.height * 0.45)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, dst.bottomRight - Offset(tp.width - dst.width * 0.05, tp.height - dst.height * 0.1));
  }
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
    final breaking = client.breakingBlock;
    final progress = client.breakProgress;
    BreakOverlay? overlay;
    if (breaking != null && progress != null && progress > 0 && progress < 1) {
      const dirs = [(-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1)];
      var mask = 0;
      for (var d = 0; d < 6; d++) {
        final (dx, dy, dz) = dirs[d];
        if (!client.level.isSolid(breaking.x + dx, breaking.y + dy, breaking.z + dz)) mask |= 1 << d;
      }
      overlay = BreakOverlay(breaking, (progress * 10).floor().clamp(0, 9), mask);
    }
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
      breaking: overlay,
      worldTime: client.worldTime,
      light: 0.3 + 0.7 * daylightFor(client.worldTime),
    );
  }

  @override
  bool shouldRepaint(_WorldPainter old) => old.client != client || old.renderDistance != renderDistance;
}

class _HudPainter extends CustomPainter {
  _HudPainter(this.client, this.pack, this.pressed, Listenable repaint) : super(repaint: repaint);

  final McpeClient client;
  final TexturePack? pack;
  final Set<_Pad> pressed;

  static const _sprites = {
    _Pad.up: GuiSprites.dpadUp,
    _Pad.left: GuiSprites.dpadLeft,
    _Pad.down: GuiSprites.dpadDown,
    _Pad.right: GuiSprites.dpadRight,
    _Pad.center: GuiSprites.jump,
    _Pad.flyDown: GuiSprites.flyDown,
  };

  static const _labels = {
    _Pad.up: '▲',
    _Pad.left: '◀',
    _Pad.down: '▼',
    _Pad.right: '▶',
    _Pad.center: '◆',
    _Pad.flyDown: '⇓',
  };

  void _label(Canvas canvas, Rect rect, String text, double size) {
    final tp = TextPainter(text: TextSpan(text: text, style: mcTextStyle(size)), textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = client;
    final l = _Layout(size, flying: c.player.flying, creative: c.isCreative);
    final s = l.s;
    final gui = pack?.gui, icons = pack?.icons;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white70;
    final fill = Paint()..color = const Color(0x66000000);

    // Прицел.
    final cross = Rect.fromCenter(center: size.center(Offset.zero), width: 15 * s, height: 15 * s);
    if (icons != null) {
      drawSprite(canvas, icons, GuiSprites.crosshair, cross,
          paint: Paint()
            ..filterQuality = FilterQuality.none
            ..blendMode = BlendMode.difference);
    } else {
      final w = Paint()
        ..color = Colors.white
        ..strokeWidth = 2;
      canvas.drawLine(cross.centerLeft, cross.centerRight, w);
      canvas.drawLine(cross.topCenter, cross.bottomCenter, w);
    }
    final progress = c.breakProgress;
    // Без текстур трещин прогресс ломания показывается полоской под прицелом.
    if (progress != null && progress > 0 && progress < 1 && (pack?.destroyTiles.isEmpty ?? true)) {
      final bar = Rect.fromLTWH(cross.left, cross.bottom + 4 * s, cross.width, 2 * s);
      canvas.drawRect(bar, Paint()..color = Colors.black54);
      canvas.drawRect(Rect.fromLTWH(bar.left, bar.top, bar.width * progress, bar.height), Paint()..color = Colors.white);
    }

    // Хотбар.
    if (gui != null) {
      drawSprite(canvas, gui, GuiSprites.hotbar, l.hotbar);
    } else {
      canvas.drawRect(l.hotbar, fill);
      canvas.drawRect(l.hotbar, outline);
    }
    for (var i = 0; i < 9; i++) {
      final item = i == c.selectedHotbar && c.isCreative ? c.heldItem : c.hotbarItem(i);
      paintItem(canvas, l.slot(i), item, pack);
    }
    final sel = Rect.fromLTWH(l.hotbar.left + (20 * c.selectedHotbar - 1) * s, l.hotbar.top - s, 24 * s, 24 * s);
    if (gui != null) {
      drawSprite(canvas, gui, GuiSprites.hotbarSelection, sel);
    } else {
      canvas.drawRect(sel, outline..color = Colors.white);
    }
    final palette = l.palette;
    if (palette != null) {
      canvas.drawRect(palette, fill);
      _label(canvas, palette, '•••', 5 * s);
    }

    // Здоровье и голод (в выживании).
    if (!c.isCreative) {
      final hearts = c.health.ceil(), food = c.food.ceil();
      for (var i = 0; i < 10; i++) {
        final hr = Rect.fromLTWH(l.hotbar.left + i * 8 * s, l.hotbar.top - 11 * s, 9 * s, 9 * s);
        final fr = Rect.fromLTWH(l.hotbar.right - (i + 1) * 8 * s - s, l.hotbar.top - 11 * s, 9 * s, 9 * s);
        if (icons != null) {
          drawSprite(canvas, icons, GuiSprites.heartEmpty, hr);
          if (hearts >= i * 2 + 2) {
            drawSprite(canvas, icons, GuiSprites.heartFull, hr);
          } else if (hearts == i * 2 + 1) {
            drawSprite(canvas, icons, GuiSprites.heartHalf, hr);
          }
          drawSprite(canvas, icons, GuiSprites.foodEmpty, fr);
          if (food >= i * 2 + 2) {
            drawSprite(canvas, icons, GuiSprites.foodFull, fr);
          } else if (food == i * 2 + 1) {
            drawSprite(canvas, icons, GuiSprites.foodHalf, fr);
          }
        } else {
          canvas.drawRect(hr.deflate(s), Paint()..color = hearts > i * 2 ? Colors.red : Colors.black45);
          canvas.drawRect(fr.deflate(s), Paint()..color = food > i * 2 ? Colors.brown : Colors.black45);
        }
      }
    }

    // Крестовина управления.
    l.pad.forEach((key, rect) {
      final dst = rect.deflate(2 * s);
      final down = pressed.contains(key);
      if (gui != null) {
        drawSprite(canvas, gui, _sprites[key]!, dst,
            paint: Paint()
              ..filterQuality = FilterQuality.none
              ..color = Color.fromRGBO(255, 255, 255, down ? 1 : 0.6));
        if (down) canvas.drawRect(dst, Paint()..color = const Color(0x40A0C0FF));
      } else {
        canvas.drawRect(dst, Paint()..color = Color(down ? 0x99FFFFFF : 0x55000000));
        _label(canvas, dst, _labels[key]!, 10 * s);
      }
    });

    // Пауза и чат.
    for (final (rect, sprite, label) in [(l.pause, GuiSprites.pause, 'II'), (l.chat, GuiSprites.chat, '…')]) {
      if (gui != null) {
        drawSprite(canvas, gui, sprite, rect);
      } else {
        canvas.drawRect(rect, fill);
        _label(canvas, rect, label, 7 * s);
      }
    }
  }

  @override
  bool shouldRepaint(_HudPainter old) => true;
}

class _ItemIcon extends CustomPainter {
  _ItemIcon(this.item, this.pack);

  final ItemStack item;
  final TexturePack? pack;

  @override
  void paint(Canvas canvas, Size size) => paintItem(canvas, Offset.zero & size, item, pack, count: false);

  @override
  bool shouldRepaint(_ItemIcon old) => old.item != item || old.pack != pack;
}

/// 3D-вид мира с интерфейсом и сенсорным управлением в стиле MCPE.
class WorldView extends StatefulWidget {
  const WorldView({
    super.key,
    required this.client,
    required this.renderDistance,
    required this.pack,
    required this.onPause,
    this.sounds,
  });

  final McpeClient client;
  final double renderDistance;
  final TexturePack? pack;
  final SoundManager? sounds;
  final VoidCallback onPause;

  @override
  State<WorldView> createState() => WorldViewState();
}

class WorldViewState extends State<WorldView> with SingleTickerProviderStateMixin {
  final WorldRenderer _renderer = WorldRenderer();
  final ValueNotifier<int> _frame = ValueNotifier(0);
  late final Ticker _ticker;

  final Map<int, _Pad?> _padPointers = {};
  final Set<_Pad> _pressed = {};
  DateTime _lastJumpTap = DateTime(0);

  int? _lookPointer;
  Offset _lookStart = Offset.zero;
  DateTime _lookStartTime = DateTime(0);
  bool _lookMoved = false;
  bool _breaking = false;
  Timer? _holdTimer;

  bool _chatOpen = false;
  final TextEditingController _chatInput = TextEditingController();
  final FocusNode _chatFocus = FocusNode();

  static const double _lookSensitivity = 0.28;

  StreamSubscription<GameSound>? _soundSub;

  void _listenSounds() {
    _soundSub?.cancel();
    _soundSub = widget.client.sounds.listen((s) => widget.sounds?.handle(s));
  }

  @override
  void initState() {
    super.initState();
    _listenSounds();
    _renderer.setPack(widget.pack, widget.client.level);
    _ticker = createTicker((_) => _frame.value++)..start();
  }

  @override
  void didUpdateWidget(WorldView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      _renderer.clear();
      _listenSounds();
    }
    _renderer.setPack(widget.pack, widget.client.level);
  }

  @override
  void dispose() {
    _soundSub?.cancel();
    _ticker.dispose();
    _frame.dispose();
    _holdTimer?.cancel();
    _chatInput.dispose();
    _chatFocus.dispose();
    final p = widget.client.player;
    p.forward = p.strafe = 0;
    p.jump = p.descend = false;
    if (_breaking) widget.client.setBreaking(false);
    super.dispose();
  }

  /// Открыть чат (например, из меню паузы); [text] — начало сообщения, например команда.
  void openChat([String text = '']) {
    setState(() => _chatOpen = true);
    if (text.isNotEmpty) {
      _chatInput.text = text;
      _chatInput.selection = TextSelection.collapsed(offset: text.length);
    }
    _chatFocus.requestFocus();
  }

  void _applyPad() {
    final p = widget.client.player;
    p.forward = _pressed.contains(_Pad.up) ? 1 : (_pressed.contains(_Pad.down) ? -1 : 0);
    p.strafe = _pressed.contains(_Pad.right) ? 1 : (_pressed.contains(_Pad.left) ? -1 : 0);
    p.jump = _pressed.contains(_Pad.center);
    p.descend = _pressed.contains(_Pad.flyDown);
  }

  _Pad? _padAt(_Layout l, Offset pos) {
    for (final e in l.pad.entries) {
      if (e.value.contains(pos)) return e.key;
    }
    return null;
  }

  void _setPadPointer(int pointer, _Pad? pad) {
    final old = _padPointers[pointer];
    _padPointers[pointer] = pad;
    _pressed
      ..clear()
      ..addAll(_padPointers.values.whereType<_Pad>());
    if (pad == _Pad.center && old != _Pad.center) {
      final now = DateTime.now();
      // Двойное касание прыжка — полёт в творчестве, как в MCPE.
      if (now.difference(_lastJumpTap) < const Duration(milliseconds: 350) && widget.client.allowFlight) {
        widget.client.toggleFlight();
      }
      _lastJumpTap = now;
    }
    _applyPad();
  }

  void _onDown(PointerDownEvent e, _Layout l) {
    final c = widget.client;
    final pos = e.localPosition;
    if (l.pause.inflate(4).contains(pos)) {
      widget.onPause();
      return;
    }
    if (l.chat.inflate(4).contains(pos)) {
      _chatOpen ? setState(() => _chatOpen = false) : openChat();
      return;
    }
    final palette = l.palette;
    if (palette != null && palette.inflate(4).contains(pos)) {
      _openCreativePalette();
      return;
    }
    final slot = l.slotAt(pos);
    if (slot != null) {
      c.selectHotbar(slot);
      return;
    }
    if (l.dpadArea.contains(pos) || (l.pad[_Pad.flyDown]?.contains(pos) ?? false)) {
      _setPadPointer(e.pointer, _padAt(l, pos));
      return;
    }
    if (_lookPointer != null) return;
    _lookPointer = e.pointer;
    _lookStart = pos;
    _lookStartTime = DateTime.now();
    _lookMoved = false;
    _holdTimer?.cancel();
    // Удержание без движения — ломать блок.
    _holdTimer = Timer(const Duration(milliseconds: 300), () {
      if (_lookPointer == e.pointer && !_lookMoved) {
        _breaking = true;
        c.setBreaking(true);
      }
    });
  }

  void _onMove(PointerMoveEvent e, _Layout l) {
    if (_padPointers.containsKey(e.pointer)) {
      final pad = _padAt(l, e.localPosition);
      if (pad != _padPointers[e.pointer]) _setPadPointer(e.pointer, pad);
      return;
    }
    if (e.pointer != _lookPointer) return;
    if ((e.localPosition - _lookStart).distance > 10) _lookMoved = true;
    final p = widget.client.player;
    p.yaw = (p.yaw + e.delta.dx * _lookSensitivity) % 360;
    p.pitch = (p.pitch + e.delta.dy * _lookSensitivity).clamp(-89.9, 89.9);
  }

  void _onUp(PointerEvent e) {
    if (_padPointers.containsKey(e.pointer)) {
      _padPointers.remove(e.pointer);
      _pressed
        ..clear()
        ..addAll(_padPointers.values.whereType<_Pad>());
      _applyPad();
      return;
    }
    if (e.pointer != _lookPointer) return;
    _lookPointer = null;
    _holdTimer?.cancel();
    if (_breaking) {
      _breaking = false;
      widget.client.setBreaking(false);
      return;
    }
    // Короткое касание без движения — поставить блок / использовать предмет.
    if (!_lookMoved && DateTime.now().difference(_lookStartTime) < const Duration(milliseconds: 300)) {
      widget.client.useItemOnBlock();
    }
  }

  void _openCreativePalette() {
    final c = widget.client;
    final blocks = c.creativeItems.where((i) => i.id < 256 && blockTable[i.id].shape != BlockShape.none).toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xEE1E1E1E),
      builder: (ctx) => blocks.isEmpty
          ? Padding(padding: const EdgeInsets.all(24), child: Text('Сервер не прислал творческий инвентарь', style: mcTextStyle(15)))
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 52),
              itemCount: blocks.length,
              itemBuilder: (_, i) => InkWell(
                onTap: () {
                  c.takeCreativeItem(blocks[i]);
                  Navigator.of(ctx).pop();
                },
                child: Container(
                  margin: const EdgeInsets.all(3),
                  color: const Color(0xFF8B8B8B),
                  padding: const EdgeInsets.all(5),
                  child: CustomPaint(painter: _ItemIcon(blocks[i], widget.pack)),
                ),
              ),
            ),
    );
  }

  void _sendChat() {
    final text = _chatInput.text;
    if (text.trim().isEmpty) return;
    widget.client.sendMessage(text);
    _chatInput.clear();
    _chatFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.client;
    // Сообщения сервера (например, просьба зарегистрироваться) видны сразу после входа;
    // с открытым чатом — вся недавняя история.
    final List<ChatLine> shown;
    if (_chatOpen) {
      shown = c.chat.length > 30 ? c.chat.sublist(c.chat.length - 30) : c.chat;
    } else {
      final recent = c.chat.where((l) => DateTime.now().difference(l.time) < const Duration(seconds: 30)).toList();
      shown = recent.length > 8 ? recent.sublist(recent.length - 8) : recent;
    }
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      _Layout layout() => _Layout(size, flying: c.player.flying, creative: c.isCreative);
      final l = layout();
      return Stack(
        children: [
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) => _onDown(e, layout()),
              onPointerMove: (e) => _onMove(e, layout()),
              onPointerUp: _onUp,
              onPointerCancel: _onUp,
              child: RepaintBoundary(
                child: CustomPaint(
                  size: size,
                  painter: _WorldPainter(c, _renderer, widget.renderDistance, _frame),
                  foregroundPainter: _HudPainter(c, widget.pack, _pressed, _frame),
                ),
              ),
            ),
          ),
          // Сообщения чата.
          Positioned(
            left: l.s * 4,
            top: l.s * 4,
            right: size.width * 0.4,
            bottom: _chatOpen ? l.hotbar.height + 64 : null,
            child: IgnorePointer(
              ignoring: !_chatOpen,
              child: SingleChildScrollView(
                reverse: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in shown)
                      Container(
                        color: const Color(0x66000000),
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        child: McText(line.text, style: mcTextStyle(14), maxLines: _chatOpen ? null : 2),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_chatOpen)
            Positioned(
              left: 8,
              right: 8,
              bottom: l.hotbar.height + 8,
              child: Container(
                color: const Color(0xAA000000),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _chatInput,
                        focusNode: _chatFocus,
                        maxLength: 255,
                        style: mcTextStyle(15),
                        cursorColor: Colors.white,
                        textInputAction: TextInputAction.send,
                        decoration: const InputDecoration(
                          hintText: 'Сообщение или /команда',
                          hintStyle: TextStyle(color: Colors.white54),
                          border: InputBorder.none,
                          counterText: '',
                        ),
                        onSubmitted: (_) => _sendChat(),
                      ),
                    ),
                    IconButton(onPressed: _sendChat, icon: const Icon(Icons.send, color: Colors.white)),
                    IconButton(
                      onPressed: () => setState(() => _chatOpen = false),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    });
  }
}
