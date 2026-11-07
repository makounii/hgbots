--[[
	Tarkov AI - Translations

	Small dictionary used by the settings menu. The language follows the
	game's own language setting (gmod_language) on the client; the server
	side just falls back to English, since it only ever prints to console.

	Adding a language is hg.bots.Lang.Add("de", { ... }) from anywhere -
	missing keys fall through to English, and a key with no translation at
	all shows as itself, so a forgotten string is visible rather than nil.

	Setting labels are deliberately NOT all translated one by one: a
	parameter shows its own convar name (prettified) with the convar's help
	text as the tooltip, which stays correct when parameters are added or
	renamed. Anything worth a nicer name can simply be given a "cv.<name>"
	key here.
]]

hg = hg or {}
hg.bots = hg.bots or {}

hg.bots.Lang = hg.bots.Lang or {}

local Lang = hg.bots.Lang

Lang.Strings = Lang.Strings or {}

function Lang.Add(code, tbl)
	Lang.Strings[code] = Lang.Strings[code] or {}

	for k, v in pairs(tbl) do
		Lang.Strings[code][k] = v
	end
end

Lang.Add("en", {
	["title"] = "Tarkov AI Bots",
	["settings"] = "Settings",
	["actions"] = "Actions",
	["group.general"] = "General",
	["group.vision"] = "Vision & hearing",
	["group.alert"] = "Alert (weapon out)",
	["group.combat"] = "Combat",
	["group.stealth"] = "Stalking",
	["group.gear"] = "Gear",
	["group.movement"] = "Movement",
	["group.melee"] = "Melee",
	["group.grenades"] = "Grenades",
	["group.medical"] = "Medical",
	["group.downed"] = "Downed / ragdoll",
	["group.loot"] = "Looting",
	["group.squad"] = "Squad",
	["group.morale"] = "Morale",
	["group.voice"] = "Voice",
	["group.navpatch"] = "Navmesh patching",
	["group.debug"] = "Debug",
	["group.factions"] = "Factions & NPCs",
	["group.director"] = "AI director",
	["cv.hg_bot_director_mode"] = "Director combat mode",
	["director.mode.survival"] = "Survival (original director)",
	["director.mode.tdm"] = "TDM: players and guards vs raiders",
	["director.mode.ffa"] = "Free for all: everyone is an enemy",
	["act.director_settings"] = "Configure the AI director",
	["director.settings.help"] = "Choose a combat mode below, then enable the director. The highlighted mode applies immediately to its existing bots too. You can also press E on a director entity to open this page.",
	["group.cleanup"] = "Cleanup",
	["act.spawn_guard"] = "Spawn a bot friendly to players",
	["act.director_place"] = "Place the AI director",
	["act.director_status"] = "Director status",
	["act.director_clear"] = "Remove the director's bots",
	["act.spawn"] = "Spawn a bot where you're looking",
	["act.spawn_random"] = "Spawn a bot with a random kit",
	["act.spawn_kit"] = "Spawn a bot with the selected kit",
	["act.kit_save"] = "Save my gear as a kit",
	["act.kit_delete"] = "Delete the selected kit",
	["kits"] = "Gear presets",
	["kit.name"] = "Name for the new kit",
	["act.removeall"] = "Remove all bots",
	["act.reinit"] = "Re-initialize",
	["act.state"] = "Print state",
	["act.navpatch"] = "Save patched navmesh",
	["act.navpatch_undo"] = "Undo navmesh patches",
	["preset.wild"] = "Wild and aggressive",
	["preset.careful"] = "Careful",
	["preset.trusted"] = "Trust mode",
	["preset.perf"] = "Lighter on the server",
	["presets"] = "Presets",
	["bots.count"] = "Bots alive: %d",
	["need.admin"] = "Admin rights needed",
	["need.superadmin"] = "Superadmin rights needed",
	["no.rights"] = "You don't have the rights for that.",
	["applied"] = "Applied: %s",
	["refresh"] = "Refresh",
	["search"] = "Search settings",
	["search.results"] = "Search",
	["search.none"] = "Nothing matches that.",
	["ctx.state"] = "What is it doing?",
	["ctx.overlay"] = "Name tags over bots",
	["ctx.faction"] = "Faction",
	["ctx.faction.raider"] = "Raider (hostile)",
	["ctx.faction.guard"] = "Guard (friendly)",
	["ctx.gear"] = "Gear",
	["ctx.gear.random"] = "Give a random kit",
	["ctx.gear.strip"] = "Take everything away",
	["ctx.orders"] = "Orders",
	["ctx.order.come"] = "Go where I'm looking",
	["ctx.order.hold"] = "Hold that spot",
	["ctx.order.follow"] = "Follow me",
	["ctx.order.stop"] = "Cancel the order",
	["ctx.freeze"] = "Freeze / unfreeze the AI",
	["ctx.teleport"] = "Teleport it to my crosshair",
	["ctx.remove"] = "Remove this bot",
	["reset"] = "Default",
	["reset.group"] = "Reset this page to defaults",
	["builder"] = "Kit builder",
	["kit.new"] = "New kit",
	["kit.capture"] = "Take my current gear",
	["kit.roll"] = "Roll a random kit",
	["kit.save"] = "Save kit",
	["kit.spawn"] = "Spawn a bot with this kit",
	["kit.contents"] = "In this kit",
	["kit.available"] = "Available",
	["kit.ammo"] = "Ammo",
	["kit.add"] = "Add",
	["kit.remove"] = "Remove",
	["kit.empty"] = "Pick a kit on the left, or make a new one.",
	["cat.pistol"] = "Pistols",
	["cat.light"] = "Light guns",
	["cat.heavy"] = "Heavy guns",
	["cat.melee"] = "Melee",
	["cat.grenade"] = "Grenades",
	["cat.med"] = "Medical",
	["cat.armor"] = "Armour",
	["tier"] = "Tier",
	["tier.low"] = "Scav",
	["tier.mid"] = "Fighter",
	["tier.high"] = "Raider",
	["tier.any"] = "Any",
	["role"] = "Role",
	["act.cleanup_now"] = "Clean up bot corpses and gore now",
	["ban.title"] = "Random kit items",
	["ban.filter"] = "Filter items",
	["ban.help"] = "Unticked items never turn up in random kits (random spawn, hg_bot_kit_random, a rolled kit, the AI director). Kits you build by hand are not affected. Pluviska and the Fury-13 / 'Uber' Fury-16 syringes are never given to bots at all.",
	["cv.hg_bot_kit_adminonly"] = "Admin-only weapons in random kits",
	["cv.hg_bot_fury"] = "Fury-13 shot right after spawning",
	["cv.hg_bot_fury_chance"] = "Fury-13: share of bots",
	["cv.hg_bot_fury_delay"] = "Fury-13: seconds after spawn",
	["cv.hg_bot_grenade_desperate"] = "Badly wounded: spend the grenade",
	["cv.hg_bot_grenade_martyr"] = "Badly wounded: may blow itself up",
	["cv.hg_bot_grenade_martyr_dist"] = "Blow itself up when the enemy is closer than",
	["cv.hg_bot_grenade_desperate_hp"] = "Badly wounded below health share",
	["cv.hg_bot_grenade_desperate_blood"] = "Badly wounded below blood",
	["models.title"] = "Bot models",
	["models.help"] = "Click a model to tick it (green frame). With the switch below on, every new bot wears a random ticked model; off - Z-City's own random look. Right click a model to put it on every bot alive. One bot: right click it - Model.",
	["models.filter"] = "Filter models",
	["models.reroll"] = "Re-roll models of the bots alive",
	["models.all"] = "Put this on every bot alive",
	["models.copy"] = "Copy the model path",
	["models.pick"] = "Model for %s",
	["models.default"] = "Default model (Z-City / the pool)",
	["models.limit"] = "only the first %d models are shown - use the filter",
	["ctx.model"] = "Model",
	["ctx.model.pick"] = "Choose a model...",
	["cv.hg_bot_model_mode"] = "New bots wear a model from the ticked ones",
	["act.spawn_neutral"] = "Spawn a neutral bot (fights only who attacks it)",
	["act.director_on"] = "Director: on",
	["act.director_off"] = "Director: off (removes its entities too)",
	["ban.all_on"] = "Tick all",
	["ban.all_off"] = "Untick all",
	["names.help"] = "Names for new bots, one per line (empty = Z-City's random names):",
	["names.save"] = "Save names",
	["voices.title"] = "Voices",
	["voices.help"] = "Ticked packs are used by bots. Each bot keeps one voice and its own pitch; a woman's model gets a woman's pack when one is ticked. Built-in packs use Half-Life 2 sounds (rebels, Combine, metrocops). Packs from other addons: sound/hgbots_voices/<pack>/ or hg.bots.RegisterVoicePack. One bot: right click it - Voice.",
	["voices.reload"] = "Reload voice packs",
	["voices.female"] = "female",
	["voices.male"] = "male",
	["voices.builtin"] = "built-in",
	["voices.lines"] = "lines",
	["voices.none"] = "No voice packs found.",
	["ctx.faction.neutral"] = "Neutral (only fights back)",
	["ctx.rename"] = "Rename",
	["ctx.rename.help"] = "New name (empty = back to the default):",
	["ctx.voice"] = "Voice",
	["ctx.voice.auto"] = "Automatic",
	["cv.hg_bot_voice_pitch"] = "Voice pitch spread between bots",
	["cv.hg_bot_neutral_memory"] = "Neutral: seconds it holds a grudge against a bot",
	["cv.hg_bot_neutral_help"] = "Neutral: neighbours join in within",
})

