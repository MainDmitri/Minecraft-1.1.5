/// Предметы MCPE 1.1 (ID ≥ 256): название, иконка из textures/items, размер стопки, слот брони.
class ItemInfo {
  const ItemInfo(this.name, this.icons, {this.maxStack = 64, this.armorSlot = -1});

  final String name;

  /// Имя файла иконки (без расширения) по мете; ключ −1 — для любой меты.
  final Map<int, String> icons;
  final int maxStack;

  /// 0 шлем, 1 нагрудник, 2 поножи, 3 ботинки, −1 — не броня.
  final int armorSlot;
}

ItemInfo _i(String name, String icon, {int stack = 64}) => ItemInfo(name, {-1: icon}, maxStack: stack);
ItemInfo _tool(String name, String icon) => ItemInfo(name, {-1: icon}, maxStack: 1);
ItemInfo _armor(String name, String icon, int slot) => ItemInfo(name, {-1: icon}, maxStack: 1, armorSlot: slot);

const List<String> _colors = [
  'white', 'orange', 'magenta', 'light_blue', 'yellow', 'lime', 'pink', 'gray', //
  'silver', 'cyan', 'purple', 'blue', 'brown', 'green', 'red', 'black',
];

/// Цвета красителей: мета 0 — чёрный (чернильный мешок) … 15 — белый (костная мука).
const List<String> _dyeColors = [
  'black', 'red', 'green', 'brown', 'blue', 'purple', 'cyan', 'silver', //
  'gray', 'pink', 'lime', 'yellow', 'light_blue', 'magenta', 'orange', 'white',
];

