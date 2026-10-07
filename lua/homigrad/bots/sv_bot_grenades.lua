--[[
	Tarkov AI - Grenades

	Throwing and dodging grenades, using Z-City's own grenade weapons
	(weapons/weapon_hg_grenade_tpik.lua and everything based on it: F1,
	M67, RGD, HL2 frag, molotov...). Verified against the source:

	Throwing - exactly the player's input sequence:
	- LMB pulls the pin (pullback animation, ~1.2 s, then SWEP.ReadyToThrow);
	  releasing LMB throws: the weapon's ThinkAdd sees the button up, plays
	  the throw, and SWEP:Throw spawns the grenade with velocity
	  owner:GetAimVector() * 1200 / 1.5 (= 800 u/s) plus the thrower's own
	  velocity. RMB is the same with an underhand lob at 600 / 1.5 = 400.
	- The fuse starts on release (ent.timer = spoon time), explosion
	  after ENT.timeToBoom (3-5 s).
	- Reload with the pin out puts the pin back (SWEP:Reload ->
	  ResetThrow). IMPORTANT: switching weapons with the pin out drops a
	  LIVE grenade (SWEP:Holster -> Throw(0)), so the throw state can't be
	  interrupted by the usual reaction switches - see the guards in
	  sv_bot_flee.lua's threat hook and the "abort" path below.

	The throw is ballistic: for the distance and height difference to the
	target the launch angle is solved from the real throw speed and
	sv_gravity (low arc first, then a high lob over cover), and every
	candidate arc is traced segment by segment so the bot doesn't bounce
	it off the ceiling or the wall in front of it.

	When a bot throws (combat): it has a frag/molotov, the enemy was seen
	recently but is hiding now (a grenade is how you flush someone out of
	cover), within range, not right next to the bot, no other bot near the
	landing spot, cooldown passed, and a roll.

	Dodging: every live (armed) grenade - anyone's, the bot's own that
	bounced back included - is tracked. A bot within its danger radius
	that sees it land or roll up (or hears it right next to it) reacts
	after a short human delay: runs for cover out of the grenade's line of
	sight (threat-aware path), gets down once safe or when the fuse is
	about to run out, and goes back to what it was doing once it's gone.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {}
hg.bots.States = hg.bots.States or {}
hg.bots.RegisterState = hg.bots.RegisterState or function(name, tbl) hg.bots.States[name] = tbl end

local hg_bot_grenades         = CreateConVar("hg_bot_grenades",         "1",    {FCVAR_ARCHIVE}, "Bots throw grenades they carry", 0, 1)
local hg_bot_grenade_cooldown = CreateConVar("hg_bot_grenade_cooldown", "15",   {FCVAR_ARCHIVE}, "Minimum seconds between one bot's grenade throws", 1, 300)
local hg_bot_grenade_chance   = CreateConVar("hg_bot_grenade_chance",   "0.5",  {FCVAR_ARCHIVE}, "Chance per check (once a second) that a bot with a good throw actually throws", 0, 1)
local hg_bot_grenade_min      = CreateConVar("hg_bot_grenade_min",      "280",  {FCVAR_ARCHIVE}, "Minimum distance to throw at (closer is too dangerous for the thrower)", 50, 2000)
local hg_bot_grenade_max      = CreateConVar("hg_bot_grenade_max",      "1100", {FCVAR_ARCHIVE}, "Maximum throwing distance", 100, 4000)
local hg_bot_grenade_dodge    = CreateConVar("hg_bot_grenade_dodge",    "1",    {FCVAR_ARCHIVE}, "Bots run from live grenades near them", 0, 1)
local hg_bot_grenade_danger   = CreateConVar("hg_bot_grenade_danger",   "420",  {FCVAR_ARCHIVE}, "Distance from a live frag grenade that bots consider dangerous", 50, 2000)

local hg_bot_grenade_dive     = CreateConVar("hg_bot_grenade_dive",     "1",    {FCVAR_ARCHIVE}, "Bots still in the blast when a grenade is about to go off dive away into a Z-City ragdoll", 0, 1)
local hg_bot_grenade_dive_time = CreateConVar("hg_bot_grenade_dive_time", "1.0", {FCVAR_ARCHIVE}, "Seconds before the explosion at which an exposed bot dives", 0.1, 3)
local hg_bot_grenade_dive_speed = CreateConVar("hg_bot_grenade_dive_speed", "430", {FCVAR_ARCHIVE}, "Horizontal speed of the dive", 100, 1200)

local RunStraightAway -- defined in the dodging section

local HIGH_SPEED = 1200 / 1.5 -- SWEP:Throw(1200) on LMB
local LOW_SPEED = 600 / 1.5 -- SWEP:Throw(600) on RMB
local DRAG_COMP = 1.08 -- physics drag shortens throws a little

--\\ Weapons
	--- A throwable damaging grenade (not smoke/flash)?
	local function IsFragWeapon(wep)
		if not IsValid(wep) or not wep.Throw or not isstring(wep.ENT) then return false end

		local e = string.lower(wep.ENT)

		return not (string.find(e, "smoke", 1, true) or string.find(e, "flash", 1, true))
	end

	function hg.bots.FindGrenade(bot)
		for _, wep in ipairs(bot:GetWeapons()) do
			if IsFragWeapon(wep) then return wep end
		end

		return nil
	end
--//

--\\ Ballistics
	local function Gravity()
		local g = physenv and physenv.GetGravity and physenv.GetGravity():Length() or 0

		if g <= 0 then g = GetConVar("sv_gravity"):GetFloat() end

		return g
	end

	--- Launch angle (radians above horizontal) to cover horizontal distance
	-- d and rise h at speed v. high = the lob (steeper) solution.
	local function SolveAngle(v, d, h, g, high)
		local v2 = v * v
		local disc = v2 * v2 - g * (g * d * d + 2 * h * v2)

		if disc < 0 then return nil end

		local root = math.sqrt(disc)

		return math.atan((v2 + (high and root or -root)) / (g * d))
	end

	--- Does the arc actually get there? Traced in segments; hitting
	-- something before the last stretch near the target = blocked.
	local function ArcClear(bot, start, dirH, v, theta, g, target)
		local vx, vz = v * math.cos(theta), v * math.sin(theta)
		local d = (Vector(target.x, target.y, 0) - Vector(start.x, start.y, 0)):Length()
		local total = d / math.max(vx, 1)
		local steps = 14
		local prev = start

		for i = 1, steps do
			local t = total * i / steps
			local p = start + dirH * (vx * t) + Vector(0, 0, vz * t - 0.5 * g * t * t)

			local tr = util.TraceHull({
				start = prev,
				endpos = p,
				mins = Vector(-3, -3, -3),
				maxs = Vector(3, 3, 3),
				filter = { bot, bot.FakeRagdoll },
				mask = MASK_SOLID,
			})

			if tr.Hit then
				-- Landing close to the target is fine (it'll roll there).
				return tr.HitPos:DistToSqr(target) < 110 * 110
			end

			prev = p
		end

		return true
	end

	--- Best throw at target from where the bot stands.
	-- @return table { ang = Angle, low = bool } or nil if nothing works
	function hg.bots.PlanThrow(bot, target)
		local start = bot:EyePos()
		local flat = Vector(target.x - start.x, target.y - start.y, 0)
		local d = flat:Length()

		if d < 1 then return nil end

		local dirH = flat / d
		local h = target.z + 8 - start.z
		local g = Gravity()
		local aimD = d * DRAG_COMP

		-- Underhand for short throws first (softer, rolls less), then the
		-- overhand flat arc, then lobs over cover.
		local options = {
			{ LOW_SPEED, false, true },
			{ HIGH_SPEED, false, false },
			{ HIGH_SPEED, true, false },
			{ LOW_SPEED, true, true },
		}

		for _, o in ipairs(options) do
			local theta = SolveAngle(o[1], aimD, h, g, o[2])

			if theta and theta < math.rad(75) and theta > math.rad(-30) and ArcClear(bot, start, dirH, o[1], theta, g, target) then
				local ang = dirH:Angle()

				ang.p = -math.deg(theta)
				ang.r = 0

				return { ang = ang, low = o[3] }
			end
		end

		return nil
	end
--//

--\\ When to throw
	--- Called from combat's Think while the target isn't visible. Starts
	-- the "grenade" state and returns true when a throw is decided.
	function hg.bots.TryGrenade(bot, data, mem, now)
		if not hg_bot_grenades:GetBool() then return false end
		if now < (data.NextGrenadeCheck or 0) then return false end

		data.NextGrenadeCheck = now + 1

		if now < (data.NextGrenade or 0) then return false end
		if IsValid(bot.FakeRagdoll) then return false end

		local target = mem.Target
		local tpos = mem.TargetPos

		if not IsValid(target) or not tpos then return false end

		-- Seen recently, hiding now: flush them out.
		local since = now - (mem.LastSeen or 0)

		if since < 1 or since > 8 then return false end

		local myPos = bot:GetPos()
		local d = myPos:Distance(tpos)

		if d < hg_bot_grenade_min:GetFloat() or d > hg_bot_grenade_max:GetFloat() then return false end
		if math.abs(tpos.z - myPos.z) > 300 then return false end

		-- Don't frag our own.
		for other in pairs(hg.bots.List) do
			if other ~= bot and IsValid(other) and other:Alive() and other:GetPos():DistToSqr(tpos) < 280 * 280 then
				return false
			end
		end

		if math.random() > hg_bot_grenade_chance:GetFloat() then return false end

		local nade = hg.bots.FindGrenade(bot)

		if not nade then return false end

		local plan = hg.bots.PlanThrow(bot, tpos)

		if not plan then return false end

		data.GrenadeClass = nade:GetClass()
		data.GrenadePlan = plan
		data.GrenadeTargetPos = tpos

		local active = bot:GetActiveWeapon()

		data.GrenadePrevClass = IsValid(active) and active:GetClass() or nil

		hg.bots.SetState(bot, "grenade")

		return true
	end
--//

--\\ Throw state
	local function Finish(bot, data)
		data.NextGrenade = CurTime() + hg_bot_grenade_cooldown:GetFloat() * math.Rand(0.8, 1.3)
		data.GrenadeStage = "done"
	end

	hg.bots.RegisterState("grenade", {
		Enter = function(bot, data)
			data.Attacking = false
			data.AttackingSecondary = false
			data.Reloading = false
			data.Running = false
			data.Crouching = false
			data.AimSpeed = 500

			if hg.bots.ClearPath then hg.bots.ClearPath(data) end

			data.GrenadeStage = "select"
			data.GrenadeT = CurTime()

			if data.GrenadeClass then bot:SelectWeapon(data.GrenadeClass) end
		end,

		Leave = function(bot, data)
			data.Attacking = false
			data.AttackingSecondary = false
			data.Reloading = false
			data.AimSpeed = nil
			data.GrenadeStage = nil
		end,

		Think = function(bot, data)
			local now = CurTime()

			data.NextStateThink = now + 0.05

			local wep = bot:GetActiveWeapon()
			local plan = data.GrenadePlan
			local stage = data.GrenadeStage

			local function ReturnToFight()
				bot.Bot.NextWeaponSwitch = 0

				if data.GrenadePrevClass and bot:HasWeapon(data.GrenadePrevClass) then
					bot:SelectWeapon(data.GrenadePrevClass)
				elseif hg.bots.EquipBestWeapon then
					hg.bots.EquipBestWeapon(bot)
				end

				local target = data.Memory.Target
				local want = IsValid(target) and target:Alive() and (hg.bots.PickReaction and hg.bots.PickReaction(bot) or "combat") or "idle"

				hg.bots.SetState(bot, want)
			end

			if not plan then
				ReturnToFight()
				return
			end

			-- Aim along the planned arc the whole time.
			data.LookPos = bot:EyePos() + plan.ang:Forward() * 1000

			if stage == "select" then
				if IsValid(wep) and wep:GetClass() == data.GrenadeClass and now - data.GrenadeT > 0.7 then
					data.GrenadeStage = "pull"
					data.GrenadeT = now
				elseif now - data.GrenadeT > 2.5 then
					Finish(bot, data)
				end

				return
			end

			if stage == "pull" then
				-- Hold the throw button: pin out, arm back.
				data.Attacking = not plan.low
				data.AttackingSecondary = plan.low

				if IsValid(wep) and wep.ReadyToThrow then
					data.GrenadeStage = "aim"
					data.GrenadeT = now
				elseif now - data.GrenadeT > 3 or not IsValid(wep) or wep:GetClass() ~= data.GrenadeClass then
					data.GrenadeStage = "abort"
				end

				return
			end

			if stage == "aim" then
				data.Attacking = not plan.low
				data.AttackingSecondary = plan.low

				local e = bot:EyeAngles()
				local err = math.abs(math.AngleDifference(e.p, plan.ang.p)) + math.abs(math.AngleDifference(e.y, plan.ang.y))

				if err < 2 or now - data.GrenadeT > 1 then
					data.GrenadeStage = "release"
					data.GrenadeT = now
				end

				return
			end

			if stage == "release" then
				-- Let go: the weapon throws along the current aim.
				data.Attacking = false
				data.AttackingSecondary = false

				local thrown = not IsValid(wep) or wep:GetClass() ~= data.GrenadeClass
					or (now - data.GrenadeT > 0.3 and not wep.InThrowing and not wep.ReadyToThrow)

				if thrown or now - data.GrenadeT > 2.5 then
					Finish(bot, data)
				end

				return
			end

			if stage == "abort" then
				-- Pin back in before doing anything else - switching away
				-- with it out would drop a live grenade at our feet.
				data.Attacking = false
				data.AttackingSecondary = false

				if IsValid(wep) and wep.ReadyToThrow and now - data.GrenadeT < 4 then
					data.Reloading = true
					return
				end

				data.Reloading = false
				Finish(bot, data)

				return
			end

			ReturnToFight()
		end,
	})
--//

--\\ Dodging
	local live = {} -- [grenade entity] = true
	local seenBy = {} -- [grenade] = { [bot] = react-at time }

	local function IsDangerousClass(c)
		if c == "ent_hg_molotov" then return true end

		return string.StartWith(c, "ent_hg_grenade") and not string.find(c, "smoke", 1, true)
	end

	hook.Add("OnEntityCreated", "HG_Bots_TrackGrenades", function(ent)
		timer.Simple(0, function()
			if IsValid(ent) and IsDangerousClass(ent:GetClass()) then
				live[ent] = true
			end
		end)
	end)

	local function IsArmed(g)
		if g.Exploded then return false end
		if g:GetClass() == "ent_hg_molotov" then return g:GetVelocity():LengthSqr() > 50 * 50 end

		return isnumber(g.timer)
	end

	local function FuseLeft(g, now)
		if isnumber(g.timer) and isnumber(g.timeToBoom) then
			return g.timer + g.timeToBoom - now
		end

		return 2
	end

	local function DangerRadius(g)
		if g:GetClass() == "ent_hg_molotov" then return 260 end

		return hg_bot_grenade_danger:GetFloat()
	end

	--- Can the bot see (or right next to it, hear) the grenade?
	local function Notices(bot, g, dist)
		if dist < 170 then return true end

		local eye = hg.bots.GetEyePos and hg.bots.GetEyePos(bot) or bot:EyePos()
		local to = g:GetPos() - eye
		local len = to:Length()

		if len < 1 then return true end
		if bot:EyeAngles():Forward():Dot(to / len) < -0.2 then return false end -- behind it

		local tr = util.TraceLine({
			start = eye,
			endpos = g:GetPos(),
			filter = { bot, bot.FakeRagdoll, g },
			mask = MASK_VISIBLE,
		})

		return not tr.Hit
	end

	local nextDodgeScan = 0

	hook.Add("Think", "HG_Bots_GrenadeDodge", function()
		local now = CurTime()

		if now < nextDodgeScan or not next(live) then return end

		nextDodgeScan = now + 0.1

		if not hg_bot_grenade_dodge:GetBool() then return end

		for g in pairs(live) do
			if not IsValid(g) or g.Exploded then
				live[g] = nil
				seenBy[g] = nil
				continue
			end

			if not IsArmed(g) then continue end

			local gpos = g:GetPos()
			local radius = DangerRadius(g)
			local r2 = radius * radius

			seenBy[g] = seenBy[g] or {}

			for bot in pairs(hg.bots.List) do
				local data = IsValid(bot) and bot:Alive() and bot.Bot

				if not data or not data.Enabled or IsValid(bot.FakeRagdoll) then continue end
				local d2 = bot:GetPos():DistToSqr(gpos)

				if data.State == "evadegrenade" then continue end

				-- Mid-throw only a grenade that ended up right here matters
				-- (a fumbled throw / bounce back), not our own in flight.
				if data.State == "grenade" and d2 > 250 * 250 then continue end

				if d2 > r2 then continue end

				local react = seenBy[g][bot]

				if not react then
					if d2 < 150 * 150 then
						-- Right at our feet: no hesitation.
						seenBy[g][bot] = now
						react = now
					elseif Notices(bot, g, math.sqrt(d2)) then
						-- Human reaction time before bolting.
						seenBy[g][bot] = now + math.Rand(0.15, 0.45)
					end
				end

				if react and now >= react then
					data.EvadeGrenade = g
					hg.bots.SetState(bot, "evadegrenade")
				end
			end
		end
	end)

	--- Where to run: cover out of the grenade's sight, else straight away.
	local function PickEscape(bot, data, g)
		local gpos = g:GetPos()
		local radius = DangerRadius(g)
		local opts = { avoidPos = gpos, avoidRadius = radius, avoidWeight = 4, force = true }

		local cover = hg.bots.FindCoverPoint and hg.bots.FindCoverPoint(bot, gpos, radius + 250)

		if cover and cover:DistToSqr(gpos) > 200 * 200 and hg.bots.SetGoal(bot, cover, opts) then
			return
		end

		local away = bot:GetPos() - gpos
		away.z = 0

		if away:LengthSqr() < 1 then away = Vector(math.Rand(-1, 1), math.Rand(-1, 1), 0) end

		away:Normalize()

		local dest = bot:GetPos() + away * (radius + 100)
		local snapped = hg.bots.SnapToNavmesh and hg.bots.SnapToNavmesh(dest, 300) or dest

		if not hg.bots.SetGoal(bot, snapped, opts) then
			-- No route: just run straight away from it.
			if hg.bots.ClearPath then hg.bots.ClearPath(data) end

			data.Path = { bot:GetPos() + away * 300 }
			data.PathFlags = { 0 }
			data.PathIndex = 1
			data.Goal = data.Path[1]
		end
	end

	--- Direct sprint away from the grenade (no pathfinding delay): the
	-- clearest of a few directions roughly away from it, checked for walls
	-- and ledges.
	RunStraightAway = function(bot, data, g)
		local pos = bot:GetPos()
		local away = pos - g:GetPos()
		away.z = 0

		if away:LengthSqr() < 1 then away = Vector(math.Rand(-1, 1), math.Rand(-1, 1), 0) end

		away:Normalize()

		for _, yaw in ipairs({ 0, 30, -30, 60, -60, 90, -90 }) do
			local dir = Vector(away.x, away.y, 0)
			dir:Rotate(Angle(0, yaw, 0))

			local dest = pos + dir * 320

			if (not hg.bots.IsSegmentClear or hg.bots.IsSegmentClear(pos, dest, bot))
				and (not hg.bots.IsSegmentWalkable or hg.bots.IsSegmentWalkable(pos, dest, bot))
			then
				if hg.bots.ClearPath then hg.bots.ClearPath(data) end

				data.Path = { dest }
				data.PathFlags = { 0 }
				data.PathIndex = 1
				data.Goal = dest

				return true
			end
		end

		return false
	end

	--- Dive away from the grenade into a ragdoll, the way a player does it
	-- in Z-City: a jump with momentum, then "fake". hg.Ragdoll_Create gives
	-- the new ragdoll the player's current velocity (phys:SetVelocity(
	-- ply:GetVelocity())), so the push below becomes the dive; downed
	-- handling gets the bot back up afterwards.
	local function Dive(bot, data, gpos)
		local pos = bot:GetPos()
		local away = pos - gpos
		away.z = 0

		if away:LengthSqr() < 1 then away = Vector(math.Rand(-1, 1), math.Rand(-1, 1), 0) end

		away:Normalize()

		-- Straight away if the way is clear, else the clearest diagonal.
		local chosen

		for _, yaw in ipairs({ 0, 35, -35, 70, -70, 110, -110 }) do
			local dir = Vector(away.x, away.y, 0)
			dir:Rotate(Angle(0, yaw, 0))

			local tr = util.TraceHull({
				start = pos + Vector(0, 0, 20),
				endpos = pos + Vector(0, 0, 20) + dir * 120,
				mins = Vector(-14, -14, 0),
				maxs = Vector(14, 14, 40),
				filter = bot,
				mask = MASK_PLAYERSOLID,
			})

			if not tr.Hit then
				chosen = dir
				break
			end
		end

		chosen = chosen or away

		data.GrenadeDived = true
		data.LookPos = pos + chosen * 200

		-- Stay down through the blast (sv_bot_downed.lua honors this).
		local g = data.EvadeGrenade
		local fuse = IsValid(g) and isnumber(g.timer) and isnumber(g.timeToBoom) and (g.timer + g.timeToBoom - CurTime()) or 1

		data.StayDownUntil = CurTime() + math.max(fuse, 0) + 0.6

		-- Player:SetVelocity adds to the current velocity.
		bot:SetVelocity(chosen * hg_bot_grenade_dive_speed:GetFloat() + Vector(0, 0, 230))

		timer.Simple(0.06, function()
			if IsValid(bot) and bot:Alive() and not IsValid(bot.FakeRagdoll) and hg.Fake then
				hg.Fake(bot)
			end
		end)
	end

	hg.bots.RegisterState("evadegrenade", {
		Enter = function(bot, data)
			data.Attacking = false
			data.AttackingSecondary = false
			data.Running = true
			data.Crouching = false
			data.AimSpeed = nil
			data.LookPos = nil
			data.EvadeStart = CurTime()
			data.EvadeGoneAt = nil
			data.EvadeRepick = 0
			data.GrenadeDived = nil

			local g = data.EvadeGrenade

			if IsValid(g) then
				-- Close to it: sprint straight away first (the first thing
				-- that matters is distance), look for cover once running.
				if bot:GetPos():DistToSqr(g:GetPos()) < 260 * 260 and RunStraightAway(bot, data, g) then
					data.EvadeRepick = CurTime() + 0.7
				else
					PickEscape(bot, data, g)
				end
			end
		end,

		Leave = function(bot, data)
			data.Running = false
			data.Crouching = false
			data.EvadeGrenade = nil
		end,

		Think = function(bot, data)
			local now = CurTime()

			data.NextStateThink = now + 0.05

			local g = data.EvadeGrenade

			local function Back()
				local target = data.Memory.Target
				local want = IsValid(target) and target:Alive() and (hg.bots.PickReaction and hg.bots.PickReaction(bot) or "combat") or "idle"

				hg.bots.SetState(bot, want)
			end

			if not IsValid(g) or g.Exploded then
				data.EvadeGoneAt = data.EvadeGoneAt or now

				-- Stay down a moment for the blast/fragments, then go on.
				data.Crouching = true
				data.MoveTarget = nil

				if now - data.EvadeGoneAt > 0.4 then Back() end

				return
			end

			if now - data.EvadeStart > 8 then Back() return end

			local gpos = g:GetPos()
			local radius = DangerRadius(g)
			local dist = bot:GetPos():Distance(gpos)
			local eye = bot:EyePos()

			local hidden = util.TraceLine({
				start = eye,
				endpos = gpos + Vector(0, 0, 6),
				filter = { bot, g },
				mask = MASK_SOLID_BRUSHONLY,
			}).Hit

			local safe = dist > radius + 60 or (hidden and dist > 220)

			if safe then
				-- Out of it: get low and wait for the bang.
				data.Running = false
				data.Crouching = true
				data.MoveTarget = nil

				if hg.bots.ClearPath then hg.bots.ClearPath(data) end

				return
			end

			-- About to go off and we're still in it: dive clear (frag only -
			-- a molotov has no fuse, running is the answer there).
			local fuse = FuseLeft(g, now)

			if hg_bot_grenade_dive:GetBool() and not data.GrenadeDived and isnumber(g.timer)
				and fuse < hg_bot_grenade_dive_time:GetFloat() and fuse > 0.05
				and bot:IsOnGround() and hg.Fake
			then
				Dive(bot, data, gpos)
				return
			end

			-- Fuse nearly out and still exposed: hit the deck.
			if fuse < 0.5 then
				data.Running = false
				data.Crouching = true
				data.MoveTarget = nil

				return
			end

			data.Running = true
			data.Crouching = false

			-- The grenade rolled, or the route ran out: pick again. Never
			-- stand still while exposed - straight away if nothing better.
			if hg.bots.FollowPath and hg.bots.FollowPath(bot, data) then
				if now >= (data.EvadeRepick or 0) then
					data.EvadeRepick = now + 0.5
					PickEscape(bot, data, g)
				end

				if not data.Path and not data.PendingGoal then
					RunStraightAway(bot, data, g)
				end
			end
		end,
	})
--//
