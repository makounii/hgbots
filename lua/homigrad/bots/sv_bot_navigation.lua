--[[
	Tarkov AI - Navigation

	Nav-mesh pathfinding + wandering on top of sv_bot_core's movement bridge
	(which already knows how to walk a bot toward a single data.MoveTarget
	point). This file turns a "go over there" goal into a sequence of
	MoveTargets, and provides the default wander/investigate "idle" state.

	Pathing (reworked):
	- A* over CNavArea adjacency with a binary heap (was an O(n) scan per
	  pop) and areas keyed by GetID() - CNavArea userdata are not
	  guaranteed to be the same Lua object each time they are returned, so
	  using them directly as table keys was fragile.
	- Real traversal costs: water, NAV_MESH_AVOID, crouch/jump areas, climbs
	  cost more; connections that are too high to climb or too deep to
	  drop are skipped. Optional threat avoidance (opts.avoidPos) makes a
	  retreating bot prefer routes out of the threat's sight/away from it.
	- Waypoints are placed on the shared border between consecutive areas
	  (portal points) instead of area centers, then string-pulled with a
	  body-width hull trace plus a continuous-ground check. The old line
	  trace let paths shave corners the bot's hull can't actually pass,
	  which is where a lot of "stuck on a door frame" came from.
	- Search budget: at most hg_bot_path_budget A* searches per server
	  tick. Extra requests are deferred (the bot keeps following its old
	  path) instead of spiking the tick when many bots repath at once.
	- Cheap retarget: when a chased goal only moved a little, the last
	  waypoint is swapped in place instead of running a new search.

	Following:
	- Intermediate waypoints are considered reached at hg_bot_arrive_dist
	  (was ignored - the movement bridge's 16u precise arrival made bots
	  slow down at every corner). Only the final point uses precise arrival.
	- Crouch-only areas make the bot crouch (data.NavCrouch); climbs and
	  NAV_MESH_JUMP transitions on the path make it jump (data.NavJumpAt).
	- Proactive obstacle probe (hg.bots.ProbeObstacles, called from the
	  movement bridge every 0.1 s while moving): knee-high obstacle it can
	  clear -> crouch-jump; blocked at head height only -> duck; closed door
	  ahead -> opened with Use (same as +use, respects locks) and a short
	  pause while it swings. Jump height comes from the bot's real
	  JumpPower and sv_gravity.
	- Stuck handling escalates: jump / open a door in front -> repath ->
	  give up.

	Helpers for other states:
	- hg.bots.PredictPosition(pos, vel, t) - where someone moving at vel
	  will be in t seconds, clamped to walkable ground (intercept / search).
	- hg.bots.GetSearchPoints(origin, dir, count) - hiding spots near a last
	  known position, biased along the direction the target was moving.
]]

hg.bots = hg.bots or {}

-- Same defensive redeclare as sv_bot_combat.lua - Z-City's loader doesn't
-- guarantee sv_bot_core.lua runs before this file.
hg.bots.States = hg.bots.States or {}
hg.bots.RegisterState = hg.bots.RegisterState or function(name, tbl) hg.bots.States[name] = tbl end

local hg_bot_wander_radius   = CreateConVar("hg_bot_wander_radius",   "2000", {FCVAR_ARCHIVE}, "Max distance from a bot's home position it will wander to", 100, 8192)
local hg_bot_arrive_dist     = CreateConVar("hg_bot_arrive_dist",     "40",   {FCVAR_ARCHIVE}, "Distance (units) at which an intermediate waypoint counts as reached", 8, 256)
local hg_bot_stuck_time      = CreateConVar("hg_bot_stuck_time",      "2.5",  {FCVAR_ARCHIVE}, "Seconds without meaningful progress before a bot repaths", 1, 15)
local hg_bot_pathviz         = CreateConVar("hg_bot_pathviz",         "0",    {FCVAR_ARCHIVE}, "Draw bot paths with debugoverlay", 0, 1)
local hg_bot_path_smoothing  = CreateConVar("hg_bot_path_smoothing",  "1",    {FCVAR_ARCHIVE}, "String-pull navmesh paths (skip waypoints with a clear line)", 0, 1)
local hg_bot_path_trace_z    = CreateConVar("hg_bot_path_trace_z",    "24",   {FCVAR_ARCHIVE}, "Height offset for path-simplification clearance traces, so small floor lips/stairs don't block a shortcut that's actually walkable", 0, 96)
local hg_bot_step_height     = CreateConVar("hg_bot_step_height",     "22",   {FCVAR_ARCHIVE}, "Maximum height change between path samples still considered walkable (Source's default step height is 18)", 8, 64)
local hg_bot_max_drop        = CreateConVar("hg_bot_max_drop",        "90",   {FCVAR_ARCHIVE}, "Maximum drop (units) a bot will willingly walk off. Beyond this a route is treated as a ledge and rejected", 32, 512)
local hg_bot_ground_sample   = CreateConVar("hg_bot_ground_sample",   "28",   {FCVAR_ARCHIVE}, "Spacing (units) between ground samples when validating a path segment - smaller catches narrower gaps but costs more traces", 8, 128)
local hg_bot_avoid_water     = CreateConVar("hg_bot_avoid_water",     "1",    {FCVAR_ARCHIVE}, "Treat water deeper than hg_bot_wade_depth as impassable when validating paths and ledges", 0, 1)
local hg_bot_wade_depth      = CreateConVar("hg_bot_wade_depth",      "40",   {FCVAR_ARCHIVE}, "Water up to this deep (units; a player's waist is about 36) is walked through; deeper is avoided while hg_bot_avoid_water is on. 0 = any water is avoided", 0, 200)
local hg_bot_ledge_guard     = CreateConVar("hg_bot_ledge_guard",     "1",    {FCVAR_ARCHIVE}, "Last-resort movement check: refuse to step off a drop bigger than hg_bot_max_drop even if the current path says to", 0, 1)
local hg_bot_astar_max_nodes = CreateConVar("hg_bot_astar_max_nodes", "4000", {FCVAR_ARCHIVE}, "Max nav areas expanded per A* search before giving up", 100, 50000)
local hg_bot_path_budget     = CreateConVar("hg_bot_path_budget",     "3",    {FCVAR_ARCHIVE}, "Max A* searches per server tick across all bots; extra requests wait for the next tick", 1, 64)
local hg_bot_smooth_lookahead = CreateConVar("hg_bot_smooth_lookahead", "8",  {FCVAR_ARCHIVE}, "How many waypoints ahead path smoothing tries to skip to", 2, 64)
local hg_bot_climb_height    = CreateConVar("hg_bot_climb_height",    "56",   {FCVAR_ARCHIVE}, "Max height between nav areas a bot will try to climb (jump) up", 18, 128)

local NAV_CROUCH = NAV_MESH_CROUCH or 1
local NAV_JUMP = NAV_MESH_JUMP or 2
local NAV_AVOID = NAV_MESH_AVOID or 128

-- Waypoint flag bits (data.PathFlags).
local FLAG_CROUCH = 1
local FLAG_JUMP = 2

local AreaFlags -- defined in the A* section (used by FindNavPath)

local UP_VEC = Vector(0, 0, 1)

-- Slightly wider than a player (16) would be too strict for doorways;
-- 15 keeps shortcuts a body-width off walls so bots don't clip corners.
local HULL_MINS = Vector(-15, -15, 0)
local HULL_MAXS = Vector(15, 15, 20)

