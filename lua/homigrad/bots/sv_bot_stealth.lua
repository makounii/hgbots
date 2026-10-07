--[[
	Tarkov AI - Stalking

	Walking straight at somebody in the open is how a bot with a knife dies.
	This decides when a bot should creep instead, and where from.

	A bot stalks when:
	- it can't win at range anyway (melee, fists, or an empty gun), or its
	  tactic for this contact is the careful one;
	- the target doesn't appear to know about it: not looking this way, not
	  shooting at it, and far enough that footsteps don't give it away;
	- it isn't already in reach.

	While stalking it crouches (Z-City hears crouched steps at 120 units
	instead of 900 - see sv_bot_perception.lua's step radii), walks instead
	of running, and approaches from wherever the target ISN'T looking,
	picking a point behind their shoulder line rather than the shortest
	line to them. The moment they turn around, the sneak is off and the bot
	commits - creeping in someone's line of sight is just being slow.
]]

hg.bots = hg.bots or {}

local hg_bot_stealth        = CreateConVar("hg_bot_stealth",        "1",    {FCVAR_ARCHIVE}, "Bots sneak up on people who haven't noticed them (crouched, from behind), especially with melee", 0, 1)
local hg_bot_stealth_range  = CreateConVar("hg_bot_stealth_range",  "1600", {FCVAR_ARCHIVE}, "Maximum distance at which sneaking is worth it", 200, 6000)
local hg_bot_stealth_facing = CreateConVar("hg_bot_stealth_facing", "0.6",  {FCVAR_ARCHIVE}, "How directly the target must be looking at the bot to count as having noticed it (1 = dead on)", 0, 1)
local hg_bot_stealth_min    = CreateConVar("hg_bot_stealth_min",    "220",  {FCVAR_ARCHIVE}, "Closer than this the bot stops creeping and commits", 60, 1000)

--\\ Deciding
	--- Does the target look like it knows about this bot?
	function hg.bots.IsNoticed(bot, target)
		if not IsValid(target) then return false end

		local data = bot.Bot
		local mem = data and data.Memory

		-- They shot at us: they know.
		if mem and IsValid(mem.ShotBy) and CurTime() - (mem.ShotByAt or 0) < 6 then return true end
		if mem and (mem.UnderFireUntil or 0) > CurTime() then return true end

		-- Spotted a moment ago: turning away again doesn't make them forget.
		local blown = data and data.StalkBlown

		if blown and blown.who == target and CurTime() < blown.untilT then return true end

		local char = (IsValid(target.FakeRagdoll) and target.FakeRagdoll) or target
		local to = bot:WorldSpaceCenter() - char:WorldSpaceCenter()
		local len = to:Length()

		if len < 1 then return true end

		to:Normalize()

		local facing = target:GetAimVector():Dot(to)
		local noticed = facing > hg_bot_stealth_facing:GetFloat()

		-- Anywhere in front of them with a clear line is in their view
		-- (a player's FOV is far wider than a narrow cone): no creeping up
		-- on somebody's face.
		if not noticed and facing > -0.1 then
			noticed = not util.TraceLine({
				start = target:EyePos(),
				endpos = bot:EyePos(),
				mask = MASK_VISIBLE,
				filter = { target, bot, char },
			}).Hit
		end

		if noticed and data then
			data.StalkBlown = { who = target, untilT = CurTime() + 12 }
		end

		return noticed
	end

	--- Should this bot be creeping right now?
	function hg.bots.ShouldStalk(bot, data, target, dist)
		if not hg_bot_stealth:GetBool() then return false end
		if not IsValid(target) or not target:Alive() then return false end
		if IsValid(bot.FakeRagdoll) then return false end
		if dist > hg_bot_stealth_range:GetFloat() then return false end
		if dist < hg_bot_stealth_min:GetFloat() then return false end

		-- Anything that wins at range has no reason to crawl about.
		local kind = hg.bots.GetWeaponKind and hg.bots.GetWeaponKind(bot, true) or "gun"
		local careful = data.Tactic == "careful"

		if kind == "gun" and not careful then return false end

		return not hg.bots.IsNoticed(bot, target)
	end
--//

--\\ Approaching
	--- A spot to come at them from: behind their shoulder line, at the
	-- distance the bot wants to close to, and actually reachable.
	-- @return Vector or nil (nil = just go straight at them)
	function hg.bots.StalkApproach(bot, target, standoff)
		standoff = standoff or 160

		local char = (IsValid(target.FakeRagdoll) and target.FakeRagdoll) or target
		local tPos = char:GetPos()
		local aim = target:GetAimVector()

		aim.z = 0

		if aim:LengthSqr() < 0.01 then return nil end

		aim:Normalize()

		local pos = bot:GetPos()
		local best, bestScore

		-- Straight behind first, then wider off each shoulder.
		for _, deg in ipairs({ 0, 40, -40, 75, -75 }) do
			local dir = Vector(-aim.x, -aim.y, 0)

			dir:Rotate(Angle(0, deg, 0))

			local spot = tPos + dir * standoff
			spot.z = pos.z

			if not hg.bots.IsSegmentWalkable or hg.bots.IsSegmentWalkable(tPos, spot, bot) then
				-- Prefer the one we can reach soonest that is still out of
				-- their view cone.
				local score = pos:Distance(spot) + math.abs(deg) * 2

				if not bestScore or score < bestScore then best, bestScore = spot, score end
			end
		end

		return best
	end

	--- Drives one tick of a stalk. Everything about being quiet is Z-City's
	-- own: crouched movement is what makes the footsteps quiet, so that is
	-- the whole trick.
	-- @return true if it handled the movement this tick
	function hg.bots.StalkTick(bot, data, target, dist)
		local now = CurTime()

		data.Running = false
		data.Crouching = true
		data.SlowWalk = false -- crouch-walking is already slow; IN_WALK on top of it is a crawl
		data.Attacking = false

		-- Eyes on them the whole way in.
		data.LookPos = target:WorldSpaceCenter()
		data.LookLock = true

		if now >= (data.StalkPick or 0) or not data.StalkSpot then
			data.StalkPick = now + 2

			local standoff = math.max(hg_bot_stealth_min:GetFloat() * 0.7, 120)

			data.StalkSpot = hg.bots.StalkApproach(bot, target, standoff) or target:GetPos()
		end

		local spot = data.StalkSpot

		if not data.Goal or data.Goal:DistToSqr(spot) > 140 ^ 2 then
			-- Route that keeps out of their line as far as it can.
			hg.bots.SetGoal(bot, spot, { avoidPos = target:GetPos(), avoidRadius = 260, avoidWeight = 1.5 })
		end

		if hg.bots.FollowPath(bot, data) then
			-- Arrived behind them: from here it's a rush, not a creep.
			data.StalkSpot = nil
			data.StalkPick = 0

			return false
		end

		return true
	end

	function hg.bots.EndStalk(data)
		data.StalkSpot = nil
		data.StalkPick = nil
		data.Crouching = false
	end

	hook.Add("HG_BotStateChanged", "HG_Bots_ClearStalk", function(bot, oldState, newState)
		if bot.Bot then hg.bots.EndStalk(bot.Bot) end
	end)
--//
