import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../game/crafting.dart';
import '../game/items.dart';
import '../game/mcpe_client.dart';
import '../protocol/packets.dart';
import '../protocol/skin.dart';
import '../textures/texture_pack.dart';
import 'item_icon.dart';
import 'mc_ui.dart';

enum _Kind { inventory, armor, grid, result, container }

/// Слот на экране: прямоугольник в единицах интерфейса (пиксели GUI, как в Minecraft).
class _Region {
  const _Region(this.rect, this.kind, this.index, {this.big = false});

  final Rect rect;
  final _Kind kind;
  final int index;
  final bool big;
}

class _Screen {
  _Screen(this.height, this.regions, this.titles, {this.preview, this.arrow, this.flame});

  static const double width = 176;
  final double height;
  final List<_Region> regions;
  final List<(String, Offset)> titles;
  final Rect? preview;
  final Offset? arrow;
  final Offset? flame;
}

Rect _slot(double x, double y) => Rect.fromLTWH(x, y, 16, 16);

/// Экран инвентаря в стиле Minecraft: броня, игрок, крафт 2×2 (или верстак 3×3, сундук, печь),
/// 27 слотов инвентаря и хотбар.
class InventoryView extends StatefulWidget {
  const InventoryView({super.key, required this.client, required this.pack, required this.skin, required this.onClose});

  final McpeClient client;
  final TexturePack? pack;
  final SkinData skin;
  final VoidCallback onClose;

  @override
  State<InventoryView> createState() => _InventoryViewState();
}

class _InventoryViewState extends State<InventoryView> {
  StreamSubscription<void>? _sub;
  ui.Image? _skinImage;

  /// Взятая «в руку» стопка: откуда и сколько.
  SlotRef? _from;
  int _count = 0;

  /// Сетка крафта: типы предметов (по одному). Предметы остаются в инвентаре,
  /// пока не нажат результат: сервер сам забирает ингредиенты.
  List<ItemStack?> _grid = List.filled(4, null);

  String? _hint;
  Timer? _hintTimer;

  McpeClient get c => widget.client;
  bool get _workbench => c.container?.type == WindowType.workbench;
  int get _gridSize => _workbench ? 3 : 2;

  @override
  void initState() {
    super.initState();
    _sub = c.changes.listen((_) {
      if (!mounted) return;
      setState(_pruneGrid);
    });
    _decodeSkin();
  }

