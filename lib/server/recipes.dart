import 'dart:typed_data';

import '../protocol/packets.dart';
import 'server_packets.dart';

/// Мета «любая» у ингредиента.
const int _any = -1;

/// Рецепт крафта встроенного сервера.
class ServerRecipe {
  ServerRecipe._(this.shapeless, this.width, this.height, this.cells, this.result, this.uuid);

  final bool shapeless;
  final int width;
  final int height;

  /// Фигурный: width × height (null — пусто); бесформенный: список ингредиентов.
  final List<ServerItem?> cells;
  final ServerItem result;
  final Uint8List uuid;

  /// Нужен верстак.
  bool get big => shapeless ? cells.length > 4 : (width > 2 || height > 2);

  /// Ингредиент (x, y) фигурного рецепта.
  ServerItem? at(int x, int y) => x < width && y < height ? cells[y * width + x] : null;
}

bool ingredientMatches(ServerItem ingredient, int id, int meta) =>
    ingredient.id == id && (ingredient.meta == _any || ingredient.meta == meta);

class _RecipeBook {
  final List<ServerRecipe> recipes = [];

  Uint8List _uuid() {
    final n = recipes.length;
    // Постоянный UUID рецепта по его номеру.
    return Uint8List.fromList([0x4d, 0x43, 0x50, 0x45, 0x31, 0x31, (n >> 8) & 0xff, n & 0xff, 0x80, 0, 0, 0, 0, 0, 0, 1]);
  }

  void shaped(List<String> rows, Map<String, (int, int)> key, int id, {int meta = 0, int count = 1}) {
    final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    final cells = <ServerItem?>[];
    for (final row in rows) {
      for (var x = 0; x < width; x++) {
        final ch = x < row.length ? row[x] : ' ';
        final k = key[ch];
        cells.add(k == null ? null : ServerItem(k.$1, k.$2, 1));
      }
    }
    recipes.add(ServerRecipe._(false, width, rows.length, cells, ServerItem(id, meta, count), _uuid()));
  }

  void shapeless(List<(int, int)> items, int id, {int meta = 0, int count = 1}) {
    recipes.add(ServerRecipe._(
        true, 0, 0, [for (final i in items) ServerItem(i.$1, i.$2, 1)], ServerItem(id, meta, count), _uuid()));
  }
}

const (int, int) _planks = (5, _any);
const (int, int) _stick = (280, 0);

