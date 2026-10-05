import 'package:flutter/material.dart';

/// Цвета форматирования Minecraft (§0–§f).
const Map<String, Color> _mcColors = {
  '0': Color(0xFF000000),
  '1': Color(0xFF0000AA),
  '2': Color(0xFF00AA00),
  '3': Color(0xFF00AAAA),
  '4': Color(0xFFAA0000),
  '5': Color(0xFFAA00AA),
  '6': Color(0xFFFFAA00),
  '7': Color(0xFFAAAAAA),
  '8': Color(0xFF555555),
  '9': Color(0xFF5555FF),
  'a': Color(0xFF55FF55),
  'b': Color(0xFF55FFFF),
  'c': Color(0xFFFF5555),
  'd': Color(0xFFFF55FF),
  'e': Color(0xFFFFFF55),
  'f': Color(0xFFFFFFFF),
};

/// Убирает коды форматирования.
String stripFormatting(String s) => s.replaceAll(RegExp(r'§.?'), '');

List<TextSpan> _parse(String text, TextStyle base) {
  final spans = <TextSpan>[];
  var style = base;
  final buf = StringBuffer();

  void flush() {
    if (buf.isEmpty) return;
    spans.add(TextSpan(text: buf.toString(), style: style));
    buf.clear();
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == '§' && i + 1 < text.length) {
      final code = text[i + 1].toLowerCase();
      i++;
      flush();
      final color = _mcColors[code];
      if (color != null) {
        style = base.copyWith(color: color);
      } else if (code == 'l') {
        style = style.copyWith(fontWeight: FontWeight.bold);
      } else if (code == 'o') {
        style = style.copyWith(fontStyle: FontStyle.italic);
      } else if (code == 'n') {
        style = style.copyWith(decoration: TextDecoration.underline);
      } else if (code == 'm') {
        style = style.copyWith(decoration: TextDecoration.lineThrough);
      } else if (code == 'r') {
        style = base;
      }
      continue;
    }
    buf.write(ch);
  }
  flush();
  return spans;
}

class McText extends StatelessWidget {
  const McText(this.text, {super.key, this.style, this.textAlign = TextAlign.start, this.maxLines});

  final String text;
  final TextStyle? style;
  final TextAlign textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    return Text.rich(
      TextSpan(children: _parse(text, base)),
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}