  @override
  void didUpdateWidget(InventoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.skin != widget.skin) _decodeSkin();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hintTimer?.cancel();
    _skinImage?.dispose();
    super.dispose();
  }

  void _decodeSkin() {
    final skin = widget.skin;
    ui.decodeImageFromPixels(skin.rgba, 64, skin.height, ui.PixelFormat.rgba8888, (image) {
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _skinImage?.dispose();
        _skinImage = image;
      });
    });
  }

  void _showHint(String text) {
    _hintTimer?.cancel();
    setState(() => _hint = text);
    _hintTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  // ---------- Раскладка ----------

  List<int> get _hotbarSlots => [for (var i = 0; i < 9; i++) c.hotbarSlotIndex(i)];

  List<int> get _mainSlots {
    final hotbar = _hotbarSlots.toSet();
    return [for (var i = 0; i < 36; i++) if (!hotbar.contains(i)) i].take(27).toList();
  }

  _Screen _screen() {
    final container = c.container;
    final regions = <_Region>[];
    final titles = <(String, Offset)>[];
    var invTop = 84.0;
    Rect? preview;
    Offset? arrow, flame;
    double height = 166;

    if (container == null) {
      for (var i = 0; i < 4; i++) {
        regions.add(_Region(_slot(8, 8 + 18.0 * i), _Kind.armor, i));
      }
      preview = const Rect.fromLTWH(26, 8, 49, 70);
      for (var r = 0; r < 2; r++) {
        for (var col = 0; col < 2; col++) {
          regions.add(_Region(_slot(98 + 18.0 * col, 18 + 18.0 * r), _Kind.grid, r * 2 + col));
        }
      }
      arrow = const Offset(135, 27);
      regions.add(_Region(_slot(154, 28), _Kind.result, 0));
    } else if (container.type == WindowType.workbench) {
      titles.add(('Верстак', const Offset(28, 5)));
      for (var r = 0; r < 3; r++) {
        for (var col = 0; col < 3; col++) {
          regions.add(_Region(_slot(30 + 18.0 * col, 17 + 18.0 * r), _Kind.grid, r * 3 + col));
        }
      }
      arrow = const Offset(90, 34);
      regions.add(_Region(_slot(124, 35), _Kind.result, 0, big: true));
      titles.add(('Инвентарь', const Offset(8, 72)));
    } else if (container.type == WindowType.furnace) {
      titles.add(('Печь', const Offset(8, 5)));
      regions
        ..add(_Region(_slot(56, 17), _Kind.container, 0))
        ..add(_Region(_slot(56, 53), _Kind.container, 1))
        ..add(_Region(_slot(116, 35), _Kind.container, 2, big: true));
      arrow = const Offset(79, 34);
      flame = const Offset(57, 37);
      titles.add(('Инвентарь', const Offset(8, 72)));
    } else {
      final rows = math.max(1, (container.slots.length + 8) ~/ 9);
      titles.add((rows > 3 ? 'Большой сундук' : 'Сундук', const Offset(8, 5)));
      for (var i = 0; i < rows * 9; i++) {
        regions.add(_Region(_slot(8 + 18.0 * (i % 9), 18 + 18.0 * (i ~/ 9)), _Kind.container, i));
      }
      invTop = rows * 18 + 31;
      height = 114 + rows * 18;
      titles.add(('Инвентарь', Offset(8, invTop - 12)));
    }
    final main = _mainSlots;
    for (var i = 0; i < main.length; i++) {
      regions.add(_Region(_slot(8 + 18.0 * (i % 9), invTop + 18.0 * (i ~/ 9)), _Kind.inventory, main[i]));
    }
    final hotbar = _hotbarSlots;
    for (var i = 0; i < 9; i++) {
      regions.add(_Region(_slot(8 + 18.0 * i, invTop + 58), _Kind.inventory, hotbar[i]));
    }
    return _Screen(height, regions, titles, preview: preview, arrow: arrow, flame: flame);
  }

  SlotRef? _refOf(_Region r) => switch (r.kind) {
        _Kind.inventory => r.index < 0 ? null : SlotRef(ContainerIds.inventory, r.index),
        _Kind.armor => SlotRef(ContainerIds.armor, r.index),
        _Kind.container => c.container == null || c.container!.windowId < 0 ? null : SlotRef(c.container!.windowId, r.index),
        _ => null,
      };

  // ---------- Сетка крафта ----------

  void _pruneGrid() {
    if (_grid.length != _gridSize * _gridSize) {
      _grid = List.filled(_gridSize * _gridSize, null);
    }
    for (var i = 0; i < _grid.length; i++) {
      final g = _grid[i];
      if (g != null && c.countInInventory(g) == 0) _grid[i] = null;
    }
    final from = _from;
    if (from != null && c.itemAt(from).isEmpty) {
      _from = null;
      _count = 0;
    }
  }

  /// Сколько предметов каждого типа занято сеткой крафта.
  List<(ItemStack, int)> _gridNeeds() {
    final out = <(ItemStack, int)>[];
    for (final g in _grid) {
      if (g == null) continue;
      final i = out.indexWhere((e) => e.$1.sameType(g));
      if (i < 0) {
        out.add((g, 1));
      } else {
        out[i] = (out[i].$1, out[i].$2 + 1);
      }
    }
    return out;
  }

  /// Сколько предметов в слотах инвентаря зарезервировано сеткой (сервер берёт с первых слотов).
  Map<int, int> _reserved() {
    final out = <int, int>{};
    for (final (type, need) in _gridNeeds()) {
      var left = need;
      for (var i = 0; i < c.inventory.length && i < 36 && left > 0; i++) {
        final it = c.inventory[i];
        if (!it.sameType(type)) continue;
        final take = math.min(left, it.count);
        out[i] = (out[i] ?? 0) + take;
        left -= take;
      }
    }
    return out;
  }

  int _shownCount(SlotRef ref, Map<int, int> reserved) {
    var n = c.itemAt(ref).count;
    if (ref.window == ContainerIds.inventory) n -= reserved[ref.index] ?? 0;
    if (ref == _from) n -= _count;
    return math.max(0, n);
  }

  CraftMatch? _match() => matchRecipe(_grid, _gridSize, c.recipes);

  /// Сколько раз подряд можно скрафтить по текущей сетке.
  int _craftTimes() {
    var times = 64;
    for (final (type, need) in _gridNeeds()) {
      times = math.min(times, c.countInInventory(type) ~/ need);
    }
    return times;
  }

  // ---------- Действия ----------

  void _pick(SlotRef ref, int count) {
    setState(() {
      _from = ref;
      _count = count;
    });
    final item = c.itemAt(ref);
    _showHint(itemTitle(item.id, item.meta));
  }

  /// Положить [amount] предметов из руки в слот [to].
  void _place(SlotRef to, int amount) {
    final from = _from;
    if (from == null) return;
    final src = c.itemAt(from);
    final dst = c.itemAt(to);
    if (src.isEmpty) {
      setState(() => _from = null);
      return;
    }
    if (to.window == ContainerIds.armor && armorSlotOf(src.id) != to.index) {
      _showHint('Сюда можно положить только подходящую броню');
      return;
    }
    final container = c.container;
    if (container != null && container.type == WindowType.furnace && to.window == container.windowId && to.index == 2) {
      _showHint('Из этого слота можно только забирать');
      return;
    }
    final limit = to.window == ContainerIds.armor ? 1 : maxStackOf(src.id);
    if (dst.isEmpty || dst.sameType(src)) {
      final space = limit - (dst.isEmpty ? 0 : dst.count);
      final moved = math.min(amount, space);
      if (moved <= 0) return;
      c.setSlots([
        (from, src.withCount(src.count - moved)),
        (to, src.withCount((dst.isEmpty ? 0 : dst.count) + moved)),
      ]);
      setState(() {
        _count -= moved;
        if (_count <= 0) _from = null;
      });
      return;
    }
    // Разные предметы: меняются местами, если взята вся стопка.
    if (_count == src.count && (from.window != ContainerIds.armor || armorSlotOf(dst.id) == from.index)) {
      if (to.window == ContainerIds.armor || dst.count <= maxStackOf(dst.id)) {
        c.setSlots([(from, dst), (to, src)]);
        setState(() => _from = null);
      }
    }
  }

  void _tapRegion(_Region r, {required bool long}) {
    switch (r.kind) {
      case _Kind.grid:
        final from = _from;
        if (from == null) {
          setState(() => _grid[r.index] = null);
          return;
        }
        if (from.window != ContainerIds.inventory) {
          _showHint('Для крафта переложите предметы в инвентарь');
          return;
        }
        final type = c.itemAt(from).withCount(1);
        final already = _gridNeeds().where((e) => e.$1.sameType(type)).fold<int>(0, (n, e) => n + e.$2);
        final current = _grid[r.index];
        final freed = current != null && current.sameType(type) ? 1 : 0;
        if (c.countInInventory(type) - already + freed < 1) {
          _showHint('Не хватает предметов');
          return;
        }
        setState(() => _grid[r.index] = type);
      case _Kind.result:
        final m = _match();
        if (m == null) {
          if (c.recipes.isEmpty) _showHint('Сервер не прислал рецепты');
          return;
        }
        final times = _craftTimes();
        if (times < 1) {
          _showHint('Не хватает предметов');
          return;
        }
        final n = long ? math.max(1, math.min(times, 64 ~/ math.max(1, m.recipe.result.count))) : 1;
        for (var i = 0; i < n; i++) {
          c.craft(m);
        }
        _showHint('${itemTitle(m.recipe.result.id, m.recipe.result.meta)}${n > 1 ? ' ×${n * m.recipe.result.count}' : ''}');
      case _Kind.inventory:
      case _Kind.armor:
      case _Kind.container:
        final ref = _refOf(r);
        if (ref == null) return;
        final reserved = _reserved();
        if (_from == null) {
          final item = c.itemAt(ref);
          final available = _shownCount(ref, reserved);
          if (item.isEmpty || available <= 0) return;
          _pick(ref, long ? (available + 1) ~/ 2 : available);
          return;
        }
        if (ref == _from) {
          setState(() => _from = null);
          return;
        }
        _place(ref, long ? 1 : _count);
    }
  }

  void _tapOutside() {
    final from = _from;
    if (from == null) {
      widget.onClose();
      return;
    }
    if (from.window == ContainerIds.inventory && _count == c.itemAt(from).count) {
      c.dropSlot(from.index);
      setState(() => _from = null);
    } else {
      // Часть стопки или предмет из сундука выбросить нельзя — просто кладём обратно.
      setState(() => _from = null);
    }
  }

  void _onTap(Offset pos, _Screen screen, Offset origin, double s, {required bool long}) {
    final gui = (pos - origin) / s;
    // Справа от окна — взятая стопка, это тоже часть окна.
    if (!Rect.fromLTWH(-2, -2, _Screen.width + 32, screen.height + 4).contains(gui)) {
      _tapOutside();
      return;
    }
    for (final r in screen.regions) {
      if (r.rect.inflate(r.big ? 5 : 1).contains(gui)) {
        _tapRegion(r, long: long);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screen = _screen();
    if (_grid.length != _gridSize * _gridSize) _grid = List.filled(_gridSize * _gridSize, null);
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      final s = math.max(1.0, (math.min(size.width * 0.96 / (_Screen.width + 64), size.height * 0.96 / screen.height) * 2).floor() / 2);
      final origin = Offset((size.width - _Screen.width * s) / 2, (size.height - screen.height * s) / 2);
      final match = _match();
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _onTap(d.localPosition, screen, origin, s, long: false),
        onLongPressStart: (d) => _onTap(d.localPosition, screen, origin, s, long: true),
        child: CustomPaint(
          size: size,
          painter: _InventoryPainter(
            client: c,
            pack: widget.pack,
            screen: screen,
            origin: origin,
            scale: s,
            skin: _skinImage,
            skinData: widget.skin,
            grid: _grid,
            match: match,
            canCraft: match != null && _craftTimes() >= 1,
            from: _from,
            count: _count,
            shown: (ref) => _shownCount(ref, _reserved()),
            refOf: _refOf,
            hint: _hint,
          ),
        ),
      );
    });
  }
}

