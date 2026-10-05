import 'dart:convert';
import 'dart:typed_data';

class BinaryReader {
  BinaryReader(this.data, [this.offset = 0]);

  final Uint8List data;
  int offset;

  bool get eof => offset >= data.length;
  int get remaining => data.length - offset;

  void _need(int n) {
    if (offset + n > data.length) {
      throw FormatException('Недостаточно данных: нужно $n, осталось $remaining');
    }
  }

  int byte() {
    _need(1);
    return data[offset++];
  }

  bool boolean() => byte() != 0;

  Uint8List bytes(int n) {
    _need(n);
    final r = Uint8List.sublistView(data, offset, offset + n);
    offset += n;
    return r;
  }

  Uint8List rest() => bytes(remaining);

  void skip(int n) {
    _need(n);
    offset += n;
  }

  int shortBE() {
    _need(2);
    final v = (data[offset] << 8) | data[offset + 1];
    offset += 2;
    return v;
  }

  int shortLE() {
    _need(2);
    final v = data[offset] | (data[offset + 1] << 8);
    offset += 2;
    return v;
  }

  int triadLE() {
    _need(3);
    final v = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16);
    offset += 3;
    return v;
  }

  int intBE() {
    _need(4);
    final v = ByteData.sublistView(data, offset, offset + 4).getInt32(0, Endian.big);
    offset += 4;
    return v;
  }

  int intLE() {
    _need(4);
    final v = ByteData.sublistView(data, offset, offset + 4).getInt32(0, Endian.little);
    offset += 4;
    return v;
  }

  int longBE() {
    _need(8);
    final v = ByteData.sublistView(data, offset, offset + 8).getInt64(0, Endian.big);
    offset += 8;
    return v;
  }

  int longLE() {
    _need(8);
    final v = ByteData.sublistView(data, offset, offset + 8).getInt64(0, Endian.little);
    offset += 8;
    return v;
  }

  double floatLE() {
    _need(4);
    final v = ByteData.sublistView(data, offset, offset + 4).getFloat32(0, Endian.little);
    offset += 4;
    return v;
  }

  int uvarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (shift > 63) {
        throw const FormatException('Слишком длинный VarInt');
      }
      final b = byte();
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) {
        return result;
      }
      shift += 7;
    }
  }

  int varint() {
    final raw = uvarint();
    return (raw >>> 1) ^ -(raw & 1);
  }

  Uint8List byteArray() => bytes(uvarint());

  String string() => utf8.decode(byteArray(), allowMalformed: true);

  /// Строка RakNet: длина big-endian short.
  String rakString() => utf8.decode(bytes(shortBE()), allowMalformed: true);
}

class BinaryWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  int get length => _b.length;

  Uint8List take() => _b.takeBytes();

  void byte(int v) => _b.addByte(v & 0xff);

  void boolean(bool v) => byte(v ? 1 : 0);

  void bytes(List<int> v) => _b.add(v);

  void shortBE(int v) {
    byte(v >> 8);
    byte(v);
  }

  void shortLE(int v) {
    byte(v);
    byte(v >> 8);
  }

  void triadLE(int v) {
    byte(v);
    byte(v >> 8);
    byte(v >> 16);
  }

  void intBE(int v) {
    final d = ByteData(4)..setInt32(0, v, Endian.big);
    bytes(d.buffer.asUint8List());
  }

  void intLE(int v) {
    final d = ByteData(4)..setInt32(0, v, Endian.little);
    bytes(d.buffer.asUint8List());
  }

  void longBE(int v) {
    final d = ByteData(8)..setInt64(0, v, Endian.big);
    bytes(d.buffer.asUint8List());
  }

  void longLE(int v) {
    final d = ByteData(8)..setInt64(0, v, Endian.little);
    bytes(d.buffer.asUint8List());
  }

  void floatLE(double v) {
    final d = ByteData(4)..setFloat32(0, v, Endian.little);
    bytes(d.buffer.asUint8List());
  }

  void uvarint(int v) {
    var value = v;
    while (true) {
      if ((value & ~0x7f) == 0) {
        byte(value);
        return;
      }
      byte((value & 0x7f) | 0x80);
      value = value >>> 7;
    }
  }

  void varint(int v) => uvarint((v << 1) ^ (v >> 63));

  void byteArray(List<int> v) {
    uvarint(v.length);
    bytes(v);
  }

  void string(String v) => byteArray(utf8.encode(v));

  void rakString(String v) {
    final b = utf8.encode(v);
    shortBE(b.length);
    bytes(b);
  }
}
