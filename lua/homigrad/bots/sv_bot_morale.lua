--[[
	Tarkov AI - Morale

	Bots stop treating every fight as an isolated event. Hurting or killing
	one of them is noticed by the others nearby, and what they do about it
	depends on what they are carrying:

	- A bot that is well equipped (armour, a decent gun, ammo in reserve,
	  something to patch up with) gets ANGRY: it marks the attacker
	  personally, tells the others, pushes instead of waiting and stays in
	  the fight at lower health.
	- A bot that is poorly equipped, low on ammo or already hurt gets
	  SHAKEN instead: it holds angles, keeps its distance and runs sooner.

	Two numbers per bot:
	- Morale (0..1, starts at hg_bot_morale_start): how willing it is to
	  fight at all. Drops when its side gets hurt, recovers slowly, goes up
	  when its side wins something.
	- Anger per player (0..1): how personal it is with that one player.
	  Anger is what turns a morale hit into aggression rather than fear,
	  and it cools off much more slowly than morale recovers.

	The gear check reuses sv_bot_selfpreservation.lua's own loadout scoring
	(hg.bots.AssessLoadout / GetArmorScore) plus ammo reserve, health and
	whether the bot carries anything medical (sv_bot_medic.lua), so "well
	equipped" means the same thing here as everywhere else.

	Nothing here overrides a decision outright: morale biases the existing
	tactic roll (sv_bot_selfpreservation.lua's GetTactic), the flee roll
	(sv_bot_flee.lua) and melee aggression (sv_bot_melee.lua). A squad role
	still wins over morale - one bot pushing while the rest cover is a
	better answer than four angry bots charging the same corner.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {}

local hg_bot_morale         = CreateConVar("hg_bot_morale",         "1",    {FCVAR_ARCHIVE}, "Bots react to their side being hurt: anger (push harder) or shaken nerve (hold back), depending on their gear", 0, 1)
local hg_bot_morale_start   = CreateConVar("hg_bot_morale_start",   "0.6",  {FCVAR_ARCHIVE}, "Morale a bot spawns with (0 = broken, 1 = fearless)", 0, 1)
local hg_bot_morale_radius  = CreateConVar("hg_bot_morale_radius",  "1800", {FCVAR_ARCHIVE}, "How far away a bot notices one of its own being hurt or killed", 100, 8000)
local hg_bot_morale_recover = CreateConVar("hg_bot_morale_recover", "0.02", {FCVAR_ARCHIVE}, "Morale recovered per second of quiet", 0, 1)
local hg_bot_anger_decay    = CreateConVar("hg_bot_anger_decay",    "0.01", {FCVAR_ARCHIVE}, "Anger at a specific player lost per second", 0, 1)
local hg_bot_morale_kill    = CreateConVar("hg_bot_morale_kill",    "0.35", {FCVAR_ARCHIVE}, "Morale hit when a nearby bot is killed", 0, 1)
local hg_bot_morale_hurt    = CreateConVar("hg_bot_morale_hurt",    "0.08", {FCVAR_ARCHIVE}, "Morale hit when a nearby bot is badly hurt", 0, 1)
local hg_bot_morale_debug   = CreateConVar("hg_bot_morale_debug",   "0",    {FCVAR_ARCHIVE}, "Print morale/anger changes to the server console", 0, 1)

--\\ State
	local function State(bot)
		local data = bot.Bot

		if not data then return nil end

		if not data.Morale then
			data.Morale = hg_bot_morale_start:GetFloat()
			data.Anger = {}
		end

		return data
	end

	--- 0 = broken, 1 = fearless.
	function hg.bots.GetMorale(bot)
		local data = IsValid(bot) and State(bot)

		return data and data.Morale or 1
	end

	--- How personal it is with this player (0..1).
	function hg.bots.GetAnger(bot, ply)
		local data = IsValid(bot) and State(bot)

		if not data or not IsValid(ply) then return 0 end

		return data.Anger[ply] or 0
	end

	--- Out for blood AND able to back it up. Being furious with an empty
	-- magazine is still a reason to leave.
	function hg.bots.IsEnraged(bot, ply)
		if not hg_bot_morale:GetBool() then return false end
		if hg.bots.GetAnger(bot, ply) < 0.35 then return false end

		return hg.bots.GetReadiness(bot) >= 0.5
	end
--//

--\\ How well equipped the bot is (0..1)
	--- Gun, ammo, armour, health and something to patch up with. This is
	-- what decides whether a morale hit turns into aggression or caution.
	function hg.bots.GetReadiness(bot)
		if not IsValid(bot) then return 0 end

		local score = 0

		-- Weapon and armour: the same scoring the gear-aware flee logic uses.
		if hg.bots.AssessLoadout then
			score = score + math.Clamp(hg.bots.AssessLoadout(bot) / 40, 0, 1) * 0.4
		else
			score = score + 0.2
		end

		-- Ammo in reserve for whatever is in hand.
		local wep = bot:GetActiveWeapon()

		if IsValid(wep) and wep.GetPrimaryAmmoType then
			local id = wep:GetPrimaryAmmoType()

			if id and id >= 0 then
				local reserve = bot:GetAmmoCount(id) + math.max(wep:Clip1(), 0)

				score = score + math.Clamp(reserve / 90, 0, 1) * 0.25
			elseif hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep) then
				score = score + 0.1
			end
		end

		-- Health.
		local maxHP = bot:GetMaxHealth()

		score = score + (maxHP > 0 and math.Clamp(bot:Health() / maxHP, 0, 1) or 1) * 0.25

		-- Something to treat wounds with.
		if hg.bots.HasMeds and hg.bots.HasMeds(bot) then score = score + 0.1 end

		return math.Clamp(score, 0, 1)
	end
--//

--\\ Events
	local function Notify(bot, attacker, moraleHit, angerGain, why)
		local data = State(bot)

		if not data then return end

		local ready = hg.bots.GetReadiness(bot)

		-- Well kitted out: it makes them angry, not scared. Badly kitted
		-- out: the reverse. Readiness 0.5 is the break-even point.
		local swing = (ready - 0.5) * 2 -- -1 .. 1

		data.Morale = math.Clamp(data.Morale - moraleHit * (1 - math.max(swing, 0) * 0.8), 0, 1)

		if IsValid(attacker) and attacker:IsPlayer() then
			local anger = (data.Anger[attacker] or 0) + angerGain * (0.6 + math.max(swing, 0) * 0.8)

			data.Anger[attacker] = math.Clamp(anger, 0, 1)

			-- It's personal now: even in trust mode this one is fair game.
			if hg.bots.MarkHostile and data.Anger[attacker] > 0.5 then
				hg.bots.MarkHostile(attacker, bot, 1.5)
			end
		end

		if hg_bot_morale_debug:GetBool() then
			print(("[hg.bots] morale %s: %s -> %.2f (anger %.2f, readiness %.2f)"):format(
				bot:Nick(), why, data.Morale,
				IsValid(attacker) and (data.Anger[attacker] or 0) or 0, ready))
		end
	end

	--- Everyone on our side close enough to have seen or heard it.
	local function Witnesses(victim)
		local out = {}
		local radiusSqr = hg_bot_morale_radius:GetFloat() ^ 2
		local pos = victim:GetPos()

		for bot in pairs(hg.bots.List) do
			if IsValid(bot) and bot ~= victim and bot:Alive() and bot.Bot and bot.Bot.Enabled then
				if bot:GetPos():DistToSqr(pos) < radiusSqr then out[#out + 1] = bot end
			end
		end

		return out
	end

	--- One of ours is being hurt (or killed) by a player.
	function hg.bots.MoraleDamage(victim, attacker, fatal)
		if not hg_bot_morale:GetBool() then return end
		if not IsValid(victim) or not victim.IsHomigradBot then return end
		if not IsValid(attacker) or not attacker:IsPlayer() or attacker.IsHomigradBot then return end

		local hit = fatal and hg_bot_morale_kill:GetFloat() or hg_bot_morale_hurt:GetFloat()
		local anger = fatal and 0.6 or 0.15

		-- A punch or a blade is not a bullet: a blow from someone without a
		-- gun shakes the rest much less (sv_bot_nerve.lua's fist fights).
		if not fatal and hg.bots.GetWeaponKind and hg.bots.GetWeaponKind(attacker, false) ~= "gun" then
			hit = hit * 0.4
		end

		-- The one being hit takes it hardest.
		Notify(victim, attacker, hit * 0.5, anger, fatal and "killed" or "hurt")

		for _, bot in ipairs(Witnesses(victim)) do
			Notify(bot, attacker, hit, anger * 0.8, fatal and "squadmate killed" or "squadmate hurt")

			-- Angry bots go looking instead of waiting to be told.
			if hg.bots.ShareContact and hg.bots.GetAnger(bot, attacker) > 0.4 then
				hg.bots.ShareContact(victim, attacker, attacker:GetPos())
			end
		end
	end

	--- Something went our way: a player nearby died.
	local function MoraleWin(ply)
		for _, bot in ipairs(Witnesses(ply)) do
			local data = State(bot)

			if data then data.Morale = math.Clamp(data.Morale + 0.2, 0, 1) end
		end
	end

	hook.Add("EntityTakeDamage", "HG_Bots_Morale", function(ent, dmginfo)
		if not hg_bot_morale:GetBool() then return end

		local victim = hg.bots.OwnerBot and hg.bots.OwnerBot(ent) or (IsValid(ent) and ent.IsHomigradBot and ent)

		if not IsValid(victim) then return end

		local attacker = dmginfo:GetAttacker()

		if hg.bots.ResolveShooter then
			local real = hg.bots.ResolveShooter(attacker)

			if IsValid(real) then attacker = real end
		end

		if not IsValid(attacker) or not attacker:IsPlayer() or attacker.IsHomigradBot then return end

		-- Real blows only, and at most twice a second per victim: a burst
		-- of five rounds is one event, not five.
		if dmginfo:GetDamage() < 4 then return end
		if (victim.hgBotMoraleAt or 0) > CurTime() then return end

		victim.hgBotMoraleAt = CurTime() + 0.5

		hg.bots.MoraleDamage(victim, attacker, false)
	end)

	hook.Add("PlayerDeath", "HG_Bots_Morale_Death", function(victim, inflictor, attacker)
		if not hg_bot_morale:GetBool() then return end
		if not IsValid(victim) then return end

		local killer = hg.bots.ResolveShooter and hg.bots.ResolveShooter(attacker) or attacker

		if victim.IsHomigradBot then
			hg.bots.MoraleDamage(victim, killer, true)
		elseif IsValid(killer) and killer.IsHomigradBot then
			MoraleWin(victim)
		end
	end)
--//

--\\ What morale actually changes
	--- Tactic bias: "push" / "wait" / "careful" / nil (no opinion).
	-- Consulted by hg.bots.GetTactic AFTER the squad role - coordination
	-- beats mood.
	function hg.bots.MoraleTactic(bot, target)
		if not hg_bot_morale:GetBool() then return nil end

		local data = State(bot)

		if not data then return nil end

		local ready = hg.bots.GetReadiness(bot)
		local anger = IsValid(target) and (data.Anger[target] or 0) or 0

		-- Out for blood and able to back it up.
		if anger >= 0.35 and ready >= 0.5 and math.random() < 0.5 + anger * 0.4 then return "push" end

		-- Rattled, or in no state for a fight: hold the angle instead.
		if data.Morale < 0.35 or ready < 0.35 then
			return math.random() < 0.7 and "wait" or "careful"
		end

		return nil
	end

	--- Multiplier on how hard a bot presses in melee. 1 = unchanged.
	function hg.bots.MoraleAggression(bot, target)
		if not hg_bot_morale:GetBool() then return 1 end

		local data = State(bot)

		if not data then return 1 end

		local anger = IsValid(target) and (data.Anger[target] or 0) or 0

		return math.Clamp(0.7 + data.Morale * 0.5 + anger * 0.5, 0.5, 1.8)
	end

	--- Added to the flee roll: shaken bots run sooner, angry well-equipped
	-- ones stay in it longer. Consumed by sv_bot_flee.lua's ShouldFlee.
	function hg.bots.MoraleFleeBias(bot)
		if not hg_bot_morale:GetBool() then return 0 end

		local data = State(bot)

		if not data then return 0 end

		local mem = data.Memory
		local target = mem and mem.Target
		local anger = IsValid(target) and (data.Anger[target] or 0) or 0
		local ready = hg.bots.GetReadiness(bot)

		-- Nothing to fight with is its own argument for leaving.
		local bias = (1 - data.Morale) * 0.4 + (0.5 - math.min(ready, 0.5)) * 0.6

		-- The body's own fear (org.fear, Z-City's pulse module) pushes the
		-- same way, and adrenaline from the syringe pushes back: that is the
		-- whole point of carrying one (sv_bot_medic.lua's "fear" treatment).
		local org = bot.organism

		if org then
			bias = bias + math.Clamp(org.fear or 0, 0, 1) * 0.25
			bias = bias - math.Clamp((org.adrenaline or 0) / 2, 0, 1) * 0.3
		end

		return math.Clamp(bias - anger * 0.35, -0.5, 0.6)
	end

	-- Quiet time heals: morale drifts back up, grudges cool off slowly.
	timer.Create("HG_Bots_Morale", 1, 0, function()
		if not hg_bot_morale:GetBool() then return end

		local recover = hg_bot_morale_recover:GetFloat()
		local decay = hg_bot_anger_decay:GetFloat()

		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and State(bot)

			if data then
				data.Morale = math.Clamp(data.Morale + recover, 0, 1)

				for ply, anger in pairs(data.Anger) do
					local left = anger - decay

					if left <= 0 or not IsValid(ply) then
						data.Anger[ply] = nil
					else
						data.Anger[ply] = left
					end
				end
			end
		end
	end)

	concommand.Add("hg_bot_morale_report", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and State(bot)

			if data then
				local worst, worstAnger = nil, 0

				for target, anger in pairs(data.Anger) do
					if anger > worstAnger then worst, worstAnger = target, anger end
				end

				print(("[hg.bots] %s: morale %.2f, readiness %.2f, angriest at %s (%.2f)"):format(
					bot:Nick(), data.Morale, hg.bots.GetReadiness(bot),
					IsValid(worst) and worst:Nick() or "-", worstAnger))
			end
		end
	end)
--//