class _InventoryPainter extends CustomPainter {
  _InventoryPainter({
    required this.client,
    required this.pack,
    required this.screen,
    required this.origin,
    required this.scale,
    required this.skin,
    required this.skinData,
    required this.grid,
    required this.match,
    required this.canCraft,
    required this.from,
    required this.count,
    required this.shown,
    required this.refOf,
    required this.hint,
  });

  final McpeClient client;
  final TexturePack? pack;
  final _Screen screen;
  final Offset origin;
  final double scale;
  final ui.Image? skin;
  final SkinData skinData;
  final List<ItemStack?> grid;
  final CraftMatch? match;
  final bool canCraft;
  final SlotRef? from;
  final int count;
  final int Function(SlotRef) shown;
  final SlotRef? Function(_Region) refOf;
  final String? hint;

  static const _panel = Color(0xFFC6C6C6);
  static const _slotFill = Color(0xFF8B8B8B);
  static const _dark = Color(0xFF373737);
  static const _shadow = Color(0xFF555555);

  void _bevel(Canvas canvas, Rect r, Color fill, Color topLeft, Color bottomRight, double w) {
    canvas.drawRect(r, Paint()..color = fill);
    final tl = Paint()..color = topLeft;
    final br = Paint()..color = bottomRight;
    canvas
      ..drawRect(Rect.fromLTWH(r.left, r.top, r.width - w, w), tl)
      ..drawRect(Rect.fromLTWH(r.left, r.top, w, r.height - w), tl)
      ..drawRect(Rect.fromLTWH(r.left + w, r.bottom - w, r.width - w, w), br)
      ..drawRect(Rect.fromLTWH(r.right - w, r.top + w, w, r.height - w), br);
  }