final Map<int, ItemInfo> itemTable = {
  256: _tool('Железная лопата', 'iron_shovel'),
  257: _tool('Железная кирка', 'iron_pickaxe'),
  258: _tool('Железный топор', 'iron_axe'),
  259: _tool('Огниво', 'flint_and_steel'),
  260: _i('Яблоко', 'apple'),
  261: _tool('Лук', 'bow_standby'),
  262: _i('Стрела', 'arrow'),
  263: const ItemInfo('Уголь', {0: 'coal', 1: 'charcoal'}),
  264: _i('Алмаз', 'diamond'),
  265: _i('Железный слиток', 'iron_ingot'),
  266: _i('Золотой слиток', 'gold_ingot'),
  267: _tool('Железный меч', 'iron_sword'),
  268: _tool('Деревянный меч', 'wood_sword'),
  269: _tool('Деревянная лопата', 'wood_shovel'),
  270: _tool('Деревянная кирка', 'wood_pickaxe'),
  271: _tool('Деревянный топор', 'wood_axe'),
  272: _tool('Каменный меч', 'stone_sword'),
  273: _tool('Каменная лопата', 'stone_shovel'),
  274: _tool('Каменная кирка', 'stone_pickaxe'),
  275: _tool('Каменный топор', 'stone_axe'),
  276: _tool('Алмазный меч', 'diamond_sword'),
  277: _tool('Алмазная лопата', 'diamond_shovel'),
  278: _tool('Алмазная кирка', 'diamond_pickaxe'),
  279: _tool('Алмазный топор', 'diamond_axe'),
  280: _i('Палка', 'stick'),
  281: _i('Миска', 'bowl'),
  282: _tool('Грибной суп', 'mushroom_stew'),
  283: _tool('Золотой меч', 'gold_sword'),
  284: _tool('Золотая лопата', 'gold_shovel'),
  285: _tool('Золотая кирка', 'gold_pickaxe'),
  286: _tool('Золотой топор', 'gold_axe'),
  287: _i('Нить', 'string'),
  288: _i('Перо', 'feather'),
  289: _i('Порох', 'gunpowder'),
  290: _tool('Деревянная мотыга', 'wood_hoe'),
  291: _tool('Каменная мотыга', 'stone_hoe'),
  292: _tool('Железная мотыга', 'iron_hoe'),
  293: _tool('Алмазная мотыга', 'diamond_hoe'),
  294: _tool('Золотая мотыга', 'gold_hoe'),
  295: _i('Семена пшеницы', 'seeds_wheat'),
  296: _i('Пшеница', 'wheat'),
  297: _i('Хлеб', 'bread'),
  298: _armor('Кожаная шапка', 'leather_helmet', 0),
  299: _armor('Кожаная куртка', 'leather_chestplate', 1),
  300: _armor('Кожаные штаны', 'leather_leggings', 2),
  301: _armor('Кожаные ботинки', 'leather_boots', 3),
  302: _armor('Кольчужный шлем', 'chainmail_helmet', 0),
  303: _armor('Кольчужная рубаха', 'chainmail_chestplate', 1),
  304: _armor('Кольчужные поножи', 'chainmail_leggings', 2),
  305: _armor('Кольчужные ботинки', 'chainmail_boots', 3),
  306: _armor('Железный шлем', 'iron_helmet', 0),
  307: _armor('Железный нагрудник', 'iron_chestplate', 1),
  308: _armor('Железные поножи', 'iron_leggings', 2),
  309: _armor('Железные ботинки', 'iron_boots', 3),
  310: _armor('Алмазный шлем', 'diamond_helmet', 0),
  311: _armor('Алмазный нагрудник', 'diamond_chestplate', 1),
  312: _armor('Алмазные поножи', 'diamond_leggings', 2),
  313: _armor('Алмазные ботинки', 'diamond_boots', 3),
  314: _armor('Золотой шлем', 'gold_helmet', 0),
  315: _armor('Золотой нагрудник', 'gold_chestplate', 1),
  316: _armor('Золотые поножи', 'gold_leggings', 2),
  317: _armor('Золотые ботинки', 'gold_boots', 3),
  318: _i('Кремень', 'flint'),
  319: _i('Сырая свинина', 'porkchop_raw'),
  320: _i('Жареная свинина', 'porkchop_cooked'),
  321: _i('Картина', 'painting'),
  322: _i('Золотое яблоко', 'apple_golden'),
  323: _i('Табличка', 'sign', stack: 16),
  324: _i('Деревянная дверь', 'door_wood'),
  325: const ItemInfo('Ведро', {0: 'bucket_empty', 1: 'bucket_milk', 8: 'bucket_water', 10: 'bucket_lava'}, maxStack: 1),
  328: _tool('Вагонетка', 'minecart_normal'),
  329: _tool('Седло', 'saddle'),
  330: _i('Железная дверь', 'door_iron'),
  331: _i('Красная пыль', 'redstone_dust'),
  332: _i('Снежок', 'snowball', stack: 16),
  333: const ItemInfo('Лодка',
      {0: 'boat_oak', 1: 'boat_spruce', 2: 'boat_birch', 3: 'boat_jungle', 4: 'boat_acacia', 5: 'boat_darkoak'},
      maxStack: 1),
  334: _i('Кожа', 'leather'),
  336: _i('Кирпич', 'brick'),
  337: _i('Глина', 'clay_ball'),
  338: _i('Сахарный тростник', 'reeds'),
  339: _i('Бумага', 'paper'),
  340: _i('Книга', 'book_normal'),
  341: _i('Слизь', 'slimeball'),
  342: _tool('Вагонетка с сундуком', 'minecart_chest'),
  344: _i('Яйцо', 'egg', stack: 16),
  345: _i('Компас', 'compass_item'),
  346: _tool('Удочка', 'fishing_rod_uncast'),
  347: _i('Часы', 'clock_item'),
  348: _i('Светопыль', 'glowstone_dust'),
  349: const ItemInfo('Сырая рыба', {0: 'fish_raw', 1: 'fish_salmon_raw', 2: 'fish_clownfish_raw', 3: 'fish_pufferfish_raw'}),
  350: const ItemInfo('Жареная рыба', {0: 'fish_cooked', 1: 'fish_salmon_cooked'}),
  351: ItemInfo('Краситель', {for (var m = 0; m < 16; m++) m: 'dye_powder_${_dyeColors[m]}'}),
  352: _i('Кость', 'bone'),
  353: _i('Сахар', 'sugar'),
  354: _tool('Торт', 'cake'),
  355: ItemInfo('Кровать', {for (var m = 0; m < 16; m++) m: 'bed_${_colors[m]}'}, maxStack: 1),
  356: _i('Повторитель', 'repeater'),
  357: _i('Печенье', 'cookie'),
  358: _i('Карта', 'map_filled'),
  359: _tool('Ножницы', 'shears'),
  360: _i('Ломтик арбуза', 'melon'),
  361: _i('Семена тыквы', 'seeds_pumpkin'),
  362: _i('Семена арбуза', 'seeds_melon'),
  363: _i('Сырая говядина', 'beef_raw'),
  364: _i('Стейк', 'beef_cooked'),
  365: _i('Сырая курица', 'chicken_raw'),
  366: _i('Жареная курица', 'chicken_cooked'),
  367: _i('Гнилая плоть', 'rotten_flesh'),
  368: _i('Жемчуг Края', 'ender_pearl', stack: 16),
  369: _i('Огненный стержень', 'blaze_rod'),
  370: _i('Слеза гаста', 'ghast_tear'),
  371: _i('Золотой самородок', 'gold_nugget'),
  372: _i('Адский нарост', 'nether_wart'),
  373: _tool('Зелье', 'potion_bottle_drinkable'),
  374: _i('Пузырёк', 'potion_bottle_empty'),
  375: _i('Паучий глаз', 'spider_eye'),
  376: _i('Приготовленный паучий глаз', 'spider_eye_fermented'),
  377: _i('Огненный порошок', 'blaze_powder'),
  378: _i('Сгусток магмы', 'magma_cream'),
  379: _i('Варочная стойка', 'brewing_stand'),
  380: _i('Котёл', 'cauldron'),
  381: _i('Око Края', 'ender_eye'),
  382: _i('Сверкающий ломтик арбуза', 'melon_speckled'),
  383: _i('Яйцо призыва', 'spawn_egg'),
  384: _i('Пузырёк опыта', 'experience_bottle'),
  385: _i('Огненный шар', 'fireball'),
  386: _tool('Книга с пером', 'book_writable'),
  387: _i('Написанная книга', 'book_written', stack: 16),
  388: _i('Изумруд', 'emerald'),
  389: _i('Рамка', 'item_frame'),
  390: _i('Цветочный горшок', 'flower_pot'),
  391: _i('Морковь', 'carrot'),
  392: _i('Картофель', 'potato'),
  393: _i('Печёный картофель', 'potato_baked'),
  394: _i('Ядовитый картофель', 'potato_poisonous'),
  395: _i('Пустая карта', 'map_empty'),
  396: _i('Золотая морковь', 'carrot_golden'),
  397: const ItemInfo('Голова', {
    0: 'skull_skeleton', 1: 'skull_wither', 2: 'skull_zombie', 3: 'skull_steve', 4: 'skull_creeper', 5: 'skull_dragon', //
  }),
  398: _tool('Удочка с морковью', 'carrot_on_a_stick'),
  399: _i('Звезда Незера', 'nether_star'),
  400: _i('Тыквенный пирог', 'pumpkin_pie'),
  401: _i('Фейерверк', 'fireworks'),
  403: _tool('Зачарованная книга', 'book_enchanted'),
  404: _i('Компаратор', 'comparator'),
  405: _i('Адский кирпич', 'netherbrick'),
  406: _i('Кварц Незера', 'quartz'),
  407: _tool('Вагонетка с динамитом', 'minecart_tnt'),
  408: _tool('Вагонетка с воронкой', 'minecart_hopper'),
  409: _i('Осколок призмарина', 'prismarine_shard'),
  410: _i('Воронка', 'hopper'),
  411: _i('Сырая крольчатина', 'rabbit_raw'),
  412: _i('Жареная крольчатина', 'rabbit_cooked'),
  413: _tool('Тушёный кролик', 'rabbit_stew'),
  414: _i('Кроличья лапка', 'rabbit_foot'),
  415: _i('Кроличья шкурка', 'rabbit_hide'),
  416: _tool('Кожаная конская броня', 'leather_horse_armor'),
  417: _tool('Железная конская броня', 'iron_horse_armor'),
  418: _tool('Золотая конская броня', 'gold_horse_armor'),
  419: _tool('Алмазная конская броня', 'diamond_horse_armor'),
  420: _i('Поводок', 'lead'),
  421: _i('Бирка', 'name_tag'),
  422: _i('Кристалл призмарина', 'prismarine_crystals'),
  423: _i('Сырая баранина', 'mutton_raw'),
  424: _i('Жареная баранина', 'mutton_cooked'),
  426: _i('Кристалл Края', 'end_crystal'),
  427: _i('Еловая дверь', 'door_spruce'),
  428: _i('Берёзовая дверь', 'door_birch'),
  429: _i('Тропическая дверь', 'door_jungle'),
  430: _i('Акациевая дверь', 'door_acacia'),
  431: _i('Дверь из тёмного дуба', 'door_dark_oak'),
  432: _i('Плод коруса', 'chorus_fruit'),
  433: _i('Приготовленный плод коруса', 'chorus_fruit_popped'),
  437: _i('Драконье дыхание', 'dragons_breath'),
  438: _tool('Взрывное зелье', 'potion_bottle_splash'),
  441: _tool('Оседающее зелье', 'potion_bottle_lingering'),
  444: _tool('Элитры', 'elytra'),
  445: _i('Панцирь шалкера', 'shulker_shell'),
  450: _tool('Тотем бессмертия', 'totem'),
  457: _i('Свёкла', 'beetroot'),
  458: _i('Семена свёклы', 'seeds_beetroot'),
  459: _tool('Свекольный суп', 'beetroot_soup'),
  460: _i('Сырой лосось', 'fish_salmon_raw'),
  461: _i('Тропическая рыба', 'fish_clownfish_raw'),
  462: _i('Иглобрюх', 'fish_pufferfish_raw'),
  463: _i('Жареный лосось', 'fish_salmon_cooked'),
  466: _i('Зачарованное золотое яблоко', 'apple_golden'),
};

