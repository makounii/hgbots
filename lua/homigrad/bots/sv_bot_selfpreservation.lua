--[[
	Tarkov AI - Self preservation

	Three related things a bot needs in order to act like it values its own
	life rather than being a health-bar-with-a-gun:

	1. Gear recognition (hg.bots.AssessLoadout) - reads the real armor and
	   weapon a player is actually carrying and scores it. Armor comes from
	   ply.armors[placement] (set by sv_equipment.lua) looked up in
	   hg.armor[placement][name].protection - a genuine number in the armor
	   definitions (sh_armorstuff.lua: vest1 = 22, vest2 = 8, etc), not a
	   guess. Weapon score leans on SWEP.weight, which the weapon base
	   already uses as a proxy for how substantial a gun is, plus a flat
	   penalty for melee/empty hands.

	2. Cover (hg.bots.FindCoverPoint) - a navmesh point near the bot whose
	   line to the threat is actually blocked by geometry, found by testing
	   real traces rather than just "run directly away" (which is what
	   flee.lua did on its own and which happily runs into open ground).

	3. The "hold" state - camping. Sit at a position, crouched, watching a
	   direction, and shoot anything that appears there. This is where
	   retreating bots end up once they've broken contact, instead of
	   immediately reverting to cheerful wandering as if nothing happened.

	4. Equipment awareness (hg.bots.GetWeaponKind / GetEnemyWeaponKind /
	   EquipBestWeapon) - what the bot is actually armed with ("gun" only
	   counts with ammo left - an empty rifle is a club), and what the enemy
	   is armed with. The enemy's weapon is only read while the bot can SEE
	   them and is remembered afterwards (mem.TargetWeaponKind); someone
	   who shot at the bot obviously has a gun. The bot also switches to
	   the best weapon it carries before a fight.

	5. Current threat (hg.bots.GetThreatLevel, 0..1) - is there a real
	   danger right now: how fresh the contact is, what the enemy is armed
	   with and how close, whether they're aiming at the bot, incoming fire
	   and suppression. "hold" and "flee" use it to stand down once the
	   danger is actually gone instead of running on fixed timers.

	6. Reaction choice (hg.bots.ChooseReaction) - flee / ambush / combat.
	   A bot with a gun fights normally. A bot with only a melee weapon (or
	   empty hands, or an empty gun) facing a GUN does not charge across
	   open ground into it: it goes into the "ambush" state - hides out of
	   the enemy's sight next to a corner the enemy is likely to come
	   around, crouches and waits, and only attacks when the enemy walks
	   into charge range or turns their back. If spotted or shot at it
	   relocates. Melee vs melee is a normal fight.

	The flee roll itself (ShouldFlee and its hysteresis) still lives in
	sv_bot_flee.lua; this file supplies the outmatched factor that feeds it
	(hg.bots.GetOutmatchedFactor) and decides when fleeing makes no sense
	(the bot outguns a melee-armed enemy).

	Deliberately not modeled: peeking out of cover and back, suppressing
	fire at a last known position, or coordinating cover between multiple
	bots. A camping bot here holds one spot and watches one direction.
]]

hg.bots = hg.bots or {}

hg.bots.States = hg.bots.States or {}
hg.bots.RegisterState = hg.bots.RegisterState or function(name, tbl) hg.bots.States[name] = tbl end

