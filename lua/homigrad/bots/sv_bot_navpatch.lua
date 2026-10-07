--[[
	Tarkov AI - Nav patcher ("followpatcher")

	Fills holes in the navmesh so bots walk instead of hopping and
	stumbling. The classic case is a staircase generated as a few areas
	with big gaps between them (see nav_edit on most custom maps): the areas
	are CONNECTED, but the space between them has no area at all. A path
	then has to go "from the edge of this area, across nothing, to the edge
	of that one" - the waypoint lands in mid-air above the steps, the
	height difference looks like a ledge/climb, and the bot jumps or gets
	confused.

	What it does - the same operations nav_create / nav_splice perform, but
	from Lua (no sv_cheats, no manual nav_mark), with GMod's server navmesh
	API:
	- finds pairs of connected areas whose nearest edges are more than
	  hg_bot_navpatch_gap units apart (horizontally);
	- checks the ground between them is actually walkable (continuous
	  floor, normal step heights, no wall) - a real pit stays a pit;
	- fills the gap with a strip of small areas (navmesh.CreateNavArea),
	  each hugging the real ground: every corner is dropped onto the
	  floor/steps underneath it (CNavArea:SetCorner), and the strip is as
	  wide as the two areas' shared width (capped), so it sits in the
	  middle of a corridor/staircase, not along a wall;
	- connects the strip both ways: area A <-> slice 1 <-> ... <-> area B
	  (CNavArea:ConnectTo), so A* walks through it.

	Two ways it runs:
	- "follow" patching (hg_bot_navpatch_follow, on by default): whenever a
	  bot's path crosses such a gap, the gap is queued and patched in the
	  background (a couple of jobs per tick, never a frame spike). The mesh
	  heals where bots actually walk. Runtime only - nothing written to disk.
	- hg_bot_navpatch [save] (admin): scans the whole mesh, patches every
	  gap it finds, spread over ticks; with "save" it then writes the .nav
	  file (navmesh.Save) so the fix is permanent for this map.
	  hg_bot_navpatch_undo removes every area created this session.
]]

hg.bots = hg.bots or {}
hg.bots.NavPatch = hg.bots.NavPatch or { Created = {}, Queue = {}, Queued = {}, Done = {} }

local NP = hg.bots.NavPatch

local hg_bot_navpatch_follow = CreateConVar("hg_bot_navpatch_follow", "1",  {FCVAR_ARCHIVE}, "Patch navmesh gaps found on bots' paths automatically (runtime only, not saved)", 0, 1)
local hg_bot_navpatch_gap    = CreateConVar("hg_bot_navpatch_gap",    "20", {FCVAR_ARCHIVE}, "Horizontal gap (units) between connected nav areas that counts as a hole to fill", 8, 256)
local hg_bot_navpatch_maxgap = CreateConVar("hg_bot_navpatch_maxgap", "320", {FCVAR_ARCHIVE}, "Gaps longer than this are left alone (probably not a stair/doorway hole)", 32, 2000)
local hg_bot_navpatch_slice  = CreateConVar("hg_bot_navpatch_slice",  "24", {FCVAR_ARCHIVE}, "Length (units) of each filler area along the gap - smaller follows steps more closely", 8, 128)
local hg_bot_navpatch_width  = CreateConVar("hg_bot_navpatch_width",  "72", {FCVAR_ARCHIVE}, "Max width (units) of filler areas", 16, 256)
local hg_bot_navpatch_rate   = CreateConVar("hg_bot_navpatch_rate",   "2",  {FCVAR_ARCHIVE}, "Patch jobs processed per server tick", 1, 20)
local hg_bot_navpatch_debug  = CreateConVar("hg_bot_navpatch_debug",  "0",  {FCVAR_ARCHIVE}, "Draw created filler areas with debugoverlay", 0, 1)

local UP = Vector(0, 0, 1)

