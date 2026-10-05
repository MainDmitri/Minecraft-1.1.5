/// Свойства блоков MCPE 1.1 по числовому ID: как рисовать и можно ли сквозь них проходить.
/// Цвета подобраны для этого клиента (текстуры Mojang не используются).
enum BlockShape { none, cube, cross, liquid }

class BlockInfo {
  const BlockInfo(this.shape, this.color, {this.solid = true, this.opaque = true, this.topColor, this.bottomColor});

  final BlockShape shape;
  final int color;
  final int? topColor;
  final int? bottomColor;

  /// Твёрдый: игрок не проходит сквозь блок.
  final bool solid;

  /// Непрозрачный: скрывает грани соседей.
  final bool opaque;
}

const BlockInfo _air = BlockInfo(BlockShape.none, 0, solid: false, opaque: false);

BlockInfo _cube(int color, {int? top, int? bottom}) => BlockInfo(BlockShape.cube, color, topColor: top, bottomColor: bottom);

BlockInfo _see(int color) => BlockInfo(BlockShape.cube, color, opaque: false);

BlockInfo _plant(int color) => BlockInfo(BlockShape.cross, color, solid: false, opaque: false);

BlockInfo _liquid(int color) => BlockInfo(BlockShape.liquid, color, solid: false, opaque: false);

/// Цвета по метаданным (шерсть, окрашенная глина, стекло, ковёр).
const List<int> dyeColors = [
  0xFFE9ECEC, 0xFFF07613, 0xFFBD44B3, 0xFF3AAFD9, 0xFFF8C627, 0xFF70B919, 0xFFED8DAC, 0xFF3E4447, //
  0xFF8E8E86, 0xFF158991, 0xFF792AAC, 0xFF35399D, 0xFF724728, 0xFF546D1B, 0xFFA12722, 0xFF141519,
];

