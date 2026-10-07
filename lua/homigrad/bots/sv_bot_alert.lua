--[[
	Tarkov AI - Alert (weapon out, expecting contact)

	The step between wandering around and a firefight. A bot that heard
	shooting, was told about somebody, just lost a fight or saw a weapon
	come out doesn't go straight back to strolling with its hands empty -
	it draws, moves slowly, checks the direction the trouble came from and
	keeps its gun up for a while.

	Z-City has real weapon postures (weapons/homigrad_base/sh_options.lua,
	hg.postures): 3 is HIGH READY, 4 is LOW READY, 0 is the normal hold.
	Players switch them with hg_change_posture, which nets to the server
	and sets ply.posture; bots set the same field and broadcast the same
	message, so everyone sees the stance. Alert bots carry:
	- LOW READY while moving through open ground, nothing close;
	- HIGH READY when the noise was close, when the place they're checking
	  is near, or in tight spaces where a target could appear at any moment.
	The stance is dropped back to the normal hold when the bot relaxes, and
	while actually fighting (combat drives the aim itself).

	Entering alert: gunfire heard, a suspicious noise, a contact shared by
	another bot, somebody drawing a weapon nearby, taking damage, or losing
	a target after a fight (combat hands over here instead of to idle).

	Leaving: nothing new for hg_bot_alert_time seconds -> back to idle; a
	real target at any point -> combat, through the usual reaction picker.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {}
hg.bots.States = hg.bots.States or {}
hg.bots.RegisterState = hg.bots.RegisterState or function(name, tbl) hg.bots.States[name] = tbl end

local hg_bot_alert          = CreateConVar("hg_bot_alert",          "1",    {FCVAR_ARCHIVE}, "Bots have an in-between 'weapon out, expecting contact' state instead of going straight from wandering to a firefight", 0, 1)
local hg_bot_alert_time     = CreateConVar("hg_bot_alert_time",     "35",   {FCVAR_ARCHIVE}, "Seconds a bot stays alert with no new information before relaxing", 5, 300)
local hg_bot_alert_trigger  = CreateConVar("hg_bot_alert_trigger",  "0.3",  {FCVAR_ARCHIVE}, "Alertness level at which a wandering bot draws its weapon and goes alert", 0.05, 1)
local hg_bot_alert_posture  = CreateConVar("hg_bot_alert_posture",  "1",    {FCVAR_ARCHIVE}, "Use Z-City's high-ready / low-ready weapon postures while alert", 0, 1)
local hg_bot_alert_close    = CreateConVar("hg_bot_alert_close",    "900",  {FCVAR_ARCHIVE}, "Within this distance of whatever it's checking, a bot carries HIGH ready instead of low", 100, 4000)
local hg_bot_alert_patrol   = CreateConVar("hg_bot_alert_patrol",   "600",  {FCVAR_ARCHIVE}, "How far an alert bot wanders from where it got spooked while it waits for something to happen", 100, 3000)

--\\ Postures
	local POSTURE_NORMAL, POSTURE_HIGH, POSTURE_LOW = 0, 3, 4

	--- Sets Z-City's carry stance on a bot and tells the clients, exactly
	-- the way the player's own hg_change_posture does.
	function hg.bots.SetPosture(bot, posture)
		if not IsValid(bot) then return end
		if (bot.posture or 0) == posture then return end

		bot.posture = posture

		net.Start("change_posture")
		net.WriteEntity(bot)
		net.WriteInt(posture, 9)
		net.Broadcast()
	end

	--- Postures only make sense with a real firearm in the hands.
	local function CanPosture(bot)
		if not hg_bot_alert_posture:GetBool() then return false end

		local wep = bot:GetActiveWeapon()

		return IsValid(wep) and wep.ishgweapon and true or false
	end

	--- Drop back to the normal hold (leaving alert, dying, going down).
	function hg.bots.ClearPosture(bot)
		hg.bots.SetPosture(bot, POSTURE_NORMAL)
	end

	hook.Add("HG_BotStateChanged", "HG_Bots_ClearPosture", function(bot, oldState, newState)
		if newState ~= "alert" then hg.bots.ClearPosture(bot) end
	end)

	-- A corpse holding a rifle at high ready looks wrong, and the stance
	-- would carry into the next life otherwise.
	hook.Add("PlayerDeath", "HG_Bots_ClearPostureOnDeath", function(ply)
		if IsValid(ply) and ply.IsHomigradBot then hg.bots.ClearPosture(ply) end
	end)
--//

--\\ What counts as "something happened"
	--- The most recent thing worth being alert about, and where it was.
	-- @return time of that information, position (may be nil)
	local function LatestInfo(bot, data)
		local mem = data.Memory
		local best, pos = 0, nil

		local function consider(t, p)
			if t and t > best then best, pos = t, p end
		end

		consider(mem.SuspicionTime, mem.SuspicionPos)
		consider(mem.LastSeen, mem.TargetSeenPos or mem.TargetPos)
		consider(mem.UnderFireUntil and (mem.UnderFireUntil - 6), mem.UnderFireFrom)
		consider(mem.WaryUntil and (mem.WaryUntil - 10), IsValid(mem.WaryOf) and mem.WaryOf:GetPos() or nil)

		return best, pos
	end

	--- Should this bot be alert right now? Used by the idle watcher below
	-- and by anything else that wants to raise the alarm.
	function hg.bots.ShouldBeAlert(bot, data)
		if not hg_bot_alert:GetBool() then return false end

		local mem = data.Memory

		if (mem.Alertness or 0) >= hg_bot_alert_trigger:GetFloat() then return true end
		if mem.SuspicionPos then return true end
		if IsValid(mem.WaryOf) and CurTime() < (mem.WaryUntil or 0) then return true end
		if (mem.UnderFireUntil or 0) > CurTime() then return true end

		-- Fought somebody in the last while: stay switched on afterwards.
		if mem.LastSeen and CurTime() - mem.LastSeen < 30 then return true end

		return false
	end

	--- Raise the alarm on one bot (used by the squad's shared contacts and
	-- by anything else that learns about an enemy).
	function hg.bots.Alert(bot, pos, source)
		if not hg_bot_alert:GetBool() then return false end

		local data = IsValid(bot) and bot.Bot

		if not data or not data.Enabled then return false end
		if IsValid(bot.FakeRagdoll) then return false end

		local state = data.State

		-- Already busy with something more serious.
		if state ~= "idle" and state ~= "alert" then return false end

		local mem = data.Memory

		if pos then
			mem.SuspicionPos = pos
			mem.SuspicionTime = CurTime()
			mem.SuspicionKind = source or "report"
			mem.Alertness = math.max(mem.Alertness or 0, 0.5)
		end

		data.AlertUntil = CurTime() + hg_bot_alert_time:GetFloat()

		if state ~= "alert" then hg.bots.SetState(bot, "alert") end

		return true
	end
--//

--\\ The state
	local SCAN_YAWS = { 0, 55, -55, 110, -110 }

	hg.bots.RegisterState("alert", {
		Enter = function(bot, data)
			data.Running = false
			data.SlowWalk = true
			data.Crouching = false
			data.Attacking = false
			data.AttackingSecondary = false
			data.AlertUntil = CurTime() + hg_bot_alert_time:GetFloat()
			data.AlertHome = bot:GetPos()
			data.AlertScanAt = 0
			data.AlertScanStep = 0
			data.NextAlertPick = 0

			-- Weapon out. This is the whole point of the state.
			data.NextWeaponSwitch = 0

			if hg.bots.EquipBestWeapon then hg.bots.EquipBestWeapon(bot) end
		end,

		Leave = function(bot, data)
			data.SlowWalk = false
			data.AlertUntil = nil
			data.AlertHome = nil
			data.AlertCheckPos = nil

			hg.bots.ClearPosture(bot)
		end,

		Think = function(bot, data)
			data.NextStateThink = CurTime() + 0.2

			-- An actual target beats everything: straight into the fight.
			if hg.bots.CheckThreatReaction(bot, data) then return end

			local now = CurTime()
			local mem = data.Memory
			local infoTime, infoPos = LatestInfo(bot, data)

			-- Fresh information keeps the bot switched on.
			if infoTime > (data.AlertInfoAt or 0) then
				data.AlertInfoAt = infoTime
				data.AlertUntil = now + hg_bot_alert_time:GetFloat()
				data.AlertCheckPos = infoPos
				data.AlertChecked = nil
			end

			if now > (data.AlertUntil or 0) and not hg.bots.ShouldBeAlert(bot, data) then
				hg.bots.SetState(bot, "idle")
				return
			end

			-- Wounded and out of contact: patch up first (sv_bot_medic.lua).
			if hg.bots.ShouldHeal and hg.bots.ShouldHeal(bot) then
				hg.bots.SetState(bot, "heal")
				return
			end

			-- Anything lying around is still worth grabbing while nothing
			-- is happening - but only with the weapon already out.
			data.Running = false
			data.SlowWalk = true

			local check = data.AlertCheckPos
			local dist = check and bot:GetPos():Distance(check) or math.huge

			-- Carry: high ready when the thing being checked is close (or
			-- there's no room to swing a barrel up), low ready otherwise.
			if CanPosture(bot) then
				local high = dist < hg_bot_alert_close:GetFloat() or (mem.UnderFireUntil or 0) > now

				hg.bots.SetPosture(bot, high and 3 or 4)
			end

			-- Go and look at what caused this, once.
			if check and not data.AlertChecked then
				if dist > 150 then
					if not data.Goal or data.Goal:DistToSqr(check) > 120 ^ 2 then
						if not hg.bots.SetGoal(bot, check) then data.AlertChecked = true end
					end

					data.LookPos = dist < 600 and (check + Vector(0, 0, 45)) or nil

					if hg.bots.FollowPath(bot, data) then data.AlertChecked = true end

					return
				end

				data.AlertChecked = true
				data.AlertScanAt = 0
				data.AlertScanUntil = now + math.Rand(3, 5)
			end

			-- Standing over the spot: scan around it before moving on.
			if data.AlertScanUntil and now < data.AlertScanUntil then
				hg.bots.ClearPath(data)

				data.MoveTarget = nil

				if now >= (data.AlertScanAt or 0) then
					data.AlertScanAt = now + math.Rand(0.8, 1.4)
					data.AlertScanStep = (data.AlertScanStep or 0) + 1

					local yaw = bot:EyeAngles().y + SCAN_YAWS[((data.AlertScanStep - 1) % #SCAN_YAWS) + 1]

					data.LookPos = bot:EyePos() + Angle(0, yaw, 0):Forward() * 400
					data.LookLock = true
				end

				return
			end

			data.AlertScanUntil = nil

			-- Nothing to walk to: hold the area, looking around, drifting
			-- between nearby spots rather than standing like a statue.
			if hg.bots.FollowPath(bot, data) and now >= (data.NextAlertPick or 0) then
				data.NextAlertPick = now + math.Rand(3, 6)

				local home = data.AlertHome or bot:GetPos()
				local radius = hg_bot_alert_patrol:GetFloat()
				local dest = hg.bots.GetRandomWanderPoint and hg.bots.GetRandomWanderPoint(bot)

				if dest and dest:DistToSqr(home) > radius * radius then dest = nil end

				if dest then hg.bots.SetGoal(bot, dest) end
			end

			-- Watching the way trouble came from while moving.
			if check and (not data.MoveTarget or bot:GetPos():DistToSqr(check) < 500 * 500) then
				data.LookPos = check + Vector(0, 0, 45)
			end
		end,
	})
--//

--\\ Wandering bots notice things
	timer.Create("HG_Bots_Alert", 1, 0, function()
		if not hg_bot_alert:GetBool() then return end

		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and bot:Alive() and bot.Bot

			if data and data.Enabled and data.State == "idle" and not IsValid(bot.FakeRagdoll) then
				if hg.bots.ShouldBeAlert(bot, data) then hg.bots.SetState(bot, "alert") end
			end
		end
	end)
--//