  void _drawPanel(Canvas canvas, Rect r) {
    final black = Paint()..color = Colors.black;
    // Скруглённая рамка из пикселей, как у окон Minecraft.
    canvas
      ..drawRect(Rect.fromLTRB(r.left + 2, r.top - 1, r.right - 3, r.top), black)
      ..drawRect(Rect.fromLTRB(r.left + 3, r.bottom, r.right - 2, r.bottom + 1), black)
      ..drawRect(Rect.fromLTRB(r.left - 1, r.top + 2, r.left, r.bottom - 3), black)
      ..drawRect(Rect.fromLTRB(r.right, r.top + 3, r.right + 1, r.bottom - 2), black)
      ..drawRect(Rect.fromLTWH(r.left, r.top, 2, 2), black)
      ..drawRect(Rect.fromLTWH(r.right - 3, r.top, 3, 3), black)
      ..drawRect(Rect.fromLTWH(r.left, r.bottom - 3, 3, 3), black)
      ..drawRect(Rect.fromLTWH(r.right - 2, r.bottom - 2, 2, 2), black);
    canvas.drawRect(Rect.fromLTRB(r.left + 2, r.top, r.right - 3, r.bottom), Paint()..color = _panel);
    canvas.drawRect(Rect.fromLTRB(r.left, r.top + 2, r.right, r.bottom - 3), Paint()..color = _panel);
    final white = Paint()..color = Colors.white;
    final shadow = Paint()..color = _shadow;
    canvas
      ..drawRect(Rect.fromLTRB(r.left + 2, r.top, r.right - 3, r.top + 2), white)
      ..drawRect(Rect.fromLTRB(r.left, r.top + 2, r.left + 2, r.bottom - 3), white)
      ..drawRect(Rect.fromLTWH(r.left + 2, r.top + 2, 1, 1), white)
      ..drawRect(Rect.fromLTRB(r.left + 3, r.bottom - 2, r.right - 2, r.bottom), shadow)
      ..drawRect(Rect.fromLTRB(r.right - 2, r.top + 3, r.right, r.bottom - 2), shadow)
      ..drawRect(Rect.fromLTWH(r.right - 3, r.bottom - 3, 1, 1), shadow);
  }

