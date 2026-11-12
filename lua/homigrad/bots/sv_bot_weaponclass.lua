--[[
	Tarkov AI - the weapon decides how a bot fights

	A bot used to fight the same way whatever it held: close to 250 units,
	side-step, fire. Now the gun in its hands is sorted into a class, and
	the class changes how the fight is run:

	  pistol   close, mobile, quick taps. Nothing special - the old fight.
	  smg      close and busy: long bursts, pushes more than it waits.
	  rifle    (assault rifles, carbines) the mid-range all-rounder: keeps
	           400-odd units, short bursts further out, single taps at
	           long range, goes to a knee to shoot when it stands still
	           at distance, pins a lost enemy down with fire.
	  shotgun  a brawler. Does not stand and plink at range - it holds its
	           fire until the spread means something and runs the gap
	           shut instead; never backs away from a man in its face; when
	           the enemy drops out of sight it either storms after him or
	           tucks in behind the corner he has to come round and lets
	           him walk into the muzzle.
	  sniper   (scoped or bolt-action, big calibre) does not walk into a
	           fight at all. It finds a vantage point - higher than the
	           enemy if it can, a clear line to where he is, a long way
	           off - gets there at a run, goes to a knee or lies down, and
	           shoots slowly: on target, settled, one round at a time. A
	           few shots or half a minute and it moves to another spot.
	           Pressed (someone inside 400 units) it gives the perch up and
	           fights with whatever else it carries. With nobody to shoot
	           it sets up over open ground now and then and waits.
	  lmg      (belt-fed) sets up and hoses: long bursts, crouched or
	           prone, holds an angle rather than pushing it.

	How a weapon is sorted (hg.bots.ClassifyWeapon) reads what Z-City's
	weapons say about themselves: pellets per shot and the ammo name for
	shotguns, a built-in scope / a big rifle round with a small magazine
	for snipers, automatic fire with a pistol round for SMGs, 75+ rounds
	automatic for LMGs, the pistol slot for pistols, everything else a
	rifle. hg.bots.WeaponClassOverride[class] = "sniper" (etc.) settles
	any weapon the rules get wrong, and add-on weapon packs can fill it.

	The fight itself still lives in sv_bot_combat.lua; this file hands it
	a profile (distances, bursts, tactic weights) and takes over the
	movement where a class wants its own (the sniper's "overwatch" state,
	the shotgun's corner).

	hg_bot_wclass 0 switches all of it off: every gun is fought like
	before.
]]

hg.bots = hg.bots or {}
hg.bots.States = hg.bots.States or {}
hg.bots.RegisterState = hg.bots.RegisterState or function(name, tbl) hg.bots.States[name] = tbl end

local hg_bot_wclass          = CreateConVar("hg_bot_wclass",          "1",    {FCVAR_ARCHIVE}, "Bots fight according to the class of gun they hold (shotgun rushes and holds corners, sniper finds a vantage point, rifle keeps its distance...). 0 = every gun is fought the same way", 0, 1)
local hg_bot_wclass_debug    = CreateConVar("hg_bot_wclass_debug",    "0",    {FCVAR_ARCHIVE}, "Print weapon class decisions (class picked up, vantage points, corner holds)", 0, 1)
local hg_bot_sniper_min      = CreateConVar("hg_bot_sniper_min",      "700",  {FCVAR_ARCHIVE}, "A sniper's vantage point is at least this far from the enemy", 200, 6000)
local hg_bot_sniper_max      = CreateConVar("hg_bot_sniper_max",      "3200", {FCVAR_ARCHIVE}, "...and at most this far", 500, 12000)
local hg_bot_sniper_close    = CreateConVar("hg_bot_sniper_close",    "400",  {FCVAR_ARCHIVE}, "An enemy this close makes a sniper give its perch up and fight with what else it has", 100, 2000)
local hg_bot_sniper_shots    = CreateConVar("hg_bot_sniper_shots",    "4",    {FCVAR_ARCHIVE}, "A sniper moves to another spot after about this many shots from one", 1, 30)
local hg_bot_sniper_stay     = CreateConVar("hg_bot_sniper_stay",     "25",   {FCVAR_ARCHIVE}, "...or after about this many seconds in one spot", 5, 300)
local hg_bot_sniper_idle     = CreateConVar("hg_bot_sniper_idle",     "1",    {FCVAR_ARCHIVE}, "A sniper with nobody to shoot sets up on a vantage point now and then instead of only strolling", 0, 1)
local hg_bot_shotgun_range   = CreateConVar("hg_bot_shotgun_range",   "650",  {FCVAR_ARCHIVE}, "A shotgun bot holds its fire beyond this distance and closes in instead", 100, 3000)
local hg_bot_shotgun_corner  = CreateConVar("hg_bot_shotgun_corner",  "0.4",  {FCVAR_ARCHIVE}, "Chance a shotgun bot that lost sight of its enemy waits behind a corner on his way instead of storming after him", 0, 1)

local function Debug(bot, ...)
	if hg_bot_wclass_debug:GetBool() then print("[hg.bots] wclass " .. (IsValid(bot) and bot:Nick() or "?") .. ":", ...) end
end

--\\ Sorting a gun into a class
	hg.bots.WeaponClassOverride = hg.bots.WeaponClassOverride or {}

	-- Guns the rules below get wrong (both are built on Z-City's manual-
	-- action base and look like bolt-action snipers on paper).
	for class, kind in pairs({ weapon_sks = "rifle", weapon_winchester = "rifle" }) do
		if hg.bots.WeaponClassOverride[class] == nil then hg.bots.WeaponClassOverride[class] = kind end
	end

	local SNIPER_ROUNDS = { "7.62x54", "7.62x51", ".338", "12.7x108", "14.5x114", ".50 bmg", ".308", "7.92", "8.6x70", ".300", "30-06" }
	local SMALL_ROUNDS = { "9x19", ".45 acp", "4.6x30", "5.7x28", "7.65", "9x18", "7.62x25", ".40", ".380", "9x21", ".22", ".38", ".357", ".50 action", "10mm" }
	local SNIPER_NAMES = { "sniper", "svd", "mosin", "kar98", "m98", "awp", "barrett", "sr25", "m24", "l96", "ptrd", "dragunov", "scout" }

	local function Has(s, list)
		for i = 1, #list do
			if string.find(s, list[i], 1, true) then return true end
		end

		return false
	end

	local classCache = {}

	--- "pistol" | "smg" | "rifle" | "shotgun" | "sniper" | "lmg" for a
	-- firearm, nil for anything that is not one.
	function hg.bots.ClassifyWeapon(wep)
		if not IsValid(wep) then return nil end

		local class = wep:GetClass()
		local over = hg.bots.WeaponClassOverride[class]

		if over then return over end

		local cached = classCache[class]

		if cached ~= nil then return cached or nil end

		local kind

		if wep.GetFists or (hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep)) or (wep.Throw ~= nil and wep.ENT ~= nil)
			or not (wep.ishgweapon or wep:Clip1() >= 0)
		then
			kind = false
		else
			local prim = wep.Primary or {}
			local ammo = string.lower(tostring(prim.Ammo or ""))
			local name = string.lower(class)
			local auto = prim.Automatic == true
			local clip = tonumber(prim.ClipSize) or 0
			local pellets = tonumber(wep.NumBullet) or 1
			local hold = string.lower(tostring(wep.HoldType or ""))
			-- A scope of its own: the fields the scoped rifles set and the
			-- weapon base does not (what the base sets, every gun has).
			local base = weapons.GetStored("homigrad_base") or {}
			local scoped = (wep.scopemat ~= nil and wep.scopemat ~= base.scopemat)
				or (wep.FOVScoped ~= nil and wep.FOVScoped ~= base.FOVScoped)
				or (wep.scope_blackout ~= nil and wep.scope_blackout ~= base.scope_blackout)
			local bigRound = Has(ammo, SNIPER_ROUNDS)
			local pistolish = wep.IsPistol ~= false and (wep.IsPistol == true or wep.weaponInvCategory == 2 or hold == "pistol" or hold == "revolver")
			local small = Has(ammo, SMALL_ROUNDS)

			-- (Pellets alone are not proof: Z-City's bolt-actions are built
			-- on its pump shotgun and some keep its pellet count on paper
			-- while firing one rifle round.)
			if string.find(ammo, "gauge", 1, true) or string.find(ammo, "buck", 1, true) or string.find(ammo, "12/70", 1, true)
				or (pellets > 1 and not bigRound and not small)
			then
				kind = "shotgun"
			elseif not auto and (scoped or Has(name, SNIPER_NAMES) or (bigRound and clip > 0 and clip <= 10)) then
				kind = "sniper"
			elseif auto and clip >= 75 then
				kind = "lmg"
			elseif auto and (small or pistolish) then
				kind = "smg"
			elseif pistolish or (small and (tonumber(wep.weight) or 2) <= 1.5) then
				kind = "pistol"
			else
				kind = "rifle"
			end
		end

		classCache[class] = kind

		return kind or nil
	end

	--- The class of the gun in a bot's (or player's) hands, nil without one.
	function hg.bots.GetWeaponClass(ply)
		if not IsValid(ply) then return nil end

		return hg.bots.ClassifyWeapon(ply:GetActiveWeapon())
	end

	concommand.Add("hg_bot_wclass_list", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		local n = 0

		for bot in pairs(hg.bots.List or {}) do
			if IsValid(bot) then
				local wep = bot:GetActiveWeapon()

				n = n + 1
				print(("[hg.bots] %-18s %-28s %s  (state %s)"):format(bot:Nick(), IsValid(wep) and wep:GetClass() or "-", tostring(hg.bots.ClassifyWeapon(wep) or "no gun"), tostring(bot.Bot and bot.Bot.State)))
			end
		end

		if n == 0 then print("[hg.bots] no bots") end
	end, nil, "Print every bot's weapon and the class it is fought as")
