import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Префикс DER (SubjectPublicKeyInfo) для несжатого ключа secp384r1.
final Uint8List _p384SpkiPrefix = _hex('3076301006072a8648ce3d020106052b81040022036200');

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List bigIntToBytes(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

BigInt bytesToBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

SecureRandom createSecureRandom() {
  final rnd = Random.secure();
  final seed = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
  return FortunaRandom()..seed(KeyParameter(seed));
}

/// Base64 со стандартным алфавитом без '=' (так кодируют JWT серверы и клиенты MCPE 1.1).
String b64NoPad(List<int> data) => base64.encode(data).replaceAll('=', '');

Uint8List b64DecodeLoose(String s) {
  var t = s.trim().replaceAll('-', '+').replaceAll('_', '/');
  while (t.length % 4 != 0) {
    t += '=';
  }
  return base64.decode(t);
}

class IdentityKey {
  IdentityKey._(this.privateKey, this.publicKey);

  final ECPrivateKey privateKey;
  final ECPublicKey publicKey;

  static final ECDomainParameters domain = ECCurve_secp384r1();

  static IdentityKey generate() {
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(domain), createSecureRandom()));
    final pair = gen.generateKeyPair();
    return IdentityKey._(pair.privateKey, pair.publicKey);
  }

  /// Публичный ключ в DER (X.509 SubjectPublicKeyInfo), base64.
  String get publicKeyDerBase64 => base64.encode(encodePublicKeyDer(publicKey));

  static Uint8List encodePublicKeyDer(ECPublicKey key) {
    final q = key.Q!;
    final x = bigIntToBytes(q.x!.toBigInteger()!, 48);
    final y = bigIntToBytes(q.y!.toBigInteger()!, 48);
    return Uint8List.fromList([..._p384SpkiPrefix, 0x04, ...x, ...y]);
  }

  static ECPublicKey decodePublicKeyDer(Uint8List der) {
    if (der.length != _p384SpkiPrefix.length + 97) {
      throw const FormatException('Неподдерживаемый формат публичного ключа сервера');
    }
    for (var i = 0; i < _p384SpkiPrefix.length; i++) {
      if (der[i] != _p384SpkiPrefix[i]) {
        throw const FormatException('Публичный ключ сервера не на кривой secp384r1');
      }
    }
    final point = domain.curve.decodePoint(der.sublist(_p384SpkiPrefix.length));
    if (point == null) {
      throw const FormatException('Некорректная точка публичного ключа сервера');
    }
    return ECPublicKey(point, domain);
  }

  /// Подпись ES384 в формате JOSE (r || s, по 48 байт).
  Uint8List signEs384(Uint8List message) {
    final signer = Signer('SHA-384/ECDSA')
      ..init(true, ParametersWithRandom(PrivateKeyParameter<ECPrivateKey>(privateKey), createSecureRandom()));
    final sig = signer.generateSignature(message) as ECSignature;
    return Uint8List.fromList([...bigIntToBytes(sig.r, 48), ...bigIntToBytes(sig.s, 48)]);
  }

  /// JWT, подписанный этим ключом (заголовок с x5u как у клиента MCPE).
  String signJwt(Map<String, dynamic> payload) {
    final header = {'alg': 'ES384', 'x5u': publicKeyDerBase64};
    final signingInput = '${b64NoPad(utf8.encode(jsonEncode(header)))}.${b64NoPad(utf8.encode(jsonEncode(payload)))}';
    final signature = signEs384(Uint8List.fromList(utf8.encode(signingInput)));
    return '$signingInput.${b64NoPad(signature)}';
  }

  /// Общий секрет ECDH (координата X, 48 байт).
  Uint8List sharedSecret(ECPublicKey serverKey) {
    final agreement = ECDHBasicAgreement()..init(privateKey);
    return bigIntToBytes(agreement.calculateAgreement(serverKey), 48);
  }
}

Uint8List sha256(List<int> data) => SHA256Digest().process(Uint8List.fromList(data));

/// Шифрование пакетов MCPE: AES-256-CFB8 + контрольная сумма SHA-256 (8 байт).
class PacketCipher {
  PacketCipher(Uint8List key)
      : _key = key,
        _encrypt = _create(key, true),
        _decrypt = _create(key, false);

  final Uint8List _key;
  final CFBBlockCipher _encrypt;
  final CFBBlockCipher _decrypt;
  int _sendCounter = 0;
  int _receiveCounter = 0;

  static CFBBlockCipher _create(Uint8List key, bool forEncryption) {
    final iv = Uint8List.fromList(key.sublist(0, 16));
    return CFBBlockCipher(AESEngine(), 1)..init(forEncryption, ParametersWithIV(KeyParameter(key), iv));
  }

  /// Ключ = SHA-256(соль сервера || общий секрет ECDH).
  static PacketCipher fromHandshake(Uint8List salt, Uint8List sharedSecret) =>
      PacketCipher(sha256([...salt, ...sharedSecret]));

  Uint8List _checksum(int counter, Uint8List payload) {
    final counterBytes = ByteData(8)..setInt64(0, counter, Endian.little);
    final digest = sha256([...counterBytes.buffer.asUint8List(), ...payload, ..._key]);
    return Uint8List.sublistView(digest, 0, 8);
  }

  Uint8List _process(CFBBlockCipher cipher, Uint8List input) {
    final out = Uint8List(input.length);
    for (var i = 0; i < input.length; i++) {
      cipher.processBlock(input, i, out, i);
    }
    return out;
  }

  Uint8List encrypt(Uint8List payload) {
    final checksum = _checksum(_sendCounter++, payload);
    return _process(_encrypt, Uint8List.fromList([...payload, ...checksum]));
  }

  Uint8List decrypt(Uint8List data) {
    final plain = _process(_decrypt, data);
    if (plain.length < 8) {
      throw const FormatException('Слишком короткий зашифрованный пакет');
    }
    final payload = Uint8List.sublistView(plain, 0, plain.length - 8);
    final checksum = Uint8List.sublistView(plain, plain.length - 8);
    final expected = _checksum(_receiveCounter++, payload);
    for (var i = 0; i < 8; i++) {
      if (checksum[i] != expected[i]) {
        throw const FormatException('Неверная контрольная сумма зашифрованного пакета');
      }
    }
    return Uint8List.fromList(payload);
  }
}