  void _drawArrow(Canvas canvas, Offset o, double progress) {
    // Стрелка 22×15, как в окнах крафта и печи.
    final path = Path()
      ..moveTo(o.dx, o.dy + 5)
      ..lineTo(o.dx + 14, o.dy + 5)
      ..lineTo(o.dx + 14, o.dy)
      ..lineTo(o.dx + 22, o.dy + 7.5)
      ..lineTo(o.dx + 14, o.dy + 15)
      ..lineTo(o.dx + 14, o.dy + 10)
      ..lineTo(o.dx, o.dy + 10)
      ..close();
    canvas.drawPath(path, Paint()..color = _slotFill);
    if (progress > 0) {
      canvas
        ..save()
        ..clipRect(Rect.fromLTWH(o.dx, o.dy, 22 * progress.clamp(0, 1), 15))
        ..drawPath(path, Paint()..color = Colors.white)
        ..restore();
    }
  }

  void _drawFlame(Canvas canvas, Offset o, double fuel) {
    final rect = Rect.fromLTWH(o.dx, o.dy, 14, 14);
    canvas.drawRect(rect.deflate(3), Paint()..color = _slotFill);
    if (fuel > 0) {
      final h = 14 * fuel.clamp(0.0, 1.0);
      final flame = Rect.fromLTWH(o.dx + 2, o.dy + 14 - h, 10, h);
      canvas.drawRect(flame, Paint()..color = const Color(0xFFFF9A1F));
      canvas.drawRect(Rect.fromLTWH(flame.left + 3, flame.top + h * 0.3, 4, h * 0.7), Paint()..color = const Color(0xFFFFE34D));
    }
  }

  void _drawSkin(Canvas canvas, Rect box) {
    final image = skin;
    canvas.drawRect(box, Paint()..color = Colors.black);
    if (image == null) return;
    const k = 2.0;
    final cx = box.center.dx;
    final top = box.top + (box.height - 32 * k) / 2;
    final paint = Paint()..filterQuality = FilterQuality.none;
    void part(Rect src, double x, double y, {bool flip = false}) {
      final dst = Rect.fromLTWH(cx + x * k, top + y * k, src.width * k, src.height * k);
      if (!flip) {
        canvas.drawImageRect(image, src, dst, paint);
        return;
      }
      canvas
        ..save()
        ..translate(dst.center.dx, 0)
        ..scale(-1, 1)
        ..translate(-dst.center.dx, 0)
        ..drawImageRect(image, src, dst, paint)
        ..restore();
    }

    final tall = skinData.height == 64;
    part(const Rect.fromLTWH(8, 8, 8, 8), -4, 0);
    part(const Rect.fromLTWH(20, 20, 8, 12), -4, 8);
    part(const Rect.fromLTWH(44, 20, 4, 12), -8, 8);
    part(tall ? const Rect.fromLTWH(36, 52, 4, 12) : const Rect.fromLTWH(44, 20, 4, 12), 4, 8, flip: !tall);
    part(const Rect.fromLTWH(4, 20, 4, 12), -4, 20);
    part(tall ? const Rect.fromLTWH(20, 52, 4, 12) : const Rect.fromLTWH(4, 20, 4, 12), 0, 20, flip: !tall);
    part(const Rect.fromLTWH(40, 8, 8, 8), -4, 0);
  }