Lang.Add("ru", {
	["title"] = "Боты Tarkov AI",
	["settings"] = "Настройки",
	["actions"] = "Действия",
	["group.general"] = "Общее",
	["group.vision"] = "Зрение и слух",
	["group.alert"] = "Готовность (оружие наготове)",
	["group.combat"] = "Бой",
	["group.stealth"] = "Подкрадывание",
	["group.gear"] = "Снаряжение",
	["group.movement"] = "Передвижение",
	["group.melee"] = "Ближний бой",
	["group.grenades"] = "Гранаты",
	["group.medical"] = "Медицина",
	["group.downed"] = "Рэгдолл",
	["group.loot"] = "Лут",
	["group.squad"] = "Звено",
	["group.morale"] = "Мораль",
	["group.voice"] = "Озвучка",
	["group.navpatch"] = "Правка навмеша",
	["group.debug"] = "Отладка",
	["group.factions"] = "Фракции и НИПы",
	["group.director"] = "ИИ режиссёр",
	["cv.hg_bot_director_mode"] = "Режим боя режиссёра",
	["director.mode.survival"] = "Выживание (обычный режиссёр)",
	["director.mode.tdm"] = "TDM: игроки и охрана против рейдеров",
	["director.mode.ffa"] = "Каждый сам за себя",
	["act.director_settings"] = "Настроить режиссёра",
	["director.settings.help"] = "Выбери режим боя ниже, затем включи режиссёра. Выделенный режим сразу применяется и к уже созданным ботам режиссёра. Это меню также открывается по E на его сущности.",
	["group.cleanup"] = "Уборка",
	["act.spawn_guard"] = "Заспавнить дружелюбного бота",
	["act.director_place"] = "Поставить ИИ режиссёра",
	["act.director_status"] = "Состояние режиссёра",
	["act.director_clear"] = "Убрать ботов режиссёра",
	["act.spawn"] = "Заспавнить бота по прицелу",
	["act.spawn_random"] = "Заспавнить бота со случайным набором",
	["act.spawn_kit"] = "Заспавнить бота с выбранным набором",
	["act.kit_save"] = "Сохранить моё снаряжение как набор",
	["act.kit_delete"] = "Удалить выбранный набор",
	["kits"] = "Наборы снаряжения",
	["kit.name"] = "Название нового набора",
	["act.removeall"] = "Удалить всех ботов",
	["act.reinit"] = "Переинициализировать",
	["act.state"] = "Показать состояние",
	["act.navpatch"] = "Сохранить правки навмеша",
	["act.navpatch_undo"] = "Отменить правки навмеша",
	["preset.wild"] = "Дикие и агрессивные",
	["preset.careful"] = "Осторожные",
	["preset.trusted"] = "Режим доверия",
	["preset.perf"] = "Щадящий сервер",
	["presets"] = "Пресеты",
	["bots.count"] = "Ботов живо: %d",
	["need.admin"] = "Нужны права админа",
	["need.superadmin"] = "Нужны права суперадмина",
	["no.rights"] = "Нет прав на это действие.",
	["applied"] = "Применено: %s",
	["refresh"] = "Обновить",
	["search"] = "Поиск по настройкам",
	["search.results"] = "Поиск",
	["search.none"] = "Ничего не найдено.",
	["ctx.state"] = "Что он делает?",
	["ctx.overlay"] = "Подписи над ботами",
	["ctx.faction"] = "Фракция",
	["ctx.faction.raider"] = "Рейдер (враг)",
	["ctx.faction.guard"] = "Гвардеец (союзник)",
	["ctx.gear"] = "Снаряжение",
	["ctx.gear.random"] = "Выдать случайный набор",
	["ctx.gear.strip"] = "Забрать всё",
	["ctx.orders"] = "Приказы",
	["ctx.order.come"] = "Идти, куда я смотрю",
	["ctx.order.hold"] = "Держать это место",
	["ctx.order.follow"] = "Идти за мной",
	["ctx.order.stop"] = "Отменить приказ",
	["ctx.freeze"] = "Заморозить или разморозить ИИ",
	["ctx.teleport"] = "Телепортировать на прицел",
	["ctx.remove"] = "Убрать этого бота",
	["reset"] = "По умолчанию",
	["reset.group"] = "Сбросить страницу к значениям по умолчанию",
	["builder"] = "Конструктор наборов",
	["kit.new"] = "Новый набор",
	["kit.capture"] = "Взять моё снаряжение",
	["kit.roll"] = "Сгенерировать случайный набор",
	["kit.save"] = "Сохранить набор",
	["kit.spawn"] = "Заспавнить бота с этим набором",
	["kit.contents"] = "В наборе",
	["kit.available"] = "Доступно",
	["kit.ammo"] = "Патроны",
	["kit.add"] = "Добавить",
	["kit.remove"] = "Убрать",
	["kit.empty"] = "Выбери набор слева или создай новый.",
	["cat.pistol"] = "Пистолеты",
	["cat.light"] = "Лёгкое оружие",
	["cat.heavy"] = "Тяжёлое оружие",
	["cat.melee"] = "Холодное оружие",
	["cat.grenade"] = "Гранаты",
	["cat.med"] = "Медицина",
	["cat.armor"] = "Броня",
	["tier"] = "Класс",
	["tier.low"] = "Дикий",
	["tier.mid"] = "Боец",
	["tier.high"] = "Рейдер",
	["tier.any"] = "Любой",
	["role"] = "Роль",
	["act.cleanup_now"] = "Убрать трупы и ошмётки ботов сейчас",
	["ban.title"] = "Предметы в случайных наборах",
	["ban.filter"] = "Фильтр",
	["ban.help"] = "Снятые галочки - эти предметы никогда не попадут в случайный набор (случайный спавн, hg_bot_kit_random, сгенерированный набор, ИИ режиссёр). Наборы, собранные вручную, не затрагиваются. Pluviska и шприцы Fury-13 / 'Uber' Fury-16 боты не получают вообще.",
	["cv.hg_bot_kit_adminonly"] = "Админ-оружие в случайных наборах",
	["cv.hg_bot_fury"] = "Укол Fury-13 сразу после спавна",
	["cv.hg_bot_fury_chance"] = "Fury-13: доля ботов",
	["cv.hg_bot_fury_delay"] = "Fury-13: секунд после спавна",
	["cv.hg_bot_grenade_desperate"] = "Тяжело ранен: пустить гранату в ход",
	["cv.hg_bot_grenade_martyr"] = "Тяжело ранен: может подорвать себя",
	["cv.hg_bot_grenade_martyr_dist"] = "Подрыв себя, если враг ближе",
	["cv.hg_bot_grenade_desperate_hp"] = "Тяжело ранен: доля здоровья ниже",
	["cv.hg_bot_grenade_desperate_blood"] = "Тяжело ранен: крови меньше",
	["models.title"] = "Модели ботов",
	["models.help"] = "Клик по модели - отметить её (зелёная рамка). Если переключатель ниже включён, каждый новый бот получает случайную модель из отмеченных; выключен - обычный случайный вид Z-City. ПКМ по модели - надеть её на всех живых ботов. Одному боту: ПКМ по нему - Модель.",
	["models.filter"] = "Фильтр моделей",
	["models.reroll"] = "Перевыбрать модели живым ботам",
	["models.all"] = "Надеть на всех живых ботов",
	["models.copy"] = "Скопировать путь модели",
	["models.pick"] = "Модель для %s",
	["models.default"] = "Модель по умолчанию (Z-City / отмеченные)",
	["models.limit"] = "показаны только первые %d моделей - используй фильтр",
	["ctx.model"] = "Модель",
	["ctx.model.pick"] = "Выбрать модель...",
	["cv.hg_bot_model_mode"] = "Новые боты в моделях из отмеченных",
	["act.spawn_neutral"] = "Заспавнить нейтрального бота (бьёт только тех, кто напал)",
	["act.director_on"] = "Режиссёр: включить",
	["act.director_off"] = "Режиссёр: выключить (и убрать его сущности)",
	["ban.all_on"] = "Отметить все",
	["ban.all_off"] = "Снять все",
	["names.help"] = "Имена для новых ботов, по одному в строке (пусто - случайные имена Z-City):",
	["names.save"] = "Сохранить имена",
	["voices.title"] = "Голоса",
	["voices.help"] = "Отмеченные паки используют боты. Каждый бот держит один голос и свой тон; женской модели достаётся женский пак, если такой отмечен. Встроенные паки - звуки Half-Life 2 (повстанцы, комбайны, метрокопы). Паки из других аддонов: sound/hgbots_voices/<пак>/ или hg.bots.RegisterVoicePack. Одному боту: ПКМ по нему - Голос.",
	["voices.reload"] = "Перезагрузить голосовые паки",
	["voices.female"] = "женский",
	["voices.male"] = "мужской",
	["voices.builtin"] = "встроенный",
	["voices.lines"] = "реплик",
	["voices.none"] = "Голосовых паков не найдено.",
	["ctx.faction.neutral"] = "Нейтрал (только отвечает)",
	["ctx.rename"] = "Переименовать",
	["ctx.rename.help"] = "Новое имя (пусто - вернуть по умолчанию):",
	["ctx.voice"] = "Голос",
	["ctx.voice.auto"] = "Автоматически",
	["cv.hg_bot_voice_pitch"] = "Разброс тона голоса между ботами",
	["cv.hg_bot_neutral_memory"] = "Нейтрал: сколько секунд помнит напавшего бота",
	["cv.hg_bot_neutral_help"] = "Нейтрал: соседи вступаются в радиусе",
})

--- Current language code.
function Lang.Code()
	if CLIENT then
		local cvar = GetConVar("gmod_language")
		local code = cvar and cvar:GetString() or "en"

		return (code ~= "" and code) or "en"
	end

	return "en"
end

--- Translated string, falling back to English and then to the key itself.
function hg.bots.L(key)
	local code = Lang.Code()
	local tbl = Lang.Strings[code]

	if tbl and tbl[key] then return tbl[key] end

	local en = Lang.Strings.en

	if en and en[key] then return en[key] end

	return key
end

--- Label for one setting: a translation if somebody wrote one, otherwise
-- the convar name without its prefix and with the underscores opened up.
function hg.bots.LSetting(name)
	local code = Lang.Code()
	local tbl = Lang.Strings[code]
	local key = "cv." .. name

	if tbl and tbl[key] then return tbl[key] end

	local en = Lang.Strings.en

	if en and en[key] then return en[key] end

	return string.Replace(string.Replace(name, "hg_bot_", ""), "_", " ")
end
