import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'crypto.dart';
import 'packets.dart';
import 'skin.dart';

/// UUID версии 3 из ника: одинаковый при каждом входе с тем же ником.
String offlineUuid(String nickname) {
  final hash = MD5Digest().process(Uint8List.fromList(utf8.encode('OfflinePlayer:$nickname')));
  hash[6] = (hash[6] & 0x0f) | 0x30;
  hash[8] = (hash[8] & 0x3f) | 0x80;
  final hex = hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Проверка ника по правилам серверов 1.1: 3–16 символов, латиница, цифры, '_' и пробел.
String? validateNickname(String name) {
  if (name.length < 3 || name.length > 16) {
    return 'Ник должен быть от 3 до 16 символов';
  }
  if (!RegExp(r'^[A-Za-z0-9_ ]+$').hasMatch(name)) {
    return 'Допустимы только латинские буквы, цифры, «_» и пробел';
  }
  if (name.toLowerCase() == 'rcon' || name.toLowerCase() == 'console') {
    return 'Этот ник зарезервирован сервером';
  }
  return null;
}

class LoginData {
  LoginData({required this.packet, required this.key, required this.clientRandomId});

  final Uint8List packet;
  final IdentityKey key;
  final int clientRandomId;
}

/// Пакет входа без Xbox Live: цепочка из одного самоподписанного JWT.
LoginData createLogin({
  required String nickname,
  required String serverAddress,
  required SkinData skin,
  required String deviceModel,
  required String languageCode,
}) {
  final key = IdentityKey.generate();
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final rnd = Random.secure();
  final clientRandomId = rnd.nextInt(1 << 32) * 65536 + rnd.nextInt(65536);

  final identity = key.signJwt({
    'exp': now + 24 * 3600,
    'extraData': {
      'displayName': nickname,
      'identity': offlineUuid(nickname),
      'XUID': '',
    },
    'identityPublicKey': key.publicKeyDerBase64,
    'nbf': now - 60,
    'iat': now,
    'certificateAuthority': true,
  });
  final chain = utf8.encode(jsonEncode({
    'chain': [identity],
  }));

  final clientData = key.signJwt({
    'ClientRandomId': clientRandomId,
    'CurrentInputMode': 2,
    'DefaultInputMode': 2,
    'DeviceModel': deviceModel,
    'DeviceOS': 1,
    'GameVersion': mcpeVersion,
    'GuiScale': 0,
    'LanguageCode': languageCode,
    'ServerAddress': serverAddress,
    'SkinData': base64.encode(skin.rgba),
    'SkinId': skin.skinId,
    'TenantId': '',
    'UIProfile': 1,
  });

  return LoginData(
    packet: buildLoginPacket(Uint8List.fromList(chain), Uint8List.fromList(utf8.encode(clientData))),
    key: key,
    clientRandomId: clientRandomId,
  );
}
