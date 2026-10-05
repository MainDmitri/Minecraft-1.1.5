import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Скин в формате MCPE 1.1: RGBA 64x32 (8192 байт) или 64x64 (16384 байт).
class SkinData {
  SkinData(this.rgba, this.skinId);

  final Uint8List rgba;
  final String skinId;

  static const singleSize = 64 * 32 * 4;
  static const doubleSize = 64 * 64 * 4;

  bool get isValid => rgba.length == singleSize || rgba.length == doubleSize;

  int get height => rgba.length == doubleSize ? 64 : 32;

  /// Простой скин, сгенерированный клиентом (стандартная разметка 64x32, модель Steve).
  static SkinData generated() {
    final data = Uint8List(singleSize);

    void fill(int x0, int y0, int w, int h, int color) {
      for (var y = y0; y < y0 + h; y++) {
        for (var x = x0; x < x0 + w; x++) {
          final i = (y * 64 + x) * 4;
          data[i] = (color >> 16) & 0xff;
          data[i + 1] = (color >> 8) & 0xff;
          data[i + 2] = color & 0xff;
          data[i + 3] = 0xff;
        }
      }
    }

    const skinTone = 0xC58F6B;
    const hair = 0x3B2A1A;
    const shirt = 0x2E8BC0;
    const pants = 0x2B3A8C;
    const shoes = 0x404040;
    const eyeWhite = 0xFFFFFF;
    const eye = 0x3D59A8;

    // Голова (базовый слой, область 32x16).
    fill(0, 0, 32, 16, skinTone);
    fill(8, 0, 8, 8, hair); // верх
    fill(0, 8, 8, 3, hair); // правая сторона
    fill(16, 8, 8, 3, hair); // левая сторона
    fill(24, 8, 8, 8, hair); // затылок
    fill(8, 8, 8, 2, hair); // чёлка
    fill(9, 12, 2, 1, eyeWhite);
    fill(10, 12, 1, 1, eye);
    fill(13, 12, 2, 1, eyeWhite);
    fill(13, 12, 1, 1, eye);
    fill(11, 14, 2, 1, 0x8A5A44); // рот

    // Тело.
    fill(16, 16, 24, 16, shirt);
    // Руки: рукав сверху, кисти снизу.
    fill(40, 16, 16, 16, skinTone);
    fill(40, 20, 16, 4, shirt);
    fill(44, 16, 4, 4, shirt);
    // Ноги.
    fill(0, 16, 16, 16, pants);
    fill(0, 29, 16, 3, shoes);
    fill(8, 16, 4, 4, shoes);

    return SkinData(data, 'Standard_Custom');
  }

  /// Загрузка скина из PNG (64x32 или 64x64).
  static SkinData fromPng(Uint8List png) {
    final decoded = img.decodePng(png);
    if (decoded == null) {
      throw const FormatException('Файл не является PNG-изображением');
    }
    if (decoded.width != 64 || (decoded.height != 32 && decoded.height != 64)) {
      throw FormatException('Скин должен быть 64x32 или 64x64, а не ${decoded.width}x${decoded.height}');
    }
    final rgba = decoded.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
    final bytes = rgba.getBytes(order: img.ChannelOrder.rgba);
    return SkinData(Uint8List.fromList(bytes), 'Standard_Custom');
  }
}