  void _text(Canvas canvas, String text, Offset at, double size, {Color color = const Color(0xFF404040), bool shadow = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: shadow ? mcTextStyle(size) : TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xA0101010));
    canvas
      ..save()
      ..translate(origin.dx, origin.dy)
      ..scale(scale);
    final panel = Rect.fromLTWH(0, 0, _Screen.width, screen.height);
    _drawPanel(canvas, panel);

    for (final (title, at) in screen.titles) {
      _text(canvas, title, at, 7);
    }
    final preview = screen.preview;
    if (preview != null) {
      _bevel(canvas, preview.inflate(1), Colors.black, _dark, Colors.white, 1);
      _drawSkin(canvas, preview);
    }
    final container = client.container;
    final arrow = screen.arrow;
    if (arrow != null) {
      final progress = container?.type == WindowType.furnace ? (container!.data[0] ?? 0) / 200 : 0.0;
      _drawArrow(canvas, arrow, progress);
    }
    final flame = screen.flame;
    if (flame != null && container != null) {
      final burn = container.data[1] ?? 0, max = container.data[2] ?? 0;
      _drawFlame(canvas, flame, max > 0 ? burn / max : (burn > 0 ? 1 : 0));
    }

    for (final r in screen.regions) {
      final cell = r.big ? r.rect.inflate(5) : r.rect.inflate(1);
      _bevel(canvas, cell, _slotFill, _dark, Colors.white, 1);
      final item = pack;
      switch (r.kind) {
        case _Kind.grid:
          final g = grid[r.index];
          if (g != null) {
            paintItem(canvas, r.rect, g, item, count: false);
            if (client.countInInventory(g) < 1) canvas.drawRect(r.rect, Paint()..color = const Color(0x808B8B8B));
          }
        case _Kind.result:
          final m = match;
          if (m != null) {
            paintItem(canvas, r.rect, m.recipe.result, item);
            if (!canCraft) canvas.drawRect(r.rect, Paint()..color = const Color(0xA08B8B8B));
          }
        case _Kind.armor:
        case _Kind.inventory:
        case _Kind.container:
          final ref = refOf(r);
          if (ref == null) {
            canvas.drawRect(r.rect, Paint()..color = const Color(0x40000000));
            continue;
          }
          final stack = client.itemAt(ref);
          final n = shown(ref);
          if (!stack.isEmpty && n > 0) {
            paintItem(canvas, r.rect, stack, item, shownCount: n);
          } else if (r.kind == _Kind.armor && item != null) {
            final tile = item.emptyArmorTile(r.index);
            if (tile >= 0) {
              drawSprite(canvas, item.atlas,
                  Rect.fromLTWH(item.tileX(tile), item.tileY(tile), tileSize.toDouble(), tileSize.toDouble()), r.rect,
                  paint: Paint()
                    ..filterQuality = FilterQuality.none
                    ..color = const Color(0x99FFFFFF));
            }
          }
          if (ref == from) {
            canvas.drawRect(r.rect, Paint()..color = const Color(0x80FFFFFF));
          }
          if (ref.window == ContainerIds.inventory && ref.index == client.hotbarSlotIndex(client.selectedHotbar)) {
            canvas.drawRect(
                r.rect.inflate(1),
                Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 0.7
                  ..color = Colors.white);
          }
      }
    }

    // Взятая стопка показывается над окном.
    final f = from;
    if (f != null) {
      final stack = client.itemAt(f);
      final at = Rect.fromLTWH(_Screen.width + 8, 8, 20, 20);
      _bevel(canvas, at.inflate(2), _panel, Colors.white, _shadow, 1);
      paintItem(canvas, at, stack, pack, shownCount: count);
    }
    canvas.restore();

    final h = hint;
    if (h != null) {
      final tp = TextPainter(text: TextSpan(text: h, style: mcTextStyle(16)), textDirection: TextDirection.ltr)..layout();
      final at = Offset((size.width - tp.width) / 2, origin.dy + screen.height * scale + 8);
      canvas.drawRect((at & tp.size).inflate(4), Paint()..color = const Color(0xCC100010));
      tp.paint(canvas, at);
    }
  }

  @override
  bool shouldRepaint(_InventoryPainter old) => true;
}