local hg_bot_cover_search_radius = CreateConVar("hg_bot_cover_search_radius", "1200", {FCVAR_ARCHIVE}, "How far a bot looks for a cover position to retreat to", 200, 5000)
local hg_bot_cover_samples       = CreateConVar("hg_bot_cover_samples",       "24",   {FCVAR_ARCHIVE}, "How many candidate nav areas to test when looking for cover - higher is better cover but more traces", 4, 100)
local hg_bot_cover_min_dist      = CreateConVar("hg_bot_cover_min_dist",      "250",  {FCVAR_ARCHIVE}, "Minimum distance from the threat a cover point must be to count", 0, 4000)
local hg_bot_hold_duration       = CreateConVar("hg_bot_hold_duration",       "20",   {FCVAR_ARCHIVE}, "Seconds a bot camps a held position before losing interest and resuming normal behaviour", 2, 300)
local hg_bot_hold_crouch         = CreateConVar("hg_bot_hold_crouch",         "1",    {FCVAR_ARCHIVE}, "Whether a camping bot crouches while holding position", 0, 1)
local hg_bot_gear_weight         = CreateConVar("hg_bot_gear_weight",         "1",    {FCVAR_ARCHIVE}, "How strongly enemy gear advantage pushes a bot toward retreating (0 disables gear recognition entirely)", 0, 3)
local hg_bot_hold_calm_time      = CreateConVar("hg_bot_hold_calm_time",      "6",    {FCVAR_ARCHIVE}, "Seconds with no real threat (see hg.bots.GetThreatLevel) after which a camping bot stops holding", 1, 120)
local hg_bot_ambush              = CreateConVar("hg_bot_ambush",              "1",    {FCVAR_ARCHIVE}, "Melee-only bots hide and ambush gun-armed enemies instead of charging them", 0, 1)
local hg_bot_ambush_radius       = CreateConVar("hg_bot_ambush_radius",       "900",  {FCVAR_ARCHIVE}, "How far a bot looks for an ambush spot", 200, 4000)
local hg_bot_ambush_samples      = CreateConVar("hg_bot_ambush_samples",      "28",   {FCVAR_ARCHIVE}, "Candidate spots tested per ambush search (each costs a few traces)", 4, 100)
local hg_bot_ambush_charge_dist  = CreateConVar("hg_bot_ambush_charge_dist",  "240",  {FCVAR_ARCHIVE}, "An ambushing bot charges once the gun-armed enemy is this close", 60, 1000)
local hg_bot_ambush_backstab_dist = CreateConVar("hg_bot_ambush_backstab_dist", "500", {FCVAR_ARCHIVE}, "An ambushing bot also charges an enemy this close who is looking away from it", 60, 2000)
local hg_bot_ambush_time         = CreateConVar("hg_bot_ambush_time",         "35",   {FCVAR_ARCHIVE}, "Seconds a bot waits in ambush without contact before giving up", 5, 300)
local hg_bot_tactic_push         = CreateConVar("hg_bot_tactic_push",         "1",    {FCVAR_ARCHIVE}, "Weight of the PUSH tactic (rush the enemy / their last known position)", 0, 10)
local hg_bot_tactic_wait         = CreateConVar("hg_bot_tactic_wait",         "1",    {FCVAR_ARCHIVE}, "Weight of the WAIT tactic (hold the angle / ambush)", 0, 10)
local hg_bot_tactic_careful      = CreateConVar("hg_bot_tactic_careful",      "1",    {FCVAR_ARCHIVE}, "Weight of the CAREFUL PUSH tactic (slow advance aiming down sights, prefires, lean-peeks; melee bots sneak up crouched)", 0, 10)
local hg_bot_prefire_look        = CreateConVar("hg_bot_prefire_look",        "1",    {FCVAR_ARCHIVE}, "While waiting (ambush/hold) keep the view on the enemy's actual position so the bot doesn't have to turn round when they appear", 0, 1)
local hg_bot_weapon_switch       = CreateConVar("hg_bot_weapon_switch",       "1",    {FCVAR_ARCHIVE}, "Bots switch to the best weapon they carry (gun with ammo > melee > hands) when a threat appears", 0, 1)

--\\ Gear recognition
	--- Total armor protection a player is wearing, summed across slots.
	-- Reads the same tables the armor system itself uses, so it
	-- automatically reflects whatever armor exists on the server.
	function hg.bots.GetArmorScore(ply)
		if not IsValid(ply) or not ply.armors then return 0 end
		if not hg.armor then return 0 end

		local total = 0

		for placement, name in pairs(ply.armors) do
			local slot = hg.armor[placement]
			local def = slot and slot[name]

			if def and isnumber(def.protection) then
				total = total + def.protection
			end
		end

		return total
	end

	--- Rough "how dangerous is this loadout" score. Deliberately crude -
	-- it only needs to separate "armored guy with a rifle" from "someone in
	-- a t-shirt holding a knife", not to rank weapons precisely.
	function hg.bots.AssessLoadout(ply)
		if not IsValid(ply) then return 0 end

		local score = hg.bots.GetArmorScore(ply)
		local wep = ply.GetActiveWeapon and ply:GetActiveWeapon()

		if IsValid(wep) then
			if hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep) then
				score = score + 4
			else
				-- SWEP.weight is the base's own rough proxy for how
				-- substantial a firearm is (pistols sit low, rifles and
				-- machine guns high), so it doubles as a threat proxy.
				score = score + 12 + (tonumber(wep.weight) or 0) * 3
			end
		end

		return score
	end

	--- How badly bot is outgunned by target, as a factor around 0.
	-- Positive means the target is better equipped. Consumed by
	-- sv_bot_flee.lua to bias (not override) its flee roll.
	-- @return number roughly -1 .. 1
	function hg.bots.GetOutmatchedFactor(bot, target)
		if hg_bot_gear_weight:GetFloat() <= 0 then return 0 end

		target = target or (bot.Bot and bot.Bot.Memory and bot.Bot.Memory.Target)

		if not IsValid(bot) or not IsValid(target) then return 0 end

		local mine = hg.bots.AssessLoadout(bot)
		local theirs = hg.bots.AssessLoadout(target)
		local total = mine + theirs

		if total <= 0 then return 0 end

		-- Normalized difference, so it's scale-free rather than depending
		-- on absolute protection numbers that vary by server loadout.
		return ((theirs - mine) / total) * hg_bot_gear_weight:GetFloat()
	end
--//

