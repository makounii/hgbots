--[[
	Tarkov AI - Self treatment

	Bots use Z-City's own medical items on themselves, standing or while
	ragdolled, and that decision feeds the retreat logic: breaking contact
	is worth a lot more when there is something to patch up with.

	Verified against the real items (lua/weapons):

	- Every medical item derives from weapon_bandage_sh /
	  weapon_hg_medicine_base and heals its OWN owner on IN_ATTACK
	  (SWEP:PrimaryAttack -> SWEP:Heal(owner)); IN_ATTACK2 heals whoever
	  the owner looks at. Only self-treatment is used here.
	- They all carry SWEP.WorkWithFake = true, so they work while downed
	  too - which is the case that actually matters, since bleeding out on
	  the floor is what kills. Switching weapons in a ragdoll needs
	  organism.canmove (weapons/homigrad_base/sv_fake.lua), so that is
	  checked before trying.
	- What each one is for, from the organism model:
	  * organism.arterialwounds - arterial bleeding. ONLY a tourniquet
	    (SWEP:Tourniquet) stops it, and it costs the limb's use. Highest
	    priority: it drains blood fastest.
	  * organism.wounds - ordinary bleeding, closed by bandages/medkits.
	  * organism.pain - over ~50 it halves ragdoll strength
	    (fake/sv_control.lua's power) and over 60 it adds disorientation.
	    Morphine/painkillers push it down.
	- Morphine overdoses: the item damages the user once more than one
	  full dose went into the same body (owner.injectedinto), so it's
	  pressed in short pulses with a long cooldown, never held down.

	The trigger is deliberately NOT "hurt at all": bandaging in the open
	while someone is shooting is how a bot dies holding gauze. Healing
	happens after contact is broken (the flee state hands over here), or
	while idle, or while down and not being looked at - except arterial
	bleeding, which is treated even under fire.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {}
hg.bots.States = hg.bots.States or {}
hg.bots.RegisterState = hg.bots.RegisterState or function(name, tbl) hg.bots.States[name] = tbl end

local hg_bot_heal         = CreateConVar("hg_bot_heal",         "1",   {FCVAR_ARCHIVE}, "Bots treat themselves with bandages / tourniquets / morphine", 0, 1)
local hg_bot_heal_blood   = CreateConVar("hg_bot_heal_blood",   "0.93",{FCVAR_ARCHIVE}, "Blood fraction (of 5000) below which open wounds are worth stopping to bandage", 0.1, 1)
local hg_bot_heal_pain    = CreateConVar("hg_bot_heal_pain",    "25",  {FCVAR_ARCHIVE}, "Pain level at which a bot takes a painkiller/morphine (50+ halves ragdoll strength)", 5, 150)
local hg_bot_heal_safe    = CreateConVar("hg_bot_heal_safe",    "800", {FCVAR_ARCHIVE}, "How far the last known threat must be before a bot stops to treat itself", 100, 5000)
local hg_bot_heal_timeout = CreateConVar("hg_bot_heal_timeout", "14",  {FCVAR_ARCHIVE}, "Seconds a bot keeps trying to treat itself before giving up and getting back to the fight", 2, 60)
local hg_bot_heal_fear    = CreateConVar("hg_bot_heal_fear",    "1",   {FCVAR_ARCHIVE}, "Bots use the syringe (weapon_adrenaline) to kill fear: adrenaline stops the body being afraid", 0, 1)
local hg_bot_heal_fear_at = CreateConVar("hg_bot_heal_fear_at", "0.5", {FCVAR_ARCHIVE}, "Z-City fear level (org.fear, 0-1) at which a bot injects the syringe", 0.05, 1)
local hg_bot_heal_fear_morale = CreateConVar("hg_bot_heal_fear_morale", "0.45", {FCVAR_ARCHIVE}, "Morale below which a bot injects the syringe even before its body is afraid", 0, 1)
local hg_bot_heal_fear_cd = CreateConVar("hg_bot_heal_fear_cd", "60", {FCVAR_ARCHIVE}, "Seconds before a bot may use the syringe again", 5, 600)
local hg_bot_heal_adren_cap = CreateConVar("hg_bot_heal_adren_cap", "1.5", {FCVAR_ARCHIVE}, "Adrenaline already in the body above which no further dose is taken", 0.2, 4)
local hg_bot_heal_premed  = CreateConVar("hg_bot_heal_premed",  "1",   {FCVAR_ARCHIVE}, "Bots take a painkiller/morphine BEFORE a fight, while the enemy is still at a distance", 0, 1)
local hg_bot_premed_cap   = CreateConVar("hg_bot_premed_cap",   "0.6", {FCVAR_ARCHIVE}, "Analgesia a bot tops itself up to before a fight (the item damages its user past a full dose, so this stays under 1)", 0.1, 3)
local hg_bot_premed_wait  = CreateConVar("hg_bot_premed_wait",  "3",   {FCVAR_ARCHIVE}, "Seconds between painkiller presses (they inject continuously while held - this is what stops an overdose)", 0.5, 30)

--\\ The items
	-- What each item treats, and which of its MODES does it. Z-City's
	-- medkit is one item with five modes cycled with R (SWEP:Reload ->
	-- self.mode, weapon_medkit_sh): bandaging, painkiller, tranexamic
	-- acid, tourniquet, decompression needle. Picking the mode is the
	-- whole point - a medkit sitting on "bandaging" does nothing at all
	-- for arterial bleeding.
	local MED_MODES = {
		weapon_bandage_sh    = { wound = 1 },
		weapon_bigbandage_sh = { wound = 1 },
		weapon_tourniquet    = { arterial = 1 },
		weapon_morphine      = { pain = 1 },
		weapon_painkillers   = { pain = 1 },
		weapon_needle        = { pain = 1 },
		weapon_medkit_sh     = { wound = 1, pain = 2, internal = 3, arterial = 4, pneumo = 5 },
		-- The syringe (Epinephrine Autoinjector, weapon_adrenaline, base
		-- weapon_bandage_sh): its one mode pushes org.adrenalineAdd, and
		-- adrenaline is what stops a body being afraid - it also holds off
		-- the blackout from blood loss (sv_blood.lua divides the 2400 ml
		-- threshold by adrenaline/3 + 1) and takes the edge off pain. So it
		-- is its own kind of treatment, "fear", not a painkiller.
		weapon_adrenaline    = { fear = 1 },
	}

	--- Is this weapon CLASS a medical item? (Used by sv_bot_loot.lua for
	-- items lying in the world, which aren't carried by anyone yet.)
	function hg.bots.IsMedClass(class)
		return MED_MODES[class] ~= nil
	end

	--- Is there anything left in this item's mode? modeValues[mode] is the
	-- remaining amount (gauze left, doses left, 1/0 for a tourniquet).
	local function HasCharge(wep, mode)
		local mv = wep.modeValues

		if not mv then return true end

		local left = mv[mode or 1]

		return left == nil or left > 0
	end

	--- The bot's item for this kind of injury, and the mode to set it to.
	-- @return weapon, mode
	function hg.bots.FindMed(bot, kind)
		if not IsValid(bot) then return nil end

		for _, wep in ipairs(bot:GetWeapons()) do
			local modes = MED_MODES[wep:GetClass()]
			local mode = modes and modes[kind]

			if mode and HasCharge(wep, mode) then return wep, mode end
		end

		return nil
	end

	--- Does the bot carry any usable treatment at all? Used by the flee
	-- decision: having something to patch up with makes breaking contact
	-- worth more than standing and trading shots.
	function hg.bots.HasMeds(bot)
		if not IsValid(bot) then return false end

		for _, wep in ipairs(bot:GetWeapons()) do
			local modes = MED_MODES[wep:GetClass()]

			if modes then
				for _, mode in pairs(modes) do
					if HasCharge(wep, mode) then return true end
				end
			end
		end

		return false
	end
--//

--\\ What's wrong and what to do about it
	--- The most urgent thing that can be treated right now, or nil.
	-- Order is by what kills fastest, not by what hurts most.
	-- @return "arterial" | "internal" | "wound" | "pneumo" | "pain" | nil
	function hg.bots.HealNeed(bot)
		if not hg_bot_heal:GetBool() then return nil end
		if not IsValid(bot) or not bot:Alive() then return nil end

		local org = bot.organism

		if not org or org.otrub then return nil end

		if org.arterialwounds and #org.arterialwounds > 0 and hg.bots.FindMed(bot, "arterial") then
			return "arterial"
		end

		if (org.internalBleed or 0) - (org.internalBleedHeal or 0) > 0 and hg.bots.FindMed(bot, "internal") then
			return "internal"
		end

		local blood = (org.blood or 5000) / 5000

		if org.wounds and #org.wounds > 0 and blood < hg_bot_heal_blood:GetFloat() and hg.bots.FindMed(bot, "wound") then
			return "wound"
		end

		-- Collapsed lung: the decompression needle is the only thing for it.
		if not org.needle and ((org.lungsL and org.lungsL[2] == 1) or (org.lungsR and org.lungsR[2] == 1)) and hg.bots.FindMed(bot, "pneumo") then
			return "pneumo"
		end

		if (org.pain or 0) > hg_bot_heal_pain:GetFloat() and (org.analgesiaAdd or 0) < 0.8 and hg.bots.FindMed(bot, "pain") then
			return "pain"
		end

		-- Frightened, and carrying the syringe for exactly that.
		if hg.bots.FearNeed and hg.bots.FearNeed(bot) then return "fear" end

		return nil
	end

	--- Is this bot scared enough to use the syringe? Z-City's own fear
	-- (org.fear, 0..1) climbs from pain, blood loss and bleeding
	-- (should_gain_fear in organism/tier_1/modules/sv_pulse.lua) and takes
	-- minutes to fall again on its own; adrenaline is the shortcut. Our own
	-- morale counts too, so a bot whose squad just got wiped reaches for it.
	function hg.bots.FearNeed(bot)
		if not hg_bot_heal_fear:GetBool() then return false end

		local org = bot.organism
		local data = bot.Bot

		if not org or not data then return false end

		-- NOT while down. Fear is permanently high in a hurt body
		-- (should_gain_fear is pain > 30 or blood < 3000 or bleed > 1), so a
		-- downed bot "needed" the syringe forever: it lay there injecting
		-- instead of getting up, and the adrenaline kept dividing Z-City's
		-- blackout threshold, so it did not die either. One shot, then a
		-- long cooldown, and only on its feet.
		if IsValid(bot.FakeRagdoll) then return false end
		if CurTime() < (data.NextFearShot or 0) then return false end

		local adren = math.max(org.adrenaline or 0, org.adrenalineAdd or 0)

		if adren >= hg_bot_heal_adren_cap:GetFloat() then return false end
		if not hg.bots.FindMed(bot, "fear") then return false end

		if (org.fear or 0) >= hg_bot_heal_fear_at:GetFloat() then return true end

		-- Morale (sv_bot_morale.lua): shaken counts as afraid even when
		-- Z-City's own fear has not caught up yet.
		local morale = hg.bots.GetMorale and hg.bots.GetMorale(bot)

		return morale ~= nil and morale < hg_bot_heal_fear_morale:GetFloat()
	end

	--- A dose BEFORE the shooting starts, not after: pain is what makes a
	-- hit bot useless (over ~50 it halves ragdoll strength and blurs its
	-- aim), and a painkiller taken while a contact is still at a distance
	-- costs nothing. Taken once in a while, never mid-firefight, and never
	-- to the point of an overdose (the item damages you past one full
	-- dose in the same body).
	function hg.bots.ShouldPremedicate(bot)
		if not hg_bot_heal:GetBool() or not hg_bot_heal_premed:GetBool() then return false end

		local data = bot.Bot
		local mem = data and data.Memory

		if not mem then return false end

		local org = bot.organism

		if not org or org.otrub then return false end
		if CurTime() < (data.NextPremed or 0) then return false end

		-- Either a painkiller (pain is what makes a hit bot useless) or the
		-- syringe (fear is what makes a whole bot useless).
		local painReady = (org.analgesiaAdd or 0) < hg_bot_premed_cap:GetFloat() and hg.bots.FindMed(bot, "pain")
		local fearReady = hg_bot_heal_fear:GetBool() and (org.adrenaline or 0) < hg_bot_heal_adren_cap:GetFloat()
			and hg.bots.FindMed(bot, "fear")

		if not painReady and not fearReady then return false end

		-- A fight is coming: someone was spotted/heard recently, or the bot
		-- is already keyed up - but nobody is actually in sight right now.
		local target = mem.Target

		if IsValid(target) and target:Alive() and hg.bots.CanSee and hg.bots.CanSee(bot, target) then return false end

		local expecting = IsValid(target) or (mem.Alertness or 0) > 0.45 or (mem.SuspicionPos ~= nil)

		if not expecting then return false end

		-- Not with them breathing down our neck.
		local threatPos = mem.TargetPos or mem.UnderFireFrom

		if threatPos and bot:GetPos():DistToSqr(threatPos) < 500 * 500 then return false end

		return true
	end

	--- Is this a good moment to stop and treat? (The "downed" case has its
	-- own, looser rule - see TryHealDowned.)
	function hg.bots.ShouldHeal(bot)
		local need = hg.bots.HealNeed(bot)

		if not need then
			return hg.bots.ShouldPremedicate(bot)
		end

		if need == "arterial" or need == "internal" then return true end

		local data = bot.Bot
		local mem = data and data.Memory

		if not mem then return true end

		local target = mem.Target

		if IsValid(target) and target:Alive() and hg.bots.CanSee and hg.bots.CanSee(bot, target) then return false end

		local threatPos = mem.TargetPos or mem.UnderFireFrom

		if threatPos and bot:GetPos():DistToSqr(threatPos) < hg_bot_heal_safe:GetFloat() ^ 2 then return false end

		return true
	end

	--- Holds the item, puts it on the right MODE (R cycles modes on the
	-- medkit), and uses it.
	--
	-- Bandages and the like want the trigger held: with hg_healanims on,
	-- Z-City charges up a "holding" meter per tick of IN_ATTACK and only
	-- applies the treatment once it's full, so a short tap does nothing at
	-- all. Painkillers are the opposite: they inject continuously while
	-- held, and past one full dose the item starts doing damage - so those
	-- get one short press and a long wait.
	-- @return "healing" | "nomed"
	function hg.bots.HealTick(bot, data, now, kind)
		local want, mode = hg.bots.FindMed(bot, kind)

		if not IsValid(want) then return "nomed" end

		-- Keep sv_bot_selfpreservation.lua's weapon switching off our back.
		data.Healing = now

		local wep = bot:GetActiveWeapon()

		if wep ~= want then
			data.Attacking = false
			data.Reloading = false

			if now >= (data.HealSwitchAt or 0) then
				data.HealSwitchAt = now + 0.6
				bot:SelectWeapon(want:GetClass())
			end

			return "healing"
		end

		-- Wrong mode: tap R (SWEP:Reload wants an actual key PRESS, so the
		-- key is held for one tick at a time, not kept down).
		local current = want.mode or 1

		if current ~= mode then
			data.Attacking = false

			if now >= (data.HealModeAt or 0) then
				data.HealModeAt = now + 0.35
				data.HealModePress = now + 0.1
			end

			data.Reloading = now < (data.HealModePress or 0)

			return "healing"
		end

		data.Reloading = false

		-- Injectables are pulsed, not held: holding the key keeps pushing
		-- the dose in, which is how a bot overdoses itself.
		local dosed = (kind == "pain") or (kind == "fear")

		if dosed then
			if now >= (data.HealNextPress or 0) then
				data.HealPressUntil = now + 0.7
				data.HealNextPress = data.HealPressUntil + hg_bot_premed_wait:GetFloat()

				-- The syringe is one shot per fight, not a habit.
				if kind == "fear" then data.NextFearShot = now + hg_bot_heal_fear_cd:GetFloat() end
			end

			data.Attacking = now < (data.HealPressUntil or 0)
		else
			-- Held: the treatment only lands once the item's own meter fills.
			data.Attacking = true
		end

		return "healing"
	end
--//

	local function EndHeal(bot, data)
		data.Attacking = false
		data.Healing = nil
		data.HealPressUntil = nil
		data.HealNextPress = nil
		data.HealSwitchAt = nil
		data.HealModeAt = nil
		data.HealModePress = nil
		data.Reloading = false
		data.NextWeaponSwitch = 0

		if hg.bots.EquipBestWeapon then hg.bots.EquipBestWeapon(bot) end
	end

	hg.bots.EndHeal = EndHeal
--//

--\\ Heal state (standing)
	hg.bots.RegisterState("heal", {
		Enter = function(bot, data)
			hg.bots.ClearPath(data)

			data.Running = false
			data.SlowWalk = false
			data.Attacking = false
			data.AttackingSecondary = false
			data.UseKey = false
			data.HealStart = CurTime()
			data.HealPressUntil = nil
			data.HealNextPress = nil
			data.HealSwitchAt = nil
		end,

		Leave = function(bot, data)
			data.Crouching = false
			data.HealStart = nil

			EndHeal(bot, data)
		end,

		Think = function(bot, data)
			data.NextStateThink = CurTime() + 0.1

			local now = CurTime()
			local mem = data.Memory
			local target = mem.Target

			-- Someone walked in on it: fight or run, patch up later.
			if IsValid(target) and target:Alive() and hg.bots.CanSee and hg.bots.CanSee(bot, target) then
				hg.bots.SetState(bot, hg.bots.PickReaction and hg.bots.PickReaction(bot) or "combat")
				return
			end

			local need = hg.bots.HealNeed(bot)

			-- Nothing actually wrong, but a fight is coming: take something
			-- for the pain now instead of after being shot.
			if not need and hg.bots.ShouldPremedicate(bot) then
				-- Before a fight: something for the pain, and the syringe
				-- against fear. Whichever the bot has and has room for.
				local org = bot.organism
				local wantPain = hg.bots.FindMed(bot, "pain") and (not org or (org.analgesiaAdd or 0) < hg_bot_premed_cap:GetFloat())

				need = wantPain and "pain" or "fear"
				data.Premedicating = need
			elseif need then
				data.Premedicating = nil
			end

			-- One dose is enough for the pre-fight case.
			local org = bot.organism

			if data.Premedicating and org then
				local done = (data.Premedicating == "fear")
					and (org.adrenaline or 0) >= hg_bot_heal_adren_cap:GetFloat()
					or (data.Premedicating ~= "fear" and (org.analgesiaAdd or 0) >= hg_bot_premed_cap:GetFloat())

				if done then
					data.NextPremed = now + 90
					data.Premedicating = nil
					need = nil
				end
			end

			if not need or now - (data.HealStart or now) > hg_bot_heal_timeout:GetFloat() then
				if data.Premedicating then data.NextPremed = now + 90 end

				data.Premedicating = nil

				if IsValid(target) and target:Alive() then
					hg.bots.SetState(bot, hg.bots.PickReaction and hg.bots.PickReaction(bot) or "combat")
				else
					hg.bots.SetState(bot, "idle")
				end

				return
			end

			-- Crouched, watching the way the threat was last known to be.
			data.MoveTarget = nil
			data.Running = false
			data.Crouching = true

			local watch = mem.TargetPos or mem.UnderFireFrom

			data.LookPos = watch and (watch + Vector(0, 0, 50)) or nil

			if hg.bots.HealTick(bot, data, now, need) == "nomed" then
				hg.bots.SetState(bot, "idle")
			end
		end,
	})
--//

--\\ Treatment while downed
	--- Called from sv_bot_downed.lua's Think. Arterial bleeding is treated
	-- even with someone in sight (it kills faster than they do); everything
	-- else waits until nobody is looking at us.
	-- @return true if it took over this tick
	function hg.bots.TryHealDowned(bot, data, now)
		if not hg_bot_heal:GetBool() then return false end

		local org = bot.organism

		-- Weapons can't be swapped in a ragdoll without this
		-- (weapons/homigrad_base/sv_fake.lua).
		if not (org and org.canmove) then return false end

		local need = hg.bots.HealNeed(bot)

		-- Bleeding and broken things get treated on the floor; fear does
		-- not. Standing up is the answer to that one.
		if need == "fear" then need = nil end

		if not need then
			if data.Healing then EndHeal(bot, data) end

			return false
		end

		if need ~= "arterial" then
			local target = data.Memory.Target

			if IsValid(target) and target:Alive() and hg.bots.CanSee and hg.bots.CanSee(bot, target) then return false end
		end

		if hg.bots.HealTick(bot, data, now, need) == "nomed" then return false end

		-- E is the aim/stabilize key while ragdolled; treating isn't aiming.
		data.UseKey = false
		data.AttackingSecondary = false

		return true
	end
--//

--\\ Fury-13 on spawn
	--[[
		The Steam-comments request: bots that come in already on Fury-13 -
		you hear them laughing, and a few seconds later one is on top of you.

		The syringe itself never reaches a bot (sv_bot_loadout.lua bans it
		outright), so this does what weapon_fury13's SWEP:Heal does to the
		body that takes it, minus the item: the needle sound and
		org.berserk + 2. Z-City's organism takes it from there - the
		berserk state, its laughter, the speed and regeneration, and the
		slow wear-off (sv_organism.lua). Same exceptions as the item: on
		top of norepinephrine (Fury-16) it would blow the head off, so that
		body is skipped, and so is the "furry" class it poisons instead.
	]]
	local hg_bot_fury        = CreateConVar("hg_bot_fury",        "0", {FCVAR_ARCHIVE}, "Bots inject themselves with Fury-13 right after spawning (berserk: laughing, fast, hard to stop). Only the effect - the syringe is never handed out", 0, 1)
	local hg_bot_fury_chance = CreateConVar("hg_bot_fury_chance", "1", {FCVAR_ARCHIVE}, "Share of bots that take the Fury-13 shot while hg_bot_fury is on", 0, 1)
	local hg_bot_fury_delay  = CreateConVar("hg_bot_fury_delay",  "2", {FCVAR_ARCHIVE}, "Seconds after spawning before the Fury-13 shot", 0, 30)

	--- @return true if the shot went in
	function hg.bots.InjectFury(bot)
		if not IsValid(bot) or not bot:Alive() then return false end

		local org = bot.organism

		if not istable(org) or org.alive == false then return false end
		if (org.noradrenaline or 0) >= 0.4 then return false end
		if bot.PlayerClassName == "furry" then return false end

		local char = IsValid(bot.FakeRagdoll) and bot.FakeRagdoll or bot

		char:EmitSound("snd_jack_hmcd_needleprick.wav", 80, math.random(75, 90))

		org.berserk = (org.berserk or 0) + 2

		return true
	end

	-- Fired by sv_bot_core.lua once per real spawn (not when a bot merely
	-- gets back up from a ragdoll).
	hook.Add("HG_BotNewLife", "HG_Bots_Fury", function(bot)
		if not hg_bot_fury:GetBool() then return end
		if math.random() > hg_bot_fury_chance:GetFloat() then return end

		local life = (bot.hgBotFuryLife or 0) + 1

		bot.hgBotFuryLife = life

		-- After the spawn refresh and the kit (both done within ~1.2 s).
		timer.Simple(hg_bot_fury_delay:GetFloat(), function()
			if IsValid(bot) and bot.hgBotFuryLife == life and bot.IsHomigradBot then hg.bots.InjectFury(bot) end
		end)
	end)

	concommand.Add("hg_bot_fury_now", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		local count = 0

		for bot in pairs(hg.bots.List) do
			if hg.bots.InjectFury(bot) then count = count + 1 end
		end

		print(("[hg.bots] Fury-13: %d bots injected"):format(count))
	end, nil, "Give every bot alive the Fury-13 shot right now")
--//

--\\ Stopping to patch up on its own
	-- Bots that are hurt, carry something for it and aren't in a fight
	-- right now go and use it instead of wandering around bleeding.
	local HEAL_FROM = { idle = true, hold = true, ambush = true }

	timer.Create("HG_Bots_SelfHeal", 1.5, 0, function()
		if not hg_bot_heal:GetBool() then return end

		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and bot.Bot

			if data and data.Enabled and HEAL_FROM[data.State] and not IsValid(bot.FakeRagdoll) and hg.bots.ShouldHeal(bot) then
				hg.bots.SetState(bot, "heal")
			end
		end
	end)
--//
