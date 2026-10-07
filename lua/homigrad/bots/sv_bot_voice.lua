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

--\\ Loading the lines
	-- [pack] = { [category] = { all = {paths}, clean = {paths} } }
	hg.bots.VoiceLines = {}
	hg.bots.VoicePacks = {}

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

	local function AddPackFiles(pack, dir)
		local files = file.Find("sound/" .. dir .. "*.wav", "GAME")
		local count = 0

		for _, name in ipairs(files or {}) do
			local cat, swear = CategoryOf(name)

			if cat ~= "" then
				local lines = hg.bots.VoiceLines[pack]
				lines[cat] = lines[cat] or { all = {}, clean = {} }

				local path = dir .. name

				table.insert(lines[cat].all, path)

				if not swear then table.insert(lines[cat].clean, path) end

				if hg_bot_voice_fastdl:GetBool() then resource.AddFile("sound/" .. path) end

				count = count + 1
			end
		end

		return count
	end

	--- Voice packs are folders under sound/<path>/ - scav1 .. scav6, or
	-- whatever else is dropped in there. Files lying loose in the folder
	-- itself still work: they become the pack "default", which is what the
	-- old flat layout turns into.
	local function LoadVoice()
		hg.bots.VoiceLines = {}
		hg.bots.VoicePacks = {}

		local dir = hg_bot_voice_path:GetString()

		if dir == "" then return 0 end
		if string.Right(dir, 1) ~= "/" then dir = dir .. "/" end

		local _, dirs = file.Find("sound/" .. dir .. "*", "GAME")
		local count = 0

		for _, sub in ipairs(dirs or {}) do
			hg.bots.VoiceLines[sub] = {}

			local added = AddPackFiles(sub, dir .. sub .. "/")

			if added > 0 then
				table.insert(hg.bots.VoicePacks, sub)
				count = count + added
			else
				hg.bots.VoiceLines[sub] = nil
			end
		end

		hg.bots.VoiceLines.default = {}

		local loose = AddPackFiles("default", dir)

		if loose > 0 then
			table.insert(hg.bots.VoicePacks, "default")
			count = count + loose
		else
			hg.bots.VoiceLines.default = nil
		end

		table.sort(hg.bots.VoicePacks)

		return count
	end

	LoadVoice()

	hook.Add("Initialize", "HG_Bots_Voice_Load", function()
		local count = LoadVoice()

		if count == 0 then
			print("[hg.bots] voice: no .wav files under sound/" .. hg_bot_voice_path:GetString() .. " - bots stay quiet")
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

			print("[hg.bots] voice " .. pack .. ": " .. table.concat(names, ", "))
		end
	end)

	--- The voice this bot speaks with. Picked once and kept, so one bot
	-- doesn't change voice mid-sentence; hg_bot_voice_pack forces one.
	function hg.bots.VoicePack(bot)
		local forced = hg_bot_voice_pack:GetString()

		if forced ~= "" and hg.bots.VoiceLines[forced] then return forced end

		local data = bot.Bot

		if not data then return hg.bots.VoicePacks[1] end

		if not data.VoicePack or not hg.bots.VoiceLines[data.VoicePack] then
			if #hg.bots.VoicePacks == 0 then return nil end

			-- Spread the packs around rather than rolling the same one
			-- three times for three bots standing together.
			local n = (bot:EntIndex() + math.random(0, #hg.bots.VoicePacks - 1)) % #hg.bots.VoicePacks

			data.VoicePack = hg.bots.VoicePacks[n + 1]
		end

		return data.VoicePack
	end

	--- The lines of one category for this bot, falling back to another
	-- pack when its own set is missing that category.
	local function LinesFor(bot, category)
		local pack = hg.bots.VoicePack(bot)
		local set = pack and hg.bots.VoiceLines[pack] and hg.bots.VoiceLines[pack][category]

		if set then return set end

		for _, other in ipairs(hg.bots.VoicePacks) do
			local alt = hg.bots.VoiceLines[other][category]

			if alt then return alt end
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
	function hg.bots.Say(bot, category, force)
		if not hg_bot_voice:GetBool() then return false end
		if not IsValid(bot) or not bot.Bot then return false end

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

		-- Hurt bots speak quieter and a little lower.
		local maxHP = bot:GetMaxHealth()
		local frac = maxHP > 0 and (bot:Health() / maxHP) or 1
		local pitch = math.random(96, 104) - (frac < 0.4 and 6 or 0)

		bot:EmitSound(path, hg_bot_voice_volume:GetFloat(), pitch, frac < 0.4 and 0.85 or 1, CHAN_VOICE)

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