--\\ Cover
	--- Finds a nearby position whose line to threatPos is blocked.
	-- Candidates are hiding spots (navmesh-authored cover) plus random
	-- points; each must hide a standing bot's chest from the threat's eye
	-- height. Points that lie TOWARD the threat are penalized - running
	-- past the shooter to reach "cover" on their side isn't retreating.
	-- @param radius number|nil search radius (defaults to the convar)
	-- @return Vector|nil best cover point found, nil if nothing qualified.
	function hg.bots.FindCoverPoint(bot, threatPos, radius)
		if not IsValid(bot) or not threatPos then return nil end
		if not navmesh.IsLoaded() then return nil end

		local origin = bot:GetPos()
		radius = radius or hg_bot_cover_search_radius:GetFloat()

		local minDistSqr = hg_bot_cover_min_dist:GetFloat() ^ 2
		local chest = Vector(0, 0, 40) -- chest height of a bot standing at the point
		local threatEye = threatPos + Vector(0, 0, 60)

		local areas = navmesh.Find(origin, radius, 64, 64)

		if not areas or #areas == 0 then return nil end

		local samples = math.min(hg_bot_cover_samples:GetInt(), #areas)
		local toThreat = threatPos - origin
		toThreat.z = 0

		local threatDist = toThreat:Length()

		if threatDist > 1 then toThreat = toThreat / threatDist end

		local best, bestScore

		for _ = 1, samples do
			local area = areas[math.random(#areas)]

			if IsValid(area) and not area:IsUnderwater() then
				local spots = area.GetHidingSpots and area:GetHidingSpots()
				local point = (spots and #spots > 0) and spots[math.random(#spots)] or area:GetRandomPoint()

				if point:DistToSqr(threatPos) >= minDistSqr then
					local tr = util.TraceLine({
						start = point + chest,
						endpos = threatEye,
						filter = bot,
						mask = MASK_VISIBLE,
					})

					-- Blocked line == actual cover from the threat's
					-- current position.
					if tr.Hit then
						local offset = point - origin
						local d = offset:Length()
						local score = d

						-- Heading toward the threat costs extra; getting
						-- closer to it than we are now costs a lot.
						if d > 1 and threatDist > 1 then
							local towards = (offset / d):Dot(toThreat)

							if towards > 0 then score = score + towards * d * 2 end
						end

						if point:Distance(threatPos) < threatDist * 0.7 then
							score = score + 800
						end

						if not bestScore or score < bestScore then
							best, bestScore = point, score
						end
					end
				end
			end
		end

		return best
	end
--//

--\\ Hold / camp state
	--- Sends a bot to camp a position, watching watchPos.
	-- @param pos Vector where to hold (defaults to where it's standing)
	-- @param watchPos Vector what direction to watch
	function hg.bots.HoldPosition(bot, pos, watchPos)
		if not IsValid(bot) or not bot.Bot then return end

		local data = bot.Bot

		data.HoldPos = pos or bot:GetPos()
		data.HoldWatch = watchPos

		hg.bots.SetState(bot, "hold")
	end

	hg.bots.RegisterState("hold", {
		Enter = function(bot, data)
			data.Attacking = false
			data.AttackingSecondary = false
			data.Running = false
			data.UseKey = false
			data.Crouching = hg_bot_hold_crouch:GetBool()

			data.HoldSince = CurTime()

			-- Walk to the hold position if we're not already there;
			-- Think below won't start the camp timer properly until
			-- arrival, which is what stops a bot "holding" mid-sprint.
			if data.HoldPos and bot:GetPos():DistToSqr(data.HoldPos) > 64 ^ 2 then
				hg.bots.SetGoal(bot, data.HoldPos)
			else
				data.Path = nil
				data.Goal = nil
				data.MoveTarget = nil
			end
		end,

		Leave = function(bot, data)
			data.Crouching = false
			data.Attacking = false
			data.HoldSince = nil
			data.HoldPos = nil
			data.HoldWatch = nil
			data.HoldCalmSince = nil
			data.HoldResumeCombat = nil
			data.HoldDuration = nil
			data.AimSpeed = nil
			data.AttackingSecondary = false
		end,

		Think = function(bot, data)
			data.NextStateThink = CurTime() + 0.1

			local mem = data.Memory
			local target = mem.Target

			-- Still travelling to the camp spot.
			if data.Path and not hg.bots.FollowPath(bot, data) then
				data.LookPos = hg.bots.GetWaitLookPos(bot, data.HoldWatch)
				data.HoldSince = CurTime() -- don't start the camp clock until actually in position

				return
			end

			data.MoveTarget = nil
			data.Running = false

			-- Watch the threat direction by default; snap to the target
			-- itself the moment one is actually visible.
			local canSee = IsValid(target) and target:Alive() and hg.bots.CanSee(bot, target)

			-- Already facing the enemy (pre-aim), so a target stepping out
			-- only needs a small correction, not a turn.
			data.AimSpeed = 240

			if canSee then
				local char = hg.bots.GetCharacter and hg.bots.GetCharacter(target) or target

				mem.TargetPos = char:GetPos()
				mem.LastSeen = CurTime()

				local aimPoint = hg.bots.GetAimPoint and hg.bots.GetAimPoint(bot, target) or target:EyePos()

				data.LookPos = aimPoint

				-- Camping bots that get a clean shot take it, but they do
				-- NOT abandon the position to chase - that's the whole
				-- point of holding. Combat state is what chases. Only fire
				-- once the view is actually on the target.
				local wep = bot:GetActiveWeapon()
				local mayFire = true

				if hg.bots.GetAimError then
					local eye = hg.bots.GetEyePos and hg.bots.GetEyePos(bot) or bot:EyePos()
					local err, dist = hg.bots.GetAimError(bot, eye, aimPoint)

					mayFire = err <= hg.bots.GetAimTolerance(dist)
				end

				-- A melee weapon can't do anything from here: close in.
				if IsValid(wep) and hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep) then
					hg.bots.SetState(bot, hg.bots.PickReaction and hg.bots.PickReaction(bot) or "combat")
					return
				end

				if IsValid(wep) and hg.bots.ServiceWeapon then
					hg.bots.ServiceWeapon(bot, data, wep, mayFire)
				end

				-- Holding an angle with a gun = aiming down sights.
				data.AttackingSecondary = IsValid(wep) and not data.Reloading and hg.bots.GetWeaponKind(bot, false) == "gun"
			else
				data.LookPos = hg.bots.GetWaitLookPos(bot, data.HoldWatch)
				data.AttackingSecondary = IsValid(bot:GetActiveWeapon()) and not data.Reloading and hg.bots.GetWeaponKind(bot, false) == "gun"
				data.Attacking = false

				local wep = bot:GetActiveWeapon()

				-- Use the lull to reload/rack even with nobody in sight,
				-- rather than being caught empty when someone appears.
				if IsValid(wep) and hg.bots.ServiceWeapon then
					hg.bots.ServiceWeapon(bot, data, wep, false)
				end
			end

			-- Stand down early once there's genuinely nothing threatening
			-- left (target forgotten, no fire, nothing heard) - the fixed
			-- duration is only the upper bound now.
			local now = CurTime()

			if hg.bots.GetThreatLevel(bot) < 0.15 then
				data.HoldCalmSince = data.HoldCalmSince or now
			else
				data.HoldCalmSince = nil
			end

			if now - (data.HoldSince or now) > (data.HoldDuration or hg_bot_hold_duration:GetFloat())
				or (data.HoldCalmSince and now - data.HoldCalmSince > hg_bot_hold_calm_time:GetFloat())
			then
				-- A bot that chose to wait for someone instead of pushing
				-- goes hunting when nobody shows up, not back to strolling.
				if data.HoldResumeCombat and IsValid(target) and target:Alive() then
					data.WaitedFor = target
					hg.bots.SetState(bot, "combat")
				else
					hg.bots.SetState(bot, "idle")
				end
			end
		end,
	})
--//

--\\ Equipment awareness
	local HANDS_CLASSES = {
		weapon_hands_sh = true,
		weapon_hg_coolhands = true,
	}

	local function IsHands(wep)
		return IsValid(wep) and (HANDS_CLASSES[wep:GetClass()] or wep.GetFists ~= nil)
	end

	local function IsGun(wep)
		if not IsValid(wep) or IsHands(wep) then return false end
		if hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep) then return false end

		return wep.ishgweapon or wep:Clip1() >= 0
	end

	--- Does this gun still have anything to shoot? Chambered/mag rounds or
	-- reserve ammo for it.
	local function GunHasAmmo(owner, wep)
		if wep:Clip1() > 0 or wep.drawBullet == false then return true end

		local ammoType = wep:GetPrimaryAmmoType()

		return ammoType and ammoType >= 0 and owner:GetAmmoCount(ammoType) > 0
	end

	hg.bots.GunHasAmmo = GunHasAmmo

	--- What a player is effectively armed with right now.
	-- @param checkAmmo boolean treat an empty gun as melee (only honest
	--        for the bot itself - it knows its own ammo)
	-- @return "gun" | "melee" | "none"
	function hg.bots.GetWeaponKind(ply, checkAmmo)
		if not IsValid(ply) then return "none" end

		local wep = ply:GetActiveWeapon()

		if not IsValid(wep) then return "none" end

		-- Fists / bare hands are NOT a weapon.
		if IsHands(wep) then return "none" end

		if IsGun(wep) then
			if checkAmmo and not GunHasAmmo(ply, wep) then return "melee" end

			return "gun"
		end

		-- Knives, bats, fists, bare hands, grenades, medkits: nothing that
		-- wins at range.
		return (hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep)) and "melee" or "none"
	end

	--- The enemy's weapon as far as the bot knows: read live while the
	-- enemy is visible, remembered otherwise. Someone who recently shot at
	-- the bot has a gun whatever they're holding now; a never-seen enemy
	-- is assumed armed.
	function hg.bots.GetEnemyWeaponKind(bot, target)
		local mem = bot.Bot and bot.Bot.Memory

		if not mem or not IsValid(target) then return "gun" end

		if hg.bots.CanSee(bot, target) then
			mem.TargetWeaponKind = hg.bots.GetWeaponKind(target, false)
			mem.TargetWeaponOwner = target
		elseif mem.TargetWeaponOwner ~= target then
			mem.TargetWeaponKind = nil
		end

		-- Shot at by them recently (bullets only - melee hits don't count,
		-- see perception's MarkShotBy).
		if mem.ShotBy and (mem.ShotBy[target] or 0) > CurTime() - 20 then
			return "gun"
		end

		return mem.TargetWeaponKind or "gun"
	end

	--- Rough preference score for a weapon the bot carries.
	local function WeaponScore(bot, wep)
		if IsGun(wep) then
			-- Bone dry: worse than bare hands. Holding it kept the bot in the
			-- gunfight branch with nothing to shoot (the empty-gun softlock);
			-- fists at least put it in the brawl / flee logic.
			if not GunHasAmmo(bot, wep) then return 0.5 end

			return 100 + (tonumber(wep.weight) or 1)
		end

		if IsHands(wep) then return 1 end
		if hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep) then return 20 end

		return 0 -- grenades, medical, tools: never switch to these for a fight
	end

	--- Switches to the best weapon the bot carries. Cheap to call often:
	-- throttled, and never while ragdolled or mid-reload.
	function hg.bots.EquipBestWeapon(bot)
		if not hg_bot_weapon_switch:GetBool() then return end
		if not IsValid(bot) or IsValid(bot.FakeRagdoll) then return end

		local data = bot.Bot
		if not data or CurTime() < (data.NextWeaponSwitch or 0) then return end

		-- Smashing a window (maybe with bare fists on purpose): switch back
		-- once through (EndBreach resets NextWeaponSwitch).
		if data.Breach then return end

		-- Mid-treatment: the med item stays in hand (sv_bot_medic.lua).
		if data.State == "heal" or (data.Healing and CurTime() - data.Healing < 1) then return end

		-- Cooking a grenade to go out with (sv_bot_grenades.lua).
		if data.Martyr or data.State == "martyr" then return end

		data.NextWeaponSwitch = CurTime() + 3

		local active = bot:GetActiveWeapon()

		if IsValid(active) and active.reload then return end

		-- Never switch away from a grenade with its pin out or mid-throw:
		-- the grenade SWEP's Holster drops it LIVE at our feet. The movement
		-- bridge puts the pin back first; try again right after.
		if IsValid(active) and (active.ReadyToThrow or active.InThrowing) then
			data.NextWeaponSwitch = CurTime() + 0.5
			return
		end

		if data.State == "grenade" then return end

		local best, bestScore = active, IsValid(active) and WeaponScore(bot, active) or -1

		for _, wep in ipairs(bot:GetWeapons()) do
			local score = WeaponScore(bot, wep)

			if score > bestScore then
				best, bestScore = wep, score
			end
		end

		if IsValid(best) and best ~= active then
			bot:SelectWeapon(best:GetClass())
		end
	end
--//

--\\ Current threat
	--- How dangerous the bot's situation is right now, 0 (nothing) .. 1.
	-- @return number level, string|nil enemy weapon kind
	function hg.bots.GetThreatLevel(bot)
		local data = bot.Bot
		if not data then return 0 end

		local mem = data.Memory
		local now = CurTime()
		local level = 0

		-- Incoming fire is a threat whoever is behind it.
		if (mem.UnderFireUntil or 0) > now then level = 0.6 end

		level = math.max(level, (mem.Suppression or 0) * 0.8)

		local target = mem.Target

		if not IsValid(target) or not target:Alive() then
			if mem.SuspicionPos then
				level = math.max(level, 0.25 * math.min(mem.SuspicionStrength or 0.5, 1))
			end

			return math.Clamp(level, 0, 1), nil
		end

		local lastContact = math.max(mem.LastSeen or 0, mem.LastHeard or 0)
		local freshness = math.Clamp(1 - (now - lastContact) / 10, 0, 1)
		local kind = hg.bots.GetEnemyWeaponKind(bot, target)
		local enemyPos = mem.TargetPos or target:GetPos()
		local dist = bot:GetPos():Distance(enemyPos)

		local base

		if kind == "gun" then
			base = 0.7
		else
			-- A knife only matters up close.
			base = Lerp(math.Clamp((dist - 150) / 650, 0, 1), 0.8, 0.2)
		end

		level = math.max(level, base * freshness)

		-- Looking straight at the bot right now.
		if mem.TargetVisible or hg.bots.CanSee(bot, target) then
			local toBot = bot:WorldSpaceCenter() - target:EyePos()
			local len = toBot:Length()

			if len > 1 and target:GetAimVector():Dot(toBot / len) > 0.95 then
				level = level + (kind == "gun" and 0.25 or 0.1)
			end
		end

		return math.Clamp(level, 0, 1), kind
	end
--//

--\\ Reaction choice
	--- What a bot facing its current target should do: "flee", "ambush"
	-- or "combat" (nil when there's no target). Also makes sure the bot is
	-- holding its best weapon first - the whole decision depends on it.
	function hg.bots.ChooseReaction(bot)
		local data = bot.Bot
		if not data then return nil end

		local mem = data.Memory
		local target = mem.Target

		if not IsValid(target) or not target:Alive() then return nil end

		hg.bots.EquipBestWeapon(bot)

		local now = CurTime()
		local mine = hg.bots.GetWeaponKind(bot, true)
		local theirs = hg.bots.GetEnemyWeaponKind(bot, target)

		-- Running from someone you outgun (they have no gun, you do) is
		-- worse than shooting them.
		if hg.bots.ShouldFlee and hg.bots.ShouldFlee(bot) and not (mine == "gun" and theirs ~= "gun") then
			return "flee"
		end

		-- No weapon at all (fists don't count): anyone armed, or bullets
		-- flying, means scatter and hide. Fists against fists is a brawl.
		if mine == "none" then
			-- A body that can't run anymore brawls instead (last stand,
			-- sv_bot_flee.lua).
			local canRun = not hg.bots.CanRetreat or hg.bots.CanRetreat(bot)

			if canRun and (theirs ~= "none" or (mem.UnderFireUntil or 0) > now) then
				return "flee"
			end

			return "combat"
		end

		if mine == "gun" or theirs ~= "gun" or not hg_bot_ambush:GetBool() then
			return "combat"
		end

		-- Melee-only bot vs a gun from here on.
		if now < (data.AmbushFailUntil or 0) then return "combat" end -- no hiding place nearby: nothing better than fighting

		-- Push / careful push close in (combat); wait = ambush.
		if hg.bots.GetTactic(bot, target) ~= "wait" then return "combat" end

		local enemyPos = mem.TargetPos or target:GetPos()
		local dist = bot:GetPos():Distance(enemyPos)
		local charge = hg_bot_ambush_charge_dist:GetFloat()

		-- A committed charge stays committed while the enemy is near,
		-- otherwise combat <-> ambush would flip every re-evaluation.
		if now < (data.ChargeCommitUntil or 0) and dist < charge * 3 then return "combat" end

		-- Hysteresis: already fighting = keep fighting until clearly out
		-- of reach again.
		local limit = charge * (data.State == "combat" and 1.6 or 1)

		if dist <= limit then
			data.ChargeCommitUntil = now + 3

			return "combat"
		end

		return "ambush"
	end

	--- The bot's current approach to this enemy: "push", "wait" or
	-- "careful". Weighted roll (roughly equal by default), kept per enemy
	-- for a while so the bot commits; forceNew re-rolls (a fresh decision
	-- each time a gun bot loses sight of its target).
	function hg.bots.GetTactic(bot, target, forceNew)
		local data = bot.Bot
		if not data then return "push" end

		local now = CurTime()

		if forceNew or data.TacticTarget ~= target or now > (data.TacticUntil or 0) then
			-- Fighting alongside other bots: the role decides (one pushes
			-- while the others hold the angle and suppress). Alone, this is
			-- nil and the personal roll below runs as before.
			local squad = hg.bots.SquadTactic and hg.bots.SquadTactic(bot)

			if squad then
				data.Tactic = squad
				data.TacticTarget = target
				data.TacticUntil = now + 8 -- roles change; don't sit on one for 25 s

				return data.Tactic
			end

			-- Mood (sv_bot_morale.lua): a bot whose squadmate was just
			-- killed by this player, and who has the kit to do something
			-- about it, pushes; a rattled or badly equipped one holds off.
			local mood = hg.bots.MoraleTactic and hg.bots.MoraleTactic(bot, target)

			if mood then
				data.Tactic = mood
				data.TacticTarget = target
				data.TacticUntil = now + 12

				return data.Tactic
			end

			local wp, ww, wc = hg_bot_tactic_push:GetFloat(), hg_bot_tactic_wait:GetFloat(), hg_bot_tactic_careful:GetFloat()
			local total = wp + ww + wc
			local r = math.Rand(0, math.max(total, 0.001))
			local tactic = "push"

			if total > 0 then
				if r < wp then
					tactic = "push"
				elseif r < wp + ww then
					tactic = "wait"
				else
					tactic = "careful"
				end
			end

			data.Tactic = tactic
			data.TacticTarget = target
			data.TacticUntil = now + 25
		end

		return data.Tactic
	end

	--- Applies ChooseReaction, only switching when it differs.
	function hg.bots.ApplyReaction(bot)
		local want = hg.bots.ChooseReaction(bot)

		if want and bot.Bot.State ~= want then
			hg.bots.SetState(bot, want)
		end

		return want
	end
--//

--\\ Ambush
	--- Where a waiting bot should point its view: the enemy's actual
	-- position (chest height). A bot that watches "the corner" has to swing
	-- round when the enemy appears somewhere slightly different, and loses
	-- the moment it needed to shoot or swing - so waiting bots pre-aim at
	-- the person. hg_bot_prefire_look 0 falls back to the last known spot.
	function hg.bots.GetWaitLookPos(bot, fallback)
		local data = bot.Bot
		local mem = data and data.Memory
		local target = mem and mem.Target

		-- On the move with the enemy far away: look where we're walking.
		-- Staring at someone through several walls while walking made bots
		-- strafe/backpedal along their whole route and bump into things.
		if data and data.MoveTarget and IsValid(target) then
			local est = mem.TargetPos or target:GetPos()

			if bot:GetPos():DistToSqr(est) > 700 * 700 then return nil end
		end

		if hg_bot_prefire_look:GetBool() and IsValid(target) and target:Alive() then
			local char = hg.bots.GetCharacter and hg.bots.GetCharacter(target) or target

			return char:WorldSpaceCenter() + Vector(0, 0, 12)
		end

		return fallback or (mem and mem.TargetPos and mem.TargetPos + Vector(0, 0, 50))
	end

	local CHEST = Vector(0, 0, 40)
	local EYE60 = Vector(0, 0, 60)
	local UP = Vector(0, 0, 1)

	local function Hidden(from, to)
		return util.TraceLine({ start = from, endpos = to, mask = MASK_VISIBLE }).Hit
	end

	--- Is pos too close to a spot another bot already ambushes from?
	local function Claimed(bot, pos)
		for other in pairs(hg.bots.List) do
			local od = other ~= bot and IsValid(other) and other.Bot

			if od and od.AmbushPos and od.AmbushPos:DistToSqr(pos) < 160 * 160 then
				return true
			end
		end

		return false
	end

	--- Route-based ambush: the enemy coming for the bot will walk roughly
	-- the navmesh path from them to it, and a string-pulled path turns
	-- exactly at corners. The best ambush spot is just past such a turn,
	-- out of sight of the stretch the enemy walks up, but with the turn
	-- itself in view - they round it straight into reach.
	local function FindRouteAmbush(bot, enemyPos)
		if not hg.bots.FindNavPath then return nil end

		local route = hg.bots.FindNavPath(enemyPos, bot:GetPos(), nil)

		if not route or #route < 2 then return nil end

		local walked = 0
		local prev = enemyPos
		local origin = bot:GetPos()

		for i = 1, #route - 1 do
			local corner = route[i]

			walked = walked + prev:Distance(corner)

			if walked > 1400 then break end

			if walked > 220 then
				local approach = corner - prev
				approach.z = 0

				if approach:LengthSqr() > 1 then
					approach:Normalize()

					local lat = approach:Cross(UP)
					local nextDir = route[i + 1] - corner
					nextDir.z = 0

					if nextDir:LengthSqr() > 1 then nextDir:Normalize() end

					-- Past the corner (along where the path goes next) and
					-- off to either side of the approach line.
					local offsets = {
						nextDir * 90 + lat * 60, nextDir * 90 - lat * 60,
						lat * 110, lat * -110, nextDir * 130,
					}

					for _, off in ipairs(offsets) do
						local spot = hg.bots.SnapToNavmesh and hg.bots.SnapToNavmesh(corner + off, 80) or (corner + off)

						if spot and not Claimed(bot, spot)
							-- out of sight from the approach stretch
							and Hidden(spot + CHEST, prev + EYE60)
							and Hidden(spot + CHEST, enemyPos + EYE60)
							-- but the corner itself is in view
							and not Hidden(spot + CHEST, corner + CHEST)
							and spot:DistToSqr(origin) < 1200 * 1200
						then
							return spot, corner
						end
					end
				end
			end

			prev = corner
		end

		return nil
	end

	--- Fallback: a random hiding spot near the bot, hidden from the enemy,
	-- with a visible "corner" point a step to the side.
	local function FindLocalAmbush(bot, enemyPos)
		local origin = bot:GetPos()
		local areas = navmesh.Find(origin, hg_bot_ambush_radius:GetFloat(), 96, 96)

		if not areas or #areas == 0 then return nil end

		local enemyEye = enemyPos + EYE60
		local best, bestCorner, bestScore

		for _ = 1, math.min(hg_bot_ambush_samples:GetInt(), #areas) do
			local area = areas[math.random(#areas)]

			if IsValid(area) and not area:IsUnderwater() then
				local spots = area.GetHidingSpots and area:GetHidingSpots()
				local p = (spots and #spots > 0) and spots[math.random(#spots)] or area:GetRandomPoint()
				local de = p:Distance(enemyPos)

				if de > 250 and de < 1600 and not Claimed(bot, p) and Hidden(p + CHEST, enemyEye) then
					local toE = enemyPos - p
					toE.z = 0
					toE:Normalize()

					local lat = toE:Cross(UP)
					local corner

					for _, off in ipairs({ lat * 90, lat * -90, toE * 90 }) do
						local q = p + off

						if not util.TraceLine({ start = p + CHEST, endpos = q + CHEST, mask = MASK_SOLID_BRUSHONLY }).Hit
							and not Hidden(q + CHEST, enemyEye)
						then
							corner = q
							break
						end
					end

					if corner then
						local score = p:Distance(origin) + math.abs(de - 450) * 0.5

						if not bestScore or score < bestScore then
							best, bestCorner, bestScore = p, corner, score
						end
					end
				end
			end
		end

		return best, bestCorner
	end

	--- @return Vector spot, Vector corner (or nil)
	function hg.bots.FindAmbushPoint(bot, enemyPos)
		if not IsValid(bot) or not enemyPos or not navmesh.IsLoaded() then return nil end

		local spot, corner = FindRouteAmbush(bot, enemyPos)

		if spot then return spot, corner end

		return FindLocalAmbush(bot, enemyPos)
	end

	local function PickAmbush(bot, data, mem)
		local now = CurTime()

		data.AmbushRepickAt = now + 2

		local enemyPos = mem.TargetPos
		local spot, corner = hg.bots.FindAmbushPoint(bot, enemyPos)

		if not spot then
			data.AmbushFailUntil = now + 6 -- ChooseReaction falls back to combat
			return false
		end

		data.AmbushPos = spot
		data.AmbushCorner = corner
		data.AmbushAnchor = enemyPos
		data.AmbushSince = nil
		data.AmbushPeekUntil = nil
		data.NextAmbushPeek = now + math.Rand(7, 12)

		-- Route out of the enemy's sight, not across their field of fire.
		hg.bots.SetGoal(bot, spot, { avoidPos = enemyPos, avoidRadius = 700, avoidWeight = 3, force = true })

		return true
	end

	local function Charge(bot, data)
		data.ChargeCommitUntil = CurTime() + 4
		hg.bots.SetState(bot, "combat")
	end

	hg.bots.RegisterState("ambush", {
		Enter = function(bot, data)
			data.Attacking = false
			data.AttackingSecondary = false
			data.Reloading = false
			data.Running = true
			data.Crouching = false
			data.AimSpeed = nil
			data.AmbushPos = nil
			data.AmbushSince = nil

			hg.bots.ClearPath(data)

			if data.Memory.TargetPos then
				PickAmbush(bot, data, data.Memory)
			end
		end,

		Leave = function(bot, data)
			data.Crouching = false
			data.Running = false
			data.AimSpeed = nil
			data.AmbushPos = nil
			data.AmbushCorner = nil
			data.AmbushAnchor = nil
			data.AmbushSince = nil
			data.AmbushRepickAt = nil
			data.AmbushPeekUntil = nil
			data.NextAmbushPeek = nil
		end,

		Think = function(bot, data)
			local now = CurTime()

			data.NextStateThink = now + 0.1

			local mem = data.Memory
			local target = mem.Target

			if not IsValid(target) or not target:Alive() then
				hg.bots.SetState(bot, "idle")
				return
			end

			-- Circumstances changed (picked up a gun, enemy dropped theirs,
			-- enemy walked into reach, decided to push)? Move out.
			local want = hg.bots.ChooseReaction(bot)

			if want and want ~= "ambush" then
				hg.bots.SetState(bot, want)
				return
			end

			-- Still an active hunt - keep perception from forgetting.
			mem.ContactHold = now

			local myPos = bot:GetPos()
			local charge = hg_bot_ambush_charge_dist:GetFloat()

			if hg.bots.CanSee(bot, target) then
				local char = hg.bots.GetCharacter and hg.bots.GetCharacter(target) or target

				mem.TargetPos = char:GetPos()
				mem.LastSeen = now

				local toBot = bot:WorldSpaceCenter() - target:EyePos()
				local dist = toBot:Length()
				local facing = dist > 1 and target:GetAimVector():Dot(toBot / dist) > 0.9

				-- Back turned and close enough to cover the gap: go.
				if not facing and dist <= hg_bot_ambush_backstab_dist:GetFloat() then
					Charge(bot, data)
					return
				end

				-- They're looking our way - we're made. Move.
				if facing and now >= (data.AmbushRepickAt or 0) then
					PickAmbush(bot, data, mem)
				end
			elseif mem.LastHeard and now - mem.LastHeard < 0.6 and mem.TargetPos
				and mem.TargetPos:DistToSqr(myPos) < (charge * 1.6) ^ 2
			then
				-- Footsteps right round the corner: jump them before they
				-- see us.
				Charge(bot, data)
				return
			end

			if (mem.UnderFireUntil or 0) > now and now >= (data.AmbushRepickAt or 0) then
				PickAmbush(bot, data, mem)
			end

			local enemyDist = myPos:Distance(mem.TargetPos or target:GetPos())

			-- Always facing the enemy while waiting/sneaking, so there's no
			-- turn to make when they show up.
			data.LookPos = hg.bots.GetWaitLookPos(bot, data.AmbushCorner and data.AmbushCorner + Vector(0, 0, 50))
			data.AimSpeed = 240

			-- Getting into position: sprint while far, sneak once near.
			if data.Path or data.PendingGoal then
				local close = enemyDist < 900

				data.Running = not close
				data.Crouching = close

				if not hg.bots.FollowPath(bot, data) then return end
			end

			if not data.AmbushPos then
				if now >= (data.AmbushRepickAt or 0) and mem.TargetPos then
					PickAmbush(bot, data, mem)
				end

				return
			end

			data.AmbushSince = data.AmbushSince or now
			data.Running = false
			data.Attacking = false

			-- Peek: with no news for a while, lean out to the corner for a
			-- second to check, then settle back.
			if data.AmbushPeekUntil then
				if now < data.AmbushPeekUntil then
					data.Crouching = false
					data.MoveTarget = data.AmbushCorner
					return
				end

				data.AmbushPeekUntil = nil
				data.MoveTarget = data.AmbushPos
				data.NextAmbushPeek = now + math.Rand(7, 12)
			elseif data.AmbushCorner and now >= (data.NextAmbushPeek or 0)
				and now - math.max(mem.LastSeen or 0, mem.LastHeard or 0) > 6
			then
				data.AmbushPeekUntil = now + math.Rand(0.8, 1.4)
				return
			end

			-- In position: crouched and still (back on the spot if a peek
			-- moved us off it).
			data.Crouching = true

			if myPos:DistToSqr(data.AmbushPos) > 24 * 24 then
				data.MoveTarget = data.AmbushPos
			else
				data.MoveTarget = nil
			end

			-- Enemy is somewhere else entirely now - set up again.
			if mem.TargetPos and data.AmbushAnchor
				and mem.TargetPos:Distance(data.AmbushAnchor) > 600
				and now >= (data.AmbushRepickAt or 0)
			then
				PickAmbush(bot, data, mem)
				return
			end

			if now - data.AmbushSince > hg_bot_ambush_time:GetFloat() then
				-- Nobody came. Forget them rather than walking out to hunt a
				-- gunman with a knife.
				mem.Target = nil
				mem.TargetPos = nil
				mem.TargetSeenPos = nil
				mem.TargetVel = nil
				mem.ContactHold = nil

				hg.bots.SetState(bot, "idle")
			end
		end,
	})
--//

--\\ Debug
	-- hg_bot_threat_debug - each bot's own/enemy weapon read, threat level
	-- and chosen reaction.
	concommand.Add("hg_bot_threat_debug", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		for _, bot in ipairs(hg.bots.GetAll and hg.bots.GetAll() or {}) do
			local mem = bot.Bot and bot.Bot.Memory or {}
			local level, theirs = hg.bots.GetThreatLevel(bot)

			print(("[hg.bots] %s: state=%s  mine=%s  enemy=%s (%s)  threat=%.2f  reaction=%s"):format(
				bot:Nick(),
				bot.Bot and bot.Bot.State or "?",
				hg.bots.GetWeaponKind(bot, true),
				tostring(mem.Target),
				tostring(theirs),
				level,
				tostring(hg.bots.ChooseReaction(bot))
			))
		end
	end)
--//
