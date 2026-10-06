import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcpe_client/game/mcpe_client.dart';
import 'package:mcpe_client/protocol/raknet.dart';
import 'package:mcpe_client/protocol/skin.dart';
import 'package:mcpe_client/server/generator.dart';
import 'package:mcpe_client/server/local_server.dart';
import 'package:mcpe_client/server/world_storage.dart';

Future<void> pause(int ms) => Future.delayed(Duration(milliseconds: ms));

McpeClient client(int port, String name) =>
    McpeClient(host: '127.0.0.1', port: port, nickname: name, skin: SkinData.generated(), deviceModel: 'test', languageCode: 'ru_RU');

void main() {
  test('Встроенный сервер: вход двух игроков, чат, блоки, сохранение', () async {
    final dir = await Directory.systemTemp.createTemp('mcpe_world');
    addTearDown(() => dir.delete(recursive: true));
    final storage = WorldStorage(dir);
    final (sx, sy, sz) = TerrainGenerator(4242).findSpawn();
    storage.writeMeta(WorldMeta(name: 'Тест', seed: 4242, gamemode: 1, spawnX: sx, spawnY: sy, spawnZ: sz, time: 1000));

    final server = LocalServer(storage: storage, lan: false);
    final port = await server.start();
    final status = await queryServer('127.0.0.1', port);
    expect(status.protocol, 113);
    expect(status.motd, 'Тест');

    final a = client(port, 'Alice');
    await a.connect();
    expect(a.phase, ConnectionPhase.playing);
    expect(a.gamemode, 1);
    expect(a.creativeItems, isNotEmpty);

    final b = client(port, 'Bob');
    await b.connect();
    await pause(1000);
    expect(a.remotePlayers.values.map((p) => p.name), contains('Bob'));
    expect(b.remotePlayers.values.map((p) => p.name), contains('Alice'));

    a.sendMessage('привет');
    await pause(500);
    expect(b.chat.map((l) => l.text), contains('<Alice> привет'));

    // Alice ставит кирпич, Bob видит его.
    a.takeCreativeItem(a.creativeItems.firstWhere((i) => i.id == 45));
    await pause(300);
    a.player
      ..pitch = 40
      ..yaw = 0;
    final hit = a.player.raycast(a.level, 7)!;
    final target = hit.adjacent;
    a.useItemOnBlock();
    await pause(700);
    expect(a.level.blockId(target.x, target.y, target.z), 45);
    expect(b.level.blockId(target.x, target.y, target.z), 45);

    // Bob в выживании ломает блок под собой; предмет выпадает и его подбирает кто-то из стоящих рядом.
    b.sendMessage('/gamemode 0');
    await pause(500);
    b.player.pitch = 89;
    final under = b.player.raycast(b.level, 5)!.block;
    b.setBreaking(true);
    await pause(2500);
    b.setBreaking(false);
    await pause(500);
    expect(a.level.blockId(under.x, under.y, under.z), 0);
    final picked = [...a.inventory, ...b.inventory].where((i) => i.id == 3);
    expect(picked, isNotEmpty);

    b.dispose();
    a.dispose();
    await pause(300);
    await server.stop();

    // После перезапуска блок на месте.
    final server2 = LocalServer(storage: storage, lan: false);
    final port2 = await server2.start();
    final c = client(port2, 'Alice');
    await c.connect();
    await pause(500);
    expect(c.level.blockId(target.x, target.y, target.z), 45);
    c.dispose();
    await server2.stop();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
