import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mcpe_client/game/commands.dart';
import 'package:mcpe_client/game/lang.dart';
import 'package:mcpe_client/protocol/binary.dart';
import 'package:mcpe_client/protocol/crypto.dart';
import 'package:mcpe_client/protocol/login.dart';
import 'package:mcpe_client/protocol/skin.dart';

void main() {
  test('VarInt / VarLong кодируются и читаются обратно', () {
    const values = [0, 1, -1, 63, -64, 300, -300, 2147483647, -2147483648, 1 << 40, -(1 << 40)];
    final w = BinaryWriter();
    for (final v in values) {
      w.varint(v);
      w.uvarint(v.abs());
    }
    final r = BinaryReader(w.take());
    for (final v in values) {
      expect(r.varint(), v);
      expect(r.uvarint(), v.abs());
    }
    expect(r.eof, isTrue);
  });

  test('Команды: выбор перегрузки и JSON аргументов', () {
    final registry = CommandRegistry()
      ..load(jsonEncode({
        'time': {
          'versions': [
            {
              'aliases': <String>[],
              'description': 'Время',
              'overloads': {
                '1arg': {
                  'input': {
                    'parameters': [
                      {'name': 'start|stop', 'type': 'string', 'optional': false},
                    ],
                  },
                },
                '2args': {
                  'input': {
                    'parameters': [
                      {'name': 'add|set', 'type': 'string', 'optional': false},
                      {'name': 'value', 'type': 'int', 'optional': false},
                    ],
                  },
                },
              },
            },
          ],
        },
        'tp': {
          'versions': [
            {
              'aliases': ['teleport'],
              'overloads': {
                'default': {
                  'input': {
                    'parameters': [
                      {'name': 'player', 'type': 'target', 'optional': true},
                      {'name': 'destination', 'type': 'blockpos', 'optional': false},
                    ],
                  },
                },
              },
            },
          ],
        },
      }));

    final time = registry.parse('/time set 1000');
    expect(time.command, 'time');
    expect(time.overload, '2args');
    expect(jsonDecode(time.inputJson), {'add|set': 'set', 'value': 1000});

    final tp = registry.parse('/teleport Steve 10 64 -5');
    expect(tp.command, 'tp');
    expect(jsonDecode(tp.inputJson), {
      'player': {
        'rules': [
          {'inverted': false, 'name': 'name', 'value': 'Steve'},
        ],
        'selector': 'nearestPlayer',
      },
      'destination': {'x': 10, 'y': 64, 'z': -5},
    });

    expect(() => registry.parse('/time set abc'), throwsA(isA<CommandParseException>()));
    expect(registry.parse('/unknown a b').inputJson, '{"args":"a b"}');
  });

  test('Перевод ключей сервера', () {
    expect(translate('%multiplayer.player.joined', ['Steve']), 'Steve заходит в игру');
    expect(translate('§e%multiplayer.player.left', ['Alex']), '§eAlex выходит из игры');
    expect(translate('chat.type.text', ['A', 'привет']), '<A> привет');
  });

  test('Ник и UUID', () {
    expect(validateNickname('Steve_1'), isNull);
    expect(validateNickname('ab'), isNotNull);
    expect(validateNickname('Стив'), isNotNull);
    expect(offlineUuid('Steve'), offlineUuid('Steve'));
    expect(offlineUuid('Steve'), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-3[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
  });

  test('Скин: генерация и загрузка PNG', () {
    expect(SkinData.generated().isValid, isTrue);
    final image = img.Image(width: 64, height: 64, numChannels: 4);
    image.setPixelRgba(1, 2, 10, 20, 30, 255);
    final skin = SkinData.fromPng(Uint8List.fromList(img.encodePng(image)));
    expect(skin.rgba.length, SkinData.doubleSize);
    final i = (2 * 64 + 1) * 4;
    expect(skin.rgba.sublist(i, i + 4), [10, 20, 30, 255]);
    expect(() => SkinData.fromPng(Uint8List.fromList(img.encodePng(img.Image(width: 32, height: 32)))),
        throwsA(isA<FormatException>()));
  });

  test('ECDH и шифрование пакетов в обе стороны', () {
    final client = IdentityKey.generate();
    final server = IdentityKey.generate();
    final serverPub = IdentityKey.decodePublicKeyDer(base64.decode(server.publicKeyDerBase64));
    final clientPub = IdentityKey.decodePublicKeyDer(base64.decode(client.publicKeyDerBase64));
    final secretClient = client.sharedSecret(serverPub);
    expect(secretClient, server.sharedSecret(clientPub));

    final salt = Uint8List.fromList(List.generate(16, (i) => i));
    final a = PacketCipher.fromHandshake(salt, secretClient);
    final b = PacketCipher.fromHandshake(salt, secretClient);
    for (var n = 0; n < 3; n++) {
      final payload = Uint8List.fromList(List.generate(500 + n, (i) => (i * 31 + n) & 0xff));
      expect(b.decrypt(a.encrypt(payload)), payload);
    }
    final tampered = a.encrypt(Uint8List.fromList([1, 2, 3]));
    tampered[0] ^= 0xff;
    expect(() => b.decrypt(tampered), throwsA(isA<FormatException>()));
  });
}
