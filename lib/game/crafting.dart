import 'dart:typed_data';

import '../protocol/binary.dart';
import '../protocol/packets.dart';

/// Мета «любая» в ингредиентах рецептов.
const int anyMeta = 0x7fff;

class RecipeType {
  static const shapeless = 0;
  static const shaped = 1;
  static const furnace = 2;
  static const furnaceData = 3;
  static const multi = 4;
  static const shulkerBox = 5;
}

/// Рецепт из CraftingDataPacket.
class CraftingRecipe {
  CraftingRecipe({
    required this.type,
    required this.width,
    required this.height,
    required this.inputs,
    required this.outputs,
    required this.uuid,
  });

  final int type;

  /// Для фигурного рецепта — размер, для бесформенного — 0.
  final int width;
  final int height;

  /// Фигурный: width × height ячеек (воздух — пустая ячейка); бесформенный: список ингредиентов.
  final List<ItemStack> inputs;
  final List<ItemStack> outputs;
  final Uint8List uuid;

  bool get shaped => type == RecipeType.shaped;

  /// Нужен ли верстак 3×3.
  bool get big => shaped ? (width > 2 || height > 2) : inputs.fold<int>(0, (n, i) => n + i.count) > 4;

  ItemStack get result => outputs.isEmpty ? ItemStack.empty : outputs.first;
}

/// Рецепт печи: вход (мета −1 — любая) → результат.
class FurnaceRecipe {
  FurnaceRecipe(this.inputId, this.inputMeta, this.output);

  final int inputId;
  final int inputMeta;
  final ItemStack output;
}

class CraftingData {
  CraftingData(this.recipes, this.furnace);

  final List<CraftingRecipe> recipes;
  final List<FurnaceRecipe> furnace;
}

CraftingData readCraftingData(BinaryReader r) {
  final recipes = <CraftingRecipe>[];
  final furnace = <FurnaceRecipe>[];
  final count = r.uvarint();
  for (var i = 0; i < count; i++) {
    final type = r.varint();
    switch (type) {
      case RecipeType.shapeless:
      case RecipeType.shulkerBox:
        final inputs = [for (var n = r.uvarint(), k = 0; k < n; k++) readItem(r)];
        final outputs = [for (var n = r.uvarint(), k = 0; k < n; k++) readItem(r)];
        recipes.add(CraftingRecipe(type: type, width: 0, height: 0, inputs: inputs, outputs: outputs, uuid: r.bytes(16)));
      case RecipeType.shaped:
        final w = r.varint(), h = r.varint();
        final inputs = [for (var k = 0; k < w * h; k++) readItem(r)];
        final outputs = [for (var n = r.uvarint(), k = 0; k < n; k++) readItem(r)];
        recipes.add(CraftingRecipe(type: type, width: w, height: h, inputs: inputs, outputs: outputs, uuid: r.bytes(16)));
      case RecipeType.furnace:
        final id = r.varint();
        furnace.add(FurnaceRecipe(id, -1, readItem(r)));
      case RecipeType.furnaceData:
        final id = r.varint(), meta = r.varint();
        furnace.add(FurnaceRecipe(id, meta, readItem(r)));
      case RecipeType.multi:
        r.bytes(16);
      default:
        // Неизвестный тип — дальше разобрать нельзя.
        return CraftingData(recipes, furnace);
    }
  }
  return CraftingData(recipes, furnace);
}

bool ingredientMatches(ItemStack ingredient, ItemStack item) {
  if (ingredient.isEmpty || item.isEmpty) return ingredient.isEmpty && item.isEmpty;
  return ingredient.id == item.id && (ingredient.meta == anyMeta || ingredient.meta == item.meta);
}

/// Найденный рецепт для сетки крафта и ингредиенты в том виде, в каком их ждёт сервер:
/// 9 ячеек 3×3 (индекс y·3+x), по одному предмету.
class CraftMatch {
  CraftMatch(this.recipe, this.input);

  final CraftingRecipe recipe;
  final List<ItemStack> input;
}

/// Подбор рецепта для сетки [size]×[size] (ячейки построчно, null — пусто).
CraftMatch? matchRecipe(List<ItemStack?> grid, int size, List<CraftingRecipe> recipes) {
  final cells = [for (final c in grid) c == null || c.isEmpty ? ItemStack.empty : c.withCount(1)];
  var minX = size, minY = size, maxX = -1, maxY = -1;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      if (cells[y * size + x].isEmpty) continue;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < 0) return null;
  final bw = maxX - minX + 1, bh = maxY - minY + 1;
  ItemStack at(int x, int y) => cells[(minY + y) * size + minX + x];
  final filled = [for (final c in cells) if (!c.isEmpty) c];

  for (final recipe in recipes) {
    if (recipe.result.isEmpty || (recipe.big && size < 3)) continue;
    if (recipe.shaped) {
      if (recipe.width != bw || recipe.height != bh) continue;
      for (final mirror in const [false, true]) {
        var ok = true;
        for (var y = 0; y < bh && ok; y++) {
          for (var x = 0; x < bw; x++) {
            final item = at(mirror ? bw - 1 - x : x, y);
            if (!ingredientMatches(recipe.inputs[y * bw + x], item)) {
              ok = false;
              break;
            }
          }
        }
        if (!ok) continue;
        final input = List<ItemStack>.filled(9, ItemStack.empty);
        for (var y = 0; y < bh; y++) {
          for (var x = 0; x < bw; x++) {
            input[y * 3 + x] = at(mirror ? bw - 1 - x : x, y);
          }
        }
        return CraftMatch(recipe, input);
      }
    } else if (recipe.type == RecipeType.shapeless || recipe.type == RecipeType.shulkerBox) {
      final needed = [for (final i in recipe.inputs) for (var k = 0; k < (i.count > 0 ? i.count : 1); k++) i];
      if (needed.length != filled.length) continue;
      final used = List<bool>.filled(needed.length, false);
      var ok = true;
      for (final item in filled) {
        var found = false;
        for (var k = 0; k < needed.length; k++) {
          if (!used[k] && ingredientMatches(needed[k], item)) {
            used[k] = true;
            found = true;
            break;
          }
        }
        if (!found) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      final input = List<ItemStack>.filled(9, ItemStack.empty);
      for (var k = 0; k < filled.length; k++) {
        input[k] = filled[k];
      }
      return CraftMatch(recipe, input);
    }
  }
  return null;
}
