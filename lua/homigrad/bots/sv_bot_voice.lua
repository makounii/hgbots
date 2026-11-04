--[[
	Tarkov AI - Voice

	Scav voice lines, tied to what the bot is actually doing. The lines are
	found on disk rather than listed here: everything in sound/<path>/ is
	grouped by the category in its own file name, so dropping more files in
	(or a second voice set) needs no code change.

	Voice packs are folders under sound/<path>/: scav1 .. scav6. Each bot
	gets one of them for its whole life, so a single bot always sounds like
	the same person, while a squad is a mix of voices. Files lying loose
	directly in the folder still work as the pack "default".

	File names look like scav1_enemy_down_03_bl.wav:
		scav1_      who is speaking (any prefix works)
		enemy_down  the category - this is what gets matched to an event
		_03         the take
		_bl/_l/_n   variant: _bl is the swearing take, _l a shouted one,
		            _n a normal one. Swearing can be switched off.

	Spam control, because 6 bots with 350 lines will otherwise talk over
	each other non-stop:
	- one line per bot at a time, with a gap after it (hg_bot_voice_gap);
	- a per-category cooldown, so the same line doesn't repeat;
	- a server-wide gap, so a squad doesn't shout in chorus;
	- a chance roll per event - most events stay silent;
	- nothing is said at all when no human is close enough to hear it,
	  except death, which is the one line worth playing to a room;
	- priority: pain and death interrupt chatter, chatter never interrupts
	  anything.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {}

local hg_bot_voice        = CreateConVar("hg_bot_voice",        "1",      {FCVAR_ARCHIVE}, "Bots speak (Tarkov scav voice lines)", 0, 1)
local hg_bot_voice_path   = CreateConVar("hg_bot_voice_path",   "voice/", {FCVAR_ARCHIVE}, "Folder under sound/ holding the voice lines")
local hg_bot_voice_gap    = CreateConVar("hg_bot_voice_gap",    "6",      {FCVAR_ARCHIVE}, "Minimum seconds between two lines from the same bot", 0.5, 60)
local hg_bot_voice_world  = CreateConVar("hg_bot_voice_world",  "1.2",    {FCVAR_ARCHIVE}, "Minimum seconds between lines from DIFFERENT bots, so a squad doesn't talk in chorus", 0, 10)
local hg_bot_voice_range  = CreateConVar("hg_bot_voice_range",  "2500",   {FCVAR_ARCHIVE}, "A bot stays quiet when no player is within this distance", 200, 10000)
local hg_bot_voice_volume = CreateConVar("hg_bot_voice_volume", "80",     {FCVAR_ARCHIVE}, "Sound level of voice lines (75 is a normal shout)", 40, 150)
local hg_bot_voice_swear  = CreateConVar("hg_bot_voice_swear",  "1",      {FCVAR_ARCHIVE}, "Allow the swearing takes (the _bl files)", 0, 1)
local hg_bot_voice_chatter = CreateConVar("hg_bot_voice_chatter", "1",    {FCVAR_ARCHIVE}, "Idle muttering and other low-priority chatter", 0, 1)
local hg_bot_voice_fastdl = CreateConVar("hg_bot_voice_fastdl", "1",      {FCVAR_ARCHIVE}, "Send the voice files to clients (resource.AddFile). Turn off if the addon is installed on clients anyway", 0, 1)
local hg_bot_voice_pack   = CreateConVar("hg_bot_voice_pack",   "",       {FCVAR_ARCHIVE}, "Force every bot onto one voice pack (scav1 ... scav6). Empty = each bot gets its own")
local hg_bot_voice_pitch  = CreateConVar("hg_bot_voice_pitch",  "8",      {FCVAR_ARCHIVE}, "How far one bot's voice pitch may differ from another's (each bot keeps its own), so two bots on the same pack don't sound like twins", 0, 30)

--\\ Loading the lines
	--[[
		Where packs come from:

		1. Folders of .wav files named by category (the Tarkov packs):
		   sound/<hg_bot_voice_path>/<pack>/ (voice/scav1 .. scav6), and
		   sound/hgbots_voices/<pack>/ - the folder meant for voice-pack
		   addons, so a pack can live in its own Workshop item and be
		   installed or removed without touching this addon. Loose files
		   directly in hg_bot_voice_path are the pack "default".

		2. hg.bots.RegisterVoicePack(name, def) from any addon's Lua, for
		   packs that reuse sounds already in the game:
		     def.sex    "m" / "f" / nil - matched against the bot's model
		     def.folder "some/dir/" - files named by category, as above
		     def.lines  { enemy_contact = { "path.wav", ... }, ... }
		     def.scan   { dir = "vo/npc/male01/", rules = {
		                    { "^pain", { "hit", "hurt_light" } }, ... } }
		                every .wav in dir whose name matches a Lua pattern
		                goes into those categories
		   Every path is checked to exist, so a pack built for content a
		   server doesn't have just ends up smaller (or empty and skipped).

		3. Built in, from Half-Life 2 sounds every GMod install has:
		   rebel_m, rebel_f (citizens), combine, metrocop. Off by default
		   while the Tarkov packs are there; on when they aren't.

		Which packs bots may use is ticked on the menu's "Voices" page
		(data/hg_bots_voices.json).
	]]

	-- [pack] = { [category] = { all = {paths}, clean = {paths} } }
	hg.bots.VoiceLines = {}
	hg.bots.VoicePacks = {}
	hg.bots.VoiceInfo = {} -- [pack] = { sex = "m"|"f"|nil, builtin = bool, lines = n }
	hg.bots.VoiceRegistry = hg.bots.VoiceRegistry or {}

	local EXTRA_ROOT = "hgbots_voices/"

	--- scav1_enemy_down_03_bl.wav -> "enemy_down", and whether it's the
	-- swearing take. Take numbers and variant tags stack (mutter_18_l_bl).
	local function CategoryOf(fileName)
		local base = string.StripExtension(fileName)
		local swear = string.find(base, "_bl$") ~= nil
		local cat = string.gsub(base, "^%a+%d*_", "") -- speaker prefix

		for _ = 1, 4 do
			cat = string.gsub(cat, "_bl$", "")
			cat = string.gsub(cat, "_[ln]$", "")
			cat = string.gsub(cat, "_%d+$", "")
		end

		return cat, swear
	end

	local function AddLine(pack, cat, path, swear, download)
		local lines = hg.bots.VoiceLines[pack]

		lines[cat] = lines[cat] or { all = {}, clean = {} }

		table.insert(lines[cat].all, path)

		if not swear then table.insert(lines[cat].clean, path) end

		if download and hg_bot_voice_fastdl:GetBool() then resource.AddFile("sound/" .. path) end
	end

	local function AddPackFiles(pack, dir)
		local files = file.Find("sound/" .. dir .. "*.wav", "GAME")
		local count = 0

		for _, name in ipairs(files or {}) do
			local cat, swear = CategoryOf(name)

			if cat ~= "" then
				AddLine(pack, cat, dir .. name, swear, true)
				count = count + 1
			end
		end

		return count
	end

	local function Exists(path)
		return file.Exists("sound/" .. path, "GAME")
	end

	--- A registered pack (see the comment at the top of this section).
	local function AddRegistered(pack, def)
		local count = 0

		if isstring(def.folder) then
			local dir = def.folder

			if string.Right(dir, 1) ~= "/" then dir = dir .. "/" end

			count = count + AddPackFiles(pack, dir)
		end

		for cat, paths in pairs(def.lines or {}) do
			for _, path in ipairs(istable(paths) and paths or { paths }) do
				if isstring(path) and Exists(path) then
					AddLine(pack, cat, path, false, false)
					count = count + 1
				end
			end
		end

		if istable(def.scan) and isstring(def.scan.dir) then
			local dir = def.scan.dir

			if string.Right(dir, 1) ~= "/" then dir = dir .. "/" end

			for _, name in ipairs(file.Find("sound/" .. dir .. "*.wav", "GAME") or {}) do
				local lower = string.lower(name)

				for _, rule in ipairs(def.scan.rules or {}) do
					if string.find(lower, rule[1]) then
						for _, cat in ipairs(rule[2]) do AddLine(pack, cat, dir .. name, false, false) end

						count = count + 1

						break
					end
				end
			end
		end

		return count
	end

	--- For voice-pack addons. Safe to call before or after this file
	-- loads; a pack added after the first load is picked up straight away.
	function hg.bots.RegisterVoicePack(name, def)
		if not isstring(name) or name == "" or not istable(def) then return false end

		hg.bots.VoiceRegistry[name] = def

		if hg.bots.LoadVoice then hg.bots.LoadVoice() end

		return true
	end

	local function LoadVoice()
		hg.bots.VoiceLines = {}
		hg.bots.VoicePacks = {}
		hg.bots.VoiceInfo = {}

		local count = 0

		local function Finish(pack, added, info)
			if added > 0 then
				table.insert(hg.bots.VoicePacks, pack)
				hg.bots.VoiceInfo[pack] = info
				count = count + added
			else
				hg.bots.VoiceLines[pack] = nil
			end
		end

		-- Folder packs, both roots.
		local roots = { hg_bot_voice_path:GetString(), EXTRA_ROOT }

		for _, dir in ipairs(roots) do
			if dir ~= "" then
				if string.Right(dir, 1) ~= "/" then dir = dir .. "/" end

				local _, dirs = file.Find("sound/" .. dir .. "*", "GAME")

				for _, sub in ipairs(dirs or {}) do
					if not hg.bots.VoiceLines[sub] then
						hg.bots.VoiceLines[sub] = {}

						Finish(sub, AddPackFiles(sub, dir .. sub .. "/"), { lines = 0 })
					end
				end
			end
		end

		local dir = hg_bot_voice_path:GetString()

		if dir ~= "" then
			if string.Right(dir, 1) ~= "/" then dir = dir .. "/" end

			hg.bots.VoiceLines.default = {}

			Finish("default", AddPackFiles("default", dir), { lines = 0 })
		end

		-- Registered packs (built-in and from other addons).
		for pack, def in pairs(hg.bots.VoiceRegistry) do
			if not hg.bots.VoiceLines[pack] then
				hg.bots.VoiceLines[pack] = {}

				local ok, added = pcall(AddRegistered, pack, def)

				Finish(pack, ok and added or 0, { sex = def.sex, builtin = def.builtin })
			end
		end

		for pack, info in pairs(hg.bots.VoiceInfo) do
			local n = 0

			for _, set in pairs(hg.bots.VoiceLines[pack] or {}) do n = n + #set.all end

			info.lines = n
		end

		table.sort(hg.bots.VoicePacks)

		return count
	end
--//

--\\ Built-in packs (Half-Life 2 sounds)
	-- Lua patterns over the file names in the folder -> our categories.
	-- Every file is checked to exist, so a guess that doesn't match the
	-- game's files simply adds nothing.
	local CITIZEN_RULES = {
		{ "^pain", { "hit", "hurt_light" } },
		{ "^ow", { "hit" } },
		{ "^moan", { "agony", "hurt_neardeath", "death" } },
		{ "^imhurt", { "hurt_neardeath", "needhelp" } },
		{ "^my[al][re][mg]", { "broke_hand", "broke_leg", "hurt_light" } },
		{ "^mygut", { "agony" } },
		{ "^help", { "needhelp" } },
		{ "^headsup", { "enemy_contact" } },
		{ "^over[th]", { "enemy_contact" } },
		{ "^upthere", { "enemy_contact" } },
		{ "^behindyou", { "enemy_contact" } },
		{ "^heretheycome", { "enemy_contact", "fight" } },
		{ "^incoming", { "enemy_contact", "enemy_grenade" } },
		{ "^watchout", { "enemy_contact", "enemy_grenade" } },
		{ "^getdown", { "enemy_grenade", "grenade" } },
		{ "^takecover", { "enemy_grenade", "coverme" } },
		{ "^runforyourlife", { "enemy_grenade", "fight_bad" } },
		{ "^gethellout", { "enemy_grenade", "fight_bad" } },
		{ "^gotone", { "enemy_down" } },
		{ "^likethat", { "enemy_down", "kill_knife" } },
		{ "^nice", { "enemy_down", "goodwork" } },
		{ "^fantastic", { "goodwork", "enemy_down" } },
		{ "^yeah", { "enemy_down", "fight_good" } },
		{ "^ohno", { "friendly_down", "fight_bad" } },
		{ "^goodgod", { "friendly_down" } },
		{ "^uhoh", { "fight_bad", "attention" } },
		{ "^coverwhilereload", { "weap_reload", "coverme" } },
		{ "^gottareload", { "weap_reload", "need_ammo" } },
		{ "^letsgo", { "going", "fight" } },
		{ "^okimready", { "start", "roger" } },
		{ "^readywhenyouare", { "start" } },
		{ "^ok%d", { "roger" } },
		{ "^yes%d", { "roger" } },
		{ "^no%d", { "negative" } },
		{ "^sorry", { "ffire" } },
		{ "^whoops", { "ffire" } },
		{ "^watchwhat", { "ffire" } },
		{ "^finally", { "clear" } },
		{ "^doingsomething", { "canyouhearit" } },
		{ "^question", { "mutter" } },
		{ "^vquestion", { "mutter" } },
		{ "^answer", { "mutter" } },
	}

	local COMBINE_RULES = {
		{ "contact", { "enemy_contact" } },
		{ "target", { "enemy_contact" } },
		{ "inbound", { "enemy_contact" } },
		{ "bouncer", { "grenade", "enemy_grenade" } },
		{ "flash", { "grenade" } },
		{ "grenade", { "grenade", "enemy_grenade" } },
		{ "cover", { "coverme", "weap_reload" } },
		{ "affirm", { "roger" } },
		{ "copy", { "roger" } },
		{ "roger", { "roger" } },
		{ "ready", { "start", "roger" } },
		{ "movein", { "going" } },
		{ "gogogo", { "going" } },
		{ "sharp", { "fight" } },
		{ "onedown", { "enemy_down" } },
		{ "contained", { "enemy_down" } },
		{ "ineffective", { "enemy_down" } },
		{ "lost", { "lostvisual" } },
		{ "clear", { "clear" } },
		{ "secure", { "clear" } },
		{ "heavyresist", { "fight_bad", "needhelp" } },
		{ "ripcord", { "fight_bad" } },
		{ "outbreak", { "attention" } },
		{ "check", { "canyouhearit", "attention" } },
		{ "alert", { "attention" } },
		{ "", { "mutter" } }, -- the rest is radio chatter
	}

	local METROCOP_RULES = {
		{ "takecover", { "coverme", "enemy_grenade" } },
		{ "getdown", { "enemy_grenade" } },
		{ "grenade", { "grenade", "enemy_grenade" } },
		{ "lookout", { "enemy_grenade", "enemy_contact" } },
		{ "watchit", { "enemy_contact" } },
		{ "thereheis", { "enemy_contact" } },
		{ "hesupthere", { "enemy_contact" } },
		{ "contact", { "enemy_contact" } },
		{ "suspect", { "enemy_contact" } },
		{ "officerneeds", { "needhelp" } },
		{ "help", { "needhelp" } },
		{ "backup", { "needhelp" } },
		{ "affirm", { "roger" } },
		{ "copy", { "roger" } },
		{ "rodger", { "roger" } },
		{ "ten4", { "roger" } },
		{ "moveit", { "going" } },
		{ "converging", { "going" } },
		{ "prosecute", { "fight" } },
		{ "dontmove", { "fight" } },
		{ "lostcontact", { "lostvisual" } },
		{ "locationunknown", { "lostvisual" } },
		{ "clear", { "clear" } },
		{ "chuckle", { "enemy_down" } },
		{ "", { "mutter" } },
	}

	local PAIN = function(dir, count, cats)
		local out = {}

		for i = 1, count do out[#out + 1] = dir .. i .. ".wav" end

		local lines = {}

		for _, cat in ipairs(cats) do lines[cat] = out end

		return lines
	end

	local function Merge(a, b)
		for cat, paths in pairs(b) do
			a[cat] = a[cat] or {}

			for _, p in ipairs(paths) do table.insert(a[cat], p) end
		end

		return a
	end

	hg.bots.RegisterVoicePack("rebel_m", { builtin = true, sex = "m", scan = { dir = "vo/npc/male01/", rules = CITIZEN_RULES } })
	hg.bots.RegisterVoicePack("rebel_f", { builtin = true, sex = "f", scan = { dir = "vo/npc/female01/", rules = CITIZEN_RULES } })
	hg.bots.RegisterVoicePack("combine", {
		builtin = true, sex = "m",
		scan = { dir = "npc/combine_soldier/vo/", rules = COMBINE_RULES },
		lines = Merge(PAIN("npc/combine_soldier/pain", 3, { "hit", "hurt_light", "agony" }),
			PAIN("npc/combine_soldier/die", 3, { "death" })),
	})
	hg.bots.RegisterVoicePack("metrocop", {
		builtin = true, sex = "m",
		scan = { dir = "npc/metropolice/vo/", rules = METROCOP_RULES },
		lines = Merge(PAIN("npc/metropolice/pain", 4, { "hit", "hurt_light", "agony" }),
			PAIN("npc/metropolice/die", 4, { "death" })),
	})

	LoadVoice()

	-- Only now: every RegisterVoicePack above would have reloaded the lot.
	-- A pack registered from here on (another addon) reloads once.
	hg.bots.LoadVoice = LoadVoice

	hook.Add("Initialize", "HG_Bots_Voice_Load", function()
		local count = LoadVoice()

		if count == 0 then
			print("[hg.bots] voice: no voice lines found - bots stay quiet")
		else
			print(("[hg.bots] voice: %d lines in %d pack(s): %s"):format(
				count, #hg.bots.VoicePacks, table.concat(hg.bots.VoicePacks, ", ")))
		end
	end)

	concommand.Add("hg_bot_voice_reload", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		print(("[hg.bots] voice: %d lines loaded"):format(LoadVoice()))
	end)

	concommand.Add("hg_bot_voice_list", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		for _, pack in ipairs(hg.bots.VoicePacks) do
			local names = {}

			for cat, set in pairs(hg.bots.VoiceLines[pack]) do
				names[#names + 1] = cat .. " (" .. #set.all .. ")"
			end

			table.sort(names)

			print(("[hg.bots] voice %s%s: %s"):format(pack, hg.bots.VoicePackOn(pack) and "" or " (off)", table.concat(names, ", ")))
		end
	end)
--//

--\\ Which pack a bot speaks with
	local VOICE_FILE = "hg_bots_voices.json"
	local packSwitch -- [pack] = true/false, set on the menu's Voices page

	local function Switches()
		if packSwitch then return packSwitch end

		packSwitch = {}

		local raw = file.Read(VOICE_FILE, "DATA")
		local parsed = raw and util.JSONToTable(raw)

		-- Stored as { {name, on}, ... }: names may look like numbers.
		if istable(parsed) then
			for _, row in pairs(parsed) do
				if istable(row) and isstring(row[1]) then packSwitch[row[1]] = row[2] == true end
			end
		end

		return packSwitch
	end

	--- Is this pack in use? Unset: folder packs (the Tarkov voices) are on,
	-- built-in ones only when there is nothing else.
	function hg.bots.VoicePackOn(pack)
		local set = Switches()[pack]

		if set ~= nil then return set end

		local info = hg.bots.VoiceInfo[pack]

		if not info or not info.builtin then return true end

		for _, other in ipairs(hg.bots.VoicePacks) do
			local oi = hg.bots.VoiceInfo[other]

			if oi and not oi.builtin then return false end
		end

		return true
	end

	function hg.bots.SetVoicePackOn(pack, on)
		if not hg.bots.VoiceLines[pack] then return false end

		Switches()[pack] = on and true or false

		local rows = {}

		for name, val in pairs(Switches()) do rows[#rows + 1] = { name, val } end

		file.Write(VOICE_FILE, util.TableToJSON(rows, true))

		-- Bots on a pack that was just switched off pick again.
		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and bot.Bot

			if data and data.VoicePack == pack and not on then data.VoicePack = nil end
		end

		return true
	end

	--- For the menu: { {name, lines, sex, on, builtin}, ... }
	function hg.bots.VoicePackList()
		local out = {}

		for _, pack in ipairs(hg.bots.VoicePacks) do
			local info = hg.bots.VoiceInfo[pack] or {}

			out[#out + 1] = { name = pack, lines = info.lines or 0, sex = info.sex, on = hg.bots.VoicePackOn(pack), builtin = info.builtin }
		end

		return out
	end

	--- Female model? Z-City's own appearance knows; otherwise the path.
	local function IsFemale(bot)
		local ap = hg.Appearance and hg.Appearance.PlayerModels
		local mdl = string.lower(bot:GetModel() or "")

		if ap and ap[2] then
			for _, tbl in pairs(ap[2]) do
				if istable(tbl) and isstring(tbl.mdl) and string.lower(tbl.mdl) == mdl then return true end
			end
		end

		return string.find(mdl, "female", 1, true) ~= nil or string.find(mdl, "/f/", 1, true) ~= nil
	end

	--- The voice this bot speaks with. Picked once and kept, so one bot
	-- doesn't change voice mid-sentence. Order: the bot's own pick (its
	-- right-click menu), hg_bot_voice_pack, then a pack that is switched
	-- on and fits the model - a woman's model doesn't get a man's pack
	-- when there is a woman's one, and the other way round.
	function hg.bots.VoicePack(bot)
		local own = bot.hgBotVoice

		if own and hg.bots.VoiceLines[own] then return own end

		local forced = hg_bot_voice_pack:GetString()

		if forced ~= "" and hg.bots.VoiceLines[forced] then return forced end

		local data = bot.Bot

		if not data then return hg.bots.VoicePacks[1] end

		if data.VoicePack and hg.bots.VoiceLines[data.VoicePack] then return data.VoicePack end

		local female = IsFemale(bot)
		local fit, any = {}, {}

		for _, pack in ipairs(hg.bots.VoicePacks) do
			if hg.bots.VoicePackOn(pack) then
				any[#any + 1] = pack

				local sex = hg.bots.VoiceInfo[pack] and hg.bots.VoiceInfo[pack].sex

				if (female and sex == "f") or (not female and sex ~= "f") then fit[#fit + 1] = pack end
			end
		end

		local list = #fit > 0 and fit or any

		if #list == 0 then return nil end

		-- Spread the packs around rather than rolling the same one three
		-- times for three bots standing together.
		local n = (bot:EntIndex() + math.random(0, #list - 1)) % #list

		data.VoicePack = list[n + 1]

		return data.VoicePack
	end

	--- One bot's pack; nil / "" goes back to automatic.
	function hg.bots.SetBotVoice(bot, pack)
		if not IsValid(bot) then return false end

		if pack == nil or pack == "" then
			bot.hgBotVoice = nil
		elseif hg.bots.VoiceLines[pack] then
			bot.hgBotVoice = pack
		else
			return false
		end

		if bot.Bot then bot.Bot.VoicePack = nil end

		return true
	end

	--- The lines of one category for this bot, falling back to another
	-- pack (switched on) when its own set is missing that category.
	local function LinesFor(bot, category)
		local pack = hg.bots.VoicePack(bot)
		local set = pack and hg.bots.VoiceLines[pack] and hg.bots.VoiceLines[pack][category]

		if set then return set end

		-- A bot on a pack picked by hand keeps its own voice: better
		-- silent than suddenly someone else.
		if bot.hgBotVoice then return nil end

		local info = pack and hg.bots.VoiceInfo[pack]

		for _, other in ipairs(hg.bots.VoicePacks) do
			local oi = hg.bots.VoiceInfo[other]

			-- Only from a pack of the same kind, so a scav doesn't suddenly
			-- answer in a Combine radio voice.
			if other ~= pack and hg.bots.VoicePackOn(other) and (not info or not oi or (info.builtin == oi.builtin and info.sex == oi.sex)) then
				local alt = hg.bots.VoiceLines[other][category]

				if alt then return alt end
			end
		end

		return nil
	end
--//

--\\ Saying things
	-- How long the same category stays quiet afterwards, and how likely it
	-- is to be said at all. Priority 3 = pain/death (always heard),
	-- 2 = fight callouts, 1 = chatter (skipped whenever anything else is
	-- going on).
	local EVENTS = {
		death          = { prio = 3, chance = 1.00, cd = 0 },
		agony          = { prio = 3, chance = 0.80, cd = 10 },
		hurt_neardeath = { prio = 3, chance = 0.70, cd = 12 },
		hurt_light     = { prio = 3, chance = 0.35, cd = 8 },
		hit            = { prio = 3, chance = 0.30, cd = 5 },
		broke_leg      = { prio = 3, chance = 0.90, cd = 60 },
		broke_hand     = { prio = 3, chance = 0.90, cd = 60 },

		enemy_contact  = { prio = 2, chance = 0.75, cd = 18 },
		enemy_usec     = { prio = 2, chance = 0.35, cd = 25 },
		enemy_bear     = { prio = 2, chance = 0.35, cd = 25 },
		enemy_down     = { prio = 2, chance = 0.70, cd = 15 },
		kill_knife     = { prio = 2, chance = 0.80, cd = 20 },
		friendly_down  = { prio = 2, chance = 0.60, cd = 25 },
		ffire          = { prio = 2, chance = 0.80, cd = 20 },
		fight          = { prio = 2, chance = 0.30, cd = 14 },
		fight_good     = { prio = 2, chance = 0.40, cd = 20 },
		fight_bad      = { prio = 2, chance = 0.40, cd = 20 },
		grenade        = { prio = 2, chance = 0.85, cd = 12 },
		enemy_grenade  = { prio = 2, chance = 0.90, cd = 10 },
		need_ammo      = { prio = 2, chance = 0.60, cd = 30 },
		weap_reload    = { prio = 2, chance = 0.20, cd = 20 },
		weap_jammed    = { prio = 2, chance = 0.70, cd = 25 },
		weap_broken    = { prio = 2, chance = 0.70, cd = 30 },
		coverme        = { prio = 2, chance = 0.35, cd = 25 },
		needhelp       = { prio = 2, chance = 0.50, cd = 25 },
		going          = { prio = 2, chance = 0.30, cd = 25 },
		spreadout      = { prio = 2, chance = 0.25, cd = 40 },
		roger          = { prio = 2, chance = 0.35, cd = 25 },
		lostvisual     = { prio = 2, chance = 0.45, cd = 20 },
		ambush         = { prio = 2, chance = 0.30, cd = 40 },
		knifesonly     = { prio = 2, chance = 0.40, cd = 45 },
		negative       = { prio = 2, chance = 0.30, cd = 30 },

		attention      = { prio = 1, chance = 0.55, cd = 25 },
		canyouhearit   = { prio = 1, chance = 0.45, cd = 30 },
		clear          = { prio = 1, chance = 0.45, cd = 35 },
		dontknow       = { prio = 1, chance = 0.30, cd = 40 },
		start          = { prio = 1, chance = 0.30, cd = 120 },
		mutter         = { prio = 1, chance = 0.25, cd = 45 },
		tired          = { prio = 1, chance = 0.35, cd = 40 },
		silence        = { prio = 1, chance = 0.25, cd = 45 },
		loot_body      = { prio = 1, chance = 0.45, cd = 30 },
		loot_container = { prio = 1, chance = 0.40, cd = 30 },
		loot_nothing   = { prio = 1, chance = 0.35, cd = 40 },
		goodwork       = { prio = 1, chance = 0.25, cd = 60 },
	}

	local lastWorldLine = 0

	local function SomebodyListening(bot)
		local rangeSqr = hg_bot_voice_range:GetFloat() ^ 2
		local pos = bot:GetPos()

		for _, ply in ipairs(player.GetHumans()) do
			if pos:DistToSqr(ply:GetPos()) < rangeSqr then return true end
		end

		return false
	end

	--- Say a line of this category, if the moment is right for it.
	-- @param force skip the chance roll (still respects the cooldowns)
	-- @return true if something was played
	--- Out cold (or dead): not a word. Z-City's org.otrub is unconscious.
	local function CanSpeak(bot)
		local org = bot.organism

		if not org then return bot:Alive() end
		if org.otrub or org.alive == false then return false end

		return (org.consciousness or 1) > 0.2
	end

	function hg.bots.Say(bot, category, force)
		if not hg_bot_voice:GetBool() then return false end
		if not IsValid(bot) or not bot.Bot then return false end

		-- The death line is played from PlayerDeath, after the fact: allow
		-- it unless the bot was already out cold when it died.
		if category == "death" then
			if bot.Bot.VoiceKnockedOut then return false end
		elseif not CanSpeak(bot) then
			return false
		end

		local set = LinesFor(bot, category)

		if not set then return false end

		local info = EVENTS[category] or { prio = 1, chance = 0.3, cd = 30 }

		if info.prio == 1 and not hg_bot_voice_chatter:GetBool() then return false end

		local data = bot.Bot
		local now = CurTime()

		-- Mid-line: only pain and death cut in.
		if now < (data.VoiceUntil or 0) and info.prio <= (data.VoicePrio or 0) then return false end

		-- Chatter waits for the room to be quiet; pain doesn't.
		if info.prio < 3 and now - lastWorldLine < hg_bot_voice_world:GetFloat() then return false end
		if info.prio < 3 and now < (data.VoiceGapUntil or 0) then return false end

		data.VoiceCats = data.VoiceCats or {}

		if now < (data.VoiceCats[category] or 0) then return false end
		if not force and math.random() > info.chance then return false end
		if info.prio < 3 and not SomebodyListening(bot) then return false end

		local pool = hg_bot_voice_swear:GetBool() and set.all or set.clean

		if #pool == 0 then pool = set.all end
		if #pool == 0 then return false end

		local path = pool[math.random(#pool)]

		-- Each bot keeps its own pitch, so the same pack is several people.
		if not data.VoicePitchBase then
			local spread = hg_bot_voice_pitch:GetFloat()

			data.VoicePitchBase = 100 + math.Rand(-spread, spread)
		end

		-- Hurt bots speak quieter and a little lower.
		local maxHP = bot:GetMaxHealth()
		local frac = maxHP > 0 and (bot:Health() / maxHP) or 1
		local pitch = math.Clamp(math.floor(data.VoicePitchBase + math.random(-3, 3) - (frac < 0.4 and 6 or 0)), 60, 140)

		-- From the body: a downed bot's player entity isn't where it lies.
		local char = IsValid(bot.FakeRagdoll) and bot.FakeRagdoll or bot

		char:EmitSound(path, hg_bot_voice_volume:GetFloat(), pitch, frac < 0.4 and 0.85 or 1, CHAN_VOICE)

		data.VoicePath = path
		data.VoiceEnt = char

		-- Lines are 1-3 seconds; the gap is on top of that.
		data.VoiceUntil = now + 2
		data.VoicePrio = info.prio
		data.VoiceGapUntil = now + hg_bot_voice_gap:GetFloat() * math.Rand(0.8, 1.4)
		data.VoiceCats[category] = now + (info.cd or 30) * math.Rand(0.8, 1.3)

		lastWorldLine = now

		return true
	end

	--- One of several categories, picked at random (contact calls come in
	-- flavours: "contact", "USEC", "BEAR").
	function hg.bots.SayAny(bot, categories, force)
		local cat = categories[math.random(#categories)]

		return hg.bots.Say(bot, cat, force)
	end

	--- Everyone else nearby, for lines that are a reaction to somebody
	-- else's trouble.
	local function Nearby(bot, radius)
		local out = {}
		local radiusSqr = (radius or 1500) ^ 2
		local pos = bot:GetPos()

		for other in pairs(hg.bots.List) do
			if IsValid(other) and other ~= bot and other:Alive() and other.Bot and pos:DistToSqr(other:GetPos()) < radiusSqr then
				out[#out + 1] = other
			end
		end

		return out
	end
--//

--\\ What gets said when
	-- Spotting somebody.
	hook.Add("HG_BotSpotted", "HG_Bots_Voice_Spotted", function(bot, target)
		hg.bots.SayAny(bot, { "enemy_contact", "enemy_contact", "enemy_usec", "enemy_bear" })
	end)

	-- Being shot / hit.
	hook.Add("EntityTakeDamage", "HG_Bots_Voice_Damage", function(ent, dmginfo)
		if not hg_bot_voice:GetBool() then return end

		local bot = hg.bots.OwnerBot and hg.bots.OwnerBot(ent) or (IsValid(ent) and ent.IsHomigradBot and ent)

		if not IsValid(bot) or not bot:Alive() then return end

		local dmg = dmginfo:GetDamage()

		if dmg < 3 then return end

		local maxHP = bot:GetMaxHealth()
		local frac = maxHP > 0 and ((bot:Health() - dmg) / maxHP) or 1

		if frac < 0.2 then
			hg.bots.SayAny(bot, { "agony", "hurt_neardeath" })
		elseif frac < 0.55 then
			hg.bots.Say(bot, "hurt_light")
		else
			hg.bots.Say(bot, "hit")
		end

		-- Shot by one of our own.
		local attacker = dmginfo:GetAttacker()

		if hg.bots.ResolveShooter then
			local real = hg.bots.ResolveShooter(attacker)

			if IsValid(real) then attacker = real end
		end

		if IsValid(attacker) and attacker ~= bot and attacker.IsHomigradBot then
			hg.bots.Say(bot, "ffire")
		end
	end)

	-- Dying, killing, and watching a squadmate go down.
	hook.Add("PlayerDeath", "HG_Bots_Voice_Death", function(victim, inflictor, attacker)
		if not hg_bot_voice:GetBool() then return end

		local killer = hg.bots.ResolveShooter and hg.bots.ResolveShooter(attacker) or attacker

		if IsValid(victim) and victim.IsHomigradBot then
			hg.bots.Say(victim, "death", true)

			for _, other in ipairs(Nearby(victim, 1600)) do
				hg.bots.Say(other, "friendly_down")
			end

			return
		end

		if IsValid(killer) and killer.IsHomigradBot and killer ~= victim then
			-- The taunt over the body.
			local wep = killer:GetActiveWeapon()

			if IsValid(wep) and hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep) then
				if hg.bots.Say(killer, "kill_knife") then return end
			end

			timer.Simple(math.Rand(0.4, 1.2), function()
				if IsValid(killer) and killer:Alive() then hg.bots.Say(killer, "enemy_down") end
			end)
		end
	end)

	-- State changes cover most of the rest.
	hook.Add("HG_BotStateChanged", "HG_Bots_Voice_State", function(bot, oldState, newState)
		if not hg_bot_voice:GetBool() then return end

		if newState == "alert" then
			hg.bots.SayAny(bot, { "attention", "canyouhearit" })
		elseif newState == "combat" and oldState ~= "combat" then
			local data = bot.Bot
			local maxHP = bot:GetMaxHealth()
			local frac = maxHP > 0 and (bot:Health() / maxHP) or 1

			if data and data.SquadRole == "push" then
				hg.bots.Say(bot, "going")
			elseif frac < 0.5 then
				hg.bots.Say(bot, "fight_bad")
			else
				hg.bots.Say(bot, "fight")
			end
		elseif newState == "flee" then
			hg.bots.SayAny(bot, { "needhelp", "negative" })
		elseif newState == "hold" then
			hg.bots.Say(bot, "coverme")
		elseif newState == "ambush" then
			hg.bots.SayAny(bot, { "ambush", "silence" })
		elseif newState == "grenade" then
			hg.bots.Say(bot, "grenade", true)
		elseif newState == "martyr" then
			hg.bots.SayAny(bot, { "agony", "grenade" }, true)
		elseif newState == "evadegrenade" then
			hg.bots.Say(bot, "enemy_grenade", true)
		elseif newState == "idle" and oldState == "combat" then
			hg.bots.SayAny(bot, { "clear", "lostvisual", "dontknow" })
		elseif newState == "idle" and oldState == "alert" then
			hg.bots.Say(bot, "clear")
		end
	end)

	-- Fresh out of the ground.
	hook.Add("PlayerSpawn", "HG_Bots_Voice_Spawn", function(ply)
		if not IsValid(ply) or not ply:IsBot() then return end

		timer.Simple(2, function()
			if IsValid(ply) and ply.Bot and ply:Alive() then hg.bots.Say(ply, "start") end
		end)
	end)

	-- Knocked out mid-sentence: the line stops there.
	timer.Create("HG_Bots_Voice_Knockout", 0.25, 0, function()
		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and bot.Bot

			if data then
				local out = bot:Alive() and not CanSpeak(bot)

				if out and not data.VoiceKnockedOut and data.VoicePath and CurTime() < (data.VoiceUntil or 0) then
					if IsValid(data.VoiceEnt) then data.VoiceEnt:StopSound(data.VoicePath) end

					bot:StopSound(data.VoicePath)

					data.VoiceUntil = 0
				end

				data.VoiceKnockedOut = out
			end
		end
	end)

	-- Muttering to themselves while nothing is happening, and complaining
	-- when the legs give out.
	timer.Create("HG_Bots_Voice_Idle", 12, 0, function()
		if not hg_bot_voice:GetBool() then return end

		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and bot:Alive() and bot.Bot

			if data and data.Enabled then
				local org = bot.organism

				if org then
					if (org.lleg == 1 or org.rleg == 1) and hg.bots.Say(bot, "broke_leg") then
						-- said it
					elseif (org.larm == 1 or org.rarm == 1) and hg.bots.Say(bot, "broke_hand") then
						-- said it
					elseif org.stamina and org.stamina[1] and org.stamina[1] < 35 then
						hg.bots.Say(bot, "tired")
					elseif data.State == "idle" then
						hg.bots.Say(bot, "mutter")
					end
				elseif data.State == "idle" then
					hg.bots.Say(bot, "mutter")
				end
			end
		end
	end)
--//