List<ServerRecipe> _build() {
  final b = _RecipeBook();
  // Доски из брёвен (мета дерева → мета досок).
  for (var m = 0; m < 4; m++) {
    b.shapeless([(17, m)], 5, meta: m, count: 4);
  }
  b
    ..shapeless([(162, 0)], 5, meta: 4, count: 4)
    ..shapeless([(162, 1)], 5, meta: 5, count: 4)
    ..shaped(['#', '#'], {'#': _planks}, 280, count: 4)
    ..shaped(['##', '##'], {'#': _planks}, 58)
    ..shaped(['###', '# #', '###'], {'#': _planks}, 54)
    ..shaped(['###', '# #', '###'], {'#': (4, 0)}, 61)
    ..shaped(['C', '|'], {'C': (263, _any), '|': _stick}, 50, count: 4);

  // Инструменты: материал → ID лопаты, кирки, топора, меча, мотыги.
  final tools = <(int, int), List<int>>{
    _planks: [269, 270, 271, 268, 290],
    (4, 0): [273, 274, 275, 272, 291],
    (265, 0): [256, 257, 258, 267, 292],
    (266, 0): [284, 285, 286, 283, 294],
    (264, 0): [277, 278, 279, 276, 293],
  };
  tools.forEach((m, ids) {
    final key = {'M': m, '|': _stick};
    b
      ..shaped(['M', '|', '|'], key, ids[0])
      ..shaped(['MMM', ' | ', ' | '], key, ids[1])
      ..shaped(['MM', 'M|', ' |'], key, ids[2])
      ..shaped(['M', 'M', '|'], key, ids[3])
      ..shaped(['MM', ' |', ' |'], key, ids[4]);
  });

  // Броня: материал → шлем, нагрудник, поножи, ботинки.
  final armor = <(int, int), int>{(334, 0): 298, (265, 0): 306, (266, 0): 314, (264, 0): 310};
  armor.forEach((m, first) {
    final key = {'M': m};
    b
      ..shaped(['MMM', 'M M'], key, first)
      ..shaped(['M M', 'MMM', 'MMM'], key, first + 1)
      ..shaped(['MMM', 'M M', 'M M'], key, first + 2)
      ..shaped(['M M', 'M M'], key, first + 3);
  });

  // Блоки из материалов и обратно.
  final storage = <(int, int), (int, int)>{
    (265, 0): (42, 0),
    (266, 0): (41, 0),
    (264, 0): (57, 0),
    (388, 0): (133, 0),
    (263, 0): (173, 0),
    (331, 0): (152, 0),
    (351, 4): (22, 0),
    (296, 0): (170, 0),
    (360, 0): (103, 0),
  };
  storage.forEach((item, block) {
    b.shaped(['###', '###', '###'], {'#': item}, block.$1, meta: block.$2);
    // Арбуз обратно на ломтики не разбирается.
    if (block.$1 != 103) b.shapeless([block], item.$1, meta: item.$2, count: 9);
  });

  b
    ..shaped(['##', '##'], {'#': (1, 0)}, 98, count: 4)
    ..shaped(['##', '##'], {'#': (12, 0)}, 24)
    ..shaped(['##', '##'], {'#': (336, 0)}, 45)
    ..shaped(['##', '##'], {'#': (332, 0)}, 80)
    ..shaped(['##', '##'], {'#': (337, 0)}, 82)
    ..shaped(['##', '##'], {'#': (348, 0)}, 89)
    ..shaped(['##', '##'], {'#': (287, 0)}, 35)
    ..shaped(['##', '##'], {'#': (406, 0)}, 155)
    ..shaped(['##', '##'], {'#': (405, 0)}, 112)
    ..shaped(['###', '###'], {'#': (20, 0)}, 102, count: 16)
    ..shaped(['###', '###'], {'#': (265, 0)}, 101, count: 16)
    ..shaped(['###', '###'], {'#': (4, 0)}, 139, count: 6)
    ..shaped(['| |', '|||', '| |'], {'|': _stick}, 65, count: 3)
    ..shaped(['#|#', '#|#'], {'#': _planks, '|': _stick}, 85, count: 3)
    ..shaped(['|#|', '|#|'], {'#': _planks, '|': _stick}, 107)
    ..shaped(['##', '##', '##'], {'#': _planks}, 324, count: 3)
    ..shaped(['##', '##', '##'], {'#': (265, 0)}, 330, count: 3)
    ..shaped(['###', '###'], {'#': _planks}, 96, count: 2)
    ..shaped(['###', 'BBB', '###'], {'#': _planks, 'B': (340, 0)}, 47)
    ..shapeless([(339, 0), (339, 0), (339, 0), (334, 0)], 340)
    ..shaped(['###'], {'#': (338, 0)}, 339, count: 3)
    ..shapeless([(338, 0)], 353)
    ..shaped(['# #', ' # '], {'#': _planks}, 281, count: 4)
    ..shaped(['WWW'], {'W': (296, 0)}, 297)
    ..shaped(['X#X', '#X#', 'X#X'], {'X': (289, 0), '#': (12, _any)}, 46)
    ..shaped(['P', 'T'], {'P': (86, 0), 'T': (50, 0)}, 91)
    ..shaped(['I I', ' I '], {'I': (265, 0)}, 325)
    ..shaped([' I', 'I '], {'I': (265, 0)}, 359)
    ..shapeless([(265, 0), (318, 0)], 259)
    ..shaped([' |S', '| S', ' |S'], {'|': _stick, 'S': (287, 0)}, 261)
    ..shaped(['F', '|', 'E'], {'F': (318, 0), '|': _stick, 'E': (288, 0)}, 262, count: 4)
    ..shaped(['  |', ' |S', '| S'], {'|': _stick, 'S': (287, 0)}, 346)
    ..shaped([' I ', 'IRI', ' I '], {'I': (265, 0), 'R': (331, 0)}, 345)
    ..shaped([' G ', 'GRG', ' G '], {'G': (266, 0), 'R': (331, 0)}, 347)
    ..shaped(['###', '###', ' | '], {'#': _planks, '|': _stick}, 323, count: 3)
    ..shaped(['I I', 'III'], {'I': (265, 0)}, 328)
    ..shaped(['I I', 'I|I', 'I I'], {'I': (265, 0), '|': _stick}, 66, count: 16)
    ..shaped(['|', 'C'], {'|': _stick, 'C': (4, 0)}, 69)
    ..shapeless([(1, 0)], 77)
    ..shaped(['##'], {'#': (1, 0)}, 70)
    ..shaped(['##'], {'#': _planks}, 72)
    ..shapeless([(352, 0)], 351, meta: 15, count: 3)
    ..shapeless([(281, 0), (39, 0), (40, 0)], 282)
    ..shaped(['GGG', 'GAG', 'GGG'], {'G': (266, 0), 'A': (260, 0)}, 322)
    ..shapeless([(86, 0)], 361, count: 4)
    ..shapeless([(360, 0)], 362)
    ..shaped(['G G', ' G '], {'G': (20, 0)}, 374, count: 3)
    ..shaped(['|||', '|L|', '|||'], {'|': _stick, 'L': (334, 0)}, 389)
    ..shaped(['|||', '|W|', '|||'], {'|': _stick, 'W': (35, _any)}, 321)
    ..shaped(['B B', ' B '], {'B': (336, 0)}, 390)
    ..shaped(['###', '#R#', '###'], {'#': _planks, 'R': (331, 0)}, 25)
    ..shaped(['###', '#R#', '###'], {'#': (4, 0), 'R': (331, 0)}, 23)
    ..shapeless([(344, 0), (353, 0), (86, 0)], 400)
    ..shaped(['WCW'], {'W': (296, 0), 'C': (351, 3)}, 357, count: 8);

  // Плиты и ступеньки.
  b
    ..shaped(['###'], {'#': (1, 0)}, 44, meta: 0, count: 6)
    ..shaped(['###'], {'#': (24, 0)}, 44, meta: 1, count: 6)
    ..shaped(['###'], {'#': (4, 0)}, 44, meta: 3, count: 6)
    ..shaped(['###'], {'#': (45, 0)}, 44, meta: 4, count: 6)
    ..shaped(['###'], {'#': (98, 0)}, 44, meta: 5, count: 6)
    ..shaped(['#  ', '## ', '###'], {'#': (4, 0)}, 67, count: 4)
    ..shaped(['#  ', '## ', '###'], {'#': (45, 0)}, 108, count: 4)
    ..shaped(['#  ', '## ', '###'], {'#': (98, 0)}, 109, count: 4)
    ..shaped(['#  ', '## ', '###'], {'#': (24, 0)}, 128, count: 4);
  const woodStairs = [53, 134, 135, 136, 163, 164];
  const boats = [0, 1, 2, 3, 4, 5];
  for (var m = 0; m < 6; m++) {
    b
      ..shaped(['###'], {'#': (5, m)}, 158, meta: m, count: 6)
      ..shaped(['#  ', '## ', '###'], {'#': (5, m)}, woodStairs[m], count: 4)
      ..shaped(['# #', '###'], {'#': (5, m)}, 333, meta: boats[m]);
  }

  // Шерсть и ковры: краситель с метой d красит в цвет 15 − d.
  for (var d = 0; d < 16; d++) {
    if (d != 15) b.shapeless([(351, d), (35, 0)], 35, meta: 15 - d);
  }
  for (var c = 0; c < 16; c++) {
    b.shaped(['##'], {'#': (35, c)}, 171, meta: c, count: 3);
  }
  return b.recipes;
}

