import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/texture_store.dart';

import '../textures/texture_pack.dart';

/// Области спрайтов в gui.png и icons.png ресурс-пака MCPE 1.1.
class GuiSprites {
  static const hotbar = Rect.fromLTWH(0, 0, 182, 22);
  static const hotbarSelection = Rect.fromLTWH(0, 22, 24, 24);
  static const buttonDisabled = Rect.fromLTWH(0, 46, 200, 20);
  static const button = Rect.fromLTWH(0, 66, 200, 20);
  static const buttonPressed = Rect.fromLTWH(0, 86, 200, 20);
  static const dpadUp = Rect.fromLTWH(2, 109, 22, 22);
  static const dpadLeft = Rect.fromLTWH(28, 109, 22, 22);
  static const dpadDown = Rect.fromLTWH(54, 109, 22, 22);
  static const dpadRight = Rect.fromLTWH(80, 109, 22, 22);
  static const jump = Rect.fromLTWH(108, 111, 18, 18);
  static const flyDown = Rect.fromLTWH(6, 139, 18, 18);
  static const pause = Rect.fromLTWH(200, 64, 18, 18);
  static const chat = Rect.fromLTWH(200, 82, 18, 18);

  static const crosshair = Rect.fromLTWH(0, 0, 15, 15);
  static const heartEmpty = Rect.fromLTWH(16, 0, 9, 9);
  static const heartFull = Rect.fromLTWH(52, 0, 9, 9);
  static const heartHalf = Rect.fromLTWH(61, 0, 9, 9);
  static const foodEmpty = Rect.fromLTWH(16, 27, 9, 9);
  static const foodFull = Rect.fromLTWH(52, 27, 9, 9);
  static const foodHalf = Rect.fromLTWH(61, 27, 9, 9);
}

final Paint _pixelPaint = Paint()
  ..filterQuality = FilterQuality.none
  ..isAntiAlias = false;

void drawSprite(Canvas canvas, ui.Image image, Rect src, Rect dst, {Paint? paint}) =>
    canvas.drawImageRect(image, src, dst, paint ?? _pixelPaint);

/// Текст в стиле Minecraft: белый с тёмной тенью.
TextStyle mcTextStyle(double size, {Color color = Colors.white}) => TextStyle(
      color: color,
      fontSize: size,
      fontWeight: FontWeight.w600,
      shadows: const [Shadow(offset: Offset(1.5, 1.5), color: Color(0xFF3F3F3F))],
    );

class _ButtonPainter extends CustomPainter {
  _ButtonPainter(this.gui, this.pressed, this.enabled);

  final ui.Image? gui;
  final bool pressed;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final image = gui;
    if (image == null) {
      final rect = Offset.zero & size;
      canvas.drawRect(rect, Paint()..color = pressed ? const Color(0xFF7A85C8) : const Color(0xFF6F6F6F));
      canvas.drawRect(rect, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black);
      return;
    }
    final src = !enabled ? GuiSprites.buttonDisabled : (pressed ? GuiSprites.buttonPressed : GuiSprites.button);
    // Кнопка растягивается по ширине из двух половин спрайта, как в игре.
    final half = size.width / 2;
    final srcHalfW = src.width / 2;
    final scale = size.height / src.height;
    final take = (half / scale).clamp(2.0, srcHalfW);
    drawSprite(canvas, image, Rect.fromLTWH(src.left, src.top, take, src.height), Rect.fromLTWH(0, 0, half, size.height));
    drawSprite(canvas, image, Rect.fromLTWH(src.right - take, src.top, take, src.height),
        Rect.fromLTWH(half, 0, size.width - half, size.height));
  }

  @override
  bool shouldRepaint(_ButtonPainter old) => old.gui != gui || old.pressed != pressed || old.enabled != enabled;
}

/// Кнопка в стиле Minecraft (спрайт из gui.png, если текстуры загружены).
class McButton extends StatefulWidget {
  const McButton({super.key, required this.label, required this.onTap, required this.pack, this.width = 320});

  final String label;
  final VoidCallback? onTap;
  final TexturePack? pack;
  final double width;

  @override
  State<McButton> createState() => _McButtonState();
}

class _McButtonState extends State<McButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: enabled
          ? (_) {
              setState(() => _pressed = false);
              context.read<TextureStore>().sounds?.click();
              widget.onTap!();
            }
          : null,
      child: SizedBox(
        width: widget.width,
        height: 40,
        child: CustomPaint(
          painter: _ButtonPainter(widget.pack?.gui, _pressed, enabled),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  widget.label,
                  maxLines: 1,
                  style: mcTextStyle(16, color: enabled ? (_pressed ? const Color(0xFFFFFFA0) : Colors.white) : Colors.grey),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DirtPainter extends CustomPainter {
  _DirtPainter(this.pack);

  final TexturePack? pack;

  @override
  void paint(Canvas canvas, Size size) {
    final p = pack;
    final tile = p?.tile(3, 0, 3) ?? -1;
    if (p == null || tile < 0) {
      canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF3B2A1E));
      return;
    }
    const cell = 64.0;
    final src = Rect.fromLTWH(p.tileX(tile), p.tileY(tile), tileSize.toDouble(), tileSize.toDouble());
    final paint = Paint()
      ..filterQuality = FilterQuality.none
      ..colorFilter = const ColorFilter.mode(Color(0xFF404040), BlendMode.modulate);
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        canvas.drawImageRect(p.atlas, src, Rect.fromLTWH(x, y, cell, cell), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DirtPainter old) => old.pack != pack;
}

/// Фон меню из блоков земли, как в Minecraft.
class McDirtBackground extends StatelessWidget {
  const McDirtBackground({super.key, required this.pack, required this.child});

  final TexturePack? pack;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _DirtPainter(pack), child: child);
}
