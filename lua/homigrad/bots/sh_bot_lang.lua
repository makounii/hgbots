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