final List<ServerRecipe> serverRecipes = _build();

final Map<String, ServerRecipe> _byUuid = {
  for (final r in serverRecipes) String.fromCharCodes(r.uuid): r,
};

ServerRecipe? recipeByUuid(Uint8List uuid) => _byUuid[String.fromCharCodes(uuid)];

// ---------- Печь ----------

/// Результат переплавки или null.
ServerItem? smeltResult(int id, int meta) {
  switch (id) {
    case 15:
      return ServerItem(265, 0, 1);
    case 14:
      return ServerItem(266, 0, 1);
    case 12:
      return ServerItem(20, 0, 1);
    case 4:
      return ServerItem(1, 0, 1);
    case 17:
    case 162:
      return ServerItem(263, 1, 1);
    case 337:
      return ServerItem(336, 0, 1);
    case 82:
      return ServerItem(172, 0, 1);
    case 87:
      return ServerItem(405, 0, 1);
    case 319:
      return ServerItem(320, 0, 1);
    case 363:
      return ServerItem(364, 0, 1);
    case 365:
      return ServerItem(366, 0, 1);
    case 349:
      return meta <= 1 ? ServerItem(350, meta, 1) : null;
    case 423:
      return ServerItem(424, 0, 1);
    case 411:
      return ServerItem(412, 0, 1);
    case 392:
      return ServerItem(393, 0, 1);
    case 81:
      return ServerItem(351, 2, 1);
    case 56:
      return ServerItem(264, 0, 1);
    case 16:
      return ServerItem(263, 0, 1);
    case 129:
      return ServerItem(388, 0, 1);
    case 21:
      return ServerItem(351, 4, 1);
    case 73:
    case 74:
      return ServerItem(331, 0, 1);
    case 153:
      return ServerItem(406, 0, 1);
    case 98:
      return meta == 0 ? ServerItem(98, 2, 1) : null;
    case 19:
      return meta == 1 ? ServerItem(19, 0, 1) : null;
    default:
      return null;
  }
}

