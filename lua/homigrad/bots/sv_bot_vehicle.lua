--[[
	Tarkov AI - cars

	Bots can take a car: Z-City's Glide vehicles (the cars; not bikes,
	tanks, boats or aircraft). A bot that wants one walks to the driver's
	door, gets in, drives, stops, gets out.

	When a bot takes one
	- Strolling with nothing to do (idle), now and then, if a free car
	  stands near: a trip to somewhere far off on the map. It parks
	  there, gets out and carries on on foot around the new place.
	- In a fight, when the enemy is a long way off, out in the open, and
	  a car is close: it goes for the car and runs him down.
	- Never a guard escorting players, never a bot under orders, never
	  one that is hurt enough to be running.

	Getting in and out
	- "approach": a path to the driver's door (the car's own exit point
	  for seat 1). The car is claimed, so two bots don't race for it.
	- "enter": stops at the door, turns to it, and half a second later
	  sits down in the driver's seat. Only into a car that stands still:
	  Z-City refuses a moving one. Z-City then straps the driver in as a
	  ragdoll after a second, like any player - sv_bot_core.lua knows a
	  seated bot is not a downed one.
	- "drive": see below.
	- "park": brakes to a stop, handbrake on, then steps out. Never out
	  of a moving car on purpose (Z-City throws whoever leaves at speed
	  through the windscreen).

	Driving
	- The route is the navmesh path search with a car's rules
	  (opts.vehicle in sv_bot_navigation.lua): wide areas only, no water,
	  no crouch / jump areas, no steps a car can't roll over. Where the
	  map's navmesh has no such route there is no trip.
	- Steering aims at the next waypoint (the car's own steer / accelerate
	  / brake inputs, the same ones a player's keys feed). Speed comes
	  down for a turn and for the last stretch.
	- A hull the width of the car looks ahead: a wall or a prop means
	  brake and steer for the clearer side; a friend or a bystander means
	  brake and horn; an ENEMY means the opposite.
	- Stuck (throttle on, not moving): back up with the wheel turned,
	  try again; after a few of those the car is given up - the bot gets
	  out, and leaves that car alone for a while.
	- On its roof, in deep water, engine burning or dead: out.

	Running people over
	- With an enemy in sight, in reach and on ground a car can get to,
	  the bot drives at where he will be, flat out, and through him. Past
	  him, it carries on a moment, turns round (backs up to do it when
	  there is no room) and comes again.
	- No line to him: the car route towards where he was last seen.
	  Nowhere a car can go, or half a minute of trying: it stops as near
	  as it got and finishes the fight on foot.
	- A threat that turns up during a trip: the same choice - run him
	  down if he is out where the car can go, otherwise stop and get out.

	Convars: hg_bot_vehicles (master switch), hg_bot_vehicle_trip (how
	often an idle bot near a car takes it), hg_bot_vehicle_ram (running
	enemies over on purpose), hg_bot_vehicle_search, hg_bot_vehicle_speed,
	hg_bot_vehicle_debug. hg_bot_vehicle_take makes the bot you look at
	take the nearest car now.
]]

hg.bots = hg.bots or {}
hg.bots.States = hg.bots.States or {}
hg.bots.RegisterState = hg.bots.RegisterState or function(name, tbl) hg.bots.States[name] = tbl end

local hg_bot_vehicles       = CreateConVar("hg_bot_vehicles",       "1",    {FCVAR_ARCHIVE}, "Bots can get into Glide cars, drive them and get out again", 0, 1)
local hg_bot_vehicle_trip   = CreateConVar("hg_bot_vehicle_trip",   "0.35", {FCVAR_ARCHIVE}, "Chance (rolled about twice a minute) that an idle bot with a free car nearby takes it for a trip across the map. 0 = bots never take a car just to go somewhere", 0, 1)
local hg_bot_vehicle_ram    = CreateConVar("hg_bot_vehicle_ram",    "1",    {FCVAR_ARCHIVE}, "A bot at the wheel runs its enemies over on purpose, and a bot in a fight may fetch a nearby car to do it", 0, 1)
local hg_bot_vehicle_search = CreateConVar("hg_bot_vehicle_search", "1400", {FCVAR_ARCHIVE}, "How far a bot looks for a car to take", 200, 8000)
local hg_bot_vehicle_speed  = CreateConVar("hg_bot_vehicle_speed",  "650",  {FCVAR_ARCHIVE}, "Cruising speed of a driving bot in units per second (17.6 = 1 mph); it goes about 1.6 times this at somebody it means to hit", 150, 2500)
local hg_bot_vehicle_debug  = CreateConVar("hg_bot_vehicle_debug",  "0",    {FCVAR_ARCHIVE}, "Print what driving bots decide", 0, 1)

local function Debug(bot, ...)
	if hg_bot_vehicle_debug:GetBool() then print("[hg.bots] vehicle " .. (IsValid(bot) and bot:Nick() or "?") .. ":", ...) end
end

local UP = Vector(0, 0, 1)
local Clamp = math.Clamp