/// Названия частых блоков (для подсказки в инвентаре).
const Map<int, String> blockTitles = {
  1: 'Камень', 2: 'Трава', 3: 'Земля', 4: 'Булыжник', 5: 'Доски', 6: 'Саженец', 7: 'Бедрок', 8: 'Вода', //
  10: 'Лава', 12: 'Песок', 13: 'Гравий', 14: 'Золотая руда', 15: 'Железная руда', 16: 'Угольная руда',
  17: 'Дерево', 18: 'Листва', 19: 'Губка', 20: 'Стекло', 21: 'Лазуритовая руда', 22: 'Лазуритовый блок',
  23: 'Раздатчик', 24: 'Песчаник', 25: 'Нотный блок', 26: 'Кровать', 27: 'Энергорельсы', 30: 'Паутина',
  31: 'Трава', 32: 'Мёртвый куст', 35: 'Шерсть', 37: 'Одуванчик', 38: 'Цветок', 39: 'Гриб', 40: 'Гриб',
  41: 'Золотой блок', 42: 'Железный блок', 44: 'Плита', 45: 'Кирпичи', 46: 'Динамит', 47: 'Книжная полка',
  48: 'Замшелый булыжник', 49: 'Обсидиан', 50: 'Факел', 53: 'Дубовые ступеньки', 54: 'Сундук',
  56: 'Алмазная руда', 57: 'Алмазный блок', 58: 'Верстак', 61: 'Печь', 65: 'Лестница', 66: 'Рельсы',
  67: 'Каменные ступеньки', 69: 'Рычаг', 72: 'Нажимная плита', 73: 'Красная руда', 76: 'Красный факел',
  77: 'Кнопка', 78: 'Снег', 79: 'Лёд', 80: 'Снежный блок', 81: 'Кактус', 82: 'Глина', 85: 'Забор',
  86: 'Тыква', 87: 'Незерак', 88: 'Песок душ', 89: 'Светокамень', 91: 'Светильник Джека', 96: 'Люк',
  98: 'Каменные кирпичи', 101: 'Железная решётка', 102: 'Стеклянная панель', 103: 'Арбуз', 106: 'Лианы',
  107: 'Калитка', 108: 'Кирпичные ступеньки', 109: 'Ступеньки из каменных кирпичей', 110: 'Мицелий',
  112: 'Адский кирпич', 116: 'Стол зачарований', 121: 'Камень Края', 129: 'Изумрудная руда',
  133: 'Изумрудный блок', 139: 'Булыжная стена', 145: 'Наковальня', 152: 'Блок красного камня',
  153: 'Кварцевая руда', 155: 'Кварцевый блок', 158: 'Деревянная плита', 159: 'Терракота',
  161: 'Листва', 162: 'Дерево', 170: 'Сноп сена', 171: 'Ковёр', 172: 'Терракота', 173: 'Угольный блок',
  174: 'Плотный лёд', 179: 'Красный песчаник',
};