/// Время горения топлива в тиках (0 — не топливо).
int fuelTicks(int id, int meta) {
  switch (id) {
    case 263:
      return 1600;
    case 173:
      return 16000;
    case 325:
      return meta == 10 ? 20000 : 0;
    case 369:
      return 2400;
    case 17:
    case 162:
    case 5:
    case 85:
    case 107:
    case 53:
    case 134:
    case 135:
    case 136:
    case 163:
    case 164:
    case 58:
    case 54:
    case 47:
    case 96:
    case 65:
    case 25:
    case 261:
    case 346:
      return 300;
    case 158:
      return 150;
    case 268:
    case 269:
    case 270:
    case 271:
    case 290:
    case 323:
      return 200;
    case 280:
    case 6:
    case 281:
    case 35:
      return 100;
    case 171:
      return 67;
    case 333:
      return 1200;
    default:
      return 0;
  }
}

/// Рецепты печи для CraftingDataPacket: вход (мета −1 — любая) → результат.
List<(int, int, ServerItem)> furnaceRecipeList() {
  final out = <(int, int, ServerItem)>[];
  for (final (id, meta) in const [
    (15, -1), (14, -1), (12, -1), (4, -1), (17, -1), (162, -1), (337, -1), (82, -1), (87, -1), (319, -1), //
    (363, -1), (365, -1), (349, 0), (349, 1), (423, -1), (411, -1), (392, -1), (81, -1), (56, -1), (16, -1),
    (129, -1), (21, -1), (73, -1), (153, -1), (98, 0), (19, 1),
  ]) {
    final r = smeltResult(id, meta < 0 ? 0 : meta);
    if (r != null) out.add((id, meta, r));
  }
  return out;
}

// ---------- Инструменты и блоки ----------

enum ToolType { none, pickaxe, axe, shovel, sword, shears }

class ToolInfo {
  const ToolInfo(this.type, this.speed, this.durability, this.level);

  final ToolType type;
  final double speed;
  final int durability;

  /// Уровень добычи: 0 дерево/золото, 1 камень, 2 железо, 3 алмаз.
  final int level;
}

const Map<int, ToolInfo> toolInfo = {
  269: ToolInfo(ToolType.shovel, 2, 59, 0),
  270: ToolInfo(ToolType.pickaxe, 2, 59, 0),
  271: ToolInfo(ToolType.axe, 2, 59, 0),
  268: ToolInfo(ToolType.sword, 1.5, 59, 0),
  273: ToolInfo(ToolType.shovel, 4, 131, 1),
  274: ToolInfo(ToolType.pickaxe, 4, 131, 1),
  275: ToolInfo(ToolType.axe, 4, 131, 1),
  272: ToolInfo(ToolType.sword, 1.5, 131, 1),
  256: ToolInfo(ToolType.shovel, 6, 250, 2),
  257: ToolInfo(ToolType.pickaxe, 6, 250, 2),
  258: ToolInfo(ToolType.axe, 6, 250, 2),
  267: ToolInfo(ToolType.sword, 1.5, 250, 2),
  277: ToolInfo(ToolType.shovel, 8, 1561, 3),
  278: ToolInfo(ToolType.pickaxe, 8, 1561, 3),
  279: ToolInfo(ToolType.axe, 8, 1561, 3),
  276: ToolInfo(ToolType.sword, 1.5, 1561, 3),
  284: ToolInfo(ToolType.shovel, 12, 32, 0),
  285: ToolInfo(ToolType.pickaxe, 12, 32, 0),
  286: ToolInfo(ToolType.axe, 12, 32, 0),
  283: ToolInfo(ToolType.sword, 1.5, 32, 0),
  359: ToolInfo(ToolType.shears, 15, 238, 0),
};

