--[[
	Tarkov AI - Combat

	Aggressive by design: any human player the bot has registered (see
	sv_bot_perception.lua - detection is accumulated, not instant) is
	treated as hostile. CheckThreatReaction below doesn't gate on
	alertness or distance, only on "is there a live Memory.Target".

	Engagement (target visible):
	- Aim turns at a limited, human-ish rate (core's data.AimSpeed) with
	  distance-scaled wobble that grows under suppression. The trigger is
	  only pulled once the view is actually on target (aim tolerance), so
	  bots no longer spray while still swinging round.
	- Chasing leads the target: the bot paths to where the target will be
	  (hg.bots.PredictPosition), not where it was, so it cuts corners
	  instead of trailing behind.
	- In range: flanks (FindFlankPoint) / strafes as before.
	- Tactical retreat: backs off from a firearm target that got too close,
	  moves to cover while reloading, and crouches in place when heavily
	  suppressed.

	Being shot at without seeing the shooter:
	- No longer runs straight at the bullet source. Faces the estimated
	  shooter position, takes cover (threat-aware path) or sidesteps, and
	  only starts hunting once the fire stops.

	Lost sight (search):
	- Goes to the predicted position (last seen position + last seen
	  velocity), not just the last seen spot - people keep moving after
	  they break line of sight.
	- Then checks a few hiding spots nearby, biased along the direction the
	  target was moving (hg.bots.GetSearchPoints), scanning at each.
	- A noise from the target (perception updates mem.TargetPos) restarts
	  the hunt toward the new position.
	- Gives up after hg_bot_seek_look_time and actually forgets the target.

	Fire/reload ride on hg's own weapon logic: PrimaryAttack fires off
	IN_ATTACK and Reload() off IN_RELOAD, set via data.Attacking /
	data.Reloading through the movement bridge in sv_bot_core.lua.

	Rack/chamber (bolt-action rifles, pump shotguns and similar), confirmed
	against the actual weapon base, not guessed:
	- SWEP.AutomaticDraw = false marks a "needs manual racking" weapon
	  (Mosin, KAR98, Remington 870, M590A1, TOZ106, PTRD). Ordinary weapons
	  re-chamber automatically inside PrimaryShoot. Revolvers don't
	  override AutomaticDraw (double-action - no rack step).
	- Firing with drawBullet false only dry-clicks (PrimaryShootEmpty). The
	  manual-action weapons override SWEP:Reload() with `if self.drawBullet
	  == false then cock(self) return end` BEFORE checking ammo - racking
	  is a RELOAD input. Holding IN_RELOAD is correct either way.
]]

hg.bots = hg.bots or {}

-- Z-City's loader doesn't guarantee sv_bot_core.lua (RegisterState) runs
-- first - redeclare defensively; `or` keeps core's real function.
hg.bots.States = hg.bots.States or {}
hg.bots.RegisterState = hg.bots.RegisterState or function(name, tbl) hg.bots.States[name] = tbl end

local hg_bot_burst_on_min  = CreateConVar("hg_bot_burst_on_min",  "0.3",  {FCVAR_ARCHIVE}, "Min seconds a bot holds the trigger per burst", 0.05, 3)
local hg_bot_burst_on_max  = CreateConVar("hg_bot_burst_on_max",  "1.0",  {FCVAR_ARCHIVE}, "Max seconds a bot holds the trigger per burst", 0.05, 3)
local hg_bot_burst_off_min = CreateConVar("hg_bot_burst_off_min", "0.1",  {FCVAR_ARCHIVE}, "Min seconds a bot pauses between bursts", 0.05, 3)
local hg_bot_burst_off_max = CreateConVar("hg_bot_burst_off_max", "0.4",  {FCVAR_ARCHIVE}, "Max seconds a bot pauses between bursts", 0.05, 3)
local hg_bot_aim_turnspeed = CreateConVar("hg_bot_aim_turnspeed", "180",  {FCVAR_ARCHIVE}, "Base aim turn speed in degrees/second", 30, 1000)
local hg_bot_aim_jitter    = CreateConVar("hg_bot_aim_jitter",    "0.02", {FCVAR_ARCHIVE}, "Aim wobble as a fraction of distance to target", 0, 0.2)
local hg_bot_aim_tolerance = CreateConVar("hg_bot_aim_tolerance", "28",   {FCVAR_ARCHIVE}, "Bots only fire once their aim is within this many units of the aim point (converted to an angle by distance, min 3 degrees)", 4, 200)
local hg_bot_engage_dist   = CreateConVar("hg_bot_engage_dist",   "250",  {FCVAR_ARCHIVE}, "Bots stop closing distance once this near their target - still fires at any range with LOS", 32, 4000)
local hg_bot_backoff_frac  = CreateConVar("hg_bot_backoff_frac",  "0.45", {FCVAR_ARCHIVE}, "With a firearm, a bot backs off when the target is closer than this fraction of engage distance (0 disables)", 0, 1)
local hg_bot_chase_lead    = CreateConVar("hg_bot_chase_lead",    "1.2",  {FCVAR_ARCHIVE}, "Max seconds of target movement a chasing bot leads (intercepts) by", 0, 4)
local hg_bot_reload_cover  = CreateConVar("hg_bot_reload_cover",  "1",    {FCVAR_ARCHIVE}, "Move to cover while reloading if the target is visible and close", 0, 1)
local hg_bot_seek_arrive_dist = CreateConVar("hg_bot_seek_arrive_dist", "80",  {FCVAR_ARCHIVE}, "How close a bot gets to a search point before it stops and looks around", 16, 400)
local hg_bot_seek_look_time   = CreateConVar("hg_bot_seek_look_time",   "14",  {FCVAR_ARCHIVE}, "Total seconds a bot searches for a lost target before giving up", 1, 120)
local hg_bot_seek_points      = CreateConVar("hg_bot_seek_points",      "3",   {FCVAR_ARCHIVE}, "How many nearby hiding spots a bot checks after reaching the last known position", 0, 10)
local hg_bot_seek_turnspeed   = CreateConVar("hg_bot_seek_turnspeed",   "110", {FCVAR_ARCHIVE}, "Aim turn speed (deg/sec) while scanning during a search", 10, 500)
local hg_bot_seek_lead        = CreateConVar("hg_bot_seek_lead",        "2.5", {FCVAR_ARCHIVE}, "Seconds of movement a bot carries a lost target on for, when working out where to search (they keep running after breaking line of sight)", 0, 6)
local hg_bot_slice            = CreateConVar("hg_bot_slice",            "1",   {FCVAR_ARCHIVE}, "Open corners sideways (slice the pie) instead of walking straight out of the same corner the target disappeared round", 0, 1)
local hg_bot_slice_range      = CreateConVar("hg_bot_slice_range",      "700", {FCVAR_ARCHIVE}, "Distance to the searched spot within which a bot opens the angle sideways", 100, 3000)
local hg_bot_slice_time       = CreateConVar("hg_bot_slice_time",       "4",   {FCVAR_ARCHIVE}, "Max seconds spent opening one corner before just moving in", 0.5, 15)
local hg_bot_suppress         = CreateConVar("hg_bot_suppress",         "1",   {FCVAR_ARCHIVE}, "Fire on the last known enemy position to keep their head down", 0, 1)
local hg_bot_suppress_range   = CreateConVar("hg_bot_suppress_range",   "1400",{FCVAR_ARCHIVE}, "Max distance for suppressing fire", 100, 6000)
local hg_bot_suppress_min_clip= CreateConVar("hg_bot_suppress_min_clip","0.35",{FCVAR_ARCHIVE}, "Fraction of the magazine a bot keeps in reserve rather than spending on suppression", 0, 1)
local hg_bot_prone            = CreateConVar("hg_bot_prone",            "1",   {FCVAR_ARCHIVE}, "Bots can go prone (Z-City ragdoll) and shoot from the floor at range", 0, 1)
local hg_bot_prone_dist       = CreateConVar("hg_bot_prone_dist",       "450", {FCVAR_ARCHIVE}, "Minimum distance to the target for going prone", 100, 4000)
local hg_bot_prone_supp       = CreateConVar("hg_bot_prone_supp",       "0.45",{FCVAR_ARCHIVE}, "Suppression level (incoming fire) at which going prone is considered", 0, 1)
local hg_bot_prone_chance     = CreateConVar("hg_bot_prone_chance",     "0.4", {FCVAR_ARCHIVE}, "Chance a bot goes prone rather than crouching when pinned at range", 0, 1)
local hg_bot_prone_time       = CreateConVar("hg_bot_prone_time",       "9",   {FCVAR_ARCHIVE}, "Base seconds a bot stays prone before getting up", 1, 60)

-- Filled in by sv_bot_melee.lua if present.
hg.bots.CheckCloseQuarters = hg.bots.CheckCloseQuarters or function() return false end

local IsGunWeapon, EndCareful, CarefulAdvance -- defined in the Search section
local ProjectLost, SlicePie -- defined in the Search section, used by it above their bodies

--\\ Shared weapon servicing
	--- Drives reload/rack/trigger for a bot that currently wants to shoot.
	-- Shared with sv_bot_downed.lua and the hold state.
	-- @param mayFire boolean whether the bot actually has a shot right now -
	--        reload/rack still proceed when false, only the trigger is withheld.
	-- @return boolean true if the trigger is being held this tick.
	function hg.bots.ServiceWeapon(bot, data, wep, mayFire)
		if not IsValid(wep) or not wep:IsWeapon() then
			data.Attacking = false
			return false
		end

		-- Reload/rack: hold IN_RELOAD until both signals clear. wep.reload
		-- is the mag-fed path; wep.drawBullet == false is the manual-action
		-- "round in mag but not chambered" state (nil is different: nothing
		-- to chamber at all).
		if data.Reloading then
			data.Attacking = false

			if not wep.reload and wep.drawBullet ~= false then
				data.Reloading = false
			end

			return false
		end

		-- Clip1() == -1: no magazine concept (melee, hands).
		local clip = wep:Clip1()
		local hasClip = clip >= 0
		local needsAmmo = hasClip and clip <= 0
		local needsRack = wep.drawBullet == false

		if needsAmmo or needsRack then
			data.Attacking = false

			if hasClip then
				-- Racking doesn't consume reserve ammo - only gate a real
				-- empty-mag reload on it.
				if needsRack or bot:GetAmmoCount(wep:GetPrimaryAmmoType()) > 0 then
					data.Reloading = true

					if hg.bots.Say then hg.bots.Say(bot, "weap_reload") end
				elseif hg.bots.Say then
					-- Empty mag, nothing left in the pockets.
					hg.bots.Say(bot, "need_ammo")
				end
			end

			return false
		end

		if not mayFire then
			data.Attacking = false

			return false
		end

		-- Irregular burst pattern instead of a perfectly held trigger.
		if CurTime() >= (data.NextBurstChange or 0) then
			data.BurstOn = not data.BurstOn

			local lo, hi = hg_bot_burst_off_min, hg_bot_burst_off_max

			if data.BurstOn then
				lo, hi = hg_bot_burst_on_min, hg_bot_burst_on_max
			end

			data.NextBurstChange = CurTime() + math.Rand(lo:GetFloat(), hi:GetFloat())
		end

		data.Attacking = data.BurstOn

		return data.BurstOn
	end

	--- Angle (degrees) between the bot's current view and aimPos.
	function hg.bots.GetAimError(bot, eyePos, aimPos)
		local dir = aimPos - eyePos
		local len = dir:Length()

		if len < 1 then return 0, len end

		local dot = bot:EyeAngles():Forward():Dot(dir / len)

		return math.deg(math.acos(math.Clamp(dot, -1, 1))), len
	end

	--- Allowed aim error (degrees) at a given distance.
	function hg.bots.GetAimTolerance(dist)
		return math.max(3, math.deg(math.atan(hg_bot_aim_tolerance:GetFloat() / math.max(dist, 1))))
	end
--//
local hg_bot_reposition_min = CreateConVar("hg_bot_reposition_min", "0.5", {FCVAR_ARCHIVE}, "Min seconds between in-combat reposition picks once within engage distance", 0.1, 5)
local hg_bot_reposition_max = CreateConVar("hg_bot_reposition_max", "1.4", {FCVAR_ARCHIVE}, "Max seconds between in-combat reposition picks once within engage distance", 0.1, 5)
local hg_bot_strafe_dist_min = CreateConVar("hg_bot_strafe_dist_min", "120", {FCVAR_ARCHIVE}, "Min lateral distance for in-combat repositioning", 16, 1000)
local hg_bot_strafe_dist_max = CreateConVar("hg_bot_strafe_dist_max", "320", {FCVAR_ARCHIVE}, "Max lateral distance for in-combat repositioning", 16, 1000)

--\\ Aim
	-- Continuously-varying offset scaled by range and suppression.
	local function GetAimJitter(bot, dist, suppression)
		local spread = math.Clamp(dist * hg_bot_aim_jitter:GetFloat(), 1, 60) * (1 + (suppression or 0) * 1.5)
		local t = CurTime() * 6 + bot:EntIndex() * 13

		return Vector(
			math.sin(t) * spread,
			math.cos(t * 1.3) * spread,
			math.sin(t * 0.7) * spread * 0.5
		)
	end

	local function ResetAimSpeed(data)
		data.AimSpeed = hg_bot_aim_turnspeed:GetFloat() * math.Rand(0.8, 1.2)
	end
--//

--\\ Positioning helpers
	-- Angles relative to the TARGET's forward facing - end up where the
	-- target isn't looking. Widest/rear first; no frontal angles.
	local FLANK_ANGLES = { 180, 150, -150, 130, -130, 100, -100 }

	--- Nearby LOS-clear point outside the target's forward cone at
	-- roughly `radius` from the target, or nil.
	local function FindFlankPoint(bot, target, radius)
		local char = hg.bots.GetCharacter and hg.bots.GetCharacter(target) or target
		local origin = char:GetPos()
		local fwd = target:EyeAngles():Forward()
		fwd.z = 0

		if fwd:Length() < 0.1 then return nil end

		fwd:Normalize()

		local targetEye = target:EyePos()

		for _, angle in ipairs(FLANK_ANGLES) do
			local dir = Vector(fwd.x, fwd.y, 0)
			dir:Rotate(Angle(0, angle, 0))

			local candidate = origin + dir * radius

			local floorTr = util.TraceLine({
				start = candidate + Vector(0, 0, 32),
				endpos = candidate - Vector(0, 0, 64),
				filter = bot,
				mask = MASK_NPCSOLID_BRUSHONLY,
			})

			if floorTr.Hit then
				local groundPos = floorTr.HitPos + Vector(0, 0, 4)

				if hg.bots.SnapToNavmesh then
					local snapped = hg.bots.SnapToNavmesh(groundPos, 120)

					if not snapped then continue end

					groundPos = snapped + Vector(0, 0, 4)
				end

				local losTr = util.TraceLine({
					start = groundPos + Vector(0, 0, 64),
					endpos = targetEye,
					filter = { bot, target, char },
					mask = MASK_VISIBLE,
				})

				if not losTr.Hit then
					return groundPos
				end
			end
		end

		return nil
	end

	--- Point `dist` units from the bot directly away from `from`, only if
	-- the ground holds and nothing blocks. Tries slight angles too.
	local function FindBackoffPoint(bot, from, dist)
		local away = bot:GetPos() - from
		away.z = 0

		if away:LengthSqr() < 1 then return nil end

		away:Normalize()

		local pos = bot:GetPos()

		for _, yaw in ipairs({ 0, 35, -35, 70, -70 }) do
			local dir = Vector(away.x, away.y, 0)
			dir:Rotate(Angle(0, yaw, 0))

			local p = pos + dir * dist

			if (not hg.bots.IsSegmentClear or hg.bots.IsSegmentClear(pos, p, bot))
				and hg.bots.IsSegmentWalkable(pos, p, bot)
			then
				return p
			end
		end

		return nil
	end

	--- Lateral sidestep relative to a direction of threat.
	local function FindSidestepPoint(bot, towardPos, dist)
		local to = towardPos - bot:GetPos()
		to.z = 0

		if to:LengthSqr() < 1 then return nil end

		to:Normalize()

		local lateral = to:Cross(Vector(0, 0, 1)) * ((math.random(0, 1) == 0) and 1 or -1)
		local pos = bot:GetPos()

		for _, sign in ipairs({ 1, -1 }) do
			local p = pos + lateral * sign * dist

			if (not hg.bots.IsSegmentClear or hg.bots.IsSegmentClear(pos, p, bot))
				and hg.bots.IsSegmentWalkable(pos, p, bot)
			then
				return p
			end
		end

		return nil
	end
--//

--\\ Search
	local SEEK_SCAN_YAWS = { 0, 65, -65, 130, -130 }

	local function ResetSeek(data)
		data.SeekStage = nil
		data.SeekSource = nil
		data.SeekGoal = nil
		data.SeekPoints = nil
		data.SeekPointIndex = nil
		data.SeekScanUntil = nil
		data.SeekScanIndex = nil
		data.NextSeekTurn = nil
		data.SeekBaseYaw = nil
		data.SeekStarted = nil
	end

	--- Scan in place at the current point for `dur` seconds. Returns true
	-- once the scan is finished.
	local function ScanHere(bot, data, now, dur)
		if not data.SeekScanUntil then
			data.SeekScanUntil = now + dur
			data.SeekScanIndex = 0
			data.NextSeekTurn = 0
			data.SeekBaseYaw = bot:EyeAngles().y
			data.AimSpeed = hg_bot_seek_turnspeed:GetFloat()
			hg.bots.ClearPath(data)
		end

		if now >= (data.NextSeekTurn or 0) then
			data.SeekScanIndex = (data.SeekScanIndex or 0) + 1
			data.NextSeekTurn = now + math.Rand(0.7, 1.2)

			local yaw = data.SeekBaseYaw + SEEK_SCAN_YAWS[((data.SeekScanIndex - 1) % #SEEK_SCAN_YAWS) + 1]

			data.LookPos = bot:EyePos() + Angle(0, yaw, 0):Forward() * 300
		end

		if now >= data.SeekScanUntil then
			data.SeekScanUntil = nil
			return true
		end

		return false
	end

	--- Walk toward pos, looking ahead at it. Returns true once arrived.
	local function MoveTo(bot, data, pos)
		local arriveSqr = hg_bot_seek_arrive_dist:GetFloat() ^ 2

		if bot:GetPos():DistToSqr(pos) <= arriveSqr then return true end

		data.SeekScanUntil = nil
		data.Running = bot:GetPos():DistToSqr(pos) > 450 * 450 -- sprint the long way, slow down near where they might be
		-- Face the way we walk while the destination is still far (the
		-- path bends round corners); look at the spot itself on approach.
		data.LookPos = bot:GetPos():DistToSqr(pos) < 350 * 350 and (pos + Vector(0, 0, 56)) or nil
		data.AimSpeed = nil -- default walking turn rate

		if not data.Goal or data.Goal:DistToSqr(pos) > 64 ^ 2 then
			if not hg.bots.SetGoal(bot, pos) then
				return true -- unreachable - treat as "checked"
			end
		end

		if hg.bots.FollowPath(bot, data) then return true end

		return false
	end

	--- Target not visible and not under fire: hunt for them.
	local function UpdateSeeking(bot, data, mem, now)
		local src = mem.TargetPos

		if not src then
			hg.bots.SetState(bot, hg.bots.States.alert and "alert" or "idle")
			return
		end

		-- Keeps perception from forgetting the target mid-search; the
		-- search's own timer below decides when to give up.
		mem.ContactHold = now

		-- New information (a fresh sighting before this, or the target
		-- was heard somewhere) restarts the hunt from that position.
		if data.SeekSource ~= src then
			ResetSeek(data)

			-- Fresh info restarts the search clock too: hearing the target
			-- again is a reason to keep hunting.
			data.SeekSource = src
			data.SeekStarted = now
			data.SeekStage = "goto"

			-- Lead: people keep moving after they break line of sight,
			-- usually all the way down the corridor they turned into.
			data.SeekGoal = ProjectLost(bot, mem, hg_bot_seek_lead:GetFloat()) or src
			data.SliceUntil = nil
			data.SliceDir = nil
		end

		data.Crouching = false

		if now - (data.SeekStarted or now) > hg_bot_seek_look_time:GetFloat() * (data.SeekCareful and 1.8 or 1) then
			-- Had a proper look, nobody's here - actually forget them.
			mem.Target = nil
			mem.TargetPos = nil
			mem.TargetSeenPos = nil
			mem.TargetVel = nil
			mem.ContactHold = nil
			data.AimSpeed = nil

			-- Lost them, but this was a fight a moment ago: weapon stays
			-- out and the bot keeps watching (sv_bot_alert.lua).
			hg.bots.SetState(bot, hg.bots.States.alert and "alert" or "idle")
			return
		end

		if data.SeekStage == "goto" then
			-- Open the corner from the side before stepping into it.
			if SlicePie(bot, data, mem, now) then return end

			data.Lean = 0

			if MoveTo(bot, data, data.SeekGoal) then
				data.SeekStage = "scan_lkp"
			end

			return
		end

		if data.SeekStage == "scan_lkp" then
			if ScanHere(bot, data, now, math.Rand(1.5, 2.5)) then
				local count = hg_bot_seek_points:GetInt()

				data.SeekPoints = (count > 0 and hg.bots.GetSearchPoints) and hg.bots.GetSearchPoints(data.SeekGoal, mem.TargetVel, count) or {}
				data.SeekPointIndex = 1
				data.SeekStage = "points"
			end

			return
		end

		if data.SeekStage == "points" then
			local point = data.SeekPoints and data.SeekPoints[data.SeekPointIndex]

			if not point then
				-- Nothing left to check - scan until the timer runs out.
				ScanHere(bot, data, now, 2)
				return
			end

			if data.SeekScanUntil then
				if ScanHere(bot, data, now, 1.5) then
					data.SeekPointIndex = data.SeekPointIndex + 1
				end

				return
			end

			if MoveTo(bot, data, point) then
				ScanHere(bot, data, now, math.Rand(1.2, 1.8))
			end
		end
	end

	--- Is wep a firearm (not melee, not hands)?
	IsGunWeapon = function(wep)
		if not IsValid(wep) or wep.GetFists then return false end
		if hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep) then return false end

		return wep.ishgweapon or wep:Clip1() >= 0
	end

	EndCareful = function(data)
		data.SeekCareful = nil
		data.SlowWalk = false
		data.Lean = 0
		data.PeekUntil = nil
		data.NextPeek = nil
		data.PrefireUntil = nil
		data.NextPrefire = nil
		data.AttackingSecondary = false
	end

	--- Careful push, layered on top of the search's movement: slow walk,
	-- aiming down sights at where the enemy is, the odd prefire burst at
	-- that spot, and every few seconds a stop to lean out (Z-City lean,
	-- toward the enemy's side) and check before moving on.
	CarefulAdvance = function(bot, data, mem, wep, now)
		data.Running = false
		data.SlowWalk = true
		data.Crouching = false
		data.AttackingSecondary = not data.Reloading
		data.AimSpeed = 200

		local look = hg.bots.GetWaitLookPos and hg.bots.GetWaitLookPos(bot) or (mem.TargetPos and mem.TargetPos + Vector(0, 0, 50))

		-- nil = far away and moving: face the direction of travel.
		data.LookPos = look

		-- Peek: stop, lean toward the side the enemy is on, look, go on.
		if data.PeekUntil then
			if now < data.PeekUntil then
				data.PauseMoveUntil = now + 0.15
			else
				data.PeekUntil = nil
				data.Lean = 0
				data.NextPeek = now + math.Rand(2.5, 5.5)
			end
		elseif now >= (data.NextPeek or now + 1) and look then
			local to = look - bot:EyePos()
			local side = to:Dot(bot:EyeAngles():Right()) >= 0 and -1 or 1 -- -1 = lean right

			if math.random() < 0.25 then side = -side end -- sometimes check the other side

			data.Lean = side
			data.PeekUntil = now + math.Rand(0.8, 1.5)
		end

		data.NextPeek = data.NextPeek or now + math.Rand(1.5, 3)

		-- Prefire: a short burst at where they probably are, now and then,
		-- only when that's reasonably close.
		if now >= (data.NextPrefire or now + 1.5) then
			data.NextPrefire = now + math.Rand(2.5, 5)

			if mem.TargetPos and bot:GetPos():DistToSqr(mem.TargetPos) < 1000 * 1000 and math.random() < 0.6 then
				data.PrefireUntil = now + math.Rand(0.12, 0.35)
			end
		end

		data.NextPrefire = data.NextPrefire or now + math.Rand(1.5, 3)

		hg.bots.ServiceWeapon(bot, data, wep, false) -- reload/rack housekeeping

		if now < (data.PrefireUntil or 0) and not data.Reloading and IsValid(wep) and wep:Clip1() > 0 then
			data.Attacking = true
		end
	end

	--- Line of sight from the bot's eyes to a spot (not to a player - this
	-- is used for places, e.g. the corner someone disappeared round).
	local function SpotVisible(bot, pos, height)
		local eye = hg.bots.GetEyePos and hg.bots.GetEyePos(bot) or bot:EyePos()

		local tr = util.TraceLine({
			start = eye,
			endpos = pos + Vector(0, 0, height or 40),
			filter = bot,
			mask = MASK_SHOT,
		})

		return tr.Fraction > 0.97
	end

	hg.bots.SpotVisible = SpotVisible

	--- Where someone who just broke line of sight probably is now: carried
	-- on along the velocity they had, stopped at the first wall and pulled
	-- back onto the navmesh. Without this a bot walks to the corner the
	-- target vanished at and searches THERE, while the target is already
	-- far down the corridor - and then meets them coming back.
	ProjectLost = function(bot, mem, maxTime)
		local src = mem.TargetSeenPos or mem.TargetPos

		if not src then return nil end

		local vel = mem.TargetVel

		if not vel or vel:Length2D() < 40 then return src end

		local flat = Vector(vel.x, vel.y, 0)
		local dest = src + flat * maxTime
		local up = Vector(0, 0, 36)

		local tr = util.TraceHull({
			start = src + up,
			endpos = dest + up,
			mins = Vector(-14, -14, -20),
			maxs = Vector(14, 14, 20),
			filter = bot,
			mask = MASK_PLAYERSOLID_BRUSHONLY,
		})

		local p = tr.HitPos - up

		if tr.Hit then p = p + tr.HitNormal * 24 end

		if navmesh and navmesh.IsLoaded and navmesh.IsLoaded() then
			local area = navmesh.GetNearestNavArea(p, false, 250, false, true)

			if area then p = area:GetClosestPointOnArea(p) end
		end

		return p
	end

	--- Slicing the pie: instead of walking straight into the opening the
	-- target disappeared into (and getting shot by someone waiting on the
	-- other side), circle sideways at the same distance so the corner opens
	-- up a bit at a time, aiming down sights at it the whole way.
	SlicePie = function(bot, data, mem, now)
		if not hg_bot_slice:GetBool() then return false end

		local goal = data.SeekGoal

		if not goal then return false end

		local pos = bot:GetPos()
		local dist = pos:Distance(goal)

		if dist > hg_bot_slice_range:GetFloat() or dist < 130 then return false end

		-- Already see the place: nothing left to open up.
		if SpotVisible(bot, goal, 40) then
			data.SliceUntil = nil
			data.Lean = 0

			return false
		end

		if data.SliceUntil and now > data.SliceUntil then return false end

		data.SliceUntil = data.SliceUntil or now + hg_bot_slice_time:GetFloat()
		data.SliceDir = data.SliceDir or (math.random() < 0.5 and 1 or -1)

		local fromGoal = pos - goal
		fromGoal.z = 0

		if fromGoal:LengthSqr() < 1 then return false end

		fromGoal:Normalize()

		for _, deg in ipairs({ 22 * data.SliceDir, 40 * data.SliceDir, -22 * data.SliceDir }) do
			local rot = Vector(fromGoal.x, fromGoal.y, 0)
			rot:Rotate(Angle(0, deg, 0))

			local p = goal + rot * dist
			p.z = pos.z

			if hg.bots.IsSegmentClear(pos, p, bot) and hg.bots.IsSegmentWalkable(pos, p, bot) then
				hg.bots.ClearPath(data)

				data.MoveTarget = p
				data.Running = false
				data.SlowWalk = true
				data.Crouching = false
				data.LookPos = goal + Vector(0, 0, 45)
				data.AimSpeed = 220
				data.AttackingSecondary = not data.Reloading -- ADS while opening the angle
				data.Lean = deg > 0 and -1 or 1 -- Z-City lean toward the side being checked

				return true
			end
		end

		-- Boxed in: give up on the arc and go the normal way.
		data.SliceUntil = now - 1
		data.Lean = 0

		return false
	end

	--- Suppressing fire: hose the last place the target was seen. It keeps
	-- their head down (and, with other bots around, buys the one that is
	-- pushing a free approach - see sv_bot_squad.lua). Only with a spot
	-- that can actually be hit from here, and never down to the last
	-- rounds: a dry magazine is worse than an unsuppressed enemy.
	-- @return true if this took over the weapon this tick
	local function UpdateSuppressFire(bot, data, mem, wep, now)
		if not hg_bot_suppress:GetBool() then return false end
		if not IsGunWeapon(wep) or data.Reloading then return false end

		local spot = mem.TargetSeenPos or mem.TargetPos

		if not spot then return false end
		if bot:GetPos():DistToSqr(spot) > hg_bot_suppress_range:GetFloat() ^ 2 then return false end

		local clip, maxClip = wep:Clip1(), wep:GetMaxClip1() or 0

		if clip <= 0 then return false end
		if maxClip > 0 and clip / maxClip < hg_bot_suppress_min_clip:GetFloat() then return false end
		if not SpotVisible(bot, spot, 40) then return false end

		if now >= (data.SuppressNext or 0) then
			data.SuppressNext = now + math.Rand(0.9, 2.2)
			data.SuppressUntil = now + math.Rand(0.25, 0.6)

			-- Spread the rounds over the opening, not at one pixel: this is
			-- fire at a place, not at a person.
			data.SuppressAim = spot + Vector(math.Rand(-28, 28), math.Rand(-28, 28), math.Rand(12, 55))
		end

		local aim = data.SuppressAim or (spot + Vector(0, 0, 45))
		local eye = hg.bots.GetEyePos and hg.bots.GetEyePos(bot) or bot:EyePos()

		data.LookPos = aim
		data.AimSpeed = 250

		local firing = now < (data.SuppressUntil or 0)
			and hg.bots.GetAimError(bot, eye, aim) <= 7
			and not (hg.bots.FriendlyInLine and hg.bots.FriendlyInLine(bot, aim))

		if hg.bots.MarkSuppressing then hg.bots.MarkSuppressing(bot, spot, firing) end

		hg.bots.ServiceWeapon(bot, data, wep, firing)

		return true
	end

	--- Go prone: drop into a Z-City ragdoll on purpose and keep shooting
	-- from the floor (sv_bot_downed.lua already aims the real barrel with E
	-- and fires from there). A tiny silhouette at range, but slow to get
	-- out of - hence the distance and cooldown conditions.
	local function TryProne(bot, data, wep, dist, suppression)
		if not hg_bot_prone:GetBool() then return false end
		if not hg.Fake or IsValid(bot.FakeRagdoll) then return false end
		if not bot:IsOnGround() or not IsGunWeapon(wep) then return false end
		if dist < hg_bot_prone_dist:GetFloat() then return false end
		if suppression < hg_bot_prone_supp:GetFloat() then return false end

		local now = CurTime()

		if now < (data.NextProneTry or 0) then return false end

		data.NextProneTry = now + 8

		if math.random() > hg_bot_prone_chance:GetFloat() then return false end

		data.Prone = true
		data.ProneUntil = now + hg_bot_prone_time:GetFloat() * math.Rand(0.7, 1.5)

		hg.Fake(bot)

		return IsValid(bot.FakeRagdoll)
	end

	--- Shot at by someone the bot can't see: face it, get out of the line
	-- of fire. Returns true while this reaction is in control.
	local function UpdateUnderFire(bot, data, mem, wep, now)
		local from = mem.UnderFireFrom

		if not from or now > (mem.UnderFireUntil or 0) then
			data.UnderFireCover = nil
			return false
		end

		local suppression = mem.Suppression or 0

		data.LookPos = from + Vector(0, 0, 56)
		ResetSeek(data)

		if not data.UnderFireCover or now > (data.UnderFireRepick or 0) then
			data.UnderFireRepick = now + 2.5

			local cover = hg.bots.FindCoverPoint and hg.bots.FindCoverPoint(bot, from, 700)

			if cover then
				data.UnderFireCover = cover
				hg.bots.SetGoal(bot, cover, { avoidPos = from, avoidRadius = 600, force = true })
			else
				data.UnderFireCover = FindSidestepPoint(bot, from, math.Rand(120, 220)) or bot:GetPos()
				hg.bots.SetGoal(bot, data.UnderFireCover)
			end
		end

		local arrived = hg.bots.FollowPath(bot, data)

		-- Sprint to cover; once there (or with nowhere to go), get low.
		data.Running = not arrived
		data.Crouching = arrived and suppression > 0.3

		-- No target in sight: nothing to shoot, but use the moment to
		-- reload/rack.
		hg.bots.ServiceWeapon(bot, data, wep, false)

		return true
	end
--//

--\\ Combat state
	hg.bots.RegisterState("combat", {
		Enter = function(bot, data)
			data.Attacking = false
			data.AttackingSecondary = false
			data.Reloading = false
			data.Running = false
			data.Crouching = false
			data.BurstOn = false
			data.NextBurstChange = 0
			data.NextReposition = nil
			data.ReloadCover = nil
			data.UnderFireCover = nil
			data.LostSightDecided = nil
			EndCareful(data)
			ResetAimSpeed(data)
			ResetSeek(data)

			-- Whatever the bot was doing before is irrelevant now.
			hg.bots.ClearPath(data)
		end,

		Leave = function(bot, data)
			data.Attacking = false
			data.AttackingSecondary = false
			data.Reloading = false
			data.Running = false
			data.Crouching = false
			data.AimSpeed = nil
			data.ReloadCover = nil
			data.UnderFireCover = nil
			EndCareful(data)
			ResetSeek(data)
		end,

		Think = function(bot, data)
			data.NextStateThink = CurTime() + 0.05

			local now = CurTime()
			local mem = data.Memory
			local target = mem.Target

			if not IsValid(target) or not target:Alive() then
				hg.bots.SetState(bot, "idle")
				return
			end

			-- Re-check gear/threat twice a second: a melee-only bot that
			-- ended up chasing a gunman at range should break off into an
			-- ambush; picking up a gun or the enemy dropping theirs flips
			-- things the other way. Only ambush is switched to from here -
			-- the flee decision keeps its existing triggers.
			if hg.bots.ChooseReaction and now >= (data.NextReactionCheck or 0) then
				data.NextReactionCheck = now + 0.5

				local want = hg.bots.ChooseReaction(bot)

				-- Flee is taken from here only when the bot has nothing left
				-- to fight with (empty gun, bare hands vs an armed enemy);
				-- the hurt-and-scared flee keeps its own triggers.
				if want == "ambush" or (want == "flee" and hg.bots.GetWeaponKind(bot, true) ~= "gun") then
					hg.bots.SetState(bot, want)
					return
				end
			end

			local wep = bot:GetActiveWeapon()

			if not IsValid(wep) or not wep:IsWeapon() then
				data.Attacking = false
				hg.bots.SetState(bot, "idle")
				return
			end

			-- Empty gun and no rounds for it: nothing to shoot and nothing
			-- to reload, so the gunfight branches below would just strafe on
			-- the spot forever. Swap to whatever is better (another gun, a
			-- blade, fists) right now instead of on the 3 s switch timer; the
			-- reaction check above then picks brawl or flee.
			if IsGunWeapon(wep) and not data.Reloading and hg.bots.GunHasAmmo and not hg.bots.GunHasAmmo(bot, wep) then
				data.Attacking = false
				data.AttackingSecondary = false

				if data.DryWeapon ~= wep then
					data.DryWeapon = wep
					data.DrySince = now
				end

				if now >= (data.DryCheckAt or 0) then
					data.DryCheckAt = now + 0.5
					data.NextWeaponSwitch = 0
					data.NextReactionCheck = 0

					if hg.bots.Say then hg.bots.Say(bot, "need_ammo") end

					hg.bots.EquipBestWeapon(bot)
				end

				-- Nothing else to switch to (or switching is off): stock-bash
				-- whoever is in reach, otherwise leave and go find something.
				if now - data.DrySince > 2 then
					local canSee = hg.bots.CanSee(bot, target)

					if canSee and hg.bots.CheckCloseQuarters(bot, data, wep, target, canSee) then return end

					if not hg.bots.CanRetreat or hg.bots.CanRetreat(bot) then
						hg.bots.SetState(bot, "flee")
						return
					end

					-- Can't run either: go in and club them with it.
					if mem.TargetPos and (not data.Goal or data.Goal:DistToSqr(mem.TargetPos) > 96 ^ 2) then
						hg.bots.SetGoal(bot, mem.TargetPos)
					end

					data.Running = not hg.bots.FollowPath(bot, data)

					return
				end

				-- Mid-swap: keep moving away from the line of fire, not
				-- standing in it.
				if not data.Path and mem.TargetPos then
					local p = FindBackoffPoint(bot, mem.TargetPos, math.Rand(150, 250))

					if p then hg.bots.SetGoal(bot, p, { force = true }) end
				end

				data.Running = not hg.bots.FollowPath(bot, data)

				return
			end

			local canSee, info = hg.bots.CanSee(bot, target)

			if not canSee then
				data.Attacking = false

				-- Enemy just ducked behind cover: flush them out with a
				-- grenade if we carry one (sv_bot_grenades.lua).
				if hg.bots.TryGrenade and hg.bots.TryGrenade(bot, data, mem, now) then return end

				if UpdateUnderFire(bot, data, mem, wep, now) then return end

				-- Just lost sight: push after them, or hold the angle and
				-- let them come back into the sights. Decided once per loss
				-- of contact; a bot that already waited for this target
				-- pushes next time instead of waiting forever.
				if not data.LostSightDecided then
					data.LostSightDecided = true

					local tactic = hg.bots.GetTactic and hg.bots.GetTactic(bot, target, true) or "push"

					-- Careful push: advance slowly, aiming down sights,
					-- with prefires and lean-peeks (see CarefulAdvance).
					data.SeekCareful = tactic == "careful" and IsGunWeapon(wep)

					if tactic == "wait" and data.WaitedFor ~= target and hg.bots.HoldPosition
						and hg.bots.GetWeaponKind and hg.bots.GetWeaponKind(bot, true) == "gun"
					then
						hg.bots.HoldPosition(bot, bot:GetPos(), mem.TargetPos)

						data.HoldResumeCombat = true
						data.HoldDuration = math.Rand(6, 12)

						return
					end
				end

				UpdateSeeking(bot, data, mem, now)

				if data.SeekCareful and data.State == "combat" then
					CarefulAdvance(bot, data, mem, wep, now)
				elseif not UpdateSuppressFire(bot, data, mem, wep, now) then
					hg.bots.ServiceWeapon(bot, data, wep, false)
				end

				return
			end

			local char = hg.bots.GetCharacter and hg.bots.GetCharacter(target) or target
			local targetPos = char:GetPos()
			local eye = hg.bots.GetEyePos and hg.bots.GetEyePos(bot) or bot:EyePos()

			mem.TargetPos = targetPos
			mem.TargetSeenPos = targetPos
			mem.TargetVel = char:GetVelocity()
			mem.LastSeen = now

			-- In contact again: the next loss of sight gets a fresh
			-- push / wait / careful decision.
			data.LostSightDecided = nil
			data.WaitedFor = nil
			EndCareful(data)

			-- Back from a search - restore combat aim speed and bookkeeping.
			if data.SeekStage then
				ResetSeek(data)
				ResetAimSpeed(data)
				hg.bots.ClearPath(data)
			end

			local dist = info and info.dist or eye:Distance(targetPos)
			local suppression = mem.Suppression or 0
			local aimPoint = (hg.bots.GetAimPoint and hg.bots.GetAimPoint(bot, target) or target:EyePos()) + GetAimJitter(bot, dist, suppression)

			data.LookPos = aimPoint

			-- Target in sight: the eyes stay on them whichever way the feet
			-- go. Without this the movement bridge hands the view to the
			-- path as soon as a sidestep / backoff point is more than 65
			-- degrees off the target - the bot turned away mid-fight and
			-- walked off to the side instead of shooting. Only a sprint to
			-- reload cover may turn its back (cleared in that branch).
			data.LookLock = true

			local engageDist = hg_bot_engage_dist:GetFloat()
			local isMelee = hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep)

			data.Crouching = false

			if data.Reloading and hg_bot_reload_cover:GetBool() and not isMelee and dist < 900 then
				-- Reloading in the open in front of someone is how you die:
				-- move to cover for the duration of the reload.
				if not data.ReloadCover then
					data.ReloadCover = hg.bots.FindCoverPoint and hg.bots.FindCoverPoint(bot, targetPos, 600) or false

					if data.ReloadCover then
						hg.bots.SetGoal(bot, data.ReloadCover, { avoidPos = targetPos, avoidRadius = 500, force = true })
					end
				end

				if data.ReloadCover then
					data.LookLock = nil
					data.Running = not hg.bots.FollowPath(bot, data)
				else
					data.Crouching = true -- nowhere to go - at least get small
				end
			elseif not isMelee and hg_bot_backoff_frac:GetFloat() > 0 and dist < engageDist * hg_bot_backoff_frac:GetFloat() then
				-- Too close for a firearm fight: back off while shooting.
				-- (Contact range is still handed to CheckCloseQuarters below.)
				data.ReloadCover = nil
				data.Running = false
				data.NextReposition = nil

				if not data.Path or hg.bots.FollowPath(bot, data) then
					local p = FindBackoffPoint(bot, targetPos, math.Rand(150, 250))

					if p then hg.bots.SetGoal(bot, p, { force = true }) end
				end
			elseif isMelee and dist <= engageDist then
				-- Melee inside engagement range: CheckCloseQuarters owns the
				-- movement (closing in / dueling) - no gunfight repositioning.
				data.ReloadCover = nil
			elseif hg.bots.ShouldStalk and hg.bots.ShouldStalk(bot, data, target, dist)
				and hg.bots.StalkTick(bot, data, target, dist)
			then
				-- Creeping up on somebody who hasn't spotted us yet
				-- (sv_bot_stealth.lua) instead of walking in openly.
				data.ReloadCover = nil
			elseif dist > engageDist then
				-- Chase, leading the target: path to where they'll be.
				data.ReloadCover = nil
				data.Running = true
				data.NextReposition = nil

				local lead = math.Clamp(dist / 400, 0, hg_bot_chase_lead:GetFloat())
				local chasePos = hg.bots.PredictPosition and hg.bots.PredictPosition(targetPos, mem.TargetVel, lead, bot) or targetPos

				if not data.Goal or data.Goal:DistToSqr(chasePos) > 96 ^ 2 then
					hg.bots.SetGoal(bot, chasePos)
				end

				hg.bots.FollowPath(bot, data)
			else
				data.ReloadCover = nil

				if suppression > 0.6 then
					-- Pinned: stay low and return fire rather than walking
					-- around in the open. At range, sometimes all the way
					-- down - prone in a ragdoll, shooting from the floor.
					hg.bots.ClearPath(data)

					if TryProne(bot, data, wep, dist, suppression) then return end

					data.Crouching = true
					data.Running = false
				else
					-- Just crossed into range: drop leftover chase waypoints.
					if not data.NextReposition then
						hg.bots.ClearPath(data)
					end

					local arrived = hg.bots.FollowPath(bot, data)

					if arrived or not data.NextReposition or now >= data.NextReposition then
						data.NextReposition = now + math.Rand(hg_bot_reposition_min:GetFloat(), hg_bot_reposition_max:GetFloat())

						local radius = math.Rand(hg_bot_strafe_dist_min:GetFloat(), hg_bot_strafe_dist_max:GetFloat())
						local wantPos = FindFlankPoint(bot, target, radius) or FindSidestepPoint(bot, targetPos, radius * 0.6)

						-- Spacing between bots (sv_bot_squad.lua).
						if wantPos and hg.bots.SpreadPoint then
							wantPos = hg.bots.SpreadPoint(bot, wantPos)
						end

						if wantPos then
							hg.bots.SetGoal(bot, wantPos)
						end
					end

					-- Walk, don't sprint: repositioning happens with the gun
					-- up and eyes on the target (strafing / backpedalling), and
					-- a sprint drops the sights (no ADS while Running).
					data.Running = false
				end
			end

			-- Contact range takes priority over shooting.
			if hg.bots.CheckCloseQuarters(bot, data, wep, target, canSee) then return end

			-- Only pull the trigger once the view is actually on target.
			local aimErr = hg.bots.GetAimError(bot, eye, aimPoint)
			local mayFire = aimErr <= hg.bots.GetAimTolerance(dist)
				and not (hg.bots.FriendlyInLine and hg.bots.FriendlyInLine(bot, aimPoint))

			hg.bots.ServiceWeapon(bot, data, wep, mayFire)

			-- Aim down sights (Z-City zoom: RMB with a gun) whenever not
			-- sprinting - better accuracy, and required outright on servers
			-- running hg_aimtoshoot 2.
			data.AttackingSecondary = IsGunWeapon(wep) and not data.Reloading and (data.Attacking or not data.Running)
		end,
	})
--//

--\\ Threat reaction (see sv_bot_navigation.lua's "idle" extension points)
	-- Any live Memory.Target means immediate combat (or flee).
	function hg.bots.CheckThreatReaction(bot, data)
		local target = data.Memory.Target

		if IsValid(target) and target:Alive() then
			hg.bots.SetState(bot, hg.bots.PickReaction(bot))

			return true
		end

		return false
	end

	--- flee / ambush / combat. The gear-aware decision lives in
	-- sv_bot_selfpreservation.lua (hg.bots.ChooseReaction); without it,
	-- the old health-only flee-or-fight.
	function hg.bots.PickReaction(bot)
		local want = hg.bots.ChooseReaction and hg.bots.ChooseReaction(bot)

		if want then return want end

		return (hg.bots.ShouldFlee and hg.bots.ShouldFlee(bot)) and "flee" or "combat"
	end

	-- Snappier reaction than waiting for idle's next tick. Also pulls a
	-- camping bot out of "hold" into a proper fight only if it's not
	-- deliberately holding - hold handles its own shooting.
	hook.Add("HG_BotSpotted", "HG_Bots_ReactToSpotted", function(bot, target)
		if not IsValid(bot) or not bot.Bot then return end
		if bot.Bot.State ~= "idle" then return end

		hg.bots.SetState(bot, hg.bots.PickReaction(bot))
	end)
--//