--//

--\\ Profiles
	local Vantage, StartOverwatch -- below

	--- Burst timings { on min, on max, off min, off max } by distance.
	local function RifleBurst(dist)
		if dist > 1400 then return { 0.06, 0.12, 0.35, 0.8 } end -- single taps
		if dist > 700 then return { 0.15, 0.35, 0.25, 0.6 } end -- short bursts

		return { 0.35, 0.9, 0.1, 0.35 }
	end

	local PROFILES = {
		pistol = {
			engage = 230, backoff = 0.4,
			burst = function() return { 0.06, 0.12, 0.15, 0.45 } end,
		},

		smg = {
			engage = 220, backoff = 0.3,
			tactic = { push = 1.6, wait = 0.7, careful = 0.8 },
			burst = function(dist) return dist > 700 and { 0.2, 0.4, 0.2, 0.5 } or { 0.5, 1.3, 0.08, 0.3 } end,
		},

		rifle = {
			engage = 450, backoff = 0.3, crouchBeyond = 800,
			tactic = { push = 0.9, wait = 1, careful = 1.3 },
			burst = RifleBurst,
		},

		lmg = {
			engage = 650, backoff = 0.2, crouchBeyond = 350, prone = 2,
			tactic = { push = 0.4, wait = 2, careful = 0.8 },
			burst = function(dist) return dist > 1200 and { 0.5, 1.0, 0.3, 0.7 } or { 1.0, 2.4, 0.2, 0.5 } end,
		},

		shotgun = {
			engage = 140, backoff = 0, run = true,
			tactic = { push = 3, wait = 0, careful = 0.25 },
			burst = function() return { 0.08, 0.15, 0.25, 0.55 } end,
		},

		sniper = {
			engage = 1200, backoff = 0.25, crouchBeyond = 300, prone = 2.5,
			tactic = { push = 0.15, wait = 3, careful = 0.6 },
			burst = function() return { 0.06, 0.1, 0.9, 1.7 } end,
		},
	}

	hg.bots.WeaponProfiles = PROFILES

	--- The profile for the gun a bot holds, nil when it holds none or the
	-- whole thing is switched off (the fight then runs as it always did).
	function hg.bots.WeaponProfile(bot, wep)
		if not hg_bot_wclass:GetBool() then return nil end

		local class = hg.bots.ClassifyWeapon(wep or bot:GetActiveWeapon())
		local prof = class and PROFILES[class]

		if not prof then return nil end

		local data = bot.Bot

		if data and data.WClass ~= class then
			data.WClass = class
			Debug(bot, "now fights as", class)
		end

		prof.class = class

		return prof
	end

	--- How much further than the plain sight range this bot sees: through
	-- a scope, set up and looking down it, a sniper makes a man out at
	-- twice the distance (sv_bot_perception.lua asks once per tick).
	function hg.bots.SightRangeMul(bot)
		if not hg_bot_wclass:GetBool() then return 1 end

		local data = bot.Bot

		if not data then return 1 end

		if hg.bots.GetWeaponClass(bot) ~= "sniper" then return 1 end

		return data.State == "overwatch" and 2.2 or 1.6
	end

	--- Pick a weapon for the range: the long gun is no use to a sniper
	-- with a man on top of it, nor a shotgun across a field, when the
	-- bot carries something else. Added to sv_bot_selfpreservation.lua's
	-- weapon score.
	function hg.bots.WeaponRangeScore(bot, wep)
		if not hg_bot_wclass:GetBool() then return 0 end

		local mem = bot.Bot and bot.Bot.Memory
		local target = mem and mem.Target

		if not IsValid(target) or not mem.TargetPos then return 0 end

		local class = hg.bots.ClassifyWeapon(wep)

		if not class then return 0 end

		local dist = bot:GetPos():Distance(mem.TargetPos)

		if class == "sniper" then return dist < hg_bot_sniper_close:GetFloat() * 1.25 and -60 or 15 end
		if class == "shotgun" then return dist > hg_bot_shotgun_range:GetFloat() * 1.8 and -40 or (dist < 400 and 20 or 0) end
		if class == "pistol" then return -10 end -- a sidearm is a sidearm

		return 0
	end