class BlockRule {
  const BlockRule(this.hardness, [this.tool = ToolType.none, this.level = -1]);

  /// Твёрдость; −1 — неразрушимый.
  final double hardness;
  final ToolType tool;

  /// Нужный уровень кирки для добычи (−1 — добывается чем угодно).
  final int level;
}

const BlockRule _default = BlockRule(1);

const Map<int, BlockRule> blockRules = {
  0: BlockRule(0), 1: BlockRule(1.5, ToolType.pickaxe, 0), 2: BlockRule(0.6, ToolType.shovel), //
  3: BlockRule(0.5, ToolType.shovel), 4: BlockRule(2, ToolType.pickaxe, 0), 5: BlockRule(2, ToolType.axe),
  6: BlockRule(0), 7: BlockRule(-1), 12: BlockRule(0.5, ToolType.shovel), 13: BlockRule(0.6, ToolType.shovel),
  14: BlockRule(3, ToolType.pickaxe, 2), 15: BlockRule(3, ToolType.pickaxe, 1), 16: BlockRule(3, ToolType.pickaxe, 0),
  17: BlockRule(2, ToolType.axe), 18: BlockRule(0.2, ToolType.shears), 19: BlockRule(0.6), 20: BlockRule(0.3),
  21: BlockRule(3, ToolType.pickaxe, 1), 22: BlockRule(3, ToolType.pickaxe, 1), 23: BlockRule(3.5, ToolType.pickaxe, 0),
  24: BlockRule(0.8, ToolType.pickaxe, 0), 25: BlockRule(0.8, ToolType.axe), 31: BlockRule(0), 32: BlockRule(0),
  35: BlockRule(0.8, ToolType.shears), 37: BlockRule(0), 38: BlockRule(0), 39: BlockRule(0), 40: BlockRule(0),
  41: BlockRule(3, ToolType.pickaxe, 2), 42: BlockRule(5, ToolType.pickaxe, 1), 43: BlockRule(2, ToolType.pickaxe, 0),
  44: BlockRule(2, ToolType.pickaxe, 0), 45: BlockRule(2, ToolType.pickaxe, 0), 46: BlockRule(0),
  47: BlockRule(1.5, ToolType.axe), 48: BlockRule(2, ToolType.pickaxe, 0), 49: BlockRule(50, ToolType.pickaxe, 3),
  50: BlockRule(0), 53: BlockRule(2, ToolType.axe), 54: BlockRule(2.5, ToolType.axe),
  56: BlockRule(3, ToolType.pickaxe, 2), 57: BlockRule(5, ToolType.pickaxe, 2), 58: BlockRule(2.5, ToolType.axe),
  60: BlockRule(0.6, ToolType.shovel), 61: BlockRule(3.5, ToolType.pickaxe, 0), 62: BlockRule(3.5, ToolType.pickaxe, 0),
  64: BlockRule(3, ToolType.axe), 65: BlockRule(0.4, ToolType.axe), 66: BlockRule(0.7, ToolType.pickaxe),
  67: BlockRule(2, ToolType.pickaxe, 0), 69: BlockRule(0.5), 70: BlockRule(0.5, ToolType.pickaxe, 0),
  71: BlockRule(5, ToolType.pickaxe, 0), 72: BlockRule(0.5, ToolType.axe), 73: BlockRule(3, ToolType.pickaxe, 2),
  74: BlockRule(3, ToolType.pickaxe, 2), 77: BlockRule(0.5), 78: BlockRule(0.1, ToolType.shovel),
  79: BlockRule(0.5, ToolType.pickaxe), 80: BlockRule(0.2, ToolType.shovel), 81: BlockRule(0.4),
  82: BlockRule(0.6, ToolType.shovel), 83: BlockRule(0), 85: BlockRule(2, ToolType.axe), 86: BlockRule(1, ToolType.axe),
  87: BlockRule(0.4, ToolType.pickaxe, 0), 88: BlockRule(0.5, ToolType.shovel), 89: BlockRule(0.3),
  91: BlockRule(1, ToolType.axe), 96: BlockRule(3, ToolType.axe), 98: BlockRule(1.5, ToolType.pickaxe, 0),
  101: BlockRule(5, ToolType.pickaxe, 0), 102: BlockRule(0.3), 103: BlockRule(1, ToolType.axe), 106: BlockRule(0.2),
  107: BlockRule(2, ToolType.axe), 108: BlockRule(2, ToolType.pickaxe, 0), 109: BlockRule(1.5, ToolType.pickaxe, 0),
  110: BlockRule(0.6, ToolType.shovel), 112: BlockRule(2, ToolType.pickaxe, 0), 121: BlockRule(3, ToolType.pickaxe, 0),
  128: BlockRule(0.8, ToolType.pickaxe, 0), 129: BlockRule(3, ToolType.pickaxe, 2), 133: BlockRule(5, ToolType.pickaxe, 2),
  134: BlockRule(2, ToolType.axe), 135: BlockRule(2, ToolType.axe), 136: BlockRule(2, ToolType.axe),
  139: BlockRule(2, ToolType.pickaxe, 0), 152: BlockRule(5, ToolType.pickaxe, 0), 153: BlockRule(3, ToolType.pickaxe, 0),
  155: BlockRule(0.8, ToolType.pickaxe, 0), 158: BlockRule(2, ToolType.axe), 159: BlockRule(1.25, ToolType.pickaxe, 0),
  161: BlockRule(0.2, ToolType.shears), 162: BlockRule(2, ToolType.axe), 163: BlockRule(2, ToolType.axe),
  164: BlockRule(2, ToolType.axe), 170: BlockRule(0.5), 171: BlockRule(0.1), 172: BlockRule(1.25, ToolType.pickaxe, 0),
  173: BlockRule(5, ToolType.pickaxe, 0), 174: BlockRule(0.5, ToolType.pickaxe), 175: BlockRule(0),
  179: BlockRule(0.8, ToolType.pickaxe, 0),
};

