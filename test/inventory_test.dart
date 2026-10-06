import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcpe_client/game/crafting.dart';
import 'package:mcpe_client/game/mcpe_client.dart';
import 'package:mcpe_client/protocol/packets.dart';
import 'package:mcpe_client/protocol/skin.dart';
import 'package:mcpe_client/server/generator.dart';
import 'package:mcpe_client/server/local_server.dart';
import 'package:mcpe_client/server/world_storage.dart';

Future<void> pause(int ms) => Future.delayed(Duration(milliseconds: ms));

/// Ждать, пока значение станет ожидаемым (сервер отвечает не мгновенно).
Future<void> soon(Object? Function() value, Object? expected, {int ms = 5000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    final v = value();
    if (expected is Matcher ? expected.matches(v, {}) : v == expected) return;
    await pause(50);
  }
  expect(value(), expected);
}

McpeClient client(int port) =>
    McpeClient(host: '127.0.0.1', port: port, nickname: 'Steve', skin: SkinData.generated(), deviceModel: 'test', languageCode: 'ru_RU');

int slotOf(McpeClient c, int id) => c.inventory.take(36).toList().indexWhere((i) => i.id == id);

int total(McpeClient c, int id) => c.inventory.take(36).where((i) => i.id == id).fold(0, (n, i) => n + i.count);

ItemStack one(int id, [int meta = 0]) => ItemStack.simple(id, meta, 1);

/// Скрафтить по сетке и дождаться ответа сервера.
Future<void> craft(McpeClient c, List<ItemStack?> grid, int size) async {
  final m = matchRecipe(grid, size, c.recipes);
  expect(m, isNotNull, reason: 'рецепт для $grid');
  c.craft(m!);
}

/// Поставить блок из слота хотбара перед собой.
Future<BlockPosition> place(McpeClient c, int id, double yaw) async {
  final slot = slotOf(c, id);
  expect(slot, inInclusiveRange(0, 8));
  c.selectHotbar(slot);
  await pause(200);
  c.player
    ..yaw = yaw
    ..pitch = 50;
  final hit = c.player.raycast(c.level, 5)!;
  final at = hit.adjacent;
  c.useItemOnBlock();
  await soon(() => c.level.blockId(at.x, at.y, at.z), id);
  return BlockPosition(at.x, at.y, at.z);
}

class BlockPosition {
  BlockPosition(this.x, this.y, this.z);

  final int x, y, z;
}

