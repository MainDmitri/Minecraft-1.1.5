import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcpe_client/protocol/binary.dart';
import 'package:mcpe_client/world/mesher.dart';
import 'package:mcpe_client/world/player.dart';
import 'package:mcpe_client/world/world.dart';

/// Данные FullChunkData протокола 113: одна секция, пол из камня на высоте 0..3.
Uint8List chunkWithFloor() {
  final ids = Uint8List(4096);
  for (var x = 0; x < 16; x++) {
    for (var z = 0; z < 16; z++) {
      for (var y = 0; y < 4; y++) {
        ids[(x << 8) | (z << 4) | y] = 1;
      }
    }
  }
  final w = BinaryWriter()
    ..byte(1)
    ..byte(0)
    ..bytes(ids)
    ..bytes(Uint8List(2048))
    ..bytes(Uint8List(4096))
    ..bytes(Uint8List(512))
    ..bytes(Uint8List(256))
    ..byte(0)
    ..varint(0);
  return w.take();
}

World flatWorld() {
  final world = World();
  for (var cx = -1; cx <= 1; cx++) {
    for (var cz = -1; cz <= 1; cz++) {
      world.putChunk(Chunk.parse(cx, cz, chunkWithFloor()));
    }
  }
  return world;
}

void main() {
  test('Разбор чанка и изменение блоков', () {
    final world = flatWorld();
    expect(world.blockId(5, 3, 7), 1);
    expect(world.blockId(5, 4, 7), 0);
    expect(world.blockId(-3, 0, -9), 1);
    world.setBlock(5, 10, 7, 20, 0);
    expect(world.blockId(5, 10, 7), 20);
    expect(world.dirtySections, contains(World.sectionKey(0, 0, 0)));
  });

  test('Сетка: одиночный блок даёт 6 граней, пол — только верх', () {
    final world = World();
    final chunk = Chunk(0, 0)..set(8, 8, 8, 1, 0);
    world.putChunk(chunk);
    expect(buildSectionMesh(world, 0, 0, 0)!.count, 6);

    final flat = flatWorld();
    final mesh = buildSectionMesh(flat, 0, 0, 0)!;
    // Верх пола 16x16; нижние грани на y=0 и боковые на границе с загруженными соседями скрыты.
    expect(mesh.count, 256);
  });

  test('Физика: падение на пол, стена, луч', () {
    final world = flatWorld();
    final p = PlayerController()
      ..x = 8.5
      ..y = 10
      ..z = 8.5;
    for (var i = 0; i < 60; i++) {
      p.tick(world);
    }
    expect(p.y, closeTo(4, 1e-6));
    expect(p.onGround, isTrue);

    // Стена высотой 2 блока на z = 11: игрок упирается в неё.
    for (var x = 0; x < 16; x++) {
      world.setBlock(x, 4, 11, 1, 0);
      world.setBlock(x, 5, 11, 1, 0);
    }
    p.forward = 1;
    for (var i = 0; i < 40; i++) {
      p.tick(world);
    }
    expect(p.z, closeTo(10.7, 0.06));

    p
      ..forward = 0
      ..pitch = 90;
    final hit = p.raycast(world, 5)!;
    expect(hit.block.y, 3);
    expect(hit.face, 1);
    expect(hit.adjacent.y, 4);
  });
}