ItemInfo? itemInfo(int id) => itemTable[id];

/// Файл иконки предмета (textures/items/<имя>) или null.
String? itemIconFile(int id, int meta) {
  final icons = itemTable[id]?.icons;
  if (icons == null) return null;
  return icons[meta] ?? icons[-1] ?? icons[0];
}

int maxStackOf(int id) => id < 256 ? 64 : (itemTable[id]?.maxStack ?? 64);

int armorSlotOf(int id) => id == 86 ? 0 : (itemTable[id]?.armorSlot ?? -1);

String itemTitle(int id, int meta) {
  if (id >= 256) return itemTable[id]?.name ?? 'Предмет $id';
  return blockTitles[id] ?? 'Блок $id';
}

/// Прочность инструментов (мета предмета — износ).
const Map<int, int> _durability = {
  268: 59, 269: 59, 270: 59, 271: 59, 290: 59, //
  272: 131, 273: 131, 274: 131, 275: 131, 291: 131,
  256: 250, 257: 250, 258: 250, 267: 250, 292: 250,
  276: 1561, 277: 1561, 278: 1561, 279: 1561, 293: 1561,
  283: 32, 284: 32, 285: 32, 286: 32, 294: 32,
  259: 64, 261: 384, 346: 64, 359: 238,
};

int maxDurabilityOf(int id) => _durability[id] ?? 0;