void main() {
  test('Инвентарь: крафт 2×2 и 3×3, перенос, броня, сундук, печь, выброс и подбор', () async {
    final dir = await Directory.systemTemp.createTemp('mcpe_inv');
    addTearDown(() => dir.delete(recursive: true));
    final storage = WorldStorage(dir);
    final (sx, sy, sz) = TerrainGenerator(777).findSpawn();
    storage.writeMeta(WorldMeta(name: 'Инвентарь', seed: 777, gamemode: 0, spawnX: sx, spawnY: sy, spawnZ: sz, time: 1000));
    final server = LocalServer(storage: storage, lan: false);
    final port = await server.start();

    final c = client(port);
    await c.connect();
    await soon(() => c.recipes, isNotEmpty);

    // Доски из бревна в сетке 2×2: сервер забирает бревно и выдаёт 4 доски.
    c.sendMessage('/give 17 3');
    await soon(() => total(c, 17), 3);
    for (var i = 0; i < 3; i++) {
      await craft(c, [one(17), null, null, null], 2);
    }
    await soon(() => total(c, 17), 0);
    await soon(() => total(c, 5), 12);

    // Верстак и палки.
    await craft(c, [one(5), one(5), one(5), one(5)], 2);
    await soon(() => total(c, 58), 1);
    await soon(() => total(c, 5), 8);
    await craft(c, [one(5), null, one(5), null], 2);
    await soon(() => total(c, 280), 4);
    await soon(() => total(c, 5), 6);

    // Рецепт 3×3 без верстака сервер не принимает.
    final pickaxeGrid = [one(5), one(5), one(5), null, one(280), null, null, one(280), null];
    expect(matchRecipe(pickaxeGrid, 2, c.recipes), isNull);
    final pickaxe = matchRecipe(pickaxeGrid, 3, c.recipes)!;
    c.craft(pickaxe);
    await pause(800);
    expect(total(c, 270), 0);

    // Ставим верстак, нажимаем на него — открывается сетка 3×3, кирка крафтится.
    await place(c, 58, 0);
    c.player.pitch = 50;
    c.useItemOnBlock();
    await soon(() => c.container?.type, WindowType.workbench);
    c.craft(pickaxe);
    await soon(() => total(c, 270), 1);
    await soon(() => total(c, 5), 3);
    await soon(() => total(c, 280), 2);
    c.closeContainer();

    // Перенос стопки: палки в слот 20.
    final sticks = slotOf(c, 280);
    c.setSlots([
      (SlotRef(0, sticks), ItemStack.empty),
      (SlotRef(0, 20), c.inventory[sticks]),
    ]);
    await soon(() => c.inventory[20].id, 280);
    expect(c.inventory[sticks].isEmpty, isTrue);

    // Броня: шлем в слот брони.
    c.sendMessage('/give 306');
    await soon(() => slotOf(c, 306) >= 0, true);
    final helmet = slotOf(c, 306);
    c.setSlots([
      (SlotRef(0, helmet), ItemStack.empty),
      (const SlotRef(ContainerIds.armor, 0), c.inventory[helmet]),
    ]);
    await soon(() => c.armor[0].id, 306);
    expect(total(c, 306), 0);

    // Сундук: кладём палки, закрываем, открываем снова — они на месте.
    c.sendMessage('/give 54');
    await soon(() => slotOf(c, 54) >= 0, true);
    await place(c, 54, 90);
    c.player.pitch = 50;
    c.useItemOnBlock();
    await pause(400);
    await soon(() => c.container?.type, WindowType.container);
    final chest = c.container!;
    expect(chest.type, WindowType.container);
    expect(chest.slots, hasLength(27));
    c.setSlots([
      (const SlotRef(0, 20), ItemStack.empty),
      (SlotRef(chest.windowId, 0), c.inventory[20]),
    ]);
    await pause(400);
    c.closeContainer();
    await pause(200);
    c.useItemOnBlock();
    await soon(() => c.container?.slots[0].id, 280);
    expect(c.container!.slots[0].count, 2);
    c.closeContainer();

    // Печь: булыжник + уголь → камень за 10 секунд.
    c.sendMessage('/give 61');
    c.sendMessage('/give 4 1');
    c.sendMessage('/give 263 1');
    await soon(() => [61, 4, 263].every((id) => slotOf(c, id) >= 0), true);
    await place(c, 61, 180);
    c.player.pitch = 50;
    c.useItemOnBlock();
    await pause(400);
    await soon(() => c.container?.type, WindowType.furnace);
    final furnace = c.container!;
    expect(furnace.type, WindowType.furnace);
    final cobble = slotOf(c, 4), coal = slotOf(c, 263);
    c.setSlots([
      (SlotRef(0, cobble), ItemStack.empty),
      (SlotRef(furnace.windowId, 0), c.inventory[cobble]),
    ]);
    c.setSlots([
      (SlotRef(0, coal), ItemStack.empty),
      (SlotRef(furnace.windowId, 1), c.inventory[coal]),
    ]);
    await soon(() => c.container!.slots[2].id, 1, ms: 15000);
    expect(c.container!.slots[0].isEmpty, isTrue);
    expect(c.container!.data[1], greaterThan(0));
    // Забираем камень в инвентарь.
    c.setSlots([
      (SlotRef(furnace.windowId, 2), ItemStack.empty),
      (const SlotRef(0, 30), c.container!.slots[2]),
    ]);
    await soon(() => total(c, 1), 1);
    c.closeContainer();

    // Выброс кирки: она появляется в мире, а через 2 секунды подбирается обратно.
    final pick = slotOf(c, 270);
    c.dropSlot(pick);
    expect(total(c, 270), 0);
    await soon(() => c.itemEntities.values.map((e) => e.item.id).toList(), contains(270));
    await soon(() => total(c, 270), 1, ms: 8000);
    expect(c.itemEntities.values.where((e) => e.item.id == 270), isEmpty);

    c.dispose();
    await pause(300);
    await server.stop();

    // После перезапуска броня и содержимое сундука сохранены.
    final server2 = LocalServer(storage: storage, lan: false);
    final c2 = client(await server2.start());
    await c2.connect();
    await soon(() => c2.armor[0].id, 306);
    expect(total(c2, 270), 1);
    c2.dispose();
    await server2.stop();
    final containers = storage.readContainers();
    expect(containers.values.any((v) => ((v as Map)['items'] as List).any((i) => (i as List)[0] == 280)), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
