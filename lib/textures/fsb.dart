import 'dart:typed_data';

/// Звук из контейнера FMOD FSB5 с кодеком FADPCM (так хранятся звуки MCPE 1.1).
class FsbSound {
  FsbSound(this.samples, this.sampleRate, this.channels);

  /// 16-битные отсчёты, для стерео — чередуются по каналам.
  final Int16List samples;
  final int sampleRate;
  final int channels;

  /// WAV (PCM 16 бит).
  Uint8List toWav() {
    final dataSize = samples.length * 2;
    final b = ByteData(44 + dataSize);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    b.setUint32(4, 36 + dataSize, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little);
    b.setUint16(22, channels, Endian.little);
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * channels * 2, Endian.little);
    b.setUint16(32, channels * 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    b.setUint32(40, dataSize, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      b.setInt16(44 + i * 2, samples[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }
}

const List<List<int>> _fadpcmCoefs = [
  [0, 0],
  [60, 0],
  [122, 60],
  [115, 52],
  [98, 55],
  [0, 0],
  [0, 0],
  [0, 0],
];

const List<int> _rates = [4000, 8000, 11000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 96000];

/// Разбор FSB5 (первый звук в файле) и декодирование FADPCM.
FsbSound decodeFsb5(Uint8List data) {
  final b = ByteData.sublistView(data);
  if (data.length < 0x40 || String.fromCharCodes(data.sublist(0, 4)) != 'FSB5') {
    throw const FormatException('Не FSB5');
  }
  final version = b.getUint32(4, Endian.little);
  final count = b.getUint32(8, Endian.little);
  final sampleHeaderSize = b.getUint32(0x0c, Endian.little);
  final nameTableSize = b.getUint32(0x10, Endian.little);
  final codec = b.getUint32(0x18, Endian.little);
  if (count < 1) throw const FormatException('В FSB5 нет звуков');
  if (codec != 16) throw FormatException('Кодек FSB5 $codec не поддерживается (нужен FADPCM)');
  final baseHeaderSize = version == 1 ? 0x3c : 0x40;

  final mode = b.getUint64(baseHeaderSize, Endian.little);
  final numSamples = (mode >> 34) & 0x3fffffff;
  final dataOffset = ((mode >> 7) & 0x07ffffff) << 5;
  var channels = const [1, 2, 6, 8][(mode >> 5) & 3];
  final rateIndex = (mode >> 1) & 0x0f;
  var rate = rateIndex < _rates.length ? _rates[rateIndex] : 44100;
  if (mode & 1 != 0) {
    var off = baseHeaderSize + 8;
    final max = baseHeaderSize + sampleHeaderSize;
    while (off < max) {
      final flag = b.getUint32(off, Endian.little);
      final type = (flag >> 25) & 0x7f;
      final size = (flag >> 1) & 0xffffff;
      if (type == 1) channels = data[off + 4];
      if (type == 2) rate = b.getInt32(off + 4, Endian.little);
      if (flag & 1 == 0) break;
      off += 4 + size;
    }
  }

  final start = baseHeaderSize + sampleHeaderSize + nameTableSize + dataOffset;
  const frameSize = 0x8c, frameSamples = 256;
  final out = Int16List(numSamples * channels);
  final frames = (numSamples + frameSamples - 1) ~/ frameSamples;
  for (var f = 0; f < frames; f++) {
    for (var ch = 0; ch < channels; ch++) {
      final fo = start + (f * channels + ch) * frameSize;
      if (fo + frameSize > data.length) break;
      final coefs = b.getUint32(fo, Endian.little);
      final shifts = b.getUint32(fo + 4, Endian.little);
      var hist1 = b.getInt16(fo + 8, Endian.little);
      var hist2 = b.getInt16(fo + 10, Endian.little);
      var n = f * frameSamples;
      for (var i = 0; i < 8; i++) {
        final index = ((coefs >> (i * 4)) & 0x0f) % 7;
        final shift = 22 - ((shifts >> (i * 4)) & 0x0f);
        final c1 = _fadpcmCoefs[index][0], c2 = _fadpcmCoefs[index][1];
        for (var j = 0; j < 4; j++) {
          final nibbles = b.getUint32(fo + 0x0c + 0x10 * i + 4 * j, Endian.little);
          for (var k = 0; k < 8; k++) {
            var s = (nibbles >> (k * 4)) & 0x0f;
            s = ((s << 28).toSigned(32)) >> shift;
            s = (s - hist2 * c2 + hist1 * c1) >> 6;
            if (s > 32767) s = 32767;
            if (s < -32768) s = -32768;
            if (n < numSamples) out[n * channels + ch] = s;
            n++;
            hist2 = hist1;
            hist1 = s;
          }
        }
      }
    }
  }
  return FsbSound(out, rate, channels);
}
