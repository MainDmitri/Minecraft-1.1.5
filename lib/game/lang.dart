/// Перевод ключей, которые серверы MCPE 1.1 присылают вместо готового текста.
/// Переводы написаны для этого клиента; незнакомый ключ показывается как есть вместе с параметрами.
const Map<String, String> _ru = {
  'chat.type.text': '<%s> %s',
  'chat.type.emote': '* %s %s',
  'chat.type.announcement': '[%s] %s',
  'chat.type.admin': '[%s: %s]',
  'chat.type.achievement': '%s получает достижение %s',
  'multiplayer.player.joined': '%s заходит в игру',
  'multiplayer.player.left': '%s выходит из игры',
  'commands.generic.unknown': 'Неизвестная команда. Введите /help, чтобы увидеть список команд',
  'commands.generic.permission': 'Недостаточно прав для этой команды',
  'commands.generic.notFound': 'Неизвестная команда. Введите /help, чтобы увидеть список команд',
  'commands.generic.usage': 'Использование: %s',
  'commands.generic.player.notFound': 'Игрок не найден',
  'commands.generic.exception': 'При выполнении команды произошла ошибка',
  'commands.message.sameTarget': 'Нельзя отправить личное сообщение самому себе',
  'commands.help.header': '--- Список команд: страница %s из %s ---',
  'commands.message.display.incoming': '%s шепчет вам: %s',
  'commands.message.display.outgoing': 'Вы шепчете %s: %s',
  'commands.tp.success': '%s телепортирован(а) к %s',
  'commands.tp.success.coordinates': '%s телепортирован(а) на %s, %s, %s',
  'commands.time.set': 'Время установлено: %s',
  'commands.time.added': 'К времени добавлено %s',
  'commands.gamemode.success.self': 'Ваш режим игры изменён: %s',
  'commands.gamemode.success.other': 'Режим игры игрока %s изменён: %s',
  'commands.give.success': 'Выдано %s × %s игроку %s',
  'commands.kill.successful': '%s убит(а)',
  'commands.players.list': 'Онлайн %s/%s:',
  'commands.weather.clear': 'Погода: ясно',
  'commands.weather.rain': 'Погода: дождь',
  'commands.weather.thunder': 'Погода: гроза',
  'commands.difficulty.success': 'Сложность изменена: %s',
  'commands.spawnpoint.success': 'Точка возрождения игрока %s: %s, %s, %s',
  'commands.op.success': '%s получает права оператора',
  'commands.deop.success': '%s лишается прав оператора',
  'commands.kick.success': '%s кикнут(а) с сервера',
  'commands.kick.success.reason': '%s кикнут(а) с сервера: %s',
  'commands.ban.success': '%s заблокирован(а)',
  'commands.say.usage': '/say <сообщение>',
  'gameMode.survival': 'Выживание',
  'gameMode.creative': 'Творчество',
  'gameMode.adventure': 'Приключение',
  'gameMode.spectator': 'Наблюдатель',
  'gameMode.changed': 'Режим игры изменён',
  'tile.bed.noSleep': 'Спать можно только ночью',
  'tile.bed.occupied': 'Кровать занята',
  'tile.bed.respawnSet': 'Точка возрождения установлена',
  'tile.bed.tooFar': 'Кровать слишком далеко',
  'tile.bed.notValid': 'Кровать отсутствует или заблокирована',
  'death.attack.generic': '%s погибает',
  'death.attack.player': '%s погибает от руки игрока %s',
  'death.attack.mob': '%s погибает от %s',
  'death.attack.arrow': '%s застрелен(а) игроком %s',
  'death.attack.explosion': '%s погибает от взрыва',
  'death.attack.explosion.player': '%s погибает от взрыва, устроенного %s',
  'death.attack.fall': '%s разбивается при падении',
  'death.fell.accident.generic': '%s разбивается при падении',
  'death.attack.drown': '%s тонет',
  'death.attack.lava': '%s пытается плавать в лаве',
  'death.attack.inFire': '%s сгорает',
  'death.attack.onFire': '%s сгорает заживо',
  'death.attack.inWall': '%s задыхается в стене',
  'death.attack.cactus': '%s исколот(а) кактусом',
  'death.attack.outOfWorld': '%s выпадает из мира',
  'death.attack.starve': '%s умирает от голода',
  'death.attack.magic': '%s погибает от магии',
  'death.attack.wither': '%s иссыхает',
  'death.attack.lightningBolt': '%s поражён(а) молнией',
  'death.attack.anvil': '%s раздавлен(а) наковальней',
  'death.attack.fallingBlock': '%s раздавлен(а) упавшим блоком',
  'potion.saturation': 'Насыщение',
  'disconnectionScreen.outdatedClient': 'Версия клиента устарела: сервер работает на более новой версии, чем 1.1.x',
  'disconnectionScreen.outdatedServer': 'Версия сервера устарела: сервер работает на версии старше 1.1.x',
  'disconnectionScreen.serverFull': 'Сервер заполнен',
  'disconnectionScreen.invalidName': 'Сервер не принял ник',
  'disconnectionScreen.invalidSkin': 'Сервер не принял скин',
  'disconnectionScreen.notAuthenticated': 'Сервер требует вход через Xbox Live, а этот клиент его не поддерживает',
  'disconnectionScreen.noReason': 'Сервер отключил вас без указания причины',
  'disconnectionScreen.resourcePack': 'Ошибка пакета ресурсов на сервере',
  'disconnectionScreen.loggedinOtherLocation': 'Игрок с этим ником уже вошёл на сервер',
  'disconnectionScreen.timeout': 'Время ожидания истекло',
  'disconnectionScreen.serverIdConflict': 'Конфликт идентификатора сервера',
  'disconnectionScreen.notAllowed': 'Вход на сервер запрещён (белый список)',
  'disconnectionScreen.worldCorruption': 'Мир на сервере повреждён',
  'disconnectionScreen.invalidTenant': 'Сервер не принимает эту версию игры',
  'disconnectionScreen.editionMismatch': 'Сервер работает для другой редакции игры',
};

final RegExp _keyRef = RegExp(r'%([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)');
final RegExp _placeholder = RegExp(r'%(?:(\d+)\$)?([sd])|\{%(\d+)\}');

String _lookup(String key) => _ru[key] ?? key;

bool isKnownKey(String key) => _ru.containsKey(key);

String _fill(String template, List<String> params) {
  var next = 0;
  return template.replaceAllMapped(_placeholder, (m) {
    int index;
    if (m.group(3) != null) {
      index = int.parse(m.group(3)!);
    } else if (m.group(1) != null) {
      index = int.parse(m.group(1)!) - 1;
    } else {
      index = next++;
    }
    return index >= 0 && index < params.length ? params[index] : '';
  });
}

/// Перевод ключа (с ведущим '%' или без) с подстановкой параметров.
String translate(String message, List<String> params) {
  final translatedParams = params.map((p) => translate(p, const [])).toList();
  final bare = message.startsWith('%') ? message.substring(1) : message;
  if (_ru.containsKey(bare)) {
    return _fill(_lookup(bare), translatedParams);
  }
  final replaced = message.replaceAllMapped(_keyRef, (m) {
    final key = m.group(1)!;
    return _ru.containsKey(key) ? _lookup(key) : m.group(0)!;
  });
  final filled = _fill(replaced, translatedParams);
  if (filled == message && params.isNotEmpty && !_placeholder.hasMatch(replaced)) {
    return '$message ${translatedParams.join(' ')}';
  }
  return filled;
}