--\\ Cars
	local cars, carsAt = {}, -10

	local function IsCar(ent)
		return IsValid(ent) and ent.IsGlideVehicle and Glide and Glide.VEHICLE_TYPE
			and ent.VehicleType == Glide.VEHICLE_TYPE.CAR and ent.GetSeatDriver ~= nil and ent.SetInputFloat ~= nil
	end

	--- Every Glide car on the map (looked up every three seconds).
	local function Cars()
		local now = CurTime()

		if now - carsAt < 3 and now >= carsAt then return cars end

		carsAt = now
		cars = {}

		if not Glide then return cars end

		for _, ent in ipairs(ents.GetAll()) do
			if IsCar(ent) then cars[#cars + 1] = ent end
		end

		return cars
	end

	local function Speed(veh)
		return veh:GetVelocity():Length()
	end

	--- Can this car be driven at all right now?
	local function Usable(veh, bot)
		if not IsCar(veh) then return false end
		if veh.seats == nil or not IsValid(veh.seats[1]) then return false end
		if veh:GetIsLocked() then return false end
		if veh.GetEngineHealth and veh:GetEngineHealth() <= 0.05 then return false end
		if veh.GetIsEngineOnFire and veh:GetIsEngineOnFire() then return false end
		if veh.GetFuel and veh:GetFuel() <= 0 then return false end
		if veh:GetUp().z < 0.6 or veh:WaterLevel() >= 2 then return false end

		local driver = veh:GetSeatDriver(1)

		if IsValid(driver) and driver ~= bot then return false end

		return true
	end

	--- Free for this bot to walk up to and take?
	local function Free(veh, bot, now)
		if not Usable(veh, bot) then return false end
		if Speed(veh) > 60 then return false end
		if IsValid(veh.hgBotClaim) and veh.hgBotClaim ~= bot and (veh.hgBotClaimUntil or 0) > now then return false end
		if veh.hgBotBad and (veh.hgBotBad[bot] or 0) > now then return false end

		return true
	end

	local function FindCar(bot, radius)
		local now = CurTime()
		local pos = bot:GetPos()
		local best, bestD

		for _, veh in ipairs(Cars()) do
			if Free(veh, bot, now) then
				local d = veh:GetPos():DistToSqr(pos)

				if d < radius * radius and (not bestD or d < bestD) then best, bestD = veh, d end
			end
		end

		return best, bestD and math.sqrt(bestD)
	end

	hg.bots.FindCar = FindCar

	local function Bad(veh, bot, secs)
		if not IsValid(veh) then return end

		veh.hgBotBad = veh.hgBotBad or {}
		veh.hgBotBad[bot] = CurTime() + (secs or 60)
	end

	local function Release(veh, bot)
		if IsValid(veh) and veh.hgBotClaim == bot then
			veh.hgBotClaim = nil
			veh.hgBotClaimUntil = nil
		end
	end

	--- Takes the bot's hands off everything.
	local function Idle(veh)
		if not IsValid(veh) or not veh.SetInputFloat then return end

		veh:SetInputFloat(1, "accelerate", 0)
		veh:SetInputFloat(1, "brake", 0)
		veh:SetInputFloat(1, "steer", 0)
		veh:SetInputBool(1, "handbrake", false)

		if veh.SetIsHonking then veh:SetIsHonking(false) end
	end

	local WAIST = Vector(0, 0, 30)
	local carTR = {}
	local carQ = { output = carTR, mask = MASK_SOLID }

	--- Part of this car (its body, a wheel, a seat, anything parented to it)?
	local function OfCar(ent, veh)
		if not IsValid(ent) then return false end
		if ent == veh or ent:GetParent() == veh then return true end

		for _, w in ipairs(veh.wheels or {}) do
			if w == ent then return true end
		end

		return false
	end

	--- Is the car in the way of a walk from the bot to pos?
	local function CarBetween(bot, veh, pos)
		local filter = { bot }

		if IsValid(bot.FakeRagdoll) then filter[2] = bot.FakeRagdoll end

		carQ.start, carQ.endpos, carQ.filter = bot:GetPos() + WAIST, pos + WAIST, filter

		util.TraceLine(carQ)

		return carTR.Hit and OfCar(carTR.Entity, veh)
	end

	--- A point off the front or the back bumper, whichever is the shorter
	-- way round to pos, with clear walking to it and on from it.
	local function DetourPoint(bot, veh, pos)
		local fwd = veh:GetForward()

		fwd.z = 0

		if fwd:LengthSqr() < 0.01 then return nil end

		fwd:Normalize()

		local center = veh:WorldSpaceCenter()
		local reach = math.max(math.abs(veh:OBBMaxs().x), math.abs(veh:OBBMins().x)) + 80
		local from = bot:GetPos()
		local best, bestD

		for _, sign in ipairs({ 1, -1 }) do
			local p = center + fwd * (reach * sign)

			p = hg.bots.SnapToNavmesh and hg.bots.SnapToNavmesh(p, 200) or p

			if p and not CarBetween(bot, veh, p) then
				local dd = from:Distance(p) + p:Distance(pos)

				if not bestD or dd < bestD then best, bestD = p, dd end
			end
		end

		return best
	end

	--- Can a car get from a to b over the navmesh? @return path or nil
	local function CarRoute(a, b)
		if not hg.bots.FindNavPath then return nil end

		return hg.bots.FindNavPath(a, b, nil, { vehicle = true })
	end

	local skyTR = {}
	local skyQ = { output = skyTR, mask = MASK_SOLID_BRUSHONLY }

	local function Outdoors(pos)
		skyQ.start, skyQ.endpos = pos + UP * 40, pos + UP * 6000

		util.TraceLine(skyQ)

		return skyTR.HitSky or not skyTR.Hit
	end

	--- Somewhere far off that a car can reach from `from`.
	local function TripDestination(from)
		if not navmesh.IsLoaded() then return nil end

		local areas = navmesh.GetAllNavAreas()

		if #areas == 0 then return nil end

		local searches = 0

		for _ = 1, 40 do
			local area = areas[math.random(#areas)]

			if IsValid(area) and area:GetSizeX() > 150 and area:GetSizeY() > 150 and not area:IsUnderwater() then
				local c = area:GetCenter()
				local d = c:Distance(from)

				if d > 1800 and d < 9000 and Outdoors(c) then
					searches = searches + 1

					local path = CarRoute(from, c)

					if path then return c, path end
					if searches >= 3 then return nil end
				end
			end
		end

		return nil
	end
--//

--\\ Seat bookkeeping
	-- data.InVehicle is what the rest of the AI reads (sv_bot_core.lua:
	-- no "downed" for a seated ragdoll, no other state while seated, an
	-- empty walk command).
	hook.Add("PlayerEnteredVehicle", "HG_Bots_Vehicle", function(ply, seat)
		if not ply.IsHomigradBot or not ply.Bot then return end

		local data = ply.Bot
		local veh = IsValid(seat) and seat:GetParent() or nil

		data.InVehicle = IsValid(veh) and veh or seat

		-- Put into a seat by something else (an admin, another add-on):
		-- the drive state is still the only one that can get it out.
		if data.State ~= "drive" then
			data.DrivePlan = { veh = veh, purpose = "sit" }

			hg.bots.SetState(ply, "drive")
		end
	end)

	local function Left(ply)
		if not IsValid(ply) or not ply.IsHomigradBot or not ply.Bot then return end

		local data = ply.Bot
		local veh = data.InVehicle

		data.InVehicle = nil

		if IsValid(veh) and veh.GetSeatDriver and not IsValid(veh:GetSeatDriver(1)) then Idle(veh) end
	end

	hook.Add("PlayerLeaveVehicle", "HG_Bots_Vehicle", function(ply) Left(ply) end)
	hook.Add("PlayerDeath", "HG_Bots_VehicleDeath", function(ply) Left(ply) end)
--//

--\\ The wheel
	local hullTR = {}
	local hullQ = { output = hullTR, mask = MASK_SOLID, mins = Vector(-30, -30, 0), maxs = Vector(30, 30, 34) }

	--- What is ahead of the car along dir, within len.
	-- @return fraction (1 = clear), entity hit
	local function Ahead(veh, bot, dir, len)
		local filter = {}

		for i, e in ipairs(veh.selfTraceFilter or {}) do filter[i] = e end

		filter[#filter + 1] = veh
		filter[#filter + 1] = bot

		if IsValid(bot.FakeRagdoll) then filter[#filter + 1] = bot.FakeRagdoll end

		for _, e in ipairs(veh.wheels or {}) do filter[#filter + 1] = e end

		local from = veh:WorldSpaceCenter()

		hullQ.start, hullQ.endpos, hullQ.filter = from, from + dir * len, filter

		util.TraceHull(hullQ)

		-- (The road itself rising ahead is not something in the way.)
		if hullTR.Hit and hullTR.HitNormal.z > 0.45 then return 1 end

		return hullTR.Hit and hullTR.Fraction or 1, hullTR.Entity
	end

	--- One step at the wheel: steer at aim, hold about `want` units a second.
	-- @param ram Entity|nil somebody the bot means to hit (never braked for)
	-- @return distance to aim (flat), how far round it is (forward dot)
	local function Drive(bot, veh, d, aim, want, now, ram)
		local pos = veh:GetPos()
		local fwd, right = veh:GetForward(), veh:GetRight()
		local to = aim - pos

		to.z = 0

		local dist = to:Length()

		if dist < 1 then return dist, 1 end

		to:Mul(1 / dist)

		local f, r = to:Dot(fwd), to:Dot(right)
		local vel = veh:GetVelocity()
		local speed = vel:Dot(fwd) -- (negative rolling backwards)
		local steer

		if f > 0.1 then
			steer = Clamp(r * 2.4, -1, 1)
		else
			steer = r >= 0 and 1 or -1 -- behind: hard round
		end

		--\\ Backing up (stuck, or no room to turn)
		if d.reverseUntil then
			if now < d.reverseUntil then
				veh:SetInputFloat(1, "accelerate", 0)
				veh:SetInputFloat(1, "brake", 1) -- (Glide's gearbox: brake at a standstill is reverse)
				veh:SetInputFloat(1, "steer", -(d.reverseSteer or steer))
				veh:SetInputBool(1, "handbrake", false)

				return dist, f
			end

			d.reverseUntil = nil
			d.stuckSince = nil
			d.rolling = now + 1 -- brake to a stop, then forward again
		end
		--//

		-- Behind and close: quicker to back round than to drive a circle.
		if f < -0.3 and dist < 700 and math.abs(speed) < 220 and now > (d.nextTurnBack or 0) then
			d.nextTurnBack = now + 4
			d.reverseUntil = now + 1.5
			d.reverseSteer = steer

			return dist, f
		end

		-- Slower into a turn.
		want = Lerp(math.min(math.abs(steer), 1), want, math.min(want, 280))

		--\\ What is in the way
		local brakeFor

		if now >= (d.nextLook or 0) then
			d.nextLook = now + 0.12

			local flat = Vector(fwd.x, fwd.y, 0)

			flat:Normalize()

			local len = Clamp(math.abs(speed) * 0.9, 160, 800) + 60
			local frac, ent = Ahead(veh, bot, flat, len)

			d.blockFrac, d.blockEnt, d.blockLen = frac, ent, len
			d.honk = false

			-- The man it means to hit (or his ragdoll) is not an obstacle.
			if frac < 1 and ram and (ent == ram or ent == ram.FakeRagdoll) then
				d.blockFrac = 1
			elseif frac < 1 then
				local body = IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or (hg.RagdollOwner and IsValid(hg.RagdollOwner(ent))))

				if body then
					local who = ent:IsPlayer() and ent or (hg.RagdollOwner and hg.RagdollOwner(ent)) or ent
					local enemy = hg_bot_vehicle_ram:GetBool() and hg.bots.IsHostile and hg.bots.IsHostile(who, bot)
						and not (hg.bots.IsFriendly and hg.bots.IsFriendly(bot, who))

					if not enemy then
						d.honk = true
						d.blockBody = now
					else
						d.blockFrac = 1 -- an enemy in front of the bumper is not an obstacle
					end
				else
					-- A wall or a prop: which side has more room?
					local l = Ahead(veh, bot, (flat - right * 0.5):GetNormalized(), len)
					local rr = Ahead(veh, bot, (flat + right * 0.5):GetNormalized(), len)

					d.blockSide = (rr > l + 0.05) and 1 or (l > rr + 0.05) and -1 or 0
				end
			end
		end

		if d.blockFrac and d.blockFrac < 1 then
			local gap = d.blockFrac * d.blockLen - 60

			-- Stop short of it; steer for the open side while there is room to.
			want = math.min(want, math.max(gap * 1.2, 0))

			if d.honk then
				want = math.min(want, gap > 220 and 200 or 0)
			elseif (d.blockSide or 0) ~= 0 and gap > 80 then
				steer = Clamp(steer + d.blockSide * 0.8, -1, 1)
				want = math.max(want, 180)
			end

			brakeFor = gap < 140
		end
		--//

		if d.rolling and now < d.rolling and speed < -30 then want = 0 end

		local accel, brake = 0, 0

		if speed < want then
			accel = Clamp((want - speed) / 220, 0.3, 1)
		elseif speed > want + 90 then
			brake = Clamp((speed - want) / 300, 0.25, 1)
		end

		if want <= 0 then accel, brake = 0, (math.abs(speed) > 25 and 1 or 0) end

		veh:SetInputFloat(1, "accelerate", accel)
		veh:SetInputFloat(1, "brake", speed > 40 and brake or 0) -- (not at a standstill: that would be reverse)
		veh:SetInputFloat(1, "steer", steer)
		veh:SetInputBool(1, "handbrake", want <= 0 and math.abs(speed) < 40)

		if veh.SetIsHonking then veh:SetIsHonking(d.honk and math.abs(speed) < 300 and (now % 1.2) < 0.5 or false) end

		--\\ Stuck: throttle on and going nowhere
		if accel > 0 and math.abs(speed) < 30 and not (brakeFor and d.honk) then
			d.stuckSince = d.stuckSince or now

			if now - d.stuckSince > 1.6 then
				d.stuck = (d.stuck or 0) + 1
				d.stuckSince = nil
				d.reverseUntil = now + math.Rand(1.2, 1.9)
				d.reverseSteer = (d.blockSide and d.blockSide ~= 0) and d.blockSide or (math.random() < 0.5 and 1 or -1)

				Debug(bot, "stuck, backing up (" .. d.stuck .. ")")
			end
		elseif math.abs(speed) > 60 then
			d.stuckSince = nil
		end

		-- Waiting behind somebody who will not move: that is stuck too.
		if d.honk and brakeFor and d.blockBody and math.abs(speed) < 20 then
			d.waited = (d.waited or 0) + 0.1

			if d.waited > 4 then
				d.waited = 0
				d.stuck = (d.stuck or 0) + 1
				d.reverseUntil = now + 1.4
				d.reverseSteer = math.random() < 0.5 and 1 or -1
			end
		else
			d.waited = 0
		end

		-- Stopped short of a wall or a prop with no way round in sight (the
		-- throttle is off, so the check above never sees it): back off with
		-- the nose swinging towards where it wants to go, and try again.
		if brakeFor and not d.honk and want <= 0 and math.abs(speed) < 30 then
			d.walledSince = d.walledSince or now

			if now - d.walledSince > 1.5 then
				d.walledSince = nil
				d.stuck = (d.stuck or 0) + 1
				d.reverseUntil = now + math.Rand(1.2, 1.8)
				d.reverseSteer = steer > 0.1 and 1 or steer < -0.1 and -1 or (math.random() < 0.5 and 1 or -1)

				Debug(bot, "blocked, backing up (" .. d.stuck .. ")")
			end
		else
			d.walledSince = nil
		end
		--//

		return dist, f
	end

	local seeTR = {}
	local seeQ = { output = seeTR, mask = MASK_VISIBLE }

	--- Can the driver see him? From above the roof, with the car itself
	-- out of the way: the bot's own eyes sit inside the bodywork, and
	-- every line from there ends on a door pillar.
	local function SeesFromCar(veh, bot, target)
		local char = hg.bots.GetCharacter and hg.bots.GetCharacter(target) or target
		local from = veh:WorldSpaceCenter() + UP * 45
		local to = char:WorldSpaceCenter()

		if from:DistToSqr(to) > 3500 * 3500 then return false end

		local filter = { veh, bot, target, char }

		if IsValid(bot.FakeRagdoll) then filter[#filter + 1] = bot.FakeRagdoll end

		for _, e in ipairs(veh.selfTraceFilter or {}) do filter[#filter + 1] = e end
		for _, e in ipairs(veh.wheels or {}) do filter[#filter + 1] = e end

		seeQ.start, seeQ.endpos, seeQ.filter = from, to, filter

		util.TraceLine(seeQ)

		return not seeTR.Hit
	end

	local PASS_UP = Vector(0, 0, 40)
	local passTR = { output = {}, mask = MASK_SOLID_BRUSHONLY }

	--- Follows d.path. @return true when the end is reached
	local function FollowRoute(bot, veh, d, want, now)
		local path = d.path

		d.pathIndex = d.pathIndex or 1

		if not path or not path[d.pathIndex] then return true end

		local pos = veh:GetPos()
		local last = #path
		local reach = Clamp(Speed(veh) * 0.5, 130, 320)

		-- Past this waypoint: near it, or gone by it - the car is nearer
		-- the next one than this one is, and can see the next one. (A car
		-- turns wider than a man: at a sharp bend it swung out past the
		-- point, never got within reach of it, and drove circles round it.)
		while d.pathIndex < last do
			local wp, nx = path[d.pathIndex], path[d.pathIndex + 1]
			local dx, dy = wp.x - pos.x, wp.y - pos.y
			local d2 = dx * dx + dy * dy

			local passed = false

			if d2 > reach * reach then
				if d2 < 650 * 650 then
					local cx, cy = nx.x - pos.x, nx.y - pos.y
					local wx, wy = nx.x - wp.x, nx.y - wp.y

					if cx * cx + cy * cy < wx * wx + wy * wy then
						passTR.start, passTR.endpos = pos + PASS_UP, nx + PASS_UP
						util.TraceLine(passTR)

						passed = not passTR.output.Hit
					end
				end

				if not passed then break end
			end

			d.pathIndex = d.pathIndex + 1
		end

		local wp = path[d.pathIndex]
		local final = d.pathIndex == last
		local dist, f = Drive(bot, veh, d, wp, final and math.min(want, 90 + (wp - pos):Length2D() * 0.9) or want, now)

		-- Arrived: on the spot, or close by with the spot beside or behind
		-- (a car circling a point it cannot turn tight enough to touch).
		return final and (dist < 150 or (dist < 320 and f < 0.4))
	end
--//

--\\ The drive state
	local function Finish(bot, data, veh)
		local d = data.Drive
		local mem = data.Memory

		Release(veh or (d and d.veh), bot)

		data.Drive = nil
		data.UseKey = false

		-- (data.InVehicle is cleared by the leave hook; until then SetState
		-- refuses, and this is tried again on the next think.)
		if data.InVehicle then return end

		if d and d.purpose == "trip" and d.arrived then data.HomePos = bot:GetPos() end

		data.NextVehicleTry = CurTime() + math.Rand(40, 90)

		local target = mem.Target

		hg.bots.SetState(bot, (IsValid(target) and target:Alive() and hg.bots.PickReaction) and hg.bots.PickReaction(bot) or "idle")
	end

	--- Out of the seat (the car must already stand still).
	local function StepOut(bot, data, d, why)
		if d.stage ~= "out" then
			Debug(bot, "getting out:", why or "")

			d.stage = "out"
			d.t = CurTime()
		end
	end

	local function Park(bot, data, d, why)
		if d.stage == "park" or d.stage == "out" then return end

		Debug(bot, "parking:", why or "")

		d.stage = "park"
		d.t = CurTime()
		d.why = why
	end

	hg.bots.RegisterState("drive", {
		Enter = function(bot, data)
			local plan = data.DrivePlan or {}
			local now = CurTime()

			data.DrivePlan = nil
			data.Drive = {
				veh = plan.veh, purpose = plan.purpose or "trip", dest = plan.dest, path = plan.path,
				stage = data.InVehicle and "start" or "approach", t = now, began = now, stuck = 0,
			}

			data.Attacking = false
			data.AttackingSecondary = false
			data.Reloading = false
			data.Crouching = false
			data.UseKey = false
			data.Running = plan.purpose == "ram"

			hg.bots.ClearPath(data)

			local veh = plan.veh

			if IsValid(veh) and not data.InVehicle then
				veh.hgBotClaim = bot
				veh.hgBotClaimUntil = now + 30

				local d = data.Drive

				d.door = veh.GetSeatExitPos and veh:GetSeatExitPos(1) or veh:GetPos()

				-- No route to the door (a door point the navmesh does not
				-- reach, or the car parked across the way): round a bumper
				-- first, and only then give the car up.
				if not hg.bots.SetGoal(bot, d.door, { force = true }) then
					local p = DetourPoint(bot, veh, d.door)

					if p and hg.bots.SetGoal(bot, p, { force = true }) then
						d.detour, d.detourUntil = p, now + 6
					else
						Debug(bot, "no way to the driver's door of", veh:GetClass())
						Bad(veh, bot, 45)
						d.stage = "fail"
					end
				end
			end
		end,

		Leave = function(bot, data)
			local d = data.Drive

			if d then Release(d.veh, bot) end

			data.Drive = nil
			data.UseKey = false
			data.Running = false
		end,

		Think = function(bot, data)
			local now = CurTime()

			data.NextStateThink = now + 0.05

			local d = data.Drive
			local mem = data.Memory

			if not d then
				if data.InVehicle then
					data.Drive = { veh = data.InVehicle, purpose = "sit", stage = "park", t = now, began = now, stuck = 0 }
				else
					Finish(bot, data)
				end

				return
			end

			local veh = d.veh
			local seated = bot:InVehicle()
			local target = mem.Target
			local hasTarget = IsValid(target) and target:Alive()

			--\\ On foot: to the door, and in
			if d.stage == "fail" then Finish(bot, data, veh) return end

			if d.stage == "approach" or d.stage == "enter" then
				if seated then
					d.stage, d.t = "start", now
					return
				end

				-- Somebody else got there first, it drove off, it broke.
				if not hg_bot_vehicles:GetBool() or not Free(veh, bot, now) or now - d.began > 30 then
					Debug(bot, "gives the car up:", now - d.began > 30 and "took too long to reach it" or "no longer free")
					Finish(bot, data, veh)
					return
				end

				-- A trip is not worth walking past a man with a gun for.
				if hasTarget and d.purpose ~= "ram" then
					Debug(bot, "gives the car up: an enemy about")
					Finish(bot, data, veh)
					return
				end
				if hasTarget and d.purpose == "ram" and hg.bots.CanSee(bot, target) and bot:GetPos():DistToSqr(mem.TargetPos or target:GetPos()) < 400 * 400 then
					Finish(bot, data, veh) -- he is on top of the bot: no time for the car
					return
				end

				veh.hgBotClaimUntil = now + 10

				local seat = veh.seats[1]
				local seatD2 = bot:GetPos():DistToSqr(seat:GetPos())
				local near = seatD2 < 140 * 140 or bot:GetPos():DistToSqr(d.door) < 70 * 70

				if d.stage == "approach" then
					data.LookPos = nil

					-- Walking and getting nowhere: pressed against the car's
					-- side (its path ran under the car), or against anything.
					if bot:GetVelocity():Length2D() < 25 then
						d.stillSince = d.stillSince or now
					else
						d.stillSince = nil
					end

					local still = d.stillSince and now - d.stillSince or 0

					-- Right by the car for a while without reaching the exact
					-- door spot (it can sit just off the walkable ground, and
					-- the bot shuffles round it): close enough to get in.
					if seatD2 < 240 * 240 then
						d.closeSince = d.closeSince or now
					else
						d.closeSince = nil
					end

					if (still > 3 and seatD2 < 320 * 320) or (d.closeSince and now - d.closeSince > 2) then
						Debug(bot, "by the car, door spot out of reach - gets in from this side")

						d.stage, d.t, d.detour, d.stillSince, d.closeSince = "enter", now, nil, nil, nil

						hg.bots.ClearPath(data)

						return
					end

					if still > 1.2 and not d.detour and now >= (d.nextDetourCheck or 0) then
						d.nextDetourCheck = now + 2

						local p = DetourPoint(bot, veh, d.door)

						if p then
							d.detour, d.detourUntil = p, now + 6

							hg.bots.ClearPath(data)
							hg.bots.SetGoal(bot, p, { force = true })
						end
					end

					-- The car itself between the bot and the driver's door (it
					-- came up on the passenger side): the navmesh knows nothing
					-- of a parked car, so the path ran straight into its side.
					-- Round the nearer bumper first.
					if not d.detour and not near and now >= (d.nextDetourCheck or 0) then
						d.nextDetourCheck = now + 0.5

						if CarBetween(bot, veh, d.door) then
							local p = DetourPoint(bot, veh, d.door)

							if p then
								d.detour, d.detourUntil = p, now + 6

								hg.bots.ClearPath(data)
								hg.bots.SetGoal(bot, p, { force = true })
							end
						end
					end

					local done = hg.bots.FollowPath(bot, data)

					if d.detour and (done or now > d.detourUntil or bot:GetPos():DistToSqr(d.detour) < 70 * 70) then
						d.detour = nil
						d.nextDetourCheck = now + 1.5

						hg.bots.SetGoal(bot, d.door, { force = true })

						return
					end

					if near then
						d.stage, d.t = "enter", now
						d.detour = nil

						hg.bots.ClearPath(data)
					elseif done and not d.detour and seatD2 < 230 * 230 and not CarBetween(bot, veh, d.door) then
						-- As near the door as the ground goes (the exit point
						-- itself can lie off the navmesh): close enough to sit.
						d.stage, d.t = "enter", now

						hg.bots.ClearPath(data)
					elseif done and not d.detour then
						-- The route ended somewhere else (or there is none).
						d.tries = (d.tries or 0) + 1

						if seatD2 < 260 * 260 then
							-- The driver's door cannot be reached (against a
							-- wall, off the walkable ground) but the car is right
							-- here: in from this side, across the seats.
							Debug(bot, "door out of reach - gets in from this side")

							d.stage, d.t = "enter", now

							hg.bots.ClearPath(data)
						elseif d.tries > 2 or not hg.bots.SetGoal(bot, d.door, { force = true }) then
							Debug(bot, "gives the car up: cannot get to the door")
							Bad(veh, bot, 45)
							Finish(bot, data, veh)
						end
					end

					return
				end

				-- At the door: turn to it, hand on it, in.
				data.MoveTarget = nil
				data.Running = false
				data.LookPos = seat:GetPos() + UP * 20
				data.LookLock = true
				data.AimSpeed = 300

				-- (No real Use key here: Glide's own Use seats a player in
				-- whichever seat is nearest his eyes, which from the wrong
				-- side of the car is the passenger's.)
				if now - d.t > 0.6 then
					if hook.Run("CanPlayerEnterVehicle", bot, seat, 0) == false then
						Bad(veh, bot, 20)
						Finish(bot, data, veh)
						return
					end

					bot:SetAllowWeaponsInVehicle(false)
					bot:EnterVehicle(seat)

					if not bot:InVehicle() then
						Bad(veh, bot, 20)
						Finish(bot, data, veh)
						return
					end

					data.InVehicle = veh
					d.stage, d.t = "start", now

					Debug(bot, "got in", veh:GetClass(), "for", d.purpose)
				end

				return
			end
			--//

			-- Thrown out, killed the seat, the car is gone.
			if not seated then
				data.InVehicle = nil

				if IsValid(veh) then Idle(veh) end

				-- (On the floor after a crash: "downed" takes it from here.)
				Finish(bot, data, veh)
				return
			end

			veh = IsValid(veh) and veh or data.InVehicle
			d.veh = veh

			data.LookPos = nil
			data.MoveTarget = nil

			-- A passenger seat, or not a car this file knows how to drive.
			if not IsCar(veh) or veh:GetSeatDriver(1) ~= bot then
				if now - d.t > 2 then
					bot:ExitVehicle()
				end

				return
			end

			-- Knocked out at the wheel: hands off (Z-City does the rest).
			if bot.organism and bot.organism.otrub then
				Idle(veh)
				return
			end

			local speed = Speed(veh)

			--\\ Getting out
			if d.stage == "out" then
				Idle(veh)
				veh:SetInputBool(1, "handbrake", true)

				if now - d.t > 0.4 then
					bot:ExitVehicle()

					if bot:InVehicle() and now - d.t > 4 then
						-- Z-City would not let it out: wait where it is.
						d.t = now
					end
				end

				return
			end

			if d.stage == "park" then
				veh:SetInputFloat(1, "accelerate", 0)
				veh:SetInputFloat(1, "steer", 0)
				veh:SetInputFloat(1, "brake", speed > 40 and 1 or 0)
				veh:SetInputBool(1, "handbrake", speed < 200)

				if veh.SetIsHonking then veh:SetIsHonking(false) end

				if speed < 35 or now - d.t > 6 then StepOut(bot, data, d, d.why) end

				return
			end
			--//

			-- The car itself says stop.
			if not hg_bot_vehicles:GetBool() then Park(bot, data, d, "switched off") return end
			if veh:GetUp().z < 0.35 then
				d.flipped = d.flipped or now

				if now - d.flipped > 1.5 then StepOut(bot, data, d, "on its roof") return end
			else
				d.flipped = nil
			end

			-- Into deep water: stop first, then out (stepping out of a car
			-- that is still moving throws the driver through the
			-- windscreen - Z-City's fall-from-vehicle).
			if veh:WaterLevel() >= 2 then
				if speed > 60 then Park(bot, data, d, "in the water") else StepOut(bot, data, d, "in the water") end

				return
			end
			if (veh.GetIsEngineOnFire and veh:GetIsEngineOnFire()) or (veh.GetEngineHealth and veh:GetEngineHealth() <= 0.05) then
				Park(bot, data, d, "engine gone")
				return
			end

			if (d.stuck or 0) >= 5 then
				Bad(veh, bot, 120)
				Park(bot, data, d, "stuck for good")
				return
			end

			--\\ Just sat down: belt, engine
			if d.stage == "start" then
				Idle(veh)

				if now - d.t < 1.4 then return end

				if veh.GetEngineState and veh:GetEngineState() ~= 2 then
					if veh:GetEngineState() ~= 1 and now >= (d.nextStart or 0) then
						d.nextStart = now + 1.5
						veh:TurnOn()
					end

					if now - d.t < 6 then return end

					Bad(veh, bot, 120)
					StepOut(bot, data, d, "will not start")
					return
				end

				d.stage, d.t = "drive", now
				d.driveSince = now
			end
			--//

			if d.purpose == "sit" then Park(bot, data, d, "not its car") return end

			local cruise = hg_bot_vehicle_speed:GetFloat()

			-- A threat during a trip: run him down, or stop and fight.
			if hasTarget and d.purpose == "trip" then
				if hg_bot_vehicle_ram:GetBool() then
					d.purpose = "ram"
					d.ramSince = now
					d.path = nil

					Debug(bot, "trip over - going for", target:Nick())
				else
					Park(bot, data, d, "contact")
					return
				end
			end

			--\\ Running him down
			if d.purpose == "ram" then
				if not hasTarget then
					-- Nobody left: on with the trip if there was one, else out.
					if d.dest and not d.arrived then
						d.purpose = "trip"
						d.path = nil
					else
						d.noTarget = d.noTarget or now

						if now - d.noTarget > 3 then Park(bot, data, d, "nobody left to hit") return end

						Drive(bot, veh, d, veh:GetPos() + veh:GetForward() * 400, 0, now)
					end

					return
				end

				d.noTarget = nil
				d.ramSince = d.ramSince or now

				local char = hg.bots.GetCharacter and hg.bots.GetCharacter(target) or target
				local vpos = veh:GetPos()
				local canSee = SeesFromCar(veh, bot, target)
				local tpos = canSee and char:GetPos() or mem.TargetPos or char:GetPos()

				if canSee then
					mem.TargetPos = tpos
					mem.TargetSeenPos = tpos
					mem.TargetVel = char:GetVelocity()
					mem.LastSeen = now
				end

				mem.ContactHold = now

				local flat = (tpos - vpos):Length2D()
				local dz = math.abs(tpos.z - vpos.z)

				-- He is out of the car's reach for good (upstairs, indoors,
				-- half a minute of trying): as near as it got, then on foot.
				if now - d.ramSince > 45 or (flat < 350 and dz > 110) then
					Park(bot, data, d, "cannot reach him by car")
					return
				end

				if canSee and flat < 2200 and dz < 110 then
					-- Straight at where he will be, flat out.
					d.path = nil
					d.lostAt = nil

					local lead = Clamp(flat / math.max(speed, 350), 0, 1.2)
					local aim = tpos + (mem.TargetVel or vector_origin) * lead
					Drive(bot, veh, d, aim, cruise * 1.6, now, target)

					return
				end

				-- No line to him: the car route to where he was.
				if not d.path or now >= (d.nextRoute or 0) then
					d.nextRoute = now + 2.5

					local path = CarRoute(vpos, tpos)

					if path then
						d.path, d.pathIndex, d.lostAt = path, 1, nil
					else
						d.path = nil
						d.lostAt = d.lostAt or now

						if now - d.lostAt > 5 then
							Park(bot, data, d, "no way for a car to where he is")
							return
						end
					end
				end

				if d.path then
					if FollowRoute(bot, veh, d, cruise * 1.2, now) then d.path = nil end
				else
					Drive(bot, veh, d, vpos + veh:GetForward() * 300, 0, now)
				end

				return
			end
			--//

			--\\ A trip
			if not d.path then
				if d.dest then
					d.path = CarRoute(veh:GetPos(), d.dest)
				end

				if not d.path then
					d.dest, d.path = TripDestination(veh:GetPos())
				end

				if not d.path then
					Bad(veh, bot, 90)
					Park(bot, data, d, "nowhere a car can go from here")
					return
				end

				d.pathIndex = 1

				Debug(bot, "driving", math.floor(d.dest:Distance(veh:GetPos())), "u,", #d.path, "waypoints")
			end

			if FollowRoute(bot, veh, d, cruise, now) then
				d.arrived = true
				Park(bot, data, d, "arrived")
			elseif now - (d.driveSince or now) > 150 then
				Park(bot, data, d, "long enough")
			end
			--//
		end,
	})
--//

--\\ Deciding to take one
	local function MayDrive(bot, data)
		if not hg_bot_vehicles:GetBool() or not Glide then return false end
		if data.InVehicle or data.State == "drive" or IsValid(bot.FakeRagdoll) then return false end
		if not navmesh.IsLoaded() then return false end
		if hg.bots.GetFaction and hg.bots.GetFaction(bot) == "guard" then return false end

		return true
	end

	local function Take(bot, data, veh, purpose, dest, path)
		data.DrivePlan = { veh = veh, purpose = purpose, dest = dest, path = path }

		Debug(bot, "goes for", veh:GetClass(), "(" .. purpose .. ")")

		hg.bots.SetState(bot, "drive")

		return data.State == "drive"
	end

	hg.bots.TakeCar = function(bot, veh, purpose)
		local data = IsValid(bot) and bot.Bot

		if not data or not IsCar(veh) then return false end

		return Take(bot, data, veh, purpose or "trip")
	end

	--- Idle: a free car near by, somewhere far to go. (Called from the
	-- idle state, sv_bot_navigation.lua.)
	function hg.bots.CheckVehicleUse(bot, data)
		local now = CurTime()

		if now < (data.NextVehicleTry or 0) then return false end

		data.NextVehicleTry = now + math.Rand(20, 40)

		if not MayDrive(bot, data) then return false end
		if math.random() > hg_bot_vehicle_trip:GetFloat() then return false end

		local veh = FindCar(bot, hg_bot_vehicle_search:GetFloat())

		if not veh then return false end

		-- Only for a car that can actually go somewhere from where it stands.
		local dest, path = TripDestination(veh:GetPos())

		if not dest then
			Bad(veh, bot, 120)

			return false
		end

		return Take(bot, data, veh, "trip", dest, path)
	end

	--- In a fight: the enemy far off and out in the open, a car close by.
	-- (Called from the combat state, sv_bot_combat.lua.)
	function hg.bots.CheckVehicleCombat(bot, data, mem, target, now)
		if now < (data.NextVehicleFight or 0) then return false end

		data.NextVehicleFight = now + math.Rand(4, 8)

		if not hg_bot_vehicle_ram:GetBool() or not MayDrive(bot, data) then return false end
		if not mem.TargetPos then return false end

		local pos = bot:GetPos()
		local dist = pos:Distance(mem.TargetPos)

		if dist < 1300 or (mem.Suppression or 0) > 0.5 then return false end
		if math.abs(mem.TargetPos.z - pos.z) > 200 or not Outdoors(mem.TargetPos) then return false end

		local veh, vdist = FindCar(bot, math.min(hg_bot_vehicle_search:GetFloat(), 700))

		if not veh or vdist > dist * 0.5 then return false end
		if math.random() > 0.6 then return false end
		if not CarRoute(veh:GetPos(), mem.TargetPos) then return false end

		return Take(bot, data, veh, "ram")
	end

	concommand.Add("hg_bot_vehicle_take", function(ply, cmd, args)
		if IsValid(ply) and not ply:IsAdmin() then return end

		local function say(msg)
			print(msg)

			if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
		end

		local bot

		if IsValid(ply) then
			local ent = ply:GetEyeTrace().Entity

			bot = IsValid(ent) and (ent.IsHomigradBot and ent or (hg.RagdollOwner and hg.RagdollOwner(ent))) or nil
		end

		if not IsValid(bot) or not bot.IsHomigradBot then
			-- nobody looked at: the bot nearest to a free car
			local bestD

			for b in pairs(hg.bots.List or {}) do
				if IsValid(b) and b:Alive() and b.Bot and not b.Bot.InVehicle then
					local _, dd = FindCar(b, 100000)

					if dd and (not bestD or dd < bestD) then bot, bestD = b, dd end
				end
			end
		end

		if not IsValid(bot) or not bot.Bot then say("[hg.bots] no bot (look at one, or have one alive with a free Glide car on the map)") return end

		local veh = FindCar(bot, 100000)

		if not veh then say("[hg.bots] no free Glide car for " .. bot:Nick()) return end

		bot.Bot.NextVehicleTry = 0

		local ok = Take(bot, bot.Bot, veh, (args and args[1] == "ram") and "ram" or "trip")

		say("[hg.bots] " .. bot:Nick() .. (ok and " goes for " or " could not go for ") .. veh:GetClass())
	end, nil, "Make the bot you look at (or the one nearest a free car) take the nearest Glide car. 'hg_bot_vehicle_take ram' = to run its enemy over")
--//