--//

--\\ Shotgun: storm or corner
	--- Lost sight of the enemy. @return true when this took the bot over
	-- (it now holds a corner; combat picks the fight up again from there).
	PROFILES.shotgun.LostSight = function(bot, data, mem, wep, target, now)
		data.SeekCareful = false -- no creeping: it goes in, or it waits

		local enemyPos = mem.TargetPos

		if not enemyPos or not hg.bots.HoldPosition or not hg.bots.FindAmbushPoint then return false end
		if data.WaitedFor == target then return false end -- waited once already: this time it goes
		if math.random() > hg_bot_shotgun_corner:GetFloat() then return false end

		local dist = bot:GetPos():Distance(enemyPos)

		if dist > 1500 then return false end

		local spot, corner = hg.bots.FindAmbushPoint(bot, enemyPos)

		if not spot or spot:DistToSqr(bot:GetPos()) > 700 * 700 then return false end

		Debug(bot, "shotgun holds a corner", math.floor(spot:Distance(bot:GetPos())), "u away")

		hg.bots.HoldPosition(bot, spot, corner or enemyPos)

		data.HoldResumeCombat = true
		data.HoldDuration = math.Rand(5, 10)

		return true
	end
--//

--\\ Sniper: vantage points
	local CHEST, EYE = Vector(0, 0, 40), Vector(0, 0, 60)
	local vTR = {}
	local vQ = { output = vTR, mask = MASK_VISIBLE }

	local function Clear(a, b)
		vQ.start, vQ.endpos = a, b

		util.TraceLine(vQ)

		return not vTR.Hit
	end

	--- Is pos too close to a spot another sniper already uses?
	local function Taken(bot, pos)
		for other in pairs(hg.bots.List or {}) do
			local o = other ~= bot and IsValid(other) and other.Bot and other.Bot.Overwatch

			if o and o.spot and o.spot:DistToSqr(pos) < 220 * 220 then return true end
		end

		return false
	end

	--- A place to shoot from. With watchPos (where the enemy is): a point
	-- with a clear line to it, between the sniper's min and max distance,
	-- higher than it if there is one, near something to duck behind, and
	-- not a long run through his sights. Without: somewhere high with long
	-- open lines, to watch from.
	-- @return Vector spot, Vector watch point (or nil)
	Vantage = function(bot, watchPos, avoid)
		if not navmesh.IsLoaded() then return nil end

		local origin = bot:GetPos()
		local minD, maxD = hg_bot_sniper_min:GetFloat(), hg_bot_sniper_max:GetFloat()
		local areas = navmesh.Find(origin, watchPos and 2200 or 1600, 600, 600)

		if not areas or #areas == 0 then return nil end

		local best, bestScore, bestWatch
		local watchEye = watchPos and (watchPos + EYE)

		for _ = 1, math.min(36, #areas) do
			local area = areas[math.random(#areas)]

			if IsValid(area) and not area:IsUnderwater() and not (hg.bots.IsDeepWaterArea and hg.bots.IsDeepWaterArea(area)) then
				local spots = area.GetHidingSpots and area:GetHidingSpots()
				local hide = spots and #spots > 0
				local p = hide and spots[math.random(#spots)] or area:GetRandomPoint()
				local travel = p:Distance(origin)

				if not (avoid and p:DistToSqr(avoid) < 260 * 260) and not Taken(bot, p) then
					if watchPos then
						local d = p:Distance(watchPos)

						if d >= minD and d <= maxD and Clear(p + CHEST, watchEye) then
							-- Height is what makes a vantage point; then being
							-- about a comfortable rifle shot away; then not
							-- having to run far or towards him to get there.
							local score = (p.z - watchPos.z) * 2.5 - math.abs(d - 1400) * 0.25 - travel * 0.5 + (hide and 120 or 0)

							if d < origin:Distance(watchPos) - 300 then score = score - 250 end

							if not bestScore or score > bestScore then
								best, bestScore, bestWatch = p, score, watchPos
							end
						end
					else
						-- Nobody to watch: the longest clear lines out of six
						-- directions, and height.
						local open, far, farDist = 0, nil, 0
						local eye = p + CHEST

						for yaw = 0, 300, 60 do
							local dir = Angle(0, yaw + math.Rand(-20, 20), 0):Forward()

							vQ.start, vQ.endpos = eye, eye + dir * 2500
							util.TraceLine(vQ)

							local len = vTR.Fraction * 2500

							open = open + len

							if len > farDist then far, farDist = vTR.HitPos, len end
						end

						local score = open * 0.1 + (p.z - origin.z) * 1.5 - travel * 0.4 + (hide and 100 or 0)

						if farDist > 900 and (not bestScore or score > bestScore) then
							best, bestScore, bestWatch = p, score, far
						end
					end
				end
			end
		end

		return best, bestWatch
	end

	hg.bots.FindVantagePoint = Vantage

	--- Sends a bot to a vantage point to shoot from (or to watch from).
	-- @param watchPos Vector|nil the enemy's place; nil = just overlook
	-- @return boolean false when no spot was found
	StartOverwatch = function(bot, watchPos, idle)
		local data = bot.Bot

		if not data then return false end

		local now = CurTime()

		if now < (data.NextVantagePick or 0) then return false end

		data.NextVantagePick = now + 3

		local keep = data.OverwatchKeep
		local spot, watch

		-- Back on its feet after lying down at a spot (or after a scuffle):
		-- the same spot, if it is still a good one.
		if keep and now < keep.till and watchPos and keep.spot:DistToSqr(bot:GetPos()) < 300 * 300
			and keep.spot:Distance(watchPos) > hg_bot_sniper_close:GetFloat() * 1.5 and Clear(keep.spot + CHEST, watchPos + EYE)
		then
			spot, watch = keep.spot, watchPos
		else
			spot, watch = Vantage(bot, watchPos)
		end

		if not spot then
			-- Nothing better anywhere: where it stands, if it can see him
			-- from here and he is not on top of it.
			if not watchPos or bot:GetPos():Distance(watchPos) < hg_bot_sniper_close:GetFloat() * 1.5 then return false end

			spot, watch = bot:GetPos(), watchPos
		end

		data.OverwatchPlan = { spot = spot, watch = watch, idle = idle or false }

		Debug(bot, idle and "sets up to overlook from" or "vantage point", tostring(spot), math.floor(spot:Distance(bot:GetPos())), "u away")

		hg.bots.SetState(bot, "overwatch")

		return true
	end

	hg.bots.StartOverwatch = StartOverwatch

	--- The enemy is in sight: a sniper goes to its perch instead of
	-- fighting where it stands.
	PROFILES.sniper.Visible = function(bot, data, mem, wep, target, dist, now)
		if now < (data.SniperCloseUntil or 0) then return false end
		if dist < hg_bot_sniper_close:GetFloat() then
			data.SniperCloseUntil = now + 6

			return false
		end

		return StartOverwatch(bot, mem.TargetPos, false)
	end

	PROFILES.sniper.LostSight = function(bot, data, mem, wep, target, now)
		if now < (data.SniperCloseUntil or 0) or not mem.TargetPos then return false end
		if bot:GetPos():Distance(mem.TargetPos) < hg_bot_sniper_close:GetFloat() then return false end

		return StartOverwatch(bot, mem.TargetPos, false)
	end

	local function LeaveOverwatch(bot, data, to)
		hg.bots.SetState(bot, to)
	end

	local function Relocate(bot, data, o, mem, now)
		o.nextPick = now + 4

		local spot, watch = Vantage(bot, (not o.idle) and (mem.TargetPos or o.watch) or nil, o.spot)

		if not spot then
			o.moveAt = now + 10

			return false
		end

		Debug(bot, "moves to another spot", math.floor(spot:Distance(bot:GetPos())), "u away")

		o.spot, o.watch = spot, watch or o.watch
		o.arrived, o.tries, o.onTarget = false, 0, nil

		data.Crouching = false

		hg.bots.SetGoal(bot, spot, { force = true, avoidPos = mem.TargetPos, avoidRadius = 900, avoidWeight = 3 })

		return true
	end

	hg.bots.RegisterState("overwatch", {
		Enter = function(bot, data)
			local plan = data.OverwatchPlan or { spot = bot:GetPos(), watch = data.Memory.TargetPos, idle = false }
			local now = CurTime()

			data.OverwatchPlan = nil
			data.Overwatch = {
				spot = plan.spot, watch = plan.watch, idle = plan.idle,
				arrived = false, tries = 0, shots = 0, since = now,
				till = now + math.Rand(35, 70), -- (an idle watch ends then)
			}

			data.Attacking = false
			data.AttackingSecondary = false
			data.Reloading = false
			data.Crouching = false
			data.Running = true
			data.WBurst = PROFILES.sniper.burst()

			hg.bots.ClearPath(data)

			if plan.spot:DistToSqr(bot:GetPos()) > 70 * 70 then
				hg.bots.SetGoal(bot, plan.spot, { force = true, avoidPos = (not plan.idle) and plan.watch or nil, avoidRadius = 900, avoidWeight = 3 })
			end
		end,

		Leave = function(bot, data)
			local o = data.Overwatch

			-- Whatever takes it off the perch (a hit, a grenade, lying
			-- down): the spot is remembered for half a minute, and a
			-- sniper that still wants one comes back to it.
			if o and o.arrived then
				data.OverwatchKeep = { spot = o.spot, till = CurTime() + 30 }
			end

			data.Overwatch = nil
			data.Attacking = false
			data.AttackingSecondary = false
			data.Crouching = false
			data.Running = false
			data.AimSpeed = nil
			data.WBurst = nil
		end,

		Think = function(bot, data)
			local now = CurTime()

			data.NextStateThink = now + 0.1

			local o = data.Overwatch
			local mem = data.Memory
			local target = mem.Target
			local hasTarget = IsValid(target) and target:Alive()

			if not o then hg.bots.SetState(bot, "idle") return end

			-- Somebody turned up while it was only overlooking: this is a
			-- shoot now, from here if here can see him.
			if o.idle and hasTarget then
				o.idle = false
				o.watch = mem.TargetPos or o.watch
				o.moveAt = now + hg_bot_sniper_stay:GetFloat() * math.Rand(0.7, 1.3)
			elseif not o.idle and not hasTarget then
				LeaveOverwatch(bot, data, "idle")
				return
			end

			local wep = bot:GetActiveWeapon()

			-- The rifle is gone, dry, or swapped for something else.
			if hg.bots.ClassifyWeapon(wep) ~= "sniper" or (hg.bots.GunHasAmmo and not hg.bots.GunHasAmmo(bot, wep) and not data.Reloading) then
				data.SniperCloseUntil = now + 6
				LeaveOverwatch(bot, data, hasTarget and "combat" or "idle")
				return
			end

			local myPos = bot:GetPos()
			local canSee = hasTarget and hg.bots.CanSee(bot, target)
			local enemyPos = hasTarget and (mem.TargetPos or target:GetPos()) or nil

			if canSee then
				local char = hg.bots.GetCharacter and hg.bots.GetCharacter(target) or target

				enemyPos = char:GetPos()
				mem.TargetPos = enemyPos
				mem.TargetSeenPos = enemyPos
				mem.TargetVel = char:GetVelocity()
				mem.LastSeen = now
				o.watch = enemyPos
			end

			-- Still hunting him: perception must not forget while it waits.
			if hasTarget then mem.ContactHold = now end

			local dist = enemyPos and myPos:Distance(enemyPos) or math.huge

			-- On top of it: the perch is given up, and whatever else it
			-- carries comes out (sv_bot_selfpreservation.lua's weapon pick
			-- reads the distance through WeaponRangeScore).
			if hasTarget and dist < hg_bot_sniper_close:GetFloat() and (canSee or (mem.LastHeard and now - mem.LastHeard < 1.5)) then
				data.SniperCloseUntil = now + 8
				data.NextWeaponSwitch = 0

				Debug(bot, "pressed at", math.floor(dist), "u - gives the perch up")

				LeaveOverwatch(bot, data, "combat")
				return
			end

			-- Waited long enough for a man who never showed again.
			if hasTarget and not canSee and now - math.max(mem.LastSeen or 0, o.since) > 45 then
				mem.ContactHold = nil
				LeaveOverwatch(bot, data, "idle")
				return
			end

			if o.idle and now > o.till then
				data.NextIdleOverwatch = now + math.Rand(60, 140)
				LeaveOverwatch(bot, data, "idle")
				return
			end

			--\\ On the way
			if not o.arrived then
				data.Running = true
				data.Crouching = false
				data.Attacking = false
				data.AttackingSecondary = false
				data.LookPos = nil

				hg.bots.ServiceWeapon(bot, data, wep, false) -- reload on the run

				if hg.bots.FollowPath(bot, data) then
					if myPos:DistToSqr(o.spot) < 90 * 90 then
						o.arrived = true
					else
						-- No route there (or given up on stuck): another spot,
						-- and after two of those, right here.
						o.tries = o.tries + 1

						if o.tries > 2 or not Relocate(bot, data, o, mem, now) then
							o.spot = myPos
							o.arrived = true
						end
					end

					if o.arrived then
						o.at = now
						o.shots = 0
						o.maxShots = math.max(1, math.floor(hg_bot_sniper_shots:GetFloat() * math.Rand(0.6, 1.5) + 0.5))
						o.moveAt = now + hg_bot_sniper_stay:GetFloat() * math.Rand(0.7, 1.4)
						o.lastClip = wep:Clip1()
						o.yaw = o.watch and (o.watch - myPos):Angle().y or bot:EyeAngles().y

						-- Lie down for it: far enough off that getting up is
						-- not what kills it (sv_bot_downed.lua shoots from
						-- the floor until ProneUntil).
						local prone = GetConVar("hg_bot_prone")

						if hasTarget and dist > 900 and hg.Fake and not IsValid(bot.FakeRagdoll) and bot:IsOnGround()
							and (not prone or prone:GetBool()) and math.random() < 0.35
						then
							data.Prone = true
							data.ProneUntil = now + math.Rand(12, 22)
							data.OverwatchKeep = { spot = o.spot, till = now + 40 }

							hg.Fake(bot)

							if IsValid(bot.FakeRagdoll) then
								Debug(bot, "goes prone")

								return
							end

							-- (Z-City would not put it down just now: a knee then.)
							data.Prone = nil
							data.ProneUntil = nil
						end
					end
				end

				return
			end
			--//

			--\\ In position
			data.MoveTarget = nil
			data.Running = false
			data.Crouching = true
			data.AimSpeed = 150

			if canSee then
				local eye = hg.bots.GetEyePos and hg.bots.GetEyePos(bot) or bot:EyePos()
				local aim = hg.bots.GetAimPoint and hg.bots.GetAimPoint(bot, target) or target:WorldSpaceCenter()

				data.LookPos = aim
				data.LookLock = true

				local err, len = hg.bots.GetAimError(bot, eye, aim)

				-- On him and steady for a moment before the trigger: a
				-- sniper's shot is aimed, not sprayed in his direction.
				if err <= hg.bots.GetAimTolerance(len) * 0.5 then
					o.onTarget = o.onTarget or now
				else
					o.onTarget = nil
				end

				local mayFire = o.onTarget and now - o.onTarget > 0.3
					and not (hg.bots.FriendlyInLine and hg.bots.FriendlyInLine(bot, aim))

				hg.bots.ServiceWeapon(bot, data, wep, mayFire and true or false)
			else
				o.onTarget = nil
				data.Attacking = false

				if o.idle then
					-- Sweep the ground it overlooks, slowly.
					if now >= (o.nextSweep or 0) then
						o.nextSweep = now + math.Rand(2.5, 5)
						o.sweep = (o.yaw or 0) + math.Rand(-55, 55)
					end

					data.AimSpeed = 60
					data.LookPos = bot:EyePos() + Angle(4, o.sweep or 0, 0):Forward() * 1500
				else
					data.LookPos = hg.bots.GetWaitLookPos and hg.bots.GetWaitLookPos(bot, o.watch and (o.watch + EYE)) or (o.watch and (o.watch + EYE))
				end

				hg.bots.ServiceWeapon(bot, data, wep, false)
			end

			-- Through the scope while it waits and while it shoots.
			data.AttackingSecondary = not data.Reloading

			-- Count the rounds that left from this spot.
			local clip = wep:Clip1()

			if o.lastClip and clip < o.lastClip then o.shots = o.shots + (o.lastClip - clip) end

			o.lastClip = clip
			--//

			-- Time to move: enough shots from here to have been placed, here
			-- too long, or the fire is coming back.
			if now >= (o.nextPick or 0) and not o.idle then
				local hot = (mem.Suppression or 0) > 0.45 or ((mem.UnderFireUntil or 0) > now and not canSee)
				local blind = hasTarget and not canSee and now - (o.at or now) > 8 and o.watch and not Clear(myPos + CHEST, o.watch + EYE)

				if o.shots >= (o.maxShots or 4) or now > (o.moveAt or 0) or hot or blind then
					Relocate(bot, data, o, mem, now)
				end
			end
		end,
	})

	--- Idle: a sniper sets up over open ground now and then.
	-- Called from the idle state (sv_bot_navigation.lua).
	function hg.bots.CheckWeaponRole(bot, data)
		if not hg_bot_wclass:GetBool() or not hg_bot_sniper_idle:GetBool() then return false end

		local now = CurTime()

		if now < (data.NextIdleOverwatch or 0) then return false end

		data.NextIdleOverwatch = now + math.Rand(20, 45)

		if hg.bots.GetWeaponClass(bot) ~= "sniper" then return false end
		if math.random() > 0.5 then return false end

		data.NextVantagePick = 0

		return StartOverwatch(bot, nil, true)
	end

	-- The class's burst rhythm belongs to the states that shoot with it.
	hook.Add("HG_BotStateChanged", "HG_Bots_WClass", function(bot, old, new)
		local data = bot.Bot

		if data and new ~= "combat" and new ~= "overwatch" and new ~= "hold" then data.WBurst = nil end
	end)
--//

--- Beyond this a shotgun bot holds its fire (hg_bot_shotgun_range).
function hg.bots.ShotgunRange() return hg_bot_shotgun_range:GetFloat() end