final Map<int, BlockInfo> _blocks = {
  0: _air,
  1: _cube(0xFF7D7D7D), // камень
  2: _cube(0xFF866043, top: 0xFF6A9F3C, bottom: 0xFF866043), // трава
  3: _cube(0xFF866043), // земля
  4: _cube(0xFF6E6E6E), // булыжник
  5: _cube(0xFFA7864F), // доски
  6: _plant(0xFF4F8A2E), // саженец
  7: _cube(0xFF333333), // бедрок
  8: _liquid(0xAA2F5FD9), // вода
  9: _liquid(0xAA2F5FD9),
  10: _liquid(0xFFD8601A), // лава
  11: _liquid(0xFFD8601A),
  12: _cube(0xFFDBD3A0), // песок
  13: _cube(0xFF877F7E), // гравий
  14: _cube(0xFF8F8B7C), // золотая руда
  15: _cube(0xFF877E78), // железная руда
  16: _cube(0xFF737373), // угольная руда
  17: _cube(0xFF664F31, top: 0xFFA5824F, bottom: 0xFFA5824F), // бревно
  18: _see(0xFF3B7A22), // листва
  19: _cube(0xFFCDCD49), // губка
  20: _see(0x66C8E6F0), // стекло
  21: _cube(0xFF667087), // лазуритовая руда
  22: _cube(0xFF1F43A8), // лазуритовый блок
  23: _cube(0xFF676767), // раздатчик
  24: _cube(0xFFD8CB9B), // песчаник
  25: _cube(0xFF654433), // нотный блок
  26: _cube(0xFF8E1B1B), // кровать
  27: _plant(0xFF8B7355), // рельсы
  28: _plant(0xFF8B7355),
  30: _plant(0xFFDCDCDC), // паутина
  31: _plant(0xFF5E9A3A), // высокая трава
  32: _plant(0xFF94713A), // сухой куст
  35: _cube(0xFFE9ECEC), // шерсть (цвет по мете)
  37: _plant(0xFFF1F902), // одуванчик
  38: _plant(0xFFD3212C), // цветок
  39: _plant(0xFF9A7655), // гриб
  40: _plant(0xFFC33331),
  41: _cube(0xFFF9D849), // золотой блок
  42: _cube(0xFFDBDBDB), // железный блок
  43: _cube(0xFFA8A8A8), // двойная плита
  44: _cube(0xFFA8A8A8), // плита
  45: _cube(0xFF96614F), // кирпич
  46: _cube(0xFFDB4A2B), // динамит
  47: _cube(0xFF6B5839, top: 0xFFA7864F, bottom: 0xFFA7864F), // книжная полка
  48: _cube(0xFF5A6B5A), // замшелый булыжник
  49: _cube(0xFF14121D), // обсидиан
  50: _plant(0xFFFFD84A), // факел
  51: _plant(0xFFFF8C1A), // огонь
  52: _see(0xFF1E2C3A), // спаунер
  53: _cube(0xFFA7864F), // ступени
  54: _cube(0xFF9C6E2B), // сундук
  55: _plant(0xFFAA0000), // редстоун
  56: _cube(0xFF818C8F), // алмазная руда
  57: _cube(0xFF62DBD6), // алмазный блок
  58: _cube(0xFF8A5A33, top: 0xFFB08A5A), // верстак
  59: _plant(0xFFB5A33A), // пшеница
  60: _cube(0xFF5E3A1F), // грядка
  61: _cube(0xFF5F5F5F), // печь
  62: _cube(0xFF5F5F5F),
  63: _plant(0xFFA7864F), // табличка
  64: _see(0xFF8F6B3E), // дверь
  65: _plant(0xFF9B7A47), // лестница
  66: _plant(0xFF8B7355), // рельсы
  67: _cube(0xFF6E6E6E), // ступени из булыжника
  68: _plant(0xFFA7864F),
  69: _plant(0xFF6E6E6E), // рычаг
  70: _plant(0xFF7D7D7D),
  71: _see(0xFFC8C8C8), // железная дверь
  72: _plant(0xFFA7864F),
  73: _cube(0xFF846B6B), // редстоуновая руда
  74: _cube(0xFF846B6B),
  75: _plant(0xFFAA0000),
  76: _plant(0xFFFF2A2A),
  77: _plant(0xFF7D7D7D),
  78: _plant(0xFFF4FAFA), // слой снега
  79: _see(0xCC9CC3F5), // лёд
  80: _cube(0xFFF4FAFA), // снег
  81: _cube(0xFF0D7A1C), // кактус
  82: _cube(0xFF9EA4B0), // глина
  83: _plant(0xFF8BBF5A), // тростник
  85: _see(0xFFA7864F), // забор
  86: _cube(0xFFC97A15), // тыква
  87: _cube(0xFF6F3634), // незерак
  88: _cube(0xFF544034), // песок душ
  89: _cube(0xFFF9D49C), // светокамень
  90: _see(0xAA5A1E9A), // портал
  91: _cube(0xFFE3901D), // светильник Джека
  92: _cube(0xFFE4CDCE), // торт
  95: _see(0x88FFFFFF),
  96: _see(0xFF7E5D2D), // люк
  97: _cube(0xFF7D7D7D),
  98: _cube(0xFF7A7A7A), // каменные кирпичи
  99: _cube(0xFF8E6B53), // гриб-блок
  100: _cube(0xFFB62523),
  101: _see(0xFF6D6C6A), // решётка
  102: _see(0x66C8E6F0), // стеклянная панель
  103: _cube(0xFF8D9A23, top: 0xFFA0A82E), // арбуз
  104: _plant(0xFF5E9A3A),
  105: _plant(0xFF5E9A3A),
  106: _plant(0xFF2F6F1E), // лианы
  107: _see(0xFFA7864F), // калитка
  108: _cube(0xFF96614F),
  109: _cube(0xFF7A7A7A),
  110: _cube(0xFF6F6369, top: 0xFF8A7090), // мицелий
  111: _plant(0xFF208030), // кувшинка
  112: _cube(0xFF2C161A), // адский кирпич
  113: _see(0xFF2C161A),
  114: _cube(0xFF2C161A),
  115: _plant(0xFF8A1A1A),
  116: _cube(0xFF5A1E1E, top: 0xFF8C2E2E), // стол зачарований
  117: _plant(0xFF7A6A50),
  118: _cube(0xFF3F3F3F), // котёл
  120: _cube(0xFF3C6B5A), // рамка портала Края
  121: _cube(0xFFDDDFA5), // камень Края
  122: _cube(0xFF1E0F2A), // яйцо дракона
  123: _cube(0xFF6E3B1E), // лампа
  124: _cube(0xFFC9935A),
  125: _cube(0xFF9A2A1A), // дроппер
  126: _cube(0xFFA7864F),
  127: _plant(0xFFA0602A), // какао
  128: _cube(0xFFD8CB9B),
  129: _cube(0xFF6D8074), // изумрудная руда
  130: _cube(0xFF14121D), // сундук Края
  131: _plant(0xFF8A8A8A),
  132: _plant(0xFF8A8A8A),
  133: _cube(0xFF51D975), // изумрудный блок
  134: _cube(0xFF6B5139),
  135: _cube(0xFFC4B07B),
  136: _cube(0xFF9A6E44),
  139: _see(0xFF6E6E6E), // стена из булыжника
  140: _plant(0xFF7A3B2B), // цветочный горшок
  141: _plant(0xFF3E8C1E), // морковь
  142: _plant(0xFF3E8C1E), // картофель
  143: _plant(0xFFA7864F),
  144: _plant(0xFFC8C8C8), // голова
  145: _cube(0xFF444444), // наковальня
  146: _cube(0xFF9C6E2B),
  147: _plant(0xFFF9D849),
  148: _plant(0xFFDBDBDB),
  151: _cube(0xFF8A7A5A, top: 0xFFD0C2A0), // датчик дневного света
  152: _cube(0xFFAB1B09), // блок редстоуна
  153: _cube(0xFF7D5450), // кварцевая руда
  154: _cube(0xFF434343), // воронка
  155: _cube(0xFFECE6DF), // кварц
  156: _cube(0xFFECE6DF),
  157: _plant(0xFF8B7355),
  158: _cube(0xFFA7864F),
  159: _cube(0xFF985E43), // окрашенная глина (цвет по мете)
  160: _see(0x88FFFFFF),
  161: _see(0xFF4A8A2A), // листва акации/тёмного дуба
  162: _cube(0xFF5E4A35, top: 0xFFA5824F, bottom: 0xFFA5824F),
  163: _cube(0xFFAD5D32),
  164: _cube(0xFF422A13),
  165: _see(0xCC78C865), // блок слизи
  167: _see(0xFFC8C8C8),
  170: _cube(0xFFA8932A, top: 0xFFB8A23A), // сноп сена
  171: _plant(0xFFE9ECEC), // ковёр
  172: _cube(0xFF985E43), // обожжённая глина
  173: _cube(0xFF191919), // угольный блок
  174: _see(0xCC8DB4FA), // плотный лёд
  175: _plant(0xFF5E9A3A), // высокие растения
  178: _cube(0xFF8A7A5A, top: 0xFF5A6A8A),
  179: _cube(0xFFB65E26), // красный песчаник
  180: _cube(0xFFB65E26),
  181: _cube(0xFFB65E26),
  182: _cube(0xFFB65E26),
  183: _see(0xFF6B5139),
  184: _see(0xFFC4B07B),
  185: _see(0xFF9A6E44),
  186: _see(0xFF422A13),
  187: _see(0xFFAD5D32),
  188: _see(0xFF6B5139),
  189: _see(0xFFC4B07B),
  190: _see(0xFF9A6E44),
  191: _see(0xFF422A13),
  192: _see(0xFFAD5D32),
  193: _see(0xFF6B5139),
  194: _see(0xFFC4B07B),
  195: _see(0xFF9A6E44),
  196: _see(0xFFAD5D32),
  197: _see(0xFF422A13),
  198: _plant(0xFFE8E0D0), // стержень Края
  199: _plant(0xFF5E3A6E), // растение хоруса
  200: _cube(0xFF8A5E8A), // цветок хоруса
  201: _cube(0xFFA77BA7), // пурпур
  203: _cube(0xFFA77BA7),
  205: _cube(0xFF8E5E9E), // шалкер
  206: _cube(0xFFDDE0A5),
  207: _plant(0xFF5E8A2E), // свёкла
  208: _cube(0xFF946D45, top: 0xFF9A8A45), // тропинка
  213: _cube(0xFFC0491B), // магма
  214: _cube(0xFF7A0F10), // блок адского нароста
  215: _cube(0xFF450707),
  216: _cube(0xFFE0DCCB), // костяной блок
  218: _cube(0xFF8E5E9E),
  236: _cube(0xFF7D7D7D), // бетон
  237: _cube(0xFF9A9A9A), // цементный порошок
  241: _see(0x88FFFFFF),
  243: _cube(0xFF5A3E26, top: 0xFF6A5A30), // подзол
  244: _plant(0xFF5E8A2E),
  245: _cube(0xFF7A7A7A), // камнерез
  246: _cube(0xFF2A2140), // светящийся обсидиан
  247: _cube(0xFF5A1414), // ядро реактора
};

/// Неизвестный ID рисуется пурпурным кубом, чтобы его было видно.
const BlockInfo _unknown = BlockInfo(BlockShape.cube, 0xFFB000B0);

BlockInfo blockInfo(int id) => _blocks[id] ?? _unknown;

final List<BlockInfo> blockTable = List.generate(256, blockInfo, growable: false);

/// Цвет блока с учётом метаданных (окрашенные блоки).
int blockColor(int id, int meta) {
  if (id == 35 || id == 159 || id == 171 || id == 236 || id == 237 || id == 95 || id == 160 || id == 241) {
    final c = dyeColors[meta & 15];
    final info = blockTable[id];
    if (id == 159) return _mix(c, 0xFF985E43, 0.45);
    return info.opaque ? c : (c & 0x00FFFFFF) | (info.color & 0xFF000000);
  }
  return blockTable[id].color;
}

int _mix(int a, int b, double t) {
  int ch(int shift) => (((a >> shift) & 0xff) * (1 - t) + ((b >> shift) & 0xff) * t).round();
  return 0xFF000000 | (ch(16) << 16) | (ch(8) << 8) | ch(0);
}
