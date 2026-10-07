--[[
	Tarkov AI - Flee

	Retreat behaviour: when a bot is hurt badly enough, it has a chance to
	run from whatever it's currently aware of (see hg.bots.ShouldFlee)
	instead of always fighting to the death like a mindless turret. This
	file owns:
	- hg.bots.ShouldFlee(bot) - the actual fight-or-flee decision, called
	  from combat.lua's CheckThreatReaction/HG_BotSpotted paths AND from
	  the "HG_BotThreatened" hook below (fired by sv_bot_perception.lua's
	  new take-damage/gunfire-whiz detection - see its header).
	- the "flee" state itself: run directly away from the last known
	  threat position using real navmesh pathing (not just a straight
	  line - same reasoning as combat's flanking, running blindly into a
	  wall isn't a retreat).

	Decision is rolled once per "hurt episode", not re-rolled every tick a
	bot happens to be under the health threshold - see ShouldFlee's
	hysteresis comment. Without that, a bot sitting right at the threshold
	would flicker between combat and flee state every Think tick, which
	looks broken rather than indecisive-but-committed.

	Deliberately NOT modeled here: panic-fire while retreating (a fleeing
	bot doesn't shoot back at all right now), taking cover instead of just
	running in a straight line away, and giving up on fleeing early if
	cornered with no viable path (SetGoal's existing "no navmesh/no route"
	fallback just goes in a straight line regardless, which can end at a
	wall). All reasonable next steps, not part of this pass.
]]

hg.bots = hg.bots or {}

-- Same defensive redeclare as sv_bot_combat.lua/sv_bot_navigation.lua - see
-- either's header for why: Z-City's loader doesn't guarantee load order.
hg.bots.States = hg.bots.States or {}
hg.bots.RegisterState = hg.bots.RegisterState or function(name, tbl) hg.bots.States[name] = tbl end

local hg_bot_flee_health_frac = CreateConVar("hg_bot_flee_health_frac", "0.3", {FCVAR_ARCHIVE}, "Health fraction (of max) at or below which a bot MIGHT choose to flee instead of fight", 0, 1)
local hg_bot_flee_chance      = CreateConVar("hg_bot_flee_chance",      "0.6", {FCVAR_ARCHIVE}, "Chance (0-1) a sufficiently hurt bot actually chooses to flee rather than keep fighting", 0, 1)
local hg_bot_flee_dist        = CreateConVar("hg_bot_flee_dist",        "700", {FCVAR_ARCHIVE}, "Distance (units) a fleeing bot tries to put behind it per repick", 100, 4000)
local hg_bot_flee_safe_dist   = CreateConVar("hg_bot_flee_safe_dist",   "900", {FCVAR_ARCHIVE}, "Distance from the threat's last known position at which a fleeing bot with no LOS on it considers itself safe and stops", 100, 8000)
local hg_bot_flee_recheck     = CreateConVar("hg_bot_flee_recheck",     "1.5", {FCVAR_ARCHIVE}, "Seconds between flee-direction repicks", 0.2, 5)

local hg_bot_laststand       = CreateConVar("hg_bot_laststand",       "1",    {FCVAR_ARCHIVE}, "Last stand: a bot whose body can't run anymore (shock, blood loss, broken legs, exhaustion) fights instead of turning its back", 0, 1)
local hg_bot_laststand_blood = CreateConVar("hg_bot_laststand_blood", "3300", {FCVAR_ARCHIVE}, "Blood (of 5000) below which a bot is too weak to run away", 2000, 5000)
local hg_bot_laststand_shock = CreateConVar("hg_bot_laststand_shock", "30",   {FCVAR_ARCHIVE}, "Pain shock above which a bot can't run away (Z-City knocks out at 40)", 5, 100)
local hg_bot_flee_turnback   = CreateConVar("hg_bot_flee_turnback",   "450",  {FCVAR_ARCHIVE}, "An armed bot never turns its back on a visible enemy this close - it shoots instead", 0, 2000)
local hg_bot_flee_scavenge   = CreateConVar("hg_bot_flee_scavenge",   "700",  {FCVAR_ARCHIVE}, "A bot running with nothing to fight with grabs guns and ammo within this distance on the way (0 = off)", 0, 2000)

--\\ Last stand
	--- Can this body actually get away? Z-City's organism decides how fast
	-- somebody moves; a bot in shock, bled white, on a broken leg or out of
	-- breath is just slower at dying if it turns around.
	-- @return boolean, string reason when false
	function hg.bots.CanRetreat(bot)
		if not hg_bot_laststand:GetBool() then return true end

		local org = bot.organism

		if not org then return true end
		if org.canmove == false then return false, "paralysed" end

		if (org.lleg or 0) >= 1 or (org.rleg or 0) >= 1 or org.llegdislocation or org.rlegdislocation
			or org.llegamputated or org.rlegamputated
		then
			return false, "legs"
		end

		if (org.blood or 5000) < hg_bot_laststand_blood:GetFloat() then return false, "blood loss" end

		-- Same painkiller scaling Z-City's own pain check uses (sv_pain.lua).
		local analgesiaMul = (org.analgesia or 0) * 4 + 1

		if (org.shock or 0) > hg_bot_laststand_shock:GetFloat() * analgesiaMul then return false, "shock" end
		if (org.consciousness or 1) < 0.6 then return false, "consciousness" end
		if (org.immobilization or 0) > 40 then return false, "immobilized" end

		local stamina = org.stamina

		if istable(stamina) and stamina[1] and stamina.max and stamina[1] < stamina.max * 0.2 then
			return false, "exhausted"
		end

		return true
	end

	--- Armed, looking at the enemy, and close: turning around now only
	-- means getting shot in the back.
	local function TooCloseToTurn(bot, data)
		local target = data.Memory.Target

		if not IsValid(target) or not target:Alive() then return false end
		if not hg.bots.GetWeaponKind or hg.bots.GetWeaponKind(bot, true) ~= "gun" then return false end

		local limit = hg_bot_flee_turnback:GetFloat()

		if limit <= 0 or bot:GetPos():DistToSqr(target:GetPos()) > limit * limit then return false end

		return hg.bots.CanSee(bot, target) and true or false
	end
--//

--\\ Fight-or-flee decision
	--- Whether bot should be fleeing right now, given its current health.
	-- Deliberately stateful/sticky (via data.FleeCommitted) rather than a
	-- pure function of health: rolling fresh every call would make a bot
	-- hovering near the threshold flicker between combat and flee state
	-- constantly, which reads as broken rather than as a bot making a
	-- call and sticking to it. The roll clears (so a future drop rerolls
	-- fresh) once health recovers comfortably above the threshold - a
	-- small hysteresis gap, not the exact same value, so healing across
	-- the threshold by one point doesn't immediately re-arm the roll.
	function hg.bots.ShouldFlee(bot)
		if not IsValid(bot) or not bot.Bot then return false end

		local data = bot.Bot

		-- The body decides first: no running on legs that won't carry you,
		-- and no turning your back at point-blank range with a gun in hand.
		-- The roll below stays as it was so this doesn't consume it.
		-- Sticky for a few seconds: shock and stamina hover around their
		-- thresholds, and every hit re-asks this question - without the hold
		-- the bot flipped between running and shooting and did neither.
		local now = CurTime()

		if now < (data.LastStandUntil or 0) then return false end

		if not hg.bots.CanRetreat(bot) or TooCloseToTurn(bot, data) then
			data.LastStandUntil = now + 6

			return false
		end

		local maxHP = bot:GetMaxHealth()
		local frac = (maxHP > 0) and (bot:Health() / maxHP) or 1
		local threshold = hg_bot_flee_health_frac:GetFloat()

		if frac > threshold + 0.1 then
			data.FleeCommitted = nil
			return false
		end

		if frac > threshold then
			-- In the hysteresis band: don't newly trigger a flee decision
			-- from here, just honor whatever was already committed.
			return data.FleeCommitted == true
		end

		if data.FleeCommitted == nil then
			local chance = hg_bot_flee_chance:GetFloat()

			-- Gear recognition (sv_bot_selfpreservation.lua, optional):
			-- being visibly outgunned makes running more attractive, and
			-- being the better-equipped one makes standing your ground
			-- more attractive. Biases the existing roll rather than
			-- replacing it, so the hysteresis above still governs and a
			-- well-equipped bot can still lose its nerve occasionally.
			if hg.bots.GetOutmatchedFactor then
				chance = math.Clamp(chance + hg.bots.GetOutmatchedFactor(bot) * 0.5, 0, 1)
			end

			-- Something to patch up with makes breaking contact worth more:
			-- a bot with a bandage has a reason to leave and come back.
			-- With nothing at all, this stays the plain fight-or-run roll.
			if hg.bots.HasMeds and hg.bots.HasMeds(bot) then
				chance = math.Clamp(chance + 0.2, 0, 1)
			end

			-- Morale and kit (sv_bot_morale.lua): a shaken bot with an
			-- empty gun runs much sooner; one that is angry at whoever is
			-- in front of it, and still armed, stays in the fight.
			if hg.bots.MoraleFleeBias then
				chance = math.Clamp(chance + hg.bots.MoraleFleeBias(bot), 0, 1)
			end

			data.FleeCommitted = (math.random() <= chance)
		end

		return data.FleeCommitted
	end

	-- Fired by sv_bot_perception.lua whenever a bot gets a fresh, confirmed
	-- (non-visual) threat - a bullet whiz or an actual hit. Reacts
	-- regardless of current state, including interrupting looting or
	-- wandering - getting shot at demands attention no matter what a bot
	-- was doing a moment ago.
	hook.Add("HG_BotThreatened", "HG_Bots_ReactToThreat", function(bot, attacker)
		if not IsValid(bot) or not bot.Bot then return end

		-- Never yank a bot out of a throw (pin out - switching weapons
		-- would drop a live grenade) or out of running from one.
		local st = bot.Bot.State

		if st == "grenade" or st == "evadegrenade" or st == "martyr" or bot.Bot.Martyr then return end

		-- Gear-aware choice (flee / ambush / combat) when available. A bot
		-- already in ambush handles being shot at itself (it relocates).
		local wantState = hg.bots.PickReaction and hg.bots.PickReaction(bot) or (hg.bots.ShouldFlee(bot) and "flee" or "combat")

		if bot.Bot.State ~= wantState then
			hg.bots.SetState(bot, wantState)
		end
	end)
--//

--\\ Flee state
	--- Picks up a weapon or ammo that isn't back towards the threat.
	-- @return true while it is driving the bot to (or grabbing) an item
	local function FleeScavenge(bot, data, threatPos, now)
		local radius = hg_bot_flee_scavenge:GetFloat()

		if radius <= 0 or not hg.bots.FindNearbyLoot or not hg.bots.TryPickup then return false end

		local item = data.FleeItem

		if IsValid(item) and not hg.bots.IsLootable(item) then item = nil end

		if not item and now >= (data.NextFleeScan or 0) then
			data.NextFleeScan = now + 1

			local found = hg.bots.FindNearbyLoot(bot, radius, data.LootBlacklist)
			local score = found and hg.bots.LootScore(bot, found)

			-- Only what actually arms us (an unarmed bot scores a gun 95,
			-- wanted ammo 90), and only if getting it doesn't mean running
			-- back at them.
			if found and score and score >= 60 then
				local myDist = bot:GetPos():Distance(threatPos)
				local itemDist = found:GetPos():Distance(threatPos)

				if itemDist > 300 and itemDist > myDist * 0.75 then
					item = found
					data.FleeItemSince = now

					hg.bots.SetGoal(bot, found:GetPos(), { avoidPos = threatPos, avoidRadius = 500, avoidWeight = 2, force = true })
				end
			end
		end

		data.FleeItem = item

		if not item then return false end

		local reach = GetConVar("hg_bot_pickup_range")
		reach = reach and reach:GetFloat() or 80

		if bot:GetPos():DistToSqr(item:GetPos()) <= reach * reach then
			hg.bots.TryPickup(bot, item)

			data.FleeItem = nil
			data.NextWeaponSwitch = 0
			data.Path = nil
			data.Goal = nil
			data.NextFleePick = 0

			-- Armed again: back into it (or keep going, if still outgunned).
			if hg.bots.EquipBestWeapon then hg.bots.EquipBestWeapon(bot) end

			data.FleeRecheckAt = now + 0.8

			return true
		end

		-- Stuck on the way (on a shelf, behind a fence): forget it.
		if hg.bots.FollowPath(bot, data) or now - (data.FleeItemSince or now) > 8 then
			data.LootBlacklist = data.LootBlacklist or {}
			data.LootBlacklist[item] = now + 60
			data.FleeItem = nil
			data.NextFleePick = 0

			return false
		end

		data.Running = true

		return true
	end

	hg.bots.RegisterState("flee", {
		Enter = function(bot, data)
			data.Attacking = false
			data.AttackingSecondary = false
			data.Reloading = false
			data.Running = true
			data.AimSpeed = nil -- don't fight the view - let the movement bridge just face the direction we're running, same as plain wandering

			data.MoveTarget = nil
			data.Path = nil
			data.Goal = nil
			data.NextFleePick = 0

			-- Personal skew on "directly away" so a group of bots running
			-- from the same threat scatters instead of fleeing in a line.
			data.FleeBias = math.Rand(-65, 65)
		end,

		Leave = function(bot, data)
			data.Running = false
			data.NextFleePick = nil
			data.FleeItem = nil
			data.FleeItemSince = nil
			data.FleeRecheckAt = nil
			data.NextStandCheck = nil
		end,

		Think = function(bot, data)
			data.NextStateThink = CurTime() + 0.15

			local mem = data.Memory
			-- Deliberately mem.TargetPos only, never a live
			-- mem.Target:GetPos() fallback - a fleeing bot reasoning about
			-- the threat's REAL current position while unable to see them
			-- would be exactly the omniscience problem combat.lua's
			-- seeking rewrite exists to avoid, just relocated to this
			-- file. In practice TargetPos and Target are always set
			-- together (see sv_bot_perception.lua's ScanOneBot/
			-- ReportThreat), so this only matters as a guarantee.
			local threatPos = mem.TargetPos

			if not threatPos then
				-- Nothing left to actually run from - go back to wandering
				-- rather than sprinting in a fixed direction forever.
				hg.bots.SetState(bot, "idle")
				return
			end

			local canSeeThreat = IsValid(mem.Target) and hg.bots.CanSee(bot, mem.Target)
			local safeDistSqr = hg_bot_flee_safe_dist:GetFloat() ^ 2
			local kind = hg.bots.GetWeaponKind and hg.bots.GetWeaponKind(bot, true) or "gun"
			local now = CurTime()

			-- Last stand: the body gave out mid-retreat, or the enemy is
			-- right on top of us while we still hold a loaded gun. Turn
			-- around and fight with whatever is in hand.
			if IsValid(mem.Target) and mem.Target:Alive() and now >= (data.NextStandCheck or 0) then
				data.NextStandCheck = now + 0.5

				if (kind ~= "none" and not hg.bots.CanRetreat(bot)) or TooCloseToTurn(bot, data) then
					data.FleeCommitted = false
					data.LastStandUntil = now + 6
					hg.bots.SetState(bot, "combat")
					return
				end
			end

			-- Running with nothing to fight with: grab a gun or rounds for
			-- the one we carry if they lie on the way.
			if kind ~= "gun" and FleeScavenge(bot, data, threatPos, now) then return end

			-- Just picked something up: is it enough to go back in?
			if data.FleeRecheckAt and now >= data.FleeRecheckAt then
				data.FleeRecheckAt = nil

				if hg.bots.ApplyReaction and hg.bots.ApplyReaction(bot) ~= "flee" then return end
			end

			-- Is there still anything to run from? A stale contact, or an
			-- enemy with only a knife who's nowhere near, isn't worth
			-- sprinting away from - dig in and watch instead.
			if not canSeeThreat and hg.bots.GetThreatLevel and hg.bots.GetThreatLevel(bot) < 0.2 then
				if hg.bots.HoldPosition then
					hg.bots.HoldPosition(bot, bot:GetPos(), threatPos)
				else
					hg.bots.SetState(bot, "idle")
				end

				return
			end

			-- Far enough away AND not currently being looked at through a
			-- clear line - "safe" is about distance-plus-cover, not
			-- distance alone, otherwise a bot could stop right in the
			-- open at exactly hg_bot_flee_safe_dist units away.
			if bot:GetPos():DistToSqr(threatPos) > safeDistSqr and not canSeeThreat then
				-- Out of the fight and bleeding: that's what the retreat was
				-- for (sv_bot_medic.lua).
				if hg.bots.ShouldHeal and hg.bots.ShouldHeal(bot) then
					hg.bots.SetState(bot, "heal")
					return
				end

				-- Broken contact. Don't just go back to cheerfully
				-- wandering - dig in facing where the threat was last
				-- known to be. hg.bots.HoldPosition is optional
				-- (sv_bot_selfpreservation.lua); without it, fall back to
				-- the old straight-to-idle behaviour.
				if hg.bots.HoldPosition then
					hg.bots.HoldPosition(bot, bot:GetPos(), threatPos)
				else
					hg.bots.SetState(bot, "idle")
				end

				return
			end

			-- Repick on the timer, or early when the path ran out - but not
			-- more than twice a second: cover search + A* per 0.15s tick
			-- was a real server-frame cost with several fleeing bots.
			local pathDone = not data.Path and not data.PendingGoal

			if CurTime() >= (data.NextFleePick or 0) or (pathDone and CurTime() >= (data.LastFleePick or 0) + 0.5) then
				data.LastFleePick = CurTime()
				data.NextFleePick = CurTime() + hg_bot_flee_recheck:GetFloat()

				-- Prefer actual cover - a point the threat genuinely can't
				-- see - over "directly away", which happily sprints into
				-- open ground with the threat still looking right at it.
				-- Optional dependency again: no self-preservation file
				-- loaded means the directional fallback below is used.
				local cover = hg.bots.FindCoverPoint and hg.bots.FindCoverPoint(bot, threatPos)

				-- Threat-aware routing: prefer paths that stay away from
				-- (and out of sight of) the threat, not just the shortest.
				local avoid = { avoidPos = threatPos, avoidRadius = 800, avoidWeight = 3 }

				if cover then
					hg.bots.SetGoal(bot, cover, avoid)
				else
					local away = bot:GetPos() - threatPos
					away.z = 0

					if away:Length() < 1 then
						-- Standing right on top of the threat's last known
						-- position (rare) - Normalize() would choke on a
						-- zero vector, so just pick something instead of
						-- freezing.
						away = Vector(math.Rand(-1, 1), math.Rand(-1, 1), 0)
					end

					away:Normalize()
					away:Rotate(Angle(0, data.FleeBias or 0, 0))

					-- Real navmesh pathing (or SetGoal's own direct-line
					-- fallback with no navmesh) rather than a raw
					-- MoveTarget - running blindly in a straight line
					-- tends to end at the nearest wall.
					hg.bots.SetGoal(bot, bot:GetPos() + away * hg_bot_flee_dist:GetFloat(), avoid)
				end
			end

			hg.bots.FollowPath(bot, data)
		end,
	})
--//