BlockRule blockRule(int id) => blockRules[id] ?? _default;

/// Можно ли добыть блок этим предметом (иначе блок ломается без дропа).
bool canHarvest(int blockId, int toolId) {
  final rule = blockRule(blockId);
  if (rule.level < 0) return true;
  final tool = toolInfo[toolId];
  return tool != null && tool.type == rule.tool && tool.level >= rule.level;
}

/// Время ломания в секундах с учётом инструмента (формула Minecraft).
double breakSeconds(int blockId, int toolId) {
  final rule = blockRule(blockId);
  if (rule.hardness < 0) return double.infinity;
  if (rule.hardness == 0) return 0;
  final tool = toolInfo[toolId];
  var speed = 1.0;
  if (tool != null && tool.type == rule.tool) speed = tool.speed;
  if (tool != null && tool.type == ToolType.sword && (blockId == 18 || blockId == 161 || blockId == 30)) speed = 1.5;
  return rule.hardness * (canHarvest(blockId, toolId) ? 1.5 : 5) / speed;
}

/// CraftingDataPacket со всеми рецептами сервера.
Uint8List spCraftingData() => encodePacket(PacketId.craftingData, (w) {
      final furnace = furnaceRecipeList();
      w.uvarint(serverRecipes.length + furnace.length);
      for (final r in serverRecipes) {
        if (r.shapeless) {
          w
            ..varint(0)
            ..uvarint(r.cells.length);
          for (final c in r.cells) {
            c!.write(w);
          }
        } else {
          w
            ..varint(1)
            ..varint(r.width)
            ..varint(r.height);
          for (final c in r.cells) {
            (c ?? ServerItem.air).write(w);
          }
        }
        w.uvarint(1);
        r.result.write(w);
        w.bytes(r.uuid);
      }
      for (final (id, meta, result) in furnace) {
        if (meta < 0) {
          w
            ..varint(2)
            ..varint(id);
        } else {
          w
            ..varint(3)
            ..varint(id)
            ..varint(meta);
        }
        result.write(w);
      }
      w.boolean(true);
    });
