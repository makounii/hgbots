--[[
	Tarkov AI - Factions and non-player targets

	Two things that the AI had no concept of before:

	1. FACTIONS. Every bot belongs to one:
	   - "raider" (the default): hostile to players, to guard bots, and to
	     NPCs. This is what every bot was before this file existed.
	   - "guard": friendly to players. It hunts raiders and NPCs and never
	     opens fire on a player first - shoot it and it holds a personal
	     grudge like any bot does (sv_bot_perception.lua's trust grudge).
	   Raiders and guards are enemies both ways, so the player can have
	   allies that actually fight for them.
	   - "neutral": starts no fight with anyone - players, raiders or
	     guards - and nobody starts one with it. Whoever attacks it is
	     fought back (for hg_bot_neutral_memory seconds, or for good if a
	     player did it), and other neutrals nearby join in.

	   The faction lives on the bot ENTITY, not only in its AI table:
	   hg.bots.Init rebuilds that table (a re-init from the menu, a new
	   life) and used to drop it, which is how a guard came back from a
	   ragdoll as a raider - and why "spawn a friendly bot" sometimes
	   gave a hostile one (the faction was set a moment after spawning,
	   and an Init that came later wiped it).

	2. NPC / NEXTBOT TARGETS. Perception only ever looked at
	   player.GetHumans(), so bots walked past npc_z, zombies and any other
	   NPC as if they weren't there. Those entities are added to the
	   candidate list here, with two compatibility details:
	   - an NPC has no :Alive() / :Nick() in every build, and the whole AI
	     calls both on its target, so a tiny shim is attached to an entity
	     the first time a bot notices it;
	   - a class in hg_bot_npc_friendly is never attacked (Z-City's own
	     helper NPCs, a shopkeeper, and so on).

	Everything hooks into existing decision points rather than duplicating
	them: hg.bots.IsHostile asks FactionHostile first, perception asks
	ExtraTargets / FilterTargets for its candidate list, and the squad's
	friendly-fire block asks SameFaction.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {}

local hg_bot_factions     = CreateConVar("hg_bot_factions",     "1", {FCVAR_ARCHIVE}, "Bots have factions: raiders fight players and guards, guards fight raiders and protect players", 0, 1)
local hg_bot_npc          = CreateConVar("hg_bot_npc",          "1", {FCVAR_ARCHIVE}, "Bots see and attack NPCs and nextbots (npc_z, zombies, ...) instead of ignoring them", 0, 1)
local hg_bot_npc_range    = CreateConVar("hg_bot_npc_range",    "3000", {FCVAR_ARCHIVE}, "How far around a bot NPCs are collected as possible targets", 200, 10000)
local hg_bot_npc_friendly = CreateConVar("hg_bot_npc_friendly", "", {FCVAR_ARCHIVE}, "Comma separated NPC classes bots never attack")
local hg_bot_guard_follow = CreateConVar("hg_bot_guard_follow", "600", {FCVAR_ARCHIVE}, "How closely a guard bot sticks to the player it escorts (0 = it doesn't escort anyone)", 0, 4000)
local hg_bot_neutral_memory = CreateConVar("hg_bot_neutral_memory", "120", {FCVAR_ARCHIVE}, "Seconds a neutral bot keeps fighting a bot that attacked it (a player who attacks one is never forgiven)", 10, 1800)
local hg_bot_neutral_help = CreateConVar("hg_bot_neutral_help", "1200", {FCVAR_ARCHIVE}, "Neutral bots within this distance of an attacked neutral fight the attacker too (0 = each on its own)", 0, 5000)

hg.bots.Factions = { raider = true, guard = true, neutral = true }

--\\ Faction of a bot
	function hg.bots.GetFaction(bot)
		if not IsValid(bot) or not bot.IsHomigradBot then return nil end

		local data = bot.Bot

		return (data and data.Faction) or bot.hgBotFaction or "raider"
	end

	--- Works before the bot has its AI table too (straight after
	-- hg.bots.Spawn): hg.bots.Init picks the faction up from the entity.
	-- @param faction "raider" | "guard" | "neutral"
	function hg.bots.SetFaction(bot, faction)
		if not IsValid(bot) or not hg.bots.Factions[faction] then return false end

		bot.hgBotFaction = faction
		bot:SetNWString("hg_bot_faction", faction)

		local data = bot.Bot

		if not data then return true end

		data.Faction = faction

		-- Drop whatever it was fighting: the answer may have just changed.
		local mem = data.Memory

		if mem then
			mem.Target = nil
			mem.TargetPos = nil
			mem.Grudge = nil
			mem.Attackers = nil
		end

		return true
	end

	function hg.bots.SameFaction(a, b)
		if not IsValid(a) or not IsValid(b) then return false end
		if not (a.IsHomigradBot and b.IsHomigradBot) then return false end
		local friendly = hg.bots.DirectorFriendly and hg.bots.DirectorFriendly(a, b)
		if friendly ~= nil then return friendly end
		if not hg_bot_factions:GetBool() then return true end

		return hg.bots.GetFaction(a) == hg.bots.GetFaction(b)
	end
--//

--\\ NPCs as targets
	local friendlyClasses, friendlyRaw = {}, nil

	local function IsFriendlyClass(class)
		local raw = hg_bot_npc_friendly:GetString()

		if raw ~= friendlyRaw then
			friendlyRaw = raw
			friendlyClasses = {}

			for _, name in ipairs(string.Explode(",", raw)) do
				name = string.Trim(string.lower(name))

				if name ~= "" then friendlyClasses[name] = true end
			end
		end

		return friendlyClasses[string.lower(class or "")] or false
	end

	--- The AI calls :Alive() and :Nick() on whatever it is fighting. An NPC
	-- has neither in every build, so give this one entity both, once.
	local function Shim(ent)
		if ent.hgBotShimmed then return ent end

		ent.hgBotShimmed = true

		if not ent.Alive then
			ent.Alive = function(self) return self:Health() > 0 end
		end

		if not ent.Nick then
			ent.Nick = function(self) return self:GetClass() end
		end

		if not ent.IsSprinting then
			ent.IsSprinting = function() return false end
		end

		if not ent.Crouching then
			ent.Crouching = function() return false end
		end

		if not ent.GetAmmoCount then
			ent.GetAmmoCount = function() return 0 end
		end

		return ent
	end

	hg.bots.ShimTarget = Shim

	--[[
		Helper NPCs that are not fighters and must never be shot at. The
		important one is npc_bullseye: Z-City spawns ONE PER PLAYER and one
		per fake ragdoll (lua/homigrad/sh_utility.lua, fake/sv_tier_0.lua)
		so that ordinary NPCs and turrets have something to aim at. They are
		invisible, they sit on top of the player, and they are NPCs - so bots
		locked onto the bullseye instead of the player, then kicked at thin
		air and circled staring at the floor, ignoring everybody else. That
		is exactly what "target npc_bullseye" in the state dump was.
	]]
	local NEVER_TARGET = {
		npc_bullseye = true, npc_bullseye_new = true, npc_enemyfinder = true,
		npc_enemyfinder_combinecannon = true, npc_furniture = true,
		npc_maker = true, npc_template_maker = true, npc_launcher = true,
		npc_grenade_frag = true, npc_handgrenade = true, npc_satchel = true,
		npc_tripmine = true, npc_missiledefense = true, npc_helicoptersensor = true,
		npc_vehicledriver = true, npc_apcdriver = true, npc_spotlight_end = true,
		npc_puppet = true, npc_dog = false, -- dog is a real NPC, listed to show the shape
	}

	hg.bots.NeverTargetNPC = NEVER_TARGET

	function hg.bots.IsNPCTarget(ent)
		if not hg_bot_npc:GetBool() then return false end
		if not IsValid(ent) or ent:IsPlayer() then return false end
		if not (ent:IsNPC() or ent:IsNextBot()) then return false end
		if ent:Health() <= 0 then return false end

		local class = ent:GetClass()

		if NEVER_TARGET[class] then return false end
		if string.find(class, "bullseye", 1, true) then return false end
		if IsFriendlyClass(class) then return false end

		-- Second safety net for helper entities nobody listed: a marker has
		-- no model and is not drawn, a real enemy has both.
		local model = ent:GetModel()

		if not model or model == "" or model == "models/error.mdl" then return false end
		if ent:GetNoDraw() then return false end
		if ent:IsFlagSet(FL_NOTARGET) then return false end

		return true
	end

	-- Collected once a second for everybody, not per bot per scan.
	local npcCache, npcCacheAt = {}, 0

	local function NPCList()
		local now = CurTime()

		if now - npcCacheAt < 1 then return npcCache end

		npcCacheAt = now
		npcCache = {}

		if not hg_bot_npc:GetBool() then return npcCache end

		for _, ent in ipairs(ents.GetAll()) do
			if hg.bots.IsNPCTarget(ent) then npcCache[#npcCache + 1] = Shim(ent) end
		end

		return npcCache
	end
--//

--\\ Who may fight whom
	--- Faction verdict for hg.bots.IsHostile.
	-- @return true / false, or nil to let the trust logic decide
	function hg.bots.FactionHostile(ent, bot)
		if not IsValid(ent) or not IsValid(bot) then return false end
		if ent == bot then return false end
		local friendly = hg.bots.DirectorFriendly and hg.bots.DirectorFriendly(ent, bot)
		if friendly ~= nil then return not friendly end

		-- NPCs: hostile unless whitelisted.
		if not ent:IsPlayer() then
			if ent:IsNPC() or ent:IsNextBot() then return hg.bots.IsNPCTarget(ent) end

			return nil
		end

		if not hg_bot_factions:GetBool() then
			-- Factions off: another bot is never a target, as before.
			if ent.IsHomigradBot then return false end

			return nil
		end

		local faction = hg.bots.GetFaction(bot)

		-- Bot versus bot: different factions fight, same faction never does
		-- - except that nobody picks a fight with a neutral, and a neutral
		-- picks none.
		if ent.IsHomigradBot then
			local other = hg.bots.GetFaction(ent)

			if other == faction then return false end
			if faction == "neutral" or other == "neutral" then return hg.bots.Provoked(bot, ent) end

			return true
		end

		-- A guard leaves players alone unless one of them shot it.
		if faction == "guard" then
			local mem = bot.Bot and bot.Bot.Memory

			return (mem and mem.Grudge and mem.Grudge[ent]) and true or false
		end

		if faction == "neutral" then return hg.bots.Provoked(bot, ent) end

		return nil -- raider versus player: the trust logic decides
	end

	--- Did ent attack this bot (recently, or ever for a player)?
	function hg.bots.Provoked(bot, ent)
		local mem = bot.Bot and bot.Bot.Memory

		if not mem then return false end
		if mem.Grudge and mem.Grudge[ent] then return true end

		local at = mem.Attackers and mem.Attackers[ent]

		return at ~= nil and CurTime() - at < hg_bot_neutral_memory:GetFloat()
	end

	-- Attack one neutral and the neutrals around it answer: they get the
	-- attacker on their own list, as if they had been shot themselves.
	hook.Add("HG_BotThreatened", "HG_Bots_NeutralHelp", function(bot, attacker)
		if not hg_bot_factions:GetBool() then return end
		if not IsValid(bot) or not IsValid(attacker) or hg.bots.GetFaction(bot) ~= "neutral" then return end

		local radius = hg_bot_neutral_help:GetFloat()

		if radius <= 0 then return end

		local now = CurTime()
		local pos = bot:GetPos()

		for other in pairs(hg.bots.List) do
			local mem = other ~= bot and IsValid(other) and other:Alive() and other.Bot and other.Bot.Memory

			if mem and hg.bots.GetFaction(other) == "neutral" and other ~= attacker
				and other:GetPos():DistToSqr(pos) < radius * radius
			then
				mem.Attackers = mem.Attackers or {}
				mem.Attackers[attacker] = now
			end
		end
	end)

	--- Adds everything besides the human players to perception's candidate
	-- list: other bots (factions sort out who fights whom) and NPCs.
	function hg.bots.ExtraTargets(list)
		if hg_bot_factions:GetBool() or (hg.bots.DirectorMode and hg.bots.DirectorMode() ~= 0) then
			for bot in pairs(hg.bots.List) do
				if IsValid(bot) and bot:Alive() then list[#list + 1] = bot end
			end
		end

		for _, ent in ipairs(NPCList()) do
			list[#list + 1] = ent
		end

		return list
	end

	--- Trims the shared candidate list down to what THIS bot may fight.
	-- Returns nil when nothing had to be removed, so the common case
	-- allocates nothing.
	function hg.bots.FilterTargets(bot, list)
		local npcRangeSqr = hg_bot_npc_range:GetFloat() ^ 2
		local pos = bot:GetPos()
		local out, dropped

		for _, ent in ipairs(list) do
			local keep = true

			if ent == bot then
				keep = false
			elseif ent.IsHomigradBot then
				keep = not hg.bots.SameFaction(ent, bot)
			elseif not ent:IsPlayer() then
				keep = hg.bots.IsNPCTarget(ent) and pos:DistToSqr(ent:GetPos()) < npcRangeSqr
			end

			if keep then
				if out then out[#out + 1] = ent end
			else
				if not out then
					out = {}

					for _, prev in ipairs(list) do
						if prev == ent then break end

						out[#out + 1] = prev
					end
				end

				dropped = true
			end
		end

		return dropped and out or nil
	end
--//

--\\ Guards stay with the players
	--- A guard with nothing to fight walks back to the nearest player
	-- instead of wandering off on its own. Called from the idle state's
	-- extension points (sv_bot_navigation.lua) through CheckGuardEscort.
	function hg.bots.CheckGuardEscort(bot, data)
		if hg.bots.IsDirectorBot and hg.bots.IsDirectorBot(bot) and hg.bots.DirectorMode() == 2 then return false end
		if not hg_bot_factions:GetBool() then return false end
		if hg.bots.GetFaction(bot) ~= "guard" then return false end

		local leash = hg_bot_guard_follow:GetFloat()

		if leash <= 0 then return false end

		local pos = bot:GetPos()
		local best, bestDist

		for _, ply in ipairs(player.GetHumans()) do
			if ply:Alive() then
				local d = pos:DistToSqr(ply:GetPos())

				if not bestDist or d < bestDist then best, bestDist = ply, d end
			end
		end

		if not best or bestDist < leash * leash then return false end

		if not data.Goal or data.Goal:DistToSqr(best:GetPos()) > 200 ^ 2 then
			hg.bots.SetGoal(bot, best:GetPos())
		end

		data.Running = bestDist > (leash * 1.8) ^ 2

		hg.bots.FollowPath(bot, data)

		return true
	end
--//

--\\ Defaults
	-- Every bot advertises its faction, so the C menu can show the right
	-- entry for it: the server-side table isn't visible to a client.
	hook.Add("HG_BotInitialized", "HG_Bots_FactionDefault", function(bot)
		if not IsValid(bot) then return end

		bot:SetNWString("hg_bot_faction", hg.bots.GetFaction(bot) or "raider")
	end)
--//

--\\ Commands
	local function CheckAccess(ply)
		return not IsValid(ply) or ply:IsSuperAdmin()
	end

	concommand.Add("hg_bot_spawn_guard", function(ply, cmd, args)
		if not CheckAccess(ply) then return end

		local pos = IsValid(ply) and ply:GetEyeTrace().HitPos + Vector(0, 0, 8) or Vector(0, 0, 0)
		local ang = IsValid(ply) and ply:EyeAngles() or Angle(0, 0, 0)
		local kit = args and args[1]
		local bot = kit and kit ~= "" and hg.bots.SpawnWithKit and hg.bots.SpawnWithKit(pos, ang, kit)
			or hg.bots.Spawn(pos, ang)

		if not IsValid(bot) then return end

		-- Straight away, on the entity: Init (two ticks later) takes it
		-- from there. A timer here used to race the Init and lose.
		hg.bots.SetFaction(bot, "guard")
	end, nil, "Spawn a bot friendly to players: hg_bot_spawn_guard [kit name]")

	--- One command that answers "why is this bot ignoring me?". Prints
	-- every gate that can silence a bot, in the order they apply.
	concommand.Add("hg_bot_diag", function(ply)
		local function say(line)
			print(line)

			if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, line) end
		end

		local trust = GetConVar("hg_bot_trust")

		say("[hg.bots] --- diagnostics ---")
		say(("trust mode: %s%s"):format(trust and trust:GetString() or "?",
			(trust and trust:GetBool()) and "  <-- BOTS ONLY ATTACK PLAYERS WHO ATTACKED A BOT. Run hg_bot_wild to turn this off." or ""))
		say(("factions: %s   npc targets: %s"):format(hg_bot_factions:GetString(), hg_bot_npc:GetString()))

		local hostileCount = 0

		for who, untilT in pairs(hg.bots.Hostile or {}) do
			if IsValid(who) and untilT > CurTime() then hostileCount = hostileCount + 1 end
		end

		say(("marked hostile players: %d"):format(hostileCount))

		-- What the NPC targeting currently considers fair game. An unexpected
		-- class in here is the fastest explanation for bots ignoring people.
		local classes = {}

		for _, ent in ipairs(ents.GetAll()) do
			if hg.bots.IsNPCTarget(ent) then
				local class = ent:GetClass()

				classes[class] = (classes[class] or 0) + 1
			end
		end

		local parts = {}

		for class, n in pairs(classes) do parts[#parts + 1] = ("%s x%d"):format(class, n) end

		say(("npc targets: %s"):format(#parts > 0 and table.concat(parts, ", ") or "none"))

		local enabled = GetConVar("hg_bot_enabled")

		if enabled then say(("hg_bot_enabled: %s"):format(enabled:GetString())) end

		local count = 0

		for bot in pairs(hg.bots.List) do
			count = count + 1

			local data = IsValid(bot) and bot.Bot

			if not data then
				say(("  %s: no Bot table (not initialized)"):format(tostring(bot)))
			else
				local mem = data.Memory or {}
				local nearest, nearestDist

				for _, human in ipairs(player.GetHumans()) do
					if human:Alive() then
						local d = bot:GetPos():Distance(human:GetPos())

						if not nearestDist or d < nearestDist then nearest, nearestDist = human, d end
					end
				end

				local spot = nearest and mem.Spot and mem.Spot[nearest] or 0
				local sees = nearest and hg.bots.CanSee and hg.bots.CanSee(bot, nearest) or false

				say(("  %s  faction=%s  enabled=%s  state=%s  target=%s  ragdoll=%s"):format(
					bot:Nick(), hg.bots.GetFaction(bot) or "-", tostring(data.Enabled),
					tostring(data.State), IsValid(mem.Target) and mem.Target:Nick() or "-",
					tostring(IsValid(bot.FakeRagdoll))))

				if nearest then
					say(("     nearest player %s: %.0f u, sees=%s, spot meter=%.2f, may attack=%s"):format(
						nearest:Nick(), nearestDist, tostring(sees), spot,
						tostring(hg.bots.IsHostile and hg.bots.IsHostile(nearest, bot))))
				end
			end
		end

		say(("bots: %d"):format(count))
	end, nil, "Print why bots are or aren't reacting (trust mode, factions, per-bot state)")

	--- Wild mode: trust off, every grudge and hostility record wiped.
	concommand.Add("hg_bot_wild", function(ply)
		if not CheckAccess(ply) then return end

		RunConsoleCommand("hg_bot_trust", "0")

		hg.bots.Hostile = {}

		for bot in pairs(hg.bots.List) do
			local mem = IsValid(bot) and bot.Bot and bot.Bot.Memory

			if mem then mem.Grudge = nil end
		end

		print("[hg.bots] wild mode: trust off, hostility records cleared - every bot attacks players again")
	end, nil, "Turn trust mode off and clear every grudge")

	-- Trust mode is saved in data/hg_bots_settings.json, so a preset applied
	-- once keeps bots passive across restarts. Say so out loud at startup -
	-- this looked exactly like "the bots are broken".
	hook.Add("Initialize", "HG_Bots_TrustWarning", function()
		timer.Simple(1, function()
			local trust = GetConVar("hg_bot_trust")

			if trust and trust:GetBool() then
				print("[hg.bots] WARNING: trust mode is ON - bots will not attack a player until that player attacks a bot. Run hg_bot_wild to turn it off.")
			end
		end)
	end)

	concommand.Add("hg_bot_faction", function(ply, cmd, args)
		if not CheckAccess(ply) then return end

		local faction = args and args[1]

		if not hg.bots.Factions[faction] then
			print("[hg.bots] usage: hg_bot_faction <raider|guard|neutral> - applies to the bot you are looking at, or all bots with 'all'")
			return
		end

		local which = args[2]

		if which == "all" then
			for bot in pairs(hg.bots.List) do hg.bots.SetFaction(bot, faction) end

			print("[hg.bots] every bot is now " .. faction)

			return
		end

		local ent = IsValid(ply) and ply:GetEyeTrace().Entity

		if IsValid(ent) and ent.IsHomigradBot and hg.bots.SetFaction(ent, faction) then
			print("[hg.bots] " .. ent:Nick() .. " is now " .. faction)
		end
	end, nil, "Set a bot's faction: hg_bot_faction <raider|guard|neutral> [all]")
--//