--\\ Cheap traces
	-- The movement checks below run for every moving bot ten times a second.
	-- Two things made them expensive, and neither was the trace itself:
	-- - a Lua FUNCTION as the trace filter is called back for every entity
	--   the ray touches. "Not players, not NPCs" is now a list of class
	--   names, which the engine checks itself;
	-- - every util.TraceLine builds a new result table of twenty-odd
	--   fields. The hot traces write into one shared table (output = ...)
	--   and read what they need from it straight away.
	local BODIES = { "player" } -- class names: players + every NPC / nextbot class seen
	local bodyClass = { player = true }

	local function NoteBody(ent)
		if not IsValid(ent) or not (ent:IsNPC() or ent:IsNextBot()) then return end

		local class = ent:GetClass()

		if not bodyClass[class] then
			bodyClass[class] = true
			BODIES[#BODIES + 1] = class
		end
	end

	hook.Add("OnEntityCreated", "HG_Bots_BodyClasses", function(ent)
		timer.Simple(0, function() NoteBody(ent) end)
	end)

	for _, ent in ipairs(ents.GetAll()) do NoteBody(ent) end

	hg.bots.BodyFilter = BODIES

	local TR = {} -- shared result; valid until the next TraceQ / HullQ
	local lineQ = { output = TR }
	local hullQ = { output = TR }
	local util_TraceLine, util_TraceHull = util.TraceLine, util.TraceHull

	--- util.TraceLine into the shared result table TR.
	local function TraceQ(a, b, filter, mask)
		lineQ.start, lineQ.endpos, lineQ.filter, lineQ.mask = a, b, filter, mask

		return util_TraceLine(lineQ)
	end

	--- util.TraceHull into the shared result table TR.
	local function HullQ(a, b, mins, maxs, filter, mask)
		hullQ.start, hullQ.endpos, hullQ.mins, hullQ.maxs, hullQ.filter, hullQ.mask = a, b, mins, maxs, filter, mask

		return util_TraceHull(hullQ)
	end

	-- util.TraceLine is looked up again whenever a test harness swaps it.
	function hg.bots.RebindTraces() util_TraceLine, util_TraceHull = util.TraceLine, util.TraceHull end
--//

--\\ Level of detail
	-- A bot nobody is near does not need the same attention as one a player
	-- is looking at. "Far" = no human within hg_bot_lod_dist of it. Far bots
	-- steer, probe and scan at a fraction of the rate; what they decide is
	-- the same, only a little later.
	local hg_bot_lod      = CreateConVar("hg_bot_lod",      "1",    {FCVAR_ARCHIVE}, "Bots far from every player think, look and steer less often (same behaviour, less server time)", 0, 1)
	local hg_bot_lod_dist = CreateConVar("hg_bot_lod_dist", "3000", {FCVAR_ARCHIVE}, "A bot with no player within this distance counts as far away for hg_bot_lod", 500, 30000)

	local lodFar = {} -- [bot] = true while far
	local lodNext = 0

	local function UpdateLOD()
		local on = hg_bot_lod:GetBool()
		local d2 = hg_bot_lod_dist:GetFloat() ^ 2
		local humans = player.GetHumans()
		local hpos = {}

		for i = 1, #humans do
			local h = humans[i]

			-- (A spectator's eyes count too: someone watching is someone near.)
			hpos[i] = h:Alive() and h:GetPos() or h:EyePos()
		end

		for bot in pairs(hg.bots.List or {}) do
			local far = false

			if on and IsValid(bot) then
				far = true

				local p = bot:GetPos()

				for i = 1, #hpos do
					if p:DistToSqr(hpos[i]) < d2 then far = false break end
				end
			end

			lodFar[bot] = far or nil

			if bot.Bot then bot.Bot.Far = far end
		end

		for bot in pairs(lodFar) do
			if not (hg.bots.List or {})[bot] then lodFar[bot] = nil end
		end
	end

	hook.Add("Think", "HG_Bots_LOD", function()
		local now = CurTime()

		if now < lodNext then return end

		lodNext = now + 0.5

		UpdateLOD()
	end)

	--- Is this bot far from every player (see hg_bot_lod)?
	function hg.bots.IsFar(bot) return lodFar[bot] == true end
--//

--\\ Water
	-- Shallow water is ground to walk on, deep water is a ledge. Any water
	-- used to be a cliff: a bot with a puddle round its feet found every
	-- step "unsafe" (the ledge guard in the movement bridge runs this file's
	-- ground check every tick) and stood there for good, and the path search
	-- refused every nav area the engine marks underwater - which it does
	-- with water 1 unit above the floor.

	--- Water still there wading-deep above this floor point?
	local function DeepAt(floor)
		local depth = hg_bot_wade_depth:GetFloat()

		if depth <= 0 then return true end

		return bit.band(util.PointContents(floor + Vector(0, 0, depth)), CONTENTS_WATER) ~= 0
	end

	--- Already in water to the waist or deeper: any way out is a good one,
	-- so nothing about water stops this bot.
	local function InDeepWater(ent)
		return IsValid(ent) and ent:IsPlayer() and ent:WaterLevel() >= 2
	end

	local areaDeep, areaDeepAt = {}, nil

	--- An underwater nav area too deep to wade: deep at its middle or at
	-- two of its corners. (Cached by area id, per wading depth.)
	function hg.bots.IsDeepWaterArea(area)
		if not area:IsUnderwater() then return false end

		local depth = hg_bot_wade_depth:GetFloat()

		if areaDeepAt ~= depth then areaDeep, areaDeepAt = {}, depth end

		local id = area:GetID()
		local deep = areaDeep[id]

		if deep == nil then
			deep = DeepAt(area:GetCenter() + UP_VEC)

			if not deep then
				local n = 0

				for i = 0, 3 do
					if DeepAt(area:GetCorner(i) + UP_VEC) then n = n + 1 end
				end

				deep = n >= 2
			end

			areaDeep[id] = deep
		end

		return deep
	end

	-- A new navmesh (or one patched) gets its areas looked at afresh.
	hook.Add("PostCleanupMap", "HG_Bots_WaterAreas", function() areaDeep = {} end)
--//

--\\ Ground checks
	-- Ground traces count props/ramps as floor; players and NPCs don't.
	local Z2 = Vector(0, 0, 2)
	local CONTENTS_WATER, CONTENTS_SLIME = CONTENTS_WATER, CONTENTS_SLIME
	local PointContents, band = util.PointContents, bit.band

	--- Is there continuous, walkable ground along the straight line a->b?
	-- A clearance trace only answers "is there a wall"; this answers "is
	-- there a floor" - no pits, no cliffs, no deep water.
	local function IsSegmentWalkable(a, b, filterEnt)
		local dist = a:Distance(b)

		if dist < 1 then return true end

		local stepHeight = hg_bot_step_height:GetFloat()
		local maxDrop = hg_bot_max_drop:GetFloat()
		local spacing = hg_bot_ground_sample:GetFloat()
		local avoidWater = hg_bot_avoid_water:GetBool() and not InDeepWater(filterEnt)

		local steps = math.ceil(dist / spacing)
		local delta = (b - a) / steps
		local up = Vector(0, 0, stepHeight)
		local down = Vector(0, 0, maxDrop + stepHeight)

		local prevZ

		for s = 0, steps do
			local sample = a + delta * s

			TraceQ(sample + up, sample - down, BODIES, MASK_NPCSOLID)

			if not TR.Hit then return false end

			local hitZ = TR.HitPos.z

			if avoidWater then
				local floor = TR.HitPos + Z2
				local contents = PointContents(floor)

				if band(contents, CONTENTS_WATER) ~= 0 and DeepAt(floor) then return false end
				if band(contents, CONTENTS_SLIME) ~= 0 then return false end
			end

			if prevZ and math.abs(hitZ - prevZ) > stepHeight then
				-- Big change between two coarse samples: a staircase (many
				-- small steps) or a real ledge (one big one)? Look closer.
				-- Without this, steep stairs read as ledges - bots jumped on
				-- them and paths/patching refused to use them.
				local sub = math.max(2, math.ceil(spacing / 8))
				local subPrev = prevZ
				local from = a + delta * (s - 1)

				for k = 1, sub do
					local sp = from + delta * (k / sub)

					TraceQ(sp + up, sp - down, BODIES, MASK_NPCSOLID)

					if not TR.Hit or math.abs(TR.HitPos.z - subPrev) > stepHeight then
						return false
					end

					subPrev = TR.HitPos.z
				end
			end

			prevZ = hitZ
		end

		return true
	end

	hg.bots.IsSegmentWalkable = IsSegmentWalkable

	--- Body-width clearance between two points at knee-to-chest height.
	local function IsSegmentClear(a, b, filterEnt)
		local z = Vector(0, 0, hg_bot_path_trace_z:GetFloat())

		HullQ(a + z, b + z, HULL_MINS, HULL_MAXS, filterEnt, MASK_NPCSOLID_BRUSHONLY)

		return not TR.Hit
	end

	hg.bots.IsSegmentClear = IsSegmentClear

	--- Would stepping from the bot's current position in dir be safe?
	-- Checked every tick in the movement bridge (combat strafes in
	-- directions no path validated). Cached per bot: at 66 ticks/s the
	-- answer barely changes between ticks, and this was 2+ traces per
	-- moving bot per tick.
	local STEP_CACHE_TIME = 0.1

	function hg.bots.IsStepSafe(bot, dir, lookahead)
		if not hg_bot_ledge_guard:GetBool() then return true end
		if not dir or not bot:IsOnGround() then return true end

		local pos = bot:GetPos()
		local now = CurTime()
		local c = bot.hgBotStepCache

		if c and now - c.t < (lodFar[bot] and STEP_CACHE_TIME * 2 or STEP_CACHE_TIME) and c.dir:Dot(dir) > 0.95 and c.pos:DistToSqr(pos) < 8 * 8 then
			return c.safe
		end

		local safe = IsSegmentWalkable(pos, pos + dir * (lookahead or 26), bot)

		if not c then
			c = { dir = Vector() }
			bot.hgBotStepCache = c
		end

		c.t, c.pos, c.safe = now, pos, safe
		c.dir:Set(dir)

		return safe
	end
--//
--\\ A*
	local function heapPush(heap, f, id)
		local n = heap.n + 1
		local hf, hid = heap.f, heap.id

		heap.n = n
		hf[n], hid[n] = f, id

		while n > 1 do
			local p = math.floor(n / 2)

			if hf[p] <= hf[n] then break end

			hf[p], hf[n] = hf[n], hf[p]
			hid[p], hid[n] = hid[n], hid[p]
			n = p
		end
	end

	local function heapPop(heap)
		local n = heap.n
		if n == 0 then return nil end

		local hf, hid = heap.f, heap.id
		local top = hid[1]

		hf[1], hid[1] = hf[n], hid[n]
		hf[n], hid[n] = nil, nil
		n = n - 1
		heap.n = n

		local i = 1

		while true do
			local l = i * 2
			local r = l + 1
			local s = i

			if l <= n and hf[l] < hf[s] then s = l end
			if r <= n and hf[r] < hf[s] then s = r end
			if s == i then break end

			hf[i], hf[s] = hf[s], hf[i]
			hid[i], hid[s] = hid[s], hid[i]
			i = s
		end

		return top
	end

	--\\ Nav cache
	-- The search used to ask the engine about every edge it looked at:
	-- centres, attributes, height change, water - eight calls into C and
	-- two new Vectors per edge, thousands of edges per search on a big
	-- map. None of that changes while a map runs, so each area is asked
	-- once and the search itself is plain Lua numbers after that.
	local NC = {} -- [area id] = node
	local ncCount = -1

	local function NavCacheReset()
		NC = {}
		ncCount = navmesh.GetNavAreaCount()
	end

	hg.bots.NavCacheReset = NavCacheReset

	local WET_UP = Vector(0, 0, 16)

	local function AreaWet(area)
		if area:IsUnderwater() then return true end
		if bit.band(util.PointContents(area:GetCenter() + WET_UP), CONTENTS_WATER) ~= 0 then return true end

		for i = 0, 3 do
			if bit.band(util.PointContents(area:GetCorner(i) + WET_UP), CONTENTS_WATER) ~= 0 then return true end
		end

		return false
	end

	local function Node(area)
		local id = area:GetID()
		local n = NC[id]

		if n then return n end

		local c = area:GetCenter()

		n = {
			area = area, id = id, x = c.x, y = c.y, z = c.z,
			water = area:IsUnderwater(),
			-- for a car (sv_bot_vehicle.lua): how narrow, no crawling / hopping,
			-- and no water at all - the map's "underwater" flag misses pools
			-- and shallow edges, so the middle and the corners are looked at.
			w = math.min(area:GetSizeX(), area:GetSizeY()),
			wet = AreaWet(area),
			tight = area:HasAttributes(NAV_CROUCH) or area:HasAttributes(NAV_JUMP),
			-- static part of the cost of stepping INTO this area
			mult = (area:HasAttributes(NAV_AVOID) and 6 or 1) * (area:HasAttributes(NAV_CROUCH) and 1.4 or 1) * (area:HasAttributes(NAV_JUMP) and 2 or 1),
			blockedAt = -1, blocked = false,
		}

		NC[id] = n

		return n
	end

	--- Neighbours of a node: n.adj (nodes), n.adjDist (centre to centre),
	-- n.adjDz (height change of the connection).
	local function Neighbours(n)
		local adj = n.adj

		if adj then return adj end

		adj = {}

		local dist, dzs = {}, {}
		local area = n.area
		local hasDz = area.ComputeAdjacentConnectionHeightChange ~= nil

		for i, nb in ipairs(area:GetAdjacentAreas()) do
			local m = Node(nb)
			local dx, dy, dz = m.x - n.x, m.y - n.y, m.z - n.z

			adj[i] = m
			dist[i] = math.sqrt(dx * dx + dy * dy + dz * dz)
			dzs[i] = hasDz and area:ComputeAdjacentConnectionHeightChange(nb) or false
		end

		n.adj, n.adjDist, n.adjDz = adj, dist, dzs

		return adj
	end

	--- Blocked areas (doors, nav blockers) do change: asked at most once a
	-- second per area.
	local function IsBlockedNode(n, now)
		if now - n.blockedAt > 1 then
			n.blockedAt = now
			n.blocked = n.area.IsBlocked ~= nil and n.area:IsBlocked() or false
		end

		return n.blocked
	end
	--//
	--- Waypoint flags for the transition a -> b: crouch-only area, or a
	-- step up that needs a jump (a climb, or an area marked NAV_MESH_JUMP).
	AreaFlags = function(a, b)
		local f = 0

		if a:HasAttributes(NAV_CROUCH) or b:HasAttributes(NAV_CROUCH) then
			f = bit.bor(f, FLAG_CROUCH)
		end

		local dz = a.ComputeAdjacentConnectionHeightChange and a:ComputeAdjacentConnectionHeightChange(b) or 0

		if b:HasAttributes(NAV_JUMP) then
			f = bit.bor(f, FLAG_JUMP)
		elseif dz > 32 then
			-- A big height change between areas is often just a staircase
			-- with a hole in the mesh: only a jump if it can't be walked.
			local pa = a:GetClosestPointOnArea(b:GetCenter())
			local pb = b:GetClosestPointOnArea(a:GetCenter())

			if not IsSegmentWalkable(pa, pb) then
				f = bit.bor(f, FLAG_JUMP)
			end
		end

		return f
	end

	--- Point on the shared border of two adjacent areas.
	local function PortalPoint(a, b)
		local pa = a:GetClosestPointOnArea(b:GetCenter())
		local pb = b:GetClosestPointOnArea(a:GetCenter())

		-- A drop or a climb: aim past the edge into the next area so the
		-- bot actually commits to it instead of stopping mid-air above it.
		if math.abs(pa.z - pb.z) > 18 then return pb end

		return (pa + pb) * 0.5
	end

	--- Greedy string-pulling with a body-width hull and a ground check.
	-- flags[i] (crouch) of skipped waypoints are OR'ed into the kept one
	-- so a skipped vent still makes the bot crouch.
	local function SimplifyPath(startPos, path, flags, filterEnt)
		if #path <= 1 or not hg_bot_path_smoothing:GetBool() then return path, flags end

		local lookahead = hg_bot_smooth_lookahead:GetInt()
		local simplified, outFlags = {}, {}
		local anchor = startPos
		local i = 0

		while i < #path do
			local farthest = i + 1

			for j = math.min(#path, i + lookahead), i + 2, -1 do
				-- Never skip across a crouch area boundary with a straight
				-- line at standing height - the hull check would pass
				-- through the vent opening only by luck.
				if anchor:DistToSqr(path[j]) < 1500 * 1500
					and IsSegmentClear(anchor, path[j], filterEnt)
					and IsSegmentWalkable(anchor, path[j], filterEnt)
				then
					farthest = j
					break
				end
			end

			-- Crouch of any skipped waypoint carries over (a skipped vent
			-- still needs crouching). Jump only from the kept waypoint's own
			-- transition: a skipped one was proven walkable, no jump needed.
			local f = bit.band(flags[farthest] or 0, FLAG_JUMP)

			for k = i + 1, farthest do
				if bit.band(flags[k] or 0, FLAG_CROUCH) ~= 0 then
					f = bit.bor(f, FLAG_CROUCH)
					break
				end
			end

			simplified[#simplified + 1] = path[farthest]
			outFlags[#outFlags + 1] = f
			anchor = path[farthest]
			i = farthest
		end

		return simplified, outFlags
	end

	local function NearestArea(pos)
		return navmesh.GetNavArea(pos, 96) or navmesh.GetNearestNavArea(pos, false, 2000, false, true)
	end

	--- A* over the navmesh from startPos to goalPos.
	-- @param opts table|nil { avoidPos = Vector, avoidRadius = number,
	--        avoidWeight = number } - threat-aware routing
	-- @return waypoints (table of Vector) and crouch flags, or nil
	local FindNavPathStrict

	--- A* over the navmesh from startPos to goalPos. Tries the strict rules
	-- first (no too-high climbs / too-deep drops / blocked areas), then once
	-- more with those filters off: on some navmeshes the height data of
	-- ordinary connections is off, and the strict pass then finds nothing
	-- at all - which left bots standing still with every wander goal
	-- "unreachable". Movement-time checks (ledge guard, obstacle probe)
	-- still protect a relaxed path.
	function hg.bots.FindNavPath(startPos, goalPos, filterEnt, opts)
		local path, flags = FindNavPathStrict(startPos, goalPos, filterEnt, opts, false)

		if path then return path, flags end

		return FindNavPathStrict(startPos, goalPos, filterEnt, opts, true)
	end

	FindNavPathStrict = function(startPos, goalPos, filterEnt, opts, relaxed)
		if not navmesh.IsLoaded() then return nil end

		-- A navmesh that grew or shrank (nav editing, generation, a load)
		-- is looked at afresh.
		if navmesh.GetNavAreaCount() ~= ncCount then NavCacheReset() end

		local startArea = NearestArea(startPos)
		local goalArea = NearestArea(goalPos)

		if not IsValid(startArea) or not IsValid(goalArea) then return nil end

		local startId, goalId = startArea:GetID(), goalArea:GetID()

		if startId == goalId then
			return { goalPos }, { goalArea:HasAttributes(NAV_CROUCH) and FLAG_CROUCH or 0 }
		end

		if opts and opts.avoidPos and not opts.avoidArea then
			opts.avoidArea = navmesh.GetNavArea(opts.avoidPos, 128)
		end

		local avoidWater = hg_bot_avoid_water:GetBool() and not InDeepWater(filterEnt)
		local maxDrop = hg_bot_max_drop:GetFloat()
		local climb = hg_bot_climb_height:GetFloat()
		local maxNodes = hg_bot_astar_max_nodes:GetInt()
		local now = CurTime()
		local sqrt = math.sqrt
		local IsDeep = hg.bots.IsDeepWaterArea

		local avoidPos = opts and opts.avoidPos
		local avoidArea = opts and opts.avoidArea
		local ax, ay, az, avoidR, avoidW

		if avoidPos then
			ax, ay, az = avoidPos.x, avoidPos.y, avoidPos.z
			avoidR = opts.avoidRadius or 700
		end

		avoidW = opts and opts.avoidWeight or 2

		-- opts.vehicle = the narrowest nav area a car may be routed through
		local vehicle = opts and opts.vehicle and (isnumber(opts.vehicle) and opts.vehicle or 110) or nil

		if avoidArea and not (IsValid(avoidArea) and avoidArea.IsPotentiallyVisible) then avoidArea = nil end

		local startNode, goalNode = Node(startArea), Node(goalArea)
		local gx, gy, gz = goalNode.x, goalNode.y, goalNode.z

		local nodes = { [startId] = startNode }
		local cameFrom = {}
		local gScore = { [startId] = 0 }
		local closed = {}
		local heap = { n = 0, f = {}, id = {} }

		do
			local dx, dy, dz = startNode.x - gx, startNode.y - gy, startNode.z - gz

			heapPush(heap, sqrt(dx * dx + dy * dy + dz * dz), startId)
		end

		local expanded = 0

		while heap.n > 0 do
			local currentId = heapPop(heap)

			if not closed[currentId] then
				if currentId == goalId then
					-- Reconstruct the area chain.
					local chain = {}
					local id = currentId

					while id do
						chain[#chain + 1] = nodes[id].area
						id = cameFrom[id]
					end

					-- (built goal-first: turn it round)
					for i = 1, math.floor(#chain / 2) do
						chain[i], chain[#chain - i + 1] = chain[#chain - i + 1], chain[i]
					end

					local path, flags = {}, {}

					for k = 1, #chain - 1 do
						local a, b = chain[k], chain[k + 1]

						-- An area removed under the cache: forget it all, and
						-- this search has no answer.
						if not IsValid(a) or not IsValid(b) then
							NavCacheReset()

							return nil
						end

						local f = AreaFlags(a, b)

						local pa = a:GetClosestPointOnArea(b:GetCenter())
						local pb = b:GetClosestPointOnArea(a:GetCenter())
						local hx, hy = pb.x - pa.x, pb.y - pa.y

						if hx * hx + hy * hy > 20 * 20 then
							-- A hole in the mesh between two connected areas
							-- (typical on stairs): leave this area at its edge
							-- and enter the next at its edge, instead of one
							-- waypoint floating over the gap.
							path[#path + 1] = pa
							flags[#flags + 1] = bit.band(f, FLAG_CROUCH)
							path[#path + 1] = pb
							flags[#flags + 1] = f
						else
							path[#path + 1] = PortalPoint(a, b)
							flags[#flags + 1] = f
						end
					end

					-- "Follow" patching: fill holes along paths bots use.
					if hg.bots.NavPatch and hg.bots.NavPatch.OnPath then
						hg.bots.NavPatch.OnPath(chain)
					end

					path[#path + 1] = goalPos
					flags[#flags + 1] = goalArea:HasAttributes(NAV_CROUCH) and FLAG_CROUCH or 0

					-- (A car's route is not pulled tight: a body-width
					-- shortcut past a corner is not one a car fits.)
					if vehicle then return path, flags end

					return SimplifyPath(startPos, path, flags, filterEnt)
				end

				closed[currentId] = true
				expanded = expanded + 1

				if expanded > maxNodes then return nil end

				local current = nodes[currentId]

				if not IsValid(current.area) then
					NavCacheReset()

					return nil
				end

				local baseG = gScore[currentId]
				local adj = Neighbours(current)
				local adjDist, adjDz = current.adjDist, current.adjDz

				for i = 1, #adj do
					local to = adj[i]
					local nid = to.id

					if not closed[nid] then
						-- Cost of stepping from current into to, or no step
						-- at all (step = nil).
						local step = adjDist[i]
						local mult = to.mult

						-- A route for a car: wide areas only, no water, nothing
						-- to crawl or hop through, no step it cannot roll over.
						if vehicle and (to.w < vehicle or to.tight or to.wet or (adjDz[i] and (adjDz[i] > 26 or adjDz[i] < -60))) then
							step = nil
						elseif to.water then
							local deep = IsDeep(to.area)

							if deep and avoidWater then
								step = nil
							else
								mult = mult * (deep and 3 or 1.5) -- wading is slow going
							end
						end

						if step and not relaxed then
							if IsBlockedNode(to, now) then
								step = nil
							else
								local dz = adjDz[i]

								if dz then
									if dz > climb or -dz > maxDrop then
										step = nil
									elseif dz > 18 then
										step = step + dz * 4 -- climbing is slow and risky
									end
								end
							end
						end

						if step then
							if avoidPos then
								local dx, dy, dz = to.x - ax, to.y - ay, to.z - az
								local d = sqrt(dx * dx + dy * dy + dz * dz)

								if d < avoidR then
									mult = mult * (1 + avoidW * 2 * (1 - d / avoidR))
								end
							end

							if avoidArea and to.area:IsPotentiallyVisible(avoidArea) then
								mult = mult * (1 + avoidW)
							end

							local g = baseG + step * mult

							if g < (gScore[nid] or math.huge) then
								nodes[nid] = to
								cameFrom[nid] = currentId
								gScore[nid] = g

								local dx, dy, dz = to.x - gx, to.y - gy, to.z - gz

								heapPush(heap, g + sqrt(dx * dx + dy * dy + dz * dz), nid)
							end
						end
					end
				end
			end
		end

		return nil
	end
	local function drawPathDebug(bot, path)
		if not hg_bot_pathviz:GetBool() then return end

		local prev = bot:GetPos()

		for _, point in ipairs(path) do
			debugoverlay.Line(prev, point, 2, Color(255, 180, 0), false)
			debugoverlay.Cross(point, 6, 2, Color(255, 80, 0), false)
			prev = point
		end
	end

	--- Pulls an arbitrary world position onto the navmesh.
	-- @return Vector|nil closest point on the nearest nav area
	function hg.bots.SnapToNavmesh(pos, maxDist)
		if not pos then return nil end
		if not navmesh.IsLoaded() then return pos end

		-- The area right under the point first: the "nearest area" search
		-- is many times dearer, and nearly every point asked about (a
		-- player's feet, a nav point) stands on one.
		local area = navmesh.GetNavArea(pos, 72)

		if not IsValid(area) then
			area = navmesh.GetNearestNavArea(pos, false, maxDist or 600, false, true)
		end

		if not IsValid(area) then return nil end

		return area:GetClosestPointOnArea(pos)
	end

	local budgetTick, budgetUsed = -1, 0

	local function TakePathBudget()
		local tick = engine.TickCount()

		if tick ~= budgetTick then
			budgetTick = tick
			budgetUsed = 0
		end

		if budgetUsed >= hg_bot_path_budget:GetInt() then return false end

		budgetUsed = budgetUsed + 1

		return true
	end

	--- Kicks off (re)pathing toward pos.
	-- @param opts table|nil passed to FindNavPath (threat avoidance), plus
	--        opts.force = true to skip the cheap-retarget shortcut
	-- @return boolean false if no usable route exists. A search deferred by
	--         the per-tick budget returns true (the bot keeps its current
	--         path and FollowPath retries next tick).
	function hg.bots.SetGoal(bot, pos, opts)
		if not IsValid(bot) or not bot.Bot or not pos then return false end

		local data = bot.Bot
		local now = CurTime()

		-- Failed-route throttle: don't re-run A* every tick at a target
		-- that simply can't be reached.
		if data.PathFailUntil and now < data.PathFailUntil
			and data.PathFailPos and data.PathFailPos:DistToSqr(pos) < 160 * 160
		then
			return false
		end

		local function fail()
			data.Path = nil
			data.PathFlags = nil
			data.MoveTarget = nil
			data.Goal = nil
			data.PendingGoal = nil
			data.PathFailPos = pos
			data.PathFailUntil = now + 1.5

			return false
		end

		local force = opts and opts.force

		-- Asked for the very place it is already walking to: nothing to do.
		-- (States ask again every think; the chase asked ten times a second.)
		if not force and data.Path and data.GoalAsked and data.GoalAsked:DistToSqr(pos) < 20 * 20 then
			return true
		end

		-- One search per bot every third of a second while it has a path to
		-- walk meanwhile (five a second at most when it has none): fifteen
		-- bots in a fight asked for 350 routes a second and got the 150 the
		-- budget let through, most of them to a goal that had moved a step.
		-- The newest wish waits (FollowPath asks again); a forced one -
		-- cover, a way out - is never held up.
		if not force and now < (data.NextSearchAt or 0) and (data.Path or now < (data.LastSearchAt or 0) + 0.2) then
			data.PendingGoal = pos
			data.PendingOpts = opts

			return true
		end

		local snapped = hg.bots.SnapToNavmesh(pos) or pos

		-- Cheap retarget: the goal moved a little (a chased target
		-- shuffling around) - swap the last waypoint in place if the
		-- previous one still has a clean line to it.
		if data.Path and data.Goal and not (opts and opts.force) and data.Goal:DistToSqr(snapped) < 220 * 220 then
			local last = #data.Path
			local from = data.Path[last - 1] or bot:GetPos()

			if IsSegmentClear(from, snapped, bot) and IsSegmentWalkable(from, snapped, bot) then
				data.Path[last] = snapped
				data.Goal = snapped
				data.GoalAsked = pos

				if data.PathIndex > last then
					data.MoveTarget = snapped
				end

				return true
			end
		end

		if not TakePathBudget() then
			data.PendingGoal = snapped
			data.PendingOpts = opts

			return true
		end

		data.PendingGoal = nil
		data.PendingOpts = nil
		data.NextSearchAt = now + (lodFar[bot] and 0.7 or 0.35) + math.Rand(0, 0.1)
		data.LastSearchAt = now

		local path, flags = hg.bots.FindNavPath(bot:GetPos(), snapped, bot, opts)

		if not path then
			-- With a navmesh present, no route means no route - don't fall
			-- back to walking in a straight line into water or off a roof.
			if navmesh.IsLoaded() then return fail() end

			if not IsSegmentWalkable(bot:GetPos(), snapped, bot) then return fail() end

			path, flags = { snapped }, { 0 }
		end

		data.PathFailUntil = nil
		data.PathFailPos = nil

		data.Goal = snapped
		data.GoalAsked = pos
		data.GoalOpts = opts
		data.Path = path
		data.PathFlags = flags
		data.PathIndex = 1
		data.MoveTarget = nil
		data.StuckPos = bot:GetPos()
		data.StuckSince = now
		data.StuckAttempts = 0
		data.UnstickStage = 0

		drawPathDebug(bot, path)

		return true
	end

	--- Has the place a state wants to go moved more than dist away from
	-- where the bot is already going (or waiting to be routed to)? What
	-- states should ask before SetGoal on a moving target, instead of
	-- comparing with data.Goal alone - that is nil while a search waits
	-- for its turn, and the state asked again every think.
	function hg.bots.GoalMoved(data, pos, dist)
		local g = data.PendingGoal or data.GoalAsked or data.Goal

		if not g or not (data.Path or data.PendingGoal) then return true end

		return g:DistToSqr(pos) > dist * dist
	end

	--- Clears every bit of path state (used when a state wants the bot to
	-- stop moving right now).
	function hg.bots.ClearPath(data)
		data.Path = nil
		data.GoalAsked = nil
		data.PathFlags = nil
		data.Goal = nil
		data.MoveTarget = nil
		data.PendingGoal = nil
		data.PendingOpts = nil
		data.NavCrouch = false
		data.NavJumpAt = nil
	end

	local function IsDoor(ent)
		if not IsValid(ent) then return false end

		if hgIsDoor then
			local ok, res = pcall(hgIsDoor, ent)

			if ok and res then return true end
		end

		local class = ent:GetClass()

		return class == "prop_door_rotating" or class == "func_door" or class == "func_door_rotating"
	end

	hg.bots.IsDoor = IsDoor

	--- Is this door closed (or closing)? Unknown door types count as
	-- closed - using one that's open would just close it, so callers also
	-- keep a per-door cooldown.
	local function IsDoorClosed(ent)
		local class = ent:GetClass()

		if class == "prop_door_rotating" then
			local st = ent:GetInternalVariable("m_eDoorState")

			return st == nil or st == 0 or st == 3 -- closed / closing
		end

		if class == "func_door" or class == "func_door_rotating" then
			local st = ent:GetInternalVariable("m_toggle_state")

			return st == nil or st == 1 or st == 3 -- at bottom (closed) / going down
		end

		return true
	end

	--\\ Breach: windows / glass (instead of a closed door, or in the way)
	local BREAKABLE_CLASSES = { func_breakable_surf = true, func_breakable = true }

	local PASS_MINS, PASS_MAXS = Vector(-13, -13, 0), Vector(13, 13, 34)
	local KICK_HULL = Vector(5, 5, 5)

	--- Something the bot can smash through: glass (func_breakable_surf) or a
	-- func_breakable that takes damage (not trigger-only, not invulnerable).
	local function IsBreakablePane(ent)
		if not IsValid(ent) then return false end

		local class = ent:GetClass()

		if not BREAKABLE_CLASSES[class] then return false end
		if class == "func_breakable_surf" then return true end

		-- spawnflag 1 = "only break on trigger"; health 0 = invulnerable
		if ent:HasSpawnFlags(1) then return false end

		local hp = ent:Health()

		return hp > 0 and hp <= 400
	end

	--- Pane geometry: normal (the thin axis), extents, and the spot the bot
	-- goes through - the pane's centre, or the part of a long pane nearest
	-- to anchor (where the path hits it).
	local function PaneGeometry(bot, ent, anchor)
		local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
		local size = maxs - mins
		local center = ent:WorldSpaceCenter()

		local normal, lat, width

		if size.x <= size.y and size.x < 16 then
			normal, lat, width = Vector(1, 0, 0), Vector(0, 1, 0), size.y
		elseif size.y < size.x and size.y < 16 then
			normal, lat, width = Vector(0, 1, 0), Vector(1, 0, 0), size.x
		end

		if not normal or width < 28 or size.z < 40 then return nil end

		local c = Vector(center.x, center.y, center.z)

		if anchor and width > 40 then
			local half = width * 0.5 - 20
			c = c + lat * math.Clamp((anchor - center):Dot(lat), -half, half)
		end

		local botPos = bot:GetPos()
		local bottom = center.z - size.z * 0.5
		local side = (botPos - c):Dot(normal) >= 0 and 1 or -1

		return {
			ent = ent, center = c, normal = normal, lat = lat, side = side,
			width = width, bottom = bottom, top = bottom + size.z,
			sill = bottom - botPos.z, low = size.z < 64,
		}
	end

	--- Stand point in front of the pane, distance d from its plane.
	local function StandPoint(bot, b, d)
		local p = b.center + b.normal * (b.side * d)
		p.z = bot:GetPos().z + 4

		return p
	end

	--- Fills in the far side landing point. @return false if there's no
	-- floor behind the pane (and requireFloor is set).
	local function PaneBack(b, requireFloor)
		local back = b.center - b.normal * (b.side * 44)

		local floor = util.TraceLine({
			start = Vector(back.x, back.y, b.bottom + 16),
			endpos = Vector(back.x, back.y, b.bottom - 90),
			mask = MASK_PLAYERSOLID_BRUSHONLY,
		})

		if floor.Hit and not floor.StartSolid then
			b.back = floor.HitPos + Vector(0, 0, 4)
		elseif requireFloor then
			return false
		else
			back.z = b.bottom
			b.back = back
		end

		return true
	end

	--- Is there a person-sized way through yet? A single bullet hole
	-- already flags func_breakable_surf as "broken", so the real test is a
	-- crouched hull through the opening.
	-- @return "pane" (still blocks), "clear", or "wall" (something else)
	local function PaneStatus(bot, b)
		if not IsValid(b.ent) then return "clear" end

		local z = math.max(bot:GetPos().z, b.bottom) + 2
		local a = b.center + b.normal * (b.side * 30)
		local c = b.center - b.normal * (b.side * 30)

		a.z, c.z = z, z

		local tr = util.TraceHull({
			start = a, endpos = c,
			mins = PASS_MINS, maxs = PASS_MAXS,
			filter = bot, mask = MASK_PLAYERSOLID,
		})

		if not tr.Hit then return "clear" end

		return tr.Entity == b.ent and "pane" or "wall"
	end

	--- A breakable pane near the door that is a real way through: thin,
	-- big enough to fit a person, a sill low enough to climb, floor on the
	-- far side, and the far side is where the bot wants to go.
	local function FindBreachBypass(bot, data, door)
		local goal = data.Goal or (data.Memory and data.Memory.TargetPos)

		if not goal then return nil end

		local botPos = bot:GetPos()
		local best, bestD

		for _, ent in ipairs(ents.FindInSphere(door:WorldSpaceCenter(), 280)) do
			if IsBreakablePane(ent) then
				local b = PaneGeometry(bot, ent)

				if b and b.sill > -12 and b.sill < 50 and (goal - b.center):Dot(b.normal) * -b.side > 32 then
					local front = StandPoint(bot, b, 40)
					local d = botPos:Distance(front)

					if d < 420 and (not bestD or d < bestD)
						and IsSegmentClear(botPos, front, bot)
						and PaneStatus(bot, b) == "pane"
						and PaneBack(b, true)
					then
						b.door = door
						b.front = front
						best, bestD = b, d
					end
				end
			end
		end

		return best
	end

	--- A pane straight in the bot's way (navmesh generation ignores
	-- breakables, so paths happily run through windows): smash it.
	local function StartPaneBreach(bot, data, ent, hitPos)
		local now = CurTime()

		if data.Breach then return true end
		if ent.hgBotBypassFailed and (ent.hgBotBypassFailed[bot] or 0) > now then return false end

		local b = PaneGeometry(bot, ent, hitPos)

		if not b or b.sill > 56 then return false end
		if PaneStatus(bot, b) ~= "pane" then return false end

		PaneBack(b, false)

		b.front = StandPoint(bot, b, 40)
		b.stage = "approach"
		b.started = now
		b.t = now
		data.Breach = b

		return true
	end

	local function EndBreach(bot, data, failed)
		local b = data.Breach

		data.Breach = nil
		data.ForceLookUntil = nil
		data.ForceAttackUntil = nil

		if b and b.tookHands then
			data.NextWeaponSwitch = 0 -- back to the real weapon
		end

		if failed and b then
			for _, ent in ipairs({ b.door, b.ent }) do
				if IsValid(ent) then
					ent.hgBotBypassFailed = ent.hgBotBypassFailed or {}
					ent.hgBotBypassFailed[bot] = CurTime() + 30
				end
			end
		end

		if data.Goal then
			local goal, opts = data.Goal, data.GoalOpts

			hg.bots.SetGoal(bot, goal, { force = true, avoidPos = opts and opts.avoidPos, avoidRadius = opts and opts.avoidRadius, avoidWeight = opts and opts.avoidWeight })
		end
	end

	-- Spots across the pane to hit one after another, so the hole grows
	-- to a person-sized opening instead of the same spot being hit.
	local HIT_PATTERN = {
		{ 0, 0 }, { -14, -8 }, { 14, -8 }, { 0, -18 }, { -20, 6 }, { 20, 6 }, { 0, 14 }, { -8, -26 }, { 8, -26 },
	}

	local function PaneAimPoint(bot, b, n)
		local off = HIT_PATTERN[(n % #HIT_PATTERN) + 1]
		local halfW = math.max(b.width * 0.5 - 6, 0)
		local z = math.Clamp(bot:EyePos().z - 10 + off[2], b.bottom + 8, b.top - 8)

		local p = b.center + b.normal * (b.side * 1) + b.lat * math.Clamp(off[1], -halfW, halfW)
		p.z = z

		return p
	end

	--- Z-City's kick traces from the eyes at pitch >= 10 (82u), after the
	-- kick animation has shoved the kicker back a bit off the wall. Find a
	-- look point on the pane that this trace would actually hit.
	local function KickLookPos(bot, b)
		if not bot.LegAttack then return nil end

		local eye = bot:EyePos()
		local back = b.normal * (b.side * 22) -- the pre-kick shove away from the wall
		local zs = { eye.z - 12, (b.bottom + b.top) * 0.5, b.bottom + 14 }

		for _, z in ipairs(zs) do
			z = math.Clamp(z, b.bottom + 6, b.top - 6)

			local look = b.center + b.normal * (b.side * 1)
			look.z = z

			local ang = (look - eye):Angle()
			local pitch = math.NormalizeAngle(ang.p)

			if pitch <= 50 then
				ang.p = math.max(pitch, 10)

				local start = eye + back

				local tr = util.TraceHull({
					start = start,
					endpos = start + ang:Forward() * 80,
					mins = -KICK_HULL, maxs = KICK_HULL,
					filter = bot,
				})

				if tr.Entity == b.ent then return look end
			end
		end

		return nil
	end

	local function HandsClass(bot)
		if bot:HasWeapon("weapon_hg_coolhands") then return "weapon_hg_coolhands" end
		if bot:HasWeapon("weapon_hands_sh") then return "weapon_hands_sh" end
	end

	--- How to hit the pane with what the bot has: a melee weapon swing,
	-- a kick, gunfire, or bare fists. @return method, stand distance
	local function PickBreakMethod(bot, b)
		local wep = bot:GetActiveWeapon()
		local nade = IsValid(wep) and wep.Throw ~= nil and wep.ENT ~= nil

		if IsValid(wep) and not nade and not wep.GetFists and hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep) then
			return "melee", 32
		end

		if not b.noKick then return "kick", 40 end

		if IsValid(wep) and not nade and not wep.GetFists and hg.bots.GetWeaponKind and hg.bots.GetWeaponKind(bot, true) == "gun" then
			return "gun", 40
		end

		-- A grenade with its pin out must never be switched away from.
		if nade and (wep.ReadyToThrow or wep.InThrowing) then return "wait", 40 end

		if HandsClass(bot) then return "fists", 22 end

		return "gun", 40 -- nothing better: whatever is in hand
	end

	--- Drives an active breach instead of normal path following:
	-- approach -> break the pane -> climb through -> repath.
	local function UpdateBreach(bot, data)
		local b = data.Breach
		local now = CurTime()
		local pos = bot:GetPos()

		if now - b.started > 16 then EndBreach(bot, data, true) return end

		if b.stage == "approach" then
			if PaneStatus(bot, b) ~= "pane" then b.stage = "through" b.t = now return end

			data.MoveTarget = b.front

			if (b.front - pos):Length2D() < 26 then
				b.stage = "break"
				b.t = now
			elseif now - b.t > 5 then
				EndBreach(bot, data, true)
			end

			return
		end

		if b.stage == "break" then
			data.MoveTarget = nil
			data.DuckUntil = nil

			local status = PaneStatus(bot, b)

			if status ~= "pane" then
				b.stage = "through"
				b.t = now
				data.ForceAttackUntil = nil
				data.ForceLookUntil = nil
				return
			end

			if now - b.t > 10 then EndBreach(bot, data, true) return end

			local method, standDist = PickBreakMethod(bot, b)

			-- Get to striking distance for this method (fists reach much
			-- less than a bat) before swinging at air.
			local planeDist = math.abs((pos - b.center):Dot(b.normal))

			if planeDist > standDist + 8 and now >= (b.nextHit or 0) - 0.3 then
				data.MoveTarget = StandPoint(bot, b, standDist)
				data.ForceLookPos = b.center
				data.ForceLookUntil = now + 0.3
				return
			end

			data.PauseMoveUntil = now + 0.2

			if method == "kick" then
				-- Mid-kick: keep the view where the kick was aimed.
				if now < (b.nextHit or 0) then return end

				local look = KickLookPos(bot, b)

				if not look or (b.kicks or 0) >= 3 then
					b.noKick = true
					return
				end

				if not (hg.bots.CanKick == nil or hg.bots.CanKick(bot)) then return end

				b.kicks = (b.kicks or 0) + 1
				b.nextHit = now + 1.5

				data.ForceLookPos = look
				data.ForceLookUntil = now + 1.1
				data.PauseMoveUntil = now + 1.1

				timer.Simple(0.2, function()
					if IsValid(bot) and bot:Alive() and not IsValid(bot.FakeRagdoll) and bot.Bot and bot.Bot.Breach == b then
						bot:LegAttack()
					end
				end)

				return
			end

			if method == "wait" then return end

			if method == "fists" then
				local wep = bot:GetActiveWeapon()

				if not (IsValid(wep) and wep.GetFists) then
					if now >= (b.nextHit or 0) then
						bot:SelectWeapon(HandsClass(bot))
						b.tookHands = true
						b.nextHit = now + 0.5
					end

					return
				end
			end

			-- Aim at the next spot across the pane, then hit once the view
			-- is on it: a shot, a swing, or a punch (the first click raises
			-- the fists).
			b.hitN = b.hitN or 0

			local aim = PaneAimPoint(bot, b, b.hitN)

			data.ForceLookPos = aim
			data.ForceLookUntil = now + 0.3

			if now < (b.nextHit or 0) then return end

			local dir = bot:GetAimVector()
			local want = (aim - bot:EyePos()):GetNormalized()

			if dir:Dot(want) < 0.97 then return end

			if method == "melee" then
				local wep = bot:GetActiveWeapon()

				if hg.bots.IsMeleeReady and not hg.bots.IsMeleeReady(wep, now) then return end

				b.nextHit = now + 0.75
			elseif method == "fists" then
				b.nextHit = now + 0.55
			else
				b.nextHit = now + 0.3
			end

			b.hitN = b.hitN + 1
			data.ForceAttackUntil = now + 0.1

			return
		end

		if b.stage == "through" then
			data.MoveTarget = b.back

			-- Over the sill / under a low frame.
			if b.low then data.DuckUntil = now + 0.3 end

			if b.sill > 16 and bot:IsOnGround() and (b.center - pos):Length2D() < 48 and now >= (b.nextJump or 0) then
				b.nextJump = now + 0.8
				data.JumpUntil = now + 0.15
				data.DuckUntil = now + 0.6
			end

			if (b.back - pos):Length2D() < 24 or now - b.t > 3.5 then
				EndBreach(bot, data, false)
			end
		end
	end

	hg.bots.UpdateBreach = UpdateBreach
	hg.bots.IsBreakablePane = IsBreakablePane
	--//

	--- Kicks a door with Z-City's own leg kick (Player:LegAttack): an
	-- unlocked door is slammed open, a locked one loses HP per kick and is
	-- blown off its hinges once it runs out (sv_legkick.lua). The kick
	-- traces straight ahead from the eyes, so the bot turns to the door
	-- first and stands still for it (kicks don't happen while sprinting).
	-- @return true if a kick is under way (the caller shouldn't also Use)
	local function KickDoor(bot, data, door, hitPos)
		local now = CurTime()

		if now < (data.NextDoorKick or 0) then
			data.PauseMoveUntil = now + 0.2 -- mid-kick / between kicks: stay put
			return true
		end

		if not bot.LegAttack then return false end
		if hg.bots.CanKick and not hg.bots.CanKick(bot) then return false end

		-- Kick reach is ~82u from the eyes; closer than that first.
		if not hitPos or bot:EyePos():Distance(hitPos) > 72 then return false end

		data.NextDoorKick = now + 1.4
		data.ForceLookPos = hitPos - Vector(0, 0, 6)
		data.ForceLookUntil = now + 0.9
		data.PauseMoveUntil = now + 0.9

		timer.Simple(0.15, function()
			if IsValid(bot) and bot:Alive() and not IsValid(bot.FakeRagdoll) then
				bot:LegAttack()
			end
		end)

		return true
	end

	--- Gets a closed door out of the way. Kicked in when it's locked, or
	-- when the bot is in a hurry (fighting, fleeing, running); otherwise
	-- opened by hand, the same way +use would (respects locks), with a
	-- short pause so the swinging door doesn't shove the bot back.
	local function OpenDoor(bot, data, door, hitPos)
		local now = CurTime()

		if not IsDoorClosed(door) then return false end

		local locked = door:GetInternalVariable("m_bLocked") == true
		-- Sneaking (crouched ambush approach, careful push) stays quiet.
		local sneaking = data.Crouching or data.SlowWalk
		local hurry = not sneaking and (data.Running or data.State ~= "idle")

		if locked or hurry then
			-- Before battering the door: a window/glass pane next to it that
			-- leads the same way is quicker (and often the smarter entry).
			local failed = door.hgBotBypassFailed and (door.hgBotBypassFailed[bot] or 0) > now

			if not data.Breach and not failed then
				local bypass = FindBreachBypass(bot, data, door)

				if bypass then
					bypass.stage = "approach"
					bypass.started = now
					bypass.t = now
					data.Breach = bypass

					return true
				end
			end

			if KickDoor(bot, data, door, hitPos) then return true end

			-- Locked and not in reach yet: keep walking up to it.
			if locked then return false end
		end

		door.hgBotUseCooldown = door.hgBotUseCooldown or {}

		if (door.hgBotUseCooldown[bot] or 0) > now then return false end

		door.hgBotUseCooldown[bot] = now + 2

		if not IsDoorClosed(door) then return false end

		door:Use(bot, bot, USE_ON, 1)

		data.PauseMoveUntil = now + 0.6

		return true
	end

	--- First stuck response: open a door in front, otherwise hop.
	local function TryUnstick(bot, data)
		local now = CurTime()
		local dir = data.MoveTarget and (data.MoveTarget - bot:GetPos()) or bot:EyeAngles():Forward()

		dir.z = 0

		if dir:LengthSqr() < 1 then dir = bot:EyeAngles():Forward() end

		dir:Normalize()

		local eye = bot:EyePos()
		local tr = util.TraceLine({
			start = eye,
			endpos = eye + dir * 72,
			filter = bot,
		})

		if IsDoor(tr.Entity) then
			if not OpenDoor(bot, data, tr.Entity, tr.HitPos) then
				-- Open but still in the way (swung toward us) - back off a
				-- step so it can be walked around.
				data.PauseMoveUntil = now + 0.4
			end

			return
		end

		-- Only hop when there's something knee-high in front; a bot pressed
		-- against a wall or another player gains nothing from jumping - the
		-- repath step handles those.
		local knee = util.TraceHull({
			start = bot:GetPos() + Vector(0, 0, 20),
			endpos = bot:GetPos() + Vector(0, 0, 20) + dir * 36,
			mins = Vector(-12, -12, 0),
			maxs = Vector(12, 12, 14),
			filter = BODIES,
			mask = MASK_PLAYERSOLID,
		})
		local chestClear = not util.TraceLine({
			start = bot:GetPos() + Vector(0, 0, 60),
			endpos = bot:GetPos() + Vector(0, 0, 60) + dir * 40,
			filter = bot,
			mask = MASK_PLAYERSOLID,
		}).Hit

		if knee.Hit and chestClear then
			data.JumpUntil = now + 0.2
		end
	end

	local STEER_INTERVAL = 0.1
	local STEER_SIDE = 64 -- how far to look sideways for walls
	local STEER_NEAR = 30 -- closer than this to a wall = push away
	local STEER_AHEAD = 44 -- forward-diagonal whisker length

	local function SteerFilter(ent)
		if not IsValid(ent) then return true end
		if ent:IsPlayer() or ent:IsNPC() then return false end

		return true
	end

	--- Local steering on top of the path: keeps the bot off walls and
	-- centered in narrow passages, and swings it wide of inner corners
	-- instead of scraping along them. Only bends the MOVE direction (never
	-- the view), so aiming, peeking and leaning are unaffected. Throttled:
	-- the bias is recomputed every STEER_INTERVAL and reused in between.
	-- @return Vector adjusted, normalized move direction
	function hg.bots.SteerMove(bot, data, moveDir)
		local now = CurTime()

		-- Close to the exact point we're walking to: go straight at it.
		if data.MoveTarget and (data.MoveTarget - bot:GetPos()):Length2D() < 24 then
			return moveDir
		end

		if now >= (data.NextSteer or 0) then
			data.NextSteer = now + (data.Far and STEER_INTERVAL * 2.5 or STEER_INTERVAL)

			local origin = bot:GetPos() + Vector(0, 0, 36)
			local fwd = Vector(moveDir.x, moveDir.y, 0)

			if fwd:LengthSqr() < 0.01 then return moveDir end

			fwd:Normalize()

			local right = fwd:Cross(UP_VEC)

			local function Dist(dir, len)
				TraceQ(origin, origin + dir * len, BODIES, MASK_PLAYERSOLID)

				return TR.Hit and not TR.StartSolid and TR.Fraction * len or len
			end

			local dl = Dist(-right, STEER_SIDE)
			local dr = Dist(right, STEER_SIDE)
			local bias = 0

			-- Open ground on both sides: no corner can be close enough for
			-- the diagonal whiskers to matter more than the next look will
			-- catch (half the traces, most of the time outdoors).
			if dl >= STEER_SIDE and dr >= STEER_SIDE and data.SteerOpen then
				data.SteerOpen = false -- every other look does check them
				data.SteerBias = 0
				data.SteerRight = right

				return moveDir
			end

			data.SteerOpen = dl >= STEER_SIDE and dr >= STEER_SIDE

			if dl < STEER_SIDE and dr < STEER_SIDE then
				-- Corridor / staircase with walls on both sides: drift to
				-- the middle.
				bias = math.Clamp((dr - dl) / math.max(dl + dr, 1), -1, 1) * 0.7
			elseif dl < STEER_NEAR then
				bias = (1 - dl / STEER_NEAR) * 0.8
			elseif dr < STEER_NEAR then
				bias = -(1 - dr / STEER_NEAR) * 0.8
			end

			-- Forward-diagonal whiskers: a corner coming up on one side.
			local fl = Dist((fwd - right):GetNormalized(), STEER_AHEAD)
			local fr = Dist((fwd + right):GetNormalized(), STEER_AHEAD)

			if fl < STEER_AHEAD and fl < fr then
				bias = bias + (1 - fl / STEER_AHEAD) * 0.6
			elseif fr < STEER_AHEAD and fr < fl then
				bias = bias - (1 - fr / STEER_AHEAD) * 0.6
			end

			data.SteerBias = math.Clamp(bias, -0.9, 0.9)
			data.SteerRight = right
		end

		local bias = data.SteerBias or 0

		if math.abs(bias) < 0.05 or not data.SteerRight then return moveDir end

		local out = moveDir + data.SteerRight * bias
		out.z = 0

		if out:LengthSqr() < 0.01 then return moveDir end

		return out:GetNormalized()
	end

	local PROBE_INTERVAL = 0.1
	local PROBE_DIST = 44
	local LOW_MINS, LOW_MAXS = Vector(-12, -12, 0), Vector(12, 12, 14) -- knee band
	local HEAD_MINS, HEAD_MAXS = Vector(-12, -12, 0), Vector(12, 12, 22) -- head band

	local function ProbeFilter(ent)
		if not IsValid(ent) then return true end -- world
		if ent:IsPlayer() or ent:IsNPC() then return false end
		if ent.hgBotProbeIgnore then return false end

		return true
	end

	--- How high this bot can get onto something: its real jump height
	-- (JumpPower, gravity) plus what a crouch-jump adds.
	local function MaxJumpHeight(bot)
		local jp = bot:GetJumpPower()
		local g = math.max(GetConVar("sv_gravity"):GetFloat(), 1)

		return (jp * jp) / (2 * g) + 16
	end

	--- Looks ahead along the movement direction every PROBE_INTERVAL and
	-- decides, BEFORE walking into it, whether to jump, crouch or open a
	-- door. Called from the movement bridge (sv_bot_core.lua) whenever the
	-- bot is moving. Stuck handling still exists as the fallback.
	function hg.bots.ProbeObstacles(bot, data, moveDir)
		local now = CurTime()

		if now < (data.NextProbe or 0) then return end

		data.NextProbe = now + (data.Far and PROBE_INTERVAL * 2 or PROBE_INTERVAL)

		local pos = bot:GetPos()
		local dir = Vector(moveDir.x, moveDir.y, 0)

		if dir:LengthSqr() < 0.01 then return end

		dir:Normalize()

		-- Doors first: a closed door reads as a wall to the checks below.
		local chest = pos + Vector(0, 0, 44)

		TraceQ(chest, chest + dir * 64, bot)

		local chestHit, chestEnt, chestPos = TR.Hit, TR.Entity, TR.HitPos

		if chestHit and IsDoor(chestEnt) then
			OpenDoor(bot, data, chestEnt, chestPos)
			return
		end

		-- A window/glass right in the path (the navmesh doesn't know about
		-- breakables): smash through it instead of pushing against it. Eye
		-- level too, for a high window whose wall the chest trace hits.
		if data.Path and not data.Breach and chestHit then
			local paneEnt, panePos = chestEnt, chestPos

			if not IsBreakablePane(paneEnt) then
				local eyeP = pos + Vector(0, 0, 60)

				TraceQ(eyeP, eyeP + dir * 64, bot)

				paneEnt, panePos = TR.Hit and TR.Entity or nil, TR.HitPos
			end

			if IsBreakablePane(paneEnt) and StartPaneBreach(bot, data, paneEnt, panePos) then
				return
			end
		end

		local onGround = bot:IsOnGround()
		local stepZ = 20 -- below this the engine steps up by itself

		-- Knee band: something we'd walk into that isn't just a step.
		local lowStart = pos + Vector(0, 0, stepZ)

		HullQ(lowStart, lowStart + dir * PROBE_DIST, LOW_MINS, LOW_MAXS, BODIES, MASK_PLAYERSOLID)

		-- (a plain copy: the traces below write over the shared result)
		local low = { Hit = TR.Hit, StartSolid = TR.StartSolid, Fraction = TR.Fraction, HitNormal = TR.HitNormal }

		local obstacleDist = PROBE_DIST * low.Fraction
		local mt = data.MoveTarget

		-- Jump only for something that is really in the way:
		-- - close (not 44u early - that's what made bots hop around);
		-- - a steep face, not a ramp/slope;
		-- - not stairs: if the ground just past it is reachable in normal
		--   steps (IsSegmentWalkable), it's a staircase or a lip, walk it;
		-- - between the bot and its current waypoint, not beside the path;
		-- - not more often than once a second.
		local jumpCandidate = low.Hit and onGround and not low.StartSolid
			and obstacleDist <= 28
			and math.abs(low.HitNormal.z) < 0.5
			and now >= (data.NextProbeJump or 0)
			and mt and (mt - pos):Length2D() > obstacleDist + 8

		if jumpCandidate and IsSegmentWalkable(pos, pos + dir * (obstacleDist + 20), bot) then
			jumpCandidate = false
		end

		if jumpCandidate then
			-- How tall is it? Trace down just past the contact point.
			local over = pos + dir * (obstacleDist + 14)
			local maxJump = MaxJumpHeight(bot)

			local top = util.TraceLine({
				start = over + Vector(0, 0, maxJump + 24),
				endpos = over + Vector(0, 0, stepZ - 4),
				filter = BODIES,
				mask = MASK_PLAYERSOLID,
			})

			local height = top.Hit and (top.HitPos.z - pos.z) or 0

			if top.Hit and not top.StartSolid and height > stepZ - 2 and height <= maxJump then
				-- Room to land up there (crouched hull, crouch-jump)?
				local land = util.TraceHull({
					start = top.HitPos + Vector(0, 0, 2),
					endpos = top.HitPos + Vector(0, 0, 2),
					mins = Vector(-14, -14, 0),
					maxs = Vector(14, 14, 36),
					filter = BODIES,
					mask = MASK_PLAYERSOLID,
				})

				if not land.Hit then
					data.JumpUntil = now + 0.15
					data.DuckUntil = now + 0.6
					data.NextProbeJump = now + 1.0

					return
				end
			end
		end

		-- Head band: clear at the knees but blocked at head height - duck
		-- under it (vents, low beams, table edges, fallen debris).
		if not low.Hit then
			local headStart = pos + Vector(0, 0, 40)

			HullQ(headStart, headStart + dir * PROBE_DIST, HEAD_MINS, HEAD_MAXS, BODIES, MASK_PLAYERSOLID)

			if TR.Hit then data.DuckUntil = now + 0.45 end
		end
	end

	--- Advances a bot along data.Path, feeding data.MoveTarget one waypoint
	-- at a time. Call this every AI tick from whatever state wants
	-- path-following.
	-- @return true once the path is finished (or there was none) - false
	--         while still travelling (including waiting on a deferred search).
	function hg.bots.FollowPath(bot, data)
		if data.PendingGoal then
			local goal, opts = data.PendingGoal, data.PendingOpts

			data.PendingGoal = nil
			data.PendingOpts = nil

			hg.bots.SetGoal(bot, goal, opts)
		end

		if data.Breach then
			UpdateBreach(bot, data)

			return false
		end

		if not data.Path or #data.Path == 0 then
			data.NavCrouch = false

			return data.PendingGoal == nil
		end

		local now = CurTime()
		local pos = bot:GetPos()

		-- Stuck detection with escalation. Deliberate stops (door, kick,
		-- peek, block) and slow-but-moving bots (injured, crouching, slow
		-- walk) don't count - only "trying to move and getting nowhere".
		local deliberate = (data.PauseMoveUntil and now < data.PauseMoveUntil)
			or (data.ForceLookUntil and now < data.ForceLookUntil)
			or (data.DefendUntil and now < data.DefendUntil)
			or not data.MoveTarget

		if deliberate or bot:GetVelocity():Length2D() > 18 then
			data.StuckPos = pos
			data.StuckSince = now
			data.UnstickStage = 0
		elseif not data.StuckPos or pos:DistToSqr(data.StuckPos) > (32 * 32) then
			data.StuckPos = pos
			data.StuckSince = now
			data.UnstickStage = 0
		else
			local stuckFor = now - (data.StuckSince or now)

			if stuckFor > 0.8 and (data.UnstickStage or 0) < 1 then
				data.UnstickStage = 1
				TryUnstick(bot, data)
			elseif stuckFor > hg_bot_stuck_time:GetFloat() then
				data.StuckAttempts = (data.StuckAttempts or 0) + 1
				data.StuckSince = now
				data.StuckPos = pos
				data.UnstickStage = 0

				if data.StuckAttempts > 2 or not data.Goal then
					hg.bots.ClearPath(data)

					return true
				end

				local goal, opts = data.Goal, data.GoalOpts
				local attempts = data.StuckAttempts

				hg.bots.SetGoal(bot, goal, { force = true, avoidPos = opts and opts.avoidPos, avoidRadius = opts and opts.avoidRadius, avoidWeight = opts and opts.avoidWeight })

				data.StuckAttempts = attempts -- SetGoal resets it; keep counting toward giving up

				return false
			end
		end

		-- Intermediate waypoints: generous arrival radius so the bot flows
		-- through corners. The final one keeps the bridge's precise 16u.
		local mt = data.MoveTarget

		if mt and data.PathIndex <= #data.Path then
			local dz = math.abs(mt.z - pos.z)
			local d2 = (mt.x - pos.x) ^ 2 + (mt.y - pos.y) ^ 2

			if dz < 64 then
				local nextWp = data.Path[data.PathIndex]

				if d2 < 18 * 18 then
					data.MoveTarget = nil
				elseif d2 < hg_bot_arrive_dist:GetFloat() ^ 2 and nextWp
					and now >= (data.NextCornerCheck or 0)
				then
					data.NextCornerCheck = now + 0.1

					if IsSegmentClear(pos, nextWp, bot) then
						data.MoveTarget = nil
					end
				elseif d2 < 160 * 160 and nextWp and not data.NavJumpAt
					and now >= (data.NextCornerCheck or 0)
				then
					-- Gone past it wider than that: a running bot carried on
					-- by its momentum, or pushed aside by the wall steering,
					-- turned back to touch the waypoint and circled it. Past
					-- the end of its leg with the next one in sight counts
					-- as reached. (A climb is reached by height, not this.)
					local from = data.Path[data.PathIndex - 2] or data.LegFrom

					if from then
						local lx, ly = mt.x - from.x, mt.y - from.y
						local len2 = lx * lx + ly * ly

						if len2 > 16 * 16 and (pos.x - from.x) * lx + (pos.y - from.y) * ly > len2 then
							data.NextCornerCheck = now + 0.1

							if IsSegmentClear(pos, nextWp, bot) then
								data.MoveTarget = nil
							end
						end
					end
				end
			end
		end

		if data.MoveTarget == nil then
			if data.PathIndex > #data.Path then
				hg.bots.ClearPath(data)

				return true
			end

			local f = data.PathFlags and data.PathFlags[data.PathIndex] or 0

			data.MoveTarget = data.Path[data.PathIndex]
			data.LegFrom = pos -- where this leg starts, for the gone-past check above
			data.NavCrouch = bit.band(f, FLAG_CROUCH) ~= 0
			data.NavJumpAt = bit.band(f, FLAG_JUMP) ~= 0 and data.MoveTarget or nil
			data.PathIndex = data.PathIndex + 1
		end

		-- A climb/jump transition on the path: hop when close to it.
		if data.NavJumpAt and bot:IsOnGround() then
			local j = data.NavJumpAt
			local d2 = (j.x - pos.x) ^ 2 + (j.y - pos.y) ^ 2

			if d2 < 60 * 60 and j.z > pos.z + 20 then
				data.NavJumpAt = nil

				-- Stairs or a ramp lead up there on foot - no jump needed.
				if not IsSegmentWalkable(pos, j, bot) then
					data.JumpUntil = now + 0.15
					data.DuckUntil = now + 0.6 -- crouch-jump clears more height
				end
			end
		end

		return false
	end

	-- Nothing path-related should survive a state change: a leftover
	-- deferred search or crouch flag would otherwise leak into whatever
	-- the new state does.
	hook.Add("HG_BotStateChanged", "HG_Bots_ClearNavState", function(bot, oldState, newState)
		local data = bot.Bot
		if not data then return end

		data.PendingGoal = nil
		data.PendingOpts = nil
		data.NavCrouch = false
		data.JumpUntil = nil
		data.DuckUntil = nil
		data.UsePulseUntil = nil
		data.PauseMoveUntil = nil
		data.NavJumpAt = nil
		data.SlowWalk = false
		data.Lean = 0
		data.ForceLookUntil = nil
		data.ForceAttackUntil = nil
		data.Breach = nil
	end)
--//

--\\ Prediction & search helpers
	--- Where something at pos moving with vel will be in t seconds,
	-- clamped to ground that is actually walkable and not behind a wall.
	function hg.bots.PredictPosition(pos, vel, t, filterEnt)
		if not pos then return nil end
		if not vel or vel:Length2DSqr() < 40 * 40 then return pos end

		local v = Vector(vel.x, vel.y, 0)

		for _, frac in ipairs({ 1, 0.6, 0.3 }) do
			local p = pos + v * (t * frac)

			if IsSegmentClear(pos, p, filterEnt) and IsSegmentWalkable(pos, p, filterEnt) then
				return hg.bots.SnapToNavmesh(p, 200) or p
			end
		end

		return pos
	end

	--- Places worth checking around a last known position: hiding spots
	-- (or area centers) that are NOT visible from that position - that's
	-- where someone who broke contact actually went - biased along dir.
	-- @return table of Vector, best first
	function hg.bots.GetSearchPoints(origin, dir, count, radius)
		if not origin or not navmesh.IsLoaded() then return {} end

		local areas = navmesh.Find(origin, radius or 900, 120, 120)
		local cands = {}

		for _, area in ipairs(areas) do
			local spots = area.GetHidingSpots and area:GetHidingSpots()

			if spots and #spots > 0 then
				for _, s in ipairs(spots) do cands[#cands + 1] = s end
			else
				cands[#cands + 1] = area:GetCenter()
			end
		end

		-- Trace budget: only score a random subset on big open maps.
		while #cands > 40 do
			table.remove(cands, math.random(#cands))
		end

		local eyeZ = Vector(0, 0, 56)
		local flatDir = dir and Vector(dir.x, dir.y, 0)

		if flatDir and flatDir:LengthSqr() > 1 then flatDir:Normalize() else flatDir = nil end

		local scored = {}

		for _, p in ipairs(cands) do
			local offset = p - origin
			local d = offset:Length()

			if d > 120 then
				local score = -d / 1500

				if flatDir then
					score = score + (offset / d):Dot(flatDir)
				end

				local tr = util.TraceLine({
					start = origin + eyeZ,
					endpos = p + eyeZ,
					mask = MASK_SOLID_BRUSHONLY,
				})

				if tr.Hit then score = score + 0.6 end

				scored[#scored + 1] = { p = p, s = score }
			end
		end

		table.sort(scored, function(a, b) return a.s > b.s end)

		local out = {}

		for _, c in ipairs(scored) do
			local tooClose = false

			for _, o in ipairs(out) do
				if o:DistToSqr(c.p) < 220 * 220 then tooClose = true break end
			end

			if not tooClose then
				out[#out + 1] = c.p

				if #out >= (count or 3) then break end
			end
		end

		return out
	end
--//

--\\ Wandering
	--- Nav areas actually connected to the bot's own area, flood-filled
	-- through GetAdjacentAreas out to `radius`. Every point picked from
	-- these is reachable by construction - unlike navmesh.Find, which could
	-- come back empty (and got cached empty for 30 s) or hand out areas on
	-- disconnected islands whose paths always failed.
	local function CollectReachableAreas(startPos, radius, maxAreas)
		local start = navmesh.GetNavArea(startPos, 128) or navmesh.GetNearestNavArea(startPos, false, 1000, false, true)

		if not IsValid(start) then return {} end

		local out, seen, queue, qi = {}, { [start:GetID()] = true }, { start }, 1
		local r2 = radius * radius

		while qi <= #queue and #out < maxAreas do
			local area = queue[qi]
			qi = qi + 1

			out[#out + 1] = area

			for _, n in ipairs(area:GetAdjacentAreas()) do
				local id = n:GetID()

				if not seen[id] then
					seen[id] = true

					if n:GetCenter():DistToSqr(startPos) < r2 and not hg.bots.IsDeepWaterArea(n) then
						queue[#queue + 1] = n
					end
				end
			end
		end

		return out
	end

	--- Picks a random reachable point for idle wandering. Stays around the
	-- bot's home: when the bot has drifted far from it, candidates closer
	-- to home win.
	-- @return Vector|nil, string reason when nil (for hg_bot_navdebug)
	local function PickWanderPoint(bot)
		local data = bot.Bot
		local pos = bot:GetPos()
		local home = (data and data.HomePos) or pos
		local radius = hg_bot_wander_radius:GetFloat()

		if navmesh.IsLoaded() then
			local areas = data and data.WanderAreas

			if not areas or CurTime() > (data.WanderAreasUntil or 0) or (data.WanderAreasFrom and data.WanderAreasFrom:DistToSqr(pos) > 600 * 600) then
				areas = CollectReachableAreas(pos, radius, 400)

				-- Never cache a useless result.
				if data and #areas > 1 then
					data.WanderAreas = areas
					data.WanderAreasUntil = CurTime() + 20
					data.WanderAreasFrom = pos
				end
			end

			if #areas == 0 then return nil, "no nav area under/near the bot" end

			local farFromHome = pos:DistToSqr(home) > radius * radius
			local best, bestScore

			for _ = 1, 8 do
				local area = areas[math.random(#areas)]

				if IsValid(area) and not area:HasAttributes(NAV_AVOID) then
					local p = area:GetRandomPoint()
					local d = p:Distance(pos)

					if d > 200 then
						local score = farFromHome and p:Distance(home) or math.Rand(0, 1)

						if not bestScore or score < bestScore then
							best, bestScore = p, score
						end
					end
				end
			end

			if best then return best end

			-- Tiny connected patch: any point in it at all.
			if #areas > 0 then
				return areas[math.random(#areas)]:GetRandomPoint()
			end

			return nil, "navmesh around the bot is too small"
		end

		-- No navmesh: random point on a ring, dropped to the floor and only
		-- accepted if the walk there holds up.
		for _ = 1, 4 do
			local ang = math.Rand(0, 360)
			local dist = math.Rand(150, 600)
			local target = home + Vector(math.cos(math.rad(ang)), math.sin(math.rad(ang)), 0) * dist

			local tr = util.TraceLine({
				start = target + Vector(0, 0, 64),
				endpos = target - Vector(0, 0, 512),
				mask = MASK_NPCSOLID_BRUSHONLY,
			})

			if tr.Hit and IsSegmentClear(pos, tr.HitPos + Vector(0, 0, 4), bot) and IsSegmentWalkable(pos, tr.HitPos + Vector(0, 0, 4), bot) then
				return tr.HitPos + Vector(0, 0, 4)
			end
		end

		return nil, "no navmesh and no walkable direction found"
	end

	--- The point handed out is remembered (data.WanderPt): a walk to it is a
	-- stroll, which sv_bot_watch.lua may cut short or linger at the end of.
	function hg.bots.GetRandomWanderPoint(bot)
		local pt, why = PickWanderPoint(bot)

		if pt and bot.Bot then bot.Bot.WanderPt = hg.bots.SnapToNavmesh(pt) or pt end

		return pt, why
	end

	--- Last-resort movement: a short straight walk in any direction whose
	-- ground and clearance check out, bypassing pathfinding entirely.
	function hg.bots.NudgeWalk(bot, data)
		local pos = bot:GetPos()

		for _ = 1, 10 do
			local a = math.Rand(0, math.pi * 2)
			local p = pos + Vector(math.cos(a), math.sin(a), 0) * math.Rand(120, 260)

			if IsSegmentClear(pos, p, bot) and IsSegmentWalkable(pos, p, bot) then
				hg.bots.ClearPath(data)

				data.Path = { p }
				data.PathFlags = { 0 }
				data.PathIndex = 1
				data.Goal = p
				data.StuckPos = pos
				data.StuckSince = CurTime()
				data.StuckAttempts = 0

				return true
			end
		end

		return false
	end

	-- Extension points other files fill in without re-registering "idle".
	-- sv_bot_combat.lua fills in CheckThreatReaction; sv_bot_loot.lua fills
	-- in CheckLootReaction.
	hg.bots.CheckThreatReaction = hg.bots.CheckThreatReaction or function(bot, data)
		if IsValid(data.Memory.Target) and not hg.bots._warnedNoCombatState then
			hg.bots._warnedNoCombatState = true
			print("[hg.bots] WARNING: a bot has a live Memory.Target but no 'combat' state is registered. sv_bot_combat.lua doesn't appear to be loaded (check it's in the same folder as the other sv_bot_*.lua files) - bots will see/hear players but never fight them.")
		end

		return false
	end

	hg.bots.CheckLootReaction = hg.bots.CheckLootReaction or function(bot, data) return false end

	local INVESTIGATE_YAWS = { 0, 70, -70, 140, -140 }
	local SUSPICION_EXPIRE = 30

	hg.bots.RegisterState("idle", {
		Enter = function(bot, data)
			data.NextWanderPick = 0
			data.InvestigateUntil = nil
			data.Crouching = false
			data.IdleMovePos = nil
			data.IdleMoveTime = nil
			data.AttackingSecondary = false
		end,

		Leave = function(bot, data)
			data.InvestigateUntil = nil
			data.Crouching = false
		end,

		Think = function(bot, data)
			data.NextStateThink = CurTime() + 0.2

			if hg.bots.CheckThreatReaction(bot, data) then return end

			local mem = data.Memory
			local now = CurTime()
			local glancing = mem.GlancePos and now < (mem.GlanceUntil or 0)

			-- Someone nearby just drew a weapon (perception sets WaryOf).
			-- Not hostile (yet): armed bots stop and cover them with their
			-- own weapon ready, unarmed ones back away. Attacking only
			-- happens if they actually aim at / shoot at a bot.
			local wary = mem.WaryOf

			if IsValid(wary) and wary:Alive() and now < (mem.WaryUntil or 0) then
				local char = hg.bots.GetCharacter and hg.bots.GetCharacter(wary) or wary
				local mine = hg.bots.GetWeaponKind and hg.bots.GetWeaponKind(bot, true) or "gun"

				data.InvestigateUntil = nil

				if mine == "none" then
					if now >= (data.NextWaryEvade or 0) then
						data.NextWaryEvade = now + 2

						local away = bot:GetPos() - char:GetPos()
						away.z = 0

						if away:LengthSqr() < 1 then away = Vector(math.Rand(-1, 1), math.Rand(-1, 1), 0) end

						away:Normalize()
						away:Rotate(Angle(0, math.Rand(-40, 40), 0))

						hg.bots.SetGoal(bot, bot:GetPos() + away * 450, { avoidPos = char:GetPos(), avoidRadius = 600, force = true })
					end

					data.Running = true
					data.AttackingSecondary = false
					data.LookPos = nil
					hg.bots.FollowPath(bot, data)

					return
				end

				-- Standoff: stand, face them, weapon up, finger off the trigger.
				hg.bots.ClearPath(data)
				data.Running = false
				data.Attacking = false
				data.AimSpeed = 240
				data.LookPos = char:WorldSpaceCenter() + Vector(0, 0, 12)
				data.AttackingSecondary = mine == "gun" -- aim down sights; RMB on a melee weapon would be a block

				return
			elseif wary then
				mem.WaryOf = nil
				data.AttackingSecondary = false
				data.AimSpeed = nil
			end

			if mem.SuspicionPos and now - (mem.SuspicionTime or now) > SUSPICION_EXPIRE then
				mem.SuspicionPos = nil
				mem.SuspicionStrength = nil
			end

			-- Unarmed (fists don't count) and that was gunfire: get away
			-- from it instead of walking up to have a look.
			if mem.SuspicionPos and mem.SuspicionKind == "gunfire"
				and hg.bots.GetWeaponKind and hg.bots.GetWeaponKind(bot, true) == "none"
			then
				if data.EvadeFrom ~= mem.SuspicionPos then
					data.EvadeFrom = mem.SuspicionPos

					local away = bot:GetPos() - mem.SuspicionPos
					away.z = 0

					if away:LengthSqr() < 1 then away = Vector(math.Rand(-1, 1), math.Rand(-1, 1), 0) end

					away:Normalize()
					away:Rotate(Angle(0, math.Rand(-60, 60), 0))

					local dest = hg.bots.SnapToNavmesh(bot:GetPos() + away * math.Rand(500, 850)) or (bot:GetPos() + away * 500)

					hg.bots.SetGoal(bot, dest, { avoidPos = mem.SuspicionPos, avoidRadius = 700, avoidWeight = 3, force = true })
				end

				data.Running = true
				data.Crouching = false
				data.LookPos = nil

				if hg.bots.FollowPath(bot, data) then
					mem.SuspicionPos = nil
					mem.SuspicionStrength = nil
					data.EvadeFrom = nil
				end

				return
			end

			if mem.SuspicionPos then
				-- Heard something but never saw anyone: go look. Loud and
				-- close (gunfire) means hurry; a faint step means sneak.
				local alert = mem.Alertness or 0

				data.Running = alert > 0.6
				data.Crouching = false
				data.InvestigateUntil = nil

				-- Look where we walk; only look at the noise itself once
				-- close to it (or when something caught the eye).
				if glancing then
					data.LookPos = mem.GlancePos
				elseif bot:GetPos():DistToSqr(mem.SuspicionPos) < 400 * 400 then
					data.LookPos = mem.SuspicionPos + Vector(0, 0, 40)
				else
					data.LookPos = nil
				end

				if not data.Goal or data.Goal:DistToSqr(mem.SuspicionPos) > 160 ^ 2 then
					hg.bots.SetGoal(bot, mem.SuspicionPos)
				end

				if hg.bots.FollowPath(bot, data) then
					-- Arrived (or no route): look around for a few seconds
					-- before going back to normal - someone who made that
					-- noise might still be close.
					mem.SuspicionPos = nil
					mem.SuspicionStrength = nil
					data.InvestigateUntil = now + math.Rand(2.5, 4)
					data.InvestigateYaw = bot:EyeAngles().y
					data.InvestigateStep = 0
					data.NextInvestigateTurn = 0
				end

				return
			end

			if data.InvestigateUntil then
				if now < data.InvestigateUntil then
					data.Running = false
					data.MoveTarget = nil

					if glancing then
						data.LookPos = mem.GlancePos
					elseif now >= (data.NextInvestigateTurn or 0) then
						data.InvestigateStep = (data.InvestigateStep or 0) + 1
						data.NextInvestigateTurn = now + math.Rand(0.7, 1.2)

						local yaw = (data.InvestigateYaw or 0) + INVESTIGATE_YAWS[((data.InvestigateStep - 1) % #INVESTIGATE_YAWS) + 1]

						data.LookPos = bot:EyePos() + Angle(0, yaw, 0):Forward() * 300
					end

					return
				end

				data.InvestigateUntil = nil
			end

			data.LookPos = glancing and mem.GlancePos or nil
			data.Running = false

			-- Told to go somewhere or follow somebody from the context menu
			-- (sv_bot_menu.lua): that beats wandering, guarding and loot.
			if hg.bots.CheckOrder and hg.bots.CheckOrder(bot, data) then return end

			-- A guard bot (sv_bot_factions.lua) that drifted too far from
			-- the players walks back before it thinks about loot.
			if hg.bots.CheckGuardEscort and hg.bots.CheckGuardEscort(bot, data) then return end

			if hg.bots.CheckLootReaction(bot, data) then return end

			-- A sniper sets up to overlook the ground (sv_bot_weaponclass.lua),
			-- a bot with somewhere far to go may take a car (sv_bot_vehicle.lua).
			if hg.bots.CheckWeaponRole and hg.bots.CheckWeaponRole(bot, data) then return end
			if hg.bots.CheckVehicleUse and hg.bots.CheckVehicleUse(bot, data) then return end

			if hg.bots.FollowPath(bot, data) then
				if now >= (data.NextWanderPick or 0) then
					-- A few picks per try: one unreachable point must not
					-- leave the bot standing for seconds.
					local ok, why = false, nil

					for _ = 1, 3 do
						local dest
						dest, why = hg.bots.GetRandomWanderPoint(bot)

						if dest then
							ok = hg.bots.SetGoal(bot, dest)
							why = ok and nil or "no route to the picked point"

							if ok then break end
						end
					end

					data.WanderFailReason = why
					data.WanderFails = ok and 0 or (data.WanderFails or 0) + 1
					data.NextWanderPick = now + (ok and math.Rand(1, 3) or 0.5)
				end
			end

			-- Watchdog: idle, nothing to investigate, and hasn't actually
			-- moved for a while (every pick failing, ledge guard, a blocked
			-- spawn spot) - take a short direct walk instead of freezing.
			local pos = bot:GetPos()

			if not data.IdleMovePos or pos:DistToSqr(data.IdleMovePos) > 48 * 48 then
				data.IdleMovePos = pos
				data.IdleMoveTime = now
			elseif now - (data.IdleMoveTime or now) > 6 then
				data.IdleMoveTime = now

				if hg.bots.NudgeWalk(bot, data) then
					data.WanderFailReason = (data.WanderFailReason or "stood still") .. " -> nudged"
				end
			end
		end,
	})
--//

--\\ Debug
	-- hg_bot_navdebug - why is a bot (not) moving?
	concommand.Add("hg_bot_navdebug", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		local function out(msg)
			print(msg)

			if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
		end

		out("[hg.bots] navmesh loaded: " .. tostring(navmesh.IsLoaded()) .. ", idle state: " .. ((hg.bots.States.idle and hg.bots.States.idle.IsPlaceholder) and "PLACEHOLDER (navigation not loaded!)" or "wander"))

		for _, bot in ipairs(hg.bots.GetAll and hg.bots.GetAll() or {}) do
			local data = bot.Bot or {}
			local area = navmesh.IsLoaded() and navmesh.GetNavArea(bot:GetPos(), 128)
			local now = CurTime()

			out(("  %s: state=%s area=%s path=%s/%s goal=%s pending=%s failThrottle=%s wanderFails=%s reason=%s ledgeBlocked=%s vel=%.0f"):format(
				bot:Nick(),
				tostring(data.State),
				IsValid(area) and tostring(area:GetID()) or "none",
				tostring(data.PathIndex), data.Path and tostring(#data.Path) or "-",
				tostring(data.Goal),
				tostring(data.PendingGoal ~= nil),
				(data.PathFailUntil and data.PathFailUntil > now) and "yes" or "no",
				tostring(data.WanderFails or 0),
				tostring(data.WanderFailReason),
				data.LedgeBlockedAt and string.format("%.1fs ago", now - data.LedgeBlockedAt) or "never",
				bot:GetVelocity():Length2D()
			))
		end
	end)
--//
