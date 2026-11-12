--[[
	Tarkov AI - server time Z-City spends per player

	A bot is a player to Z-City: every one of them runs the whole organism,
	movement and animation pipeline, 66 times a second. Measured on a
	dedicated server with fifteen bots in a firefight, all Lua hooks
	together took about 290 ms of every second - and the bots' own AI
	about 50 of that. The rest is Z-City's per-player work, which this
	add-on does not own and does not rewrite.

	Two things in it, though, are pure repetition and can be taken out
	from the outside without changing what anything computes:

	- hg.CalculateWeight (the carried weight: every weapon, every ammo
	  type, every armour piece added up) is asked for by the movement
	  hook on every tick of every player. The answer changes when
	  somebody picks something up. It is now worked out four times a
	  second per player and remembered in between. (13 microseconds a
	  call, 1000+ calls a second with fifteen bots.)

	- The NPC fall damage tracker walks ents.GetAll() - every entity on
	  the map - on every server frame, looking for NPCs. With no NPC on
	  the map it now returns at once; with some, it runs as before.

	Both are wrappers round Z-City's own functions: the originals still do
	the work, an update to Z-City changes what they do and these still
	fit. With hg_bot_zcperf 0 both wrappers pass every call straight on.
]]

hg.bots = hg.bots or {}

local hg_bot_zcperf = CreateConVar("hg_bot_zcperf", "1", {FCVAR_ARCHIVE}, "Two safe speed-ups of Z-City's own per-player work (carried weight remembered for a quarter second; the NPC fall tracker skipped while the map has no NPCs). 0 = Z-City exactly as shipped", 0, 1)

local WEIGHT_KEEP = 0.25

local ours = setmetatable({}, { __mode = "k" }) -- [wrapper] = original
local hasNPC = true

--\\ Carried weight
	local function WrapWeight()
		local orig = hg.CalculateWeight

		if not isfunction(orig) or ours[orig] then return end

		local function Weight(ply, maxweight)
			if not hg_bot_zcperf:GetBool() or not maxweight then return orig(ply, maxweight) end

			local memo = ply.hgWeightMemo

			if not memo then
				memo = {}
				ply.hgWeightMemo = memo
			end

			local m = memo[maxweight]
			local now = CurTime()

			if m then
				if now - m[1] < WEIGHT_KEEP and now >= m[1] then return m[2] end
			else
				m = { 0, 1 }
				memo[maxweight] = m
			end

			m[1], m[2] = now, orig(ply, maxweight)

			return m[2]
		end

		ours[Weight] = orig
		hg.CalculateWeight = Weight
	end

	-- What somebody carries just changed: weigh again on the next ask.
	local function Forget(ply)
		if IsValid(ply) then ply.hgWeightMemo = nil end
	end

	hook.Add("WeaponEquip", "HG_Bots_ZCPerfWeight", function(wep, owner) Forget(owner) end)
	hook.Add("PlayerDroppedWeapon", "HG_Bots_ZCPerfWeight", function(owner) Forget(owner) end)
	hook.Add("PlayerSpawn", "HG_Bots_ZCPerfWeight", function(ply) Forget(ply) end)
--//

--\\ NPC fall tracker
	local function WrapFallTracker()
		local tbl = hook.GetTable().Think
		local orig = tbl and tbl.NPCFallDamageTracker

		if not isfunction(orig) or ours[orig] then return end

		local function Tracker()
			if not hasNPC and hg_bot_zcperf:GetBool() then return end

			orig() -- (no return: a Think hook that hands a value on ends the chain)
		end

		ours[Tracker] = orig
		hook.Add("Think", "NPCFallDamageTracker", Tracker)
	end

	hook.Add("OnEntityCreated", "HG_Bots_ZCPerfNPC", function(ent)
		if hasNPC then return end

		timer.Simple(0, function()
			if IsValid(ent) and ent:IsNPC() and ent:GetClass() ~= "npc_bullseye" then hasNPC = true end
		end)
	end)

	timer.Create("HG_Bots_ZCPerfNPC", 3, 0, function()
		-- (Not the npc_bullseye Z-City hangs on every player and ragdoll
		-- for NPCs to aim at: those are always there and never fall.)
		hasNPC = false

		for _, ent in ipairs(ents.FindByClass("npc_*")) do
			if ent:GetClass() ~= "npc_bullseye" then hasNPC = true break end
		end

		-- Z-City's files loaded after this one, or were refreshed: the
		-- original is back in place, wrap it again.
		WrapWeight()
		WrapFallTracker()

		if hg.bots.WrapEyeTrace then hg.bots.WrapEyeTrace() end
	end)
--//

--\\ Eye trace that always answers
	-- hg.eyeTrace returns nothing at all for a player whose model has no
	-- "ValveBiped.Bip01_Neck1" bone - a bot before its appearance is on
	-- (models/player.mdl), or any model with its own skeleton. Z-City's
	-- callers index the result regardless:
	--   sh_utility.lua:1513 attempt to index local 'eyetr' (FindUseEntity,
	--   whenever such a player holds Use - a bot opening a door)
	--   weapon_hg_bow/init.lua:98 attempt to index local 'tr' (every tick)
	-- For a player the original gives no answer for, this hands back a
	-- plain trace from the eyes along the aim. Not switched by the convar:
	-- it only ever replaces an error.
	local function WrapEyeTrace()
		local orig = hg.eyeTrace

		if not isfunction(orig) or ours[orig] then return end

		local function EyeTrace(ply, dist, ent, aim_vector, startpos, fFilter)
			local tr, a, b = orig(ply, dist, ent, aim_vector, startpos, fFilter)

			if tr ~= nil or not IsValid(ply) or not ply:IsPlayer() then return tr, a, b end

			local start = isvector(startpos) and startpos or ply:EyePos()
			local aim = isvector(aim_vector) and aim_vector or isangle(aim_vector) and aim_vector:Forward() or ply:GetAimVector()

			return util.TraceLine({
				start = start,
				endpos = start + aim * (dist or 60),
				filter = fFilter or { ply, ply.FakeRagdoll },
			})
		end

		ours[EyeTrace] = orig
		hg.eyeTrace = EyeTrace
	end

	hg.bots.WrapEyeTrace = WrapEyeTrace -- (the three-second timer above puts it back after a refresh)
--//

hook.Add("InitPostEntity", "HG_Bots_ZCPerf", function()
	timer.Simple(1, function()
		WrapWeight()
		WrapFallTracker()
		WrapEyeTrace()
	end)
end)

-- (Loaded into a running game - a Lua refresh, or this file added while
-- the map is up: InitPostEntity is long gone.)
timer.Simple(0, function()
	WrapWeight()
	WrapFallTracker()
	WrapEyeTrace()
end)

--- For a look from the console: what is wrapped right now.
concommand.Add("hg_bot_zcperf_status", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end

	local tracker = hook.GetTable().Think and hook.GetTable().Think.NPCFallDamageTracker

	print(("[hg.bots] zcperf %s: carried weight %s, NPC fall tracker %s (NPCs on the map: %s)"):format(
		hg_bot_zcperf:GetBool() and "on" or "off",
		ours[hg.CalculateWeight] and "remembered" or "not wrapped",
		ours[tracker] and "guarded" or "not wrapped",
		tostring(hasNPC)))
end)