--\\ Gap detection
	--- Nearest points of two areas toward each other and their horizontal
	-- distance.
	local function GapBetween(a, b)
		local pa = a:GetClosestPointOnArea(b:GetCenter())
		local pb = b:GetClosestPointOnArea(a:GetCenter())

		-- Refine once: closest point of each to the other's closest point.
		pa = a:GetClosestPointOnArea(pb)
		pb = b:GetClosestPointOnArea(pa)

		local d = pb - pa

		return math.sqrt(d.x * d.x + d.y * d.y), pa, pb
	end

	local function PairKey(a, b)
		local ia, ib = a:GetID(), b:GetID()

		if ia > ib then ia, ib = ib, ia end

		return ia .. ":" .. ib
	end

	--- Queue a gap between two areas for patching (cheap - just a distance
	-- check; the real work happens in the background worker).
	function NP.QueueGap(a, b)
		if not IsValid(a) or not IsValid(b) then return end

		local key = PairKey(a, b)

		if NP.Queued[key] or NP.Done[key] then return end

		local gap = GapBetween(a, b)

		if gap <= hg_bot_navpatch_gap:GetFloat() or gap > hg_bot_navpatch_maxgap:GetFloat() then
			NP.Done[key] = true
			return
		end

		NP.Queued[key] = true
		NP.Queue[#NP.Queue + 1] = { a:GetID(), b:GetID(), key }
	end

	--- Called by FindNavPath for every consecutive area pair of a found
	-- path (sv_bot_navigation.lua) - the "follow" part.
	function NP.OnPath(chain)
		if not hg_bot_navpatch_follow:GetBool() then return end

		for k = 1, #chain - 1 do
			NP.QueueGap(chain[k], chain[k + 1])
		end
	end
--//

--\\ Patching
	local function GroundZ(pos, fromZ, toZ)
		local tr = util.TraceLine({
			start = Vector(pos.x, pos.y, fromZ),
			endpos = Vector(pos.x, pos.y, toZ),
			mask = MASK_PLAYERSOLID_BRUSHONLY,
		})

		if tr.Hit and not tr.StartSolid then return tr.HitPos.z end

		return nil
	end

	local function Overlap(aLo, aHi, bLo, bHi)
		return math.max(aLo, bLo), math.min(aHi, bHi)
	end

	--- Sets the four corners of a freshly created area onto the real
	-- ground so it follows stairs/ramps instead of floating flat.
	local function FitCorners(area, cornerPositions)
		if not area.SetCorner then return end

		for corner, pos in pairs(cornerPositions) do
			pcall(area.SetCorner, area, corner, pos)
		end
	end

	--- Does a nav area other than the two being joined already cover pos?
	local function ExistingAreaAt(pos, a, b)
		local found = navmesh.GetNavArea(pos + UP * 8, 24)

		if IsValid(found) and found ~= a and found ~= b then return found end

		return nil
	end

	local function Connect2(x, y)
		if not IsValid(x) or not IsValid(y) or x == y then return end

		if not x:IsConnected(y) then x:ConnectTo(y) end
		if not y:IsConnected(x) then y:ConnectTo(x) end
	end

	--- Fill the gap between areas a and b. Returns the number of areas
	-- created (0 = nothing to do or not walkable).
	local function PatchGap(a, b)
		local gap, pa, pb = GapBetween(a, b)

		if gap <= hg_bot_navpatch_gap:GetFloat() or gap > hg_bot_navpatch_maxgap:GetFloat() then return 0 end

		-- Only fill what can actually be walked: continuous floor with
		-- normal step heights and no wall. A real pit stays a pit.
		if hg.bots.IsSegmentWalkable and not hg.bots.IsSegmentWalkable(pa, pb) then return 0 end
		if hg.bots.IsSegmentClear and not hg.bots.IsSegmentClear(pa, pb) then return 0 end

		local ea, eb = a:GetExtentInfo(), b:GetExtentInfo()
		local d = pb - pa
		local alongX = math.abs(d.x) >= math.abs(d.y)

		-- Width: the span both areas share across the gap direction (the
		-- staircase/corridor width), capped, centered.
		local lo, hi

		if alongX then
			lo, hi = Overlap(ea.lo.y, ea.hi.y, eb.lo.y, eb.hi.y)
		else
			lo, hi = Overlap(ea.lo.x, ea.hi.x, eb.lo.x, eb.hi.x)
		end

		local maxW = hg_bot_navpatch_width:GetFloat()
		local mid = alongX and (pa.y + pb.y) * 0.5 or (pa.x + pb.x) * 0.5

		if hi - lo < 20 then
			lo, hi = mid - 16, mid + 16
		elseif hi - lo > maxW then
			local c = (lo + hi) * 0.5

			lo, hi = c - maxW * 0.5, c + maxW * 0.5
		end

		-- Slice the gap along its main axis.
		local s0 = alongX and pa.x or pa.y
		local s1 = alongX and pb.x or pb.y
		local sign = s1 >= s0 and 1 or -1
		local len = math.abs(s1 - s0)
		local count = math.max(1, math.ceil(len / hg_bot_navpatch_slice:GetFloat()))
		local step = len / count

		local topZ = math.max(pa.z, pb.z) + 48
		local botZ = math.min(pa.z, pb.z) - 48

		local prev = a
		local created = 0

		for i = 1, count do
			local u0 = s0 + sign * step * (i - 1)
			local u1 = s0 + sign * step * i
			local uMid = (u0 + u1) * 0.5

			local function P(u, v)
				return alongX and Vector(u, v, 0) or Vector(v, u, 0)
			end

			local centerZ = GroundZ(P(uMid, (lo + hi) * 0.5), topZ, botZ)

			if not centerZ then return created end -- floor vanished: stop here

			local center = P(uMid, (lo + hi) * 0.5)
			center.z = centerZ

			local existing = ExistingAreaAt(center, a, b)

			if existing then
				Connect2(prev, existing)
				prev = existing
			else
				local c1 = P(math.min(u0, u1), lo)
				local c2 = P(math.max(u0, u1), hi)

				c1.z, c2.z = centerZ, centerZ

				local ok, area = pcall(navmesh.CreateNavArea, c1, c2)

				if not ok or not IsValid(area) then return created end

				-- Drop each corner onto the real floor/step below it.
				local corners = {}
				-- Source nav corners: NW = (min x, min y), SE = (max x, max y)
				-- (north is -y).
				local nwX, nwY = math.min(c1.x, c2.x), math.min(c1.y, c2.y)
				local seX, seY = math.max(c1.x, c2.x), math.max(c1.y, c2.y)
				local cornerXY = {
					[0] = Vector(nwX, nwY, 0), -- NORTH_WEST
					[1] = Vector(seX, nwY, 0), -- NORTH_EAST
					[2] = Vector(seX, seY, 0), -- SOUTH_EAST
					[3] = Vector(nwX, seY, 0), -- SOUTH_WEST
				}

				for corner, xy in pairs(cornerXY) do
					local z = GroundZ(xy, topZ, botZ)

					if z then corners[corner] = Vector(xy.x, xy.y, z) end
				end

				FitCorners(area, corners)

				NP.Created[#NP.Created + 1] = area:GetID()
				created = created + 1

				if hg_bot_navpatch_debug:GetBool() then
					debugoverlay.Box(center, Vector(-4, -4, 0), Vector(4, 4, 4), 20, Color(0, 255, 120, 60))
					debugoverlay.Line(prev:GetCenter(), center, 20, Color(0, 255, 120), true)
				end

				Connect2(prev, area)
				prev = area
			end
		end

		Connect2(prev, b)

		return created
	end

	NP.PatchGap = PatchGap

	-- Background worker: a few jobs per tick so patching never hitches.
	local scanCallback

	hook.Add("Tick", "HG_Bots_NavPatch", function()
		if #NP.Queue == 0 then
			if scanCallback then
				local cb = scanCallback
				scanCallback = nil
				cb()
			end

			return
		end

		if not navmesh.IsLoaded() then return end

		for _ = 1, hg_bot_navpatch_rate:GetInt() do
			local job = table.remove(NP.Queue, 1)

			if not job then break end

			NP.Queued[job[3]] = nil
			NP.Done[job[3]] = true

			local a, b = navmesh.GetNavAreaByID(job[1]), navmesh.GetNavAreaByID(job[2])

			if IsValid(a) and IsValid(b) then
				local ok, res = pcall(PatchGap, a, b)

				if ok then
					NP.TotalCreated = (NP.TotalCreated or 0) + (res or 0)
				else
					print("[hg.bots] navpatch error: " .. tostring(res))
				end
			end
		end
	end)
--//

--\\ Commands
	local function Reply(ply, msg)
		print(msg)

		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
	end

	-- hg_bot_navpatch [save] - scan and patch the whole mesh.
	concommand.Add("hg_bot_navpatch", function(ply, cmd, args)
		if IsValid(ply) and not ply:IsAdmin() then return end

		if not navmesh.IsLoaded() then
			Reply(ply, "[hg.bots] No navmesh loaded on this map.")
			return
		end

		local save = args and args[1] == "save"
		local before = NP.TotalCreated or 0
		local queued = 0

		NP.Done = {} -- rescan everything

		for _, area in ipairs(navmesh.GetAllNavAreas()) do
			for _, n in ipairs(area:GetAdjacentAreas()) do
				local n0 = #NP.Queue

				NP.QueueGap(area, n)

				if #NP.Queue > n0 then queued = queued + 1 end
			end
		end

		Reply(ply, ("[hg.bots] navpatch: %d gaps queued, patching in the background..."):format(queued))

		scanCallback = function()
			local made = (NP.TotalCreated or 0) - before

			Reply(ply, ("[hg.bots] navpatch: done, %d filler areas created."):format(made))

			if save then
				navmesh.Save()
				Reply(ply, "[hg.bots] navpatch: navmesh saved to the map's .nav file.")
			end

			-- Wander area caches point at the old mesh layout.
			for bot in pairs(hg.bots.List or {}) do
				if IsValid(bot) and bot.Bot then bot.Bot.WanderAreas = nil end
			end
		end
	end, nil, "Patch navmesh gaps (stairs etc). 'hg_bot_navpatch save' also writes the .nav file.")

	concommand.Add("hg_bot_navpatch_undo", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		local removed = 0

		for _, id in ipairs(NP.Created) do
			local area = navmesh.GetNavAreaByID(id)

			if IsValid(area) then
				area:Remove()
				removed = removed + 1
			end
		end

		NP.Created = {}
		NP.Done = {}

		Reply(ply, ("[hg.bots] navpatch: removed %d filler areas created this session."):format(removed))
	end, nil, "Remove every nav area the patcher created this session.")

	-- New map / reloaded mesh: forget per-pair bookkeeping.
	hook.Add("InitPostEntity", "HG_Bots_NavPatch_Reset", function()
		NP.Created, NP.Queue, NP.Queued, NP.Done = {}, {}, {}, {}
	end)
--//
