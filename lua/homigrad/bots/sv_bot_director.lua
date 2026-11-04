--[[
	Tarkov AI - AI Director

	A Left 4 Dead style director: instead of an admin spawning bots by hand,
	it watches the players and decides when, where, how many and how well
	equipped. It exists as a real entity (ent_hg_director) so it can be
	spawned, moved and removed in game like anything else - while at least
	one is alive in the world the director runs, and a convar can turn it on
	without one.

	PHASES, in the order they cycle:

	- idle     nothing is spawned. Waiting for the players to do something,
	           or for the relax timer to run out.
	- buildup  a slow trickle from out of sight: pressure climbing.
	- peak     the actual fight - the full allowance of bots, the best gear
	           the difficulty allows, spawned closer and faster.
	- relax    nothing new is spawned, whatever is alive is left to finish.
	           Long enough for the players to loot, heal and move on.

	What drives the phases is PRESSURE, 0..1, recomputed every tick from
	what the players are actually going through, not from a timer:

	  + damage they have taken recently
	  + bots alive and in contact with them
	  + how hurt and how bled they are (Z-City's organism)
	  - how well equipped they are (a kitted squad gets pushed harder)
	  - how long they have survived without a fight (boredom raises it)
	  - how spread out they are (two lone players are easier to feed than
	    one tight squad, so spacing raises what it spawns per player)

	Rising pressure moves idle -> buildup -> peak; once it falls, or the
	peak has run its course, relax follows and the cycle starts again.

	WHERE: navmesh areas at a distance band from the players, out of their
	sight, preferring the side they are heading away from. Nothing ever
	spawns in view.

	GEAR: the registry at the bottom maps phase + difficulty to the tiers
	and roles from sv_bot_loadout.lua, so the same rolled-kit code hands out
	scav pistols during buildup and kitted raiders at peak on high
	difficulty. hg_bot_director_registry prints what it currently holds.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {}

local hg_bot_director       = CreateConVar("hg_bot_director",       "0",  {FCVAR_ARCHIVE}, "Run the AI director without an ent_hg_director entity in the world", 0, 1)
local hg_bot_dir_difficulty = CreateConVar("hg_bot_director_difficulty", "2", {FCVAR_ARCHIVE}, "Director difficulty: 1 easy, 2 normal, 3 hard, 4 nightmare", 1, 4)
local hg_bot_dir_max        = CreateConVar("hg_bot_director_max",    "12", {FCVAR_ARCHIVE}, "Hard cap on bots the director keeps alive at once", 1, 64)
local hg_bot_dir_per_player = CreateConVar("hg_bot_director_per_player", "3", {FCVAR_ARCHIVE}, "Bots the director aims for per living player at peak", 0.5, 16)
local hg_bot_dir_rate       = CreateConVar("hg_bot_director_rate",   "2.5", {FCVAR_ARCHIVE}, "Seconds between director spawn attempts", 0.5, 60)
local hg_bot_dir_min_dist   = CreateConVar("hg_bot_director_min_dist", "900",  {FCVAR_ARCHIVE}, "Closest a bot may be spawned to a player", 200, 6000)
local hg_bot_dir_max_dist   = CreateConVar("hg_bot_director_max_dist", "3500", {FCVAR_ARCHIVE}, "Furthest a bot may be spawned from a player", 400, 12000)
local hg_bot_dir_buildup    = CreateConVar("hg_bot_director_buildup", "25", {FCVAR_ARCHIVE}, "Seconds of build-up before the peak", 3, 300)
local hg_bot_dir_peak       = CreateConVar("hg_bot_director_peak",    "45", {FCVAR_ARCHIVE}, "Maximum length of a peak, in seconds", 5, 600)
local hg_bot_dir_relax      = CreateConVar("hg_bot_director_relax",   "60", {FCVAR_ARCHIVE}, "Seconds of quiet after a peak", 5, 900)
local hg_bot_dir_guards     = CreateConVar("hg_bot_director_guards",  "0",  {FCVAR_ARCHIVE}, "Share of director bots spawned as guards friendly to players", 0, 1)
local hg_bot_dir_debug      = CreateConVar("hg_bot_director_debug",   "0",  {FCVAR_ARCHIVE}, "Print what the director is deciding", 0, 1)

--\\ Difficulty
	-- pressure   multiplier on how fast pressure builds
	-- count      multiplier on how many bots are aimed for
	-- tier       kit tiers allowed, weighted by repetition
	-- relax      multiplier on the quiet stretch (easy gets longer breaks)
	local DIFFICULTY = {
		[1] = { pressure = 0.7, count = 0.6, relax = 1.5, tiers = { "low", "low", "mid" } },
		[2] = { pressure = 1.0, count = 1.0, relax = 1.0, tiers = { "low", "mid", "mid", "high" } },
		[3] = { pressure = 1.3, count = 1.4, relax = 0.7, tiers = { "mid", "mid", "high", "high" } },
		[4] = { pressure = 1.6, count = 1.9, relax = 0.5, tiers = { "mid", "high", "high", "high" } },
	}

	local function Difficulty()
		return DIFFICULTY[math.Clamp(hg_bot_dir_difficulty:GetInt(), 1, 4)] or DIFFICULTY[2]
	end
--//

--\\ The dynamic gear registry
	--[[
		Phase + difficulty -> what a bot spawned right now is carrying. The
		kit itself is rolled by sv_bot_loadout.lua (roles and tiers), so
		this only decides which roles and tiers are in the hat, and adds the
		odd forced item on top (a blade for a buildup scav, a grenade at
		peak) through "extra".

		Editable at runtime: hg.bots.DirectorRegistry is a plain table, and
		hg_bot_director_registry prints it.
	]]
	hg.bots.DirectorRegistry = {
		buildup = {
			roles = { "scav", "scav", "knifer", "rifleman" },
			tierShift = -1, -- one step below what the difficulty allows
			extra = { melee = 0.5, grenade = 0, med = 1 },
		},
		peak = {
			roles = { "rifleman", "raider", "knifer", "marksman", "medic" },
			tierShift = 0,
			extra = { melee = 0.25, grenade = 0.4, med = 2 },
		},
		relax = {
			roles = { "scav", "medic" },
			tierShift = -1,
			extra = { melee = 0.4, grenade = 0, med = 1 },
		},
		idle = {
			roles = { "scav" },
			tierShift = -1,
			extra = { melee = 0.4, grenade = 0, med = 1 },
		},
	}

	local TIER_ORDER = { "low", "mid", "high" }
	local TIER_INDEX = { low = 1, mid = 2, high = 3 }

	local function ShiftTier(tier, shift)
		local idx = math.Clamp((TIER_INDEX[tier] or 2) + shift, 1, 3)

		return TIER_ORDER[idx]
	end

	--- What the next bot of this phase should be carrying.
	-- @return table kit (ready for hg.bots.ApplyLoadout)
	function hg.bots.DirectorKit(phase)
		local entry = hg.bots.DirectorRegistry[phase] or hg.bots.DirectorRegistry.peak
		local diff = Difficulty()
		local tier = ShiftTier(diff.tiers[math.random(#diff.tiers)], entry.tierShift or 0)
		local role = entry.roles[math.random(#entry.roles)]
		local kit = hg.bots.RandomLoadout and hg.bots.RandomLoadout(tier, role)

		if not kit then return nil end

		-- Forced extras on top of the roll.
		local extra = entry.extra or {}
		local pool = hg.bots.LoadoutPool and hg.bots.LoadoutPool()

		if pool then
			if extra.melee and math.random() < extra.melee and #pool.melee > 0 then
				table.insert(kit.weapons, pool.melee[math.random(#pool.melee)])
			end

			if extra.grenade and math.random() < extra.grenade and #pool.grenade > 0 then
				table.insert(kit.weapons, pool.grenade[math.random(#pool.grenade)])
			end

			for _ = 1, (extra.med or 0) do
				if #pool.med > 0 then table.insert(kit.weapons, pool.med[math.random(#pool.med)]) end
			end
		end

		kit.phase = phase

		return kit
	end

	concommand.Add("hg_bot_director_registry", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		local diff = Difficulty()

		print(("[hg.bots] director registry (difficulty %d, tiers %s):"):format(
			hg_bot_dir_difficulty:GetInt(), table.concat(diff.tiers, "/")))

		for phase, entry in pairs(hg.bots.DirectorRegistry) do
			print(("  %-8s roles=%s  tierShift=%d  melee=%.2f grenade=%.2f meds=%d"):format(
				phase, table.concat(entry.roles, ","), entry.tierShift or 0,
				(entry.extra and entry.extra.melee) or 0,
				(entry.extra and entry.extra.grenade) or 0,
				(entry.extra and entry.extra.med) or 0))
		end
	end, nil, "Print the director's gear registry")
--//

--\\ Reading the players
	local state = {
		phase = "idle",
		phaseSince = 0,
		pressure = 0,
		spawned = 0,
		lastSpawn = 0,
		lastFight = 0,
		bots = {}, -- [bot] = true, only the ones the director made
	}

	hg.bots.Director = state

	local function LivePlayers()
		local out = {}

		for _, ply in ipairs(player.GetHumans()) do
			if ply:Alive() then out[#out + 1] = ply end
		end

		return out
	end

	--- How well equipped a player is, 0 (bare hands) .. 1 (kitted).
	local function GearScore(ply)
		local score = 0
		local wep = ply:GetActiveWeapon()

		if IsValid(wep) then
			if wep.ishgweapon then
				score = score + 0.35 + math.min((tonumber(wep.weight) or 1) / 12, 0.2)
			elseif wep.ismelee2 then
				score = score + 0.1
			end
		end

		local armors = ply.armors

		if istable(armors) then
			score = score + math.min(table.Count(armors) * 0.12, 0.35)
		end

		-- Something to heal with is worth as much as armour in a long fight.
		for _, w in ipairs(ply:GetWeapons()) do
			if hg.bots.IsMedClass and hg.bots.IsMedClass(w:GetClass()) then
				score = score + 0.05
			end
		end

		return math.Clamp(score, 0, 1)
	end

	--- How badly hurt a player is, 0 (fine) .. 1 (barely standing).
	local function HurtScore(ply)
		local org = ply.organism
		local hp = ply:GetMaxHealth() > 0 and (ply:Health() / ply:GetMaxHealth()) or 1
		local score = 1 - hp

		if org then
			score = math.max(score, math.Clamp((5000 - (org.blood or 5000)) / 2000, 0, 1))
			score = math.max(score, math.Clamp((org.shock or 0) / 40, 0, 1))
		end

		if IsValid(ply.FakeRagdoll) then score = 1 end

		return math.Clamp(score, 0, 1)
	end

	--- Average distance between the players: a spread-out group is fed more
	-- bots per head than one that stands in a doorway together.
	local function Spread(players)
		if #players < 2 then return 0 end

		local total, pairs_ = 0, 0

		for i = 1, #players do
			for j = i + 1, #players do
				total = total + players[i]:GetPos():Distance(players[j]:GetPos())
				pairs_ = pairs_ + 1
			end
		end

		return pairs_ > 0 and (total / pairs_) or 0
	end

	local damageTaken = {} -- [ply] = { amount, at }

	hook.Add("EntityTakeDamage", "HG_Bots_DirectorDamage", function(ent, dmg)
		local ply = ent

		if not IsValid(ply) or not ply:IsPlayer() then
			if not hg.RagdollOwner then return end

			ply = hg.RagdollOwner(ent)
		end

		if not IsValid(ply) or not ply:IsPlayer() or ply.IsHomigradBot then return end

		local rec = damageTaken[ply] or { amount = 0, at = 0 }

		-- Decay whatever was there before adding to it.
		local since = CurTime() - (rec.at or 0)

		rec.amount = math.max(rec.amount - since * 4, 0) + dmg:GetDamage()
		rec.at = CurTime()

		damageTaken[ply] = rec
	end)

	--- Recomputes state.pressure. Returns it, plus the number of live
	-- players and how many bots are currently in contact with them.
	local function Pressure()
		local players = LivePlayers()

		if #players == 0 then
			state.pressure = 0

			return 0, 0, 0
		end

		local now = CurTime()
		local diff = Difficulty()
		local hurt, gear, taken = 0, 0, 0

		-- First tick with players about: the clock for "how long has it been
		-- quiet" starts now, not at map load.
		if state.lastFight == 0 then state.lastFight = now end

		for _, ply in ipairs(players) do
			hurt = hurt + HurtScore(ply)
			gear = gear + GearScore(ply)

			local rec = damageTaken[ply]

			if rec then
				local decayed = math.max(rec.amount - (now - rec.at) * 4, 0)

				taken = taken + decayed
			end
		end

		hurt = hurt / #players
		gear = gear / #players

		local contact = 0

		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and bot:Alive() and bot.Bot

			if data and IsValid(data.Memory and data.Memory.Target) and data.Memory.Target:IsPlayer()
				and not data.Memory.Target.IsHomigradBot
			then
				contact = contact + 1
			end
		end

		-- The fight itself: damage flying and bots engaged.
		local fight = math.Clamp(taken / (120 * #players), 0, 1) * 0.6
			+ math.Clamp(contact / (#players * 2), 0, 1) * 0.4

		if fight > 0.15 then state.lastFight = now end

		-- Boredom: nothing has happened for a while, so push.
		local quiet = math.Clamp((now - (state.lastFight > 0 and state.lastFight or now)) / 90, 0, 1)

		-- Being hurt lowers what the players can take; good gear raises it.
		local capacity = math.Clamp(0.6 + gear * 0.6 - hurt * 0.7, 0.15, 1.4)

		local want = (fight * 0.55 + quiet * 0.45) * diff.pressure / capacity

		-- Smoothed, so one grenade doesn't jump straight to peak.
		state.pressure = math.Clamp(Lerp(0.15, state.pressure, want), 0, 1)
		state.spread = Spread(players)

		return state.pressure, #players, contact
	end
--//

--\\ Where to put them
	--- Is this point hidden from every player, and standable?
	local function UsableSpot(spot, players)
		for _, ply in ipairs(players) do
			local tr = util.TraceLine({
				start = ply:EyePos(),
				endpos = spot + Vector(0, 0, 40),
				mask = MASK_VISIBLE,
				filter = ply,
			})

			if not tr.Hit then return false end -- they can see it
		end

		-- Room for a standing player, and something solid under it.
		local hull = util.TraceHull({
			start = spot + Vector(0, 0, 8),
			endpos = spot + Vector(0, 0, 8),
			mins = Vector(-16, -16, 0),
			maxs = Vector(16, 16, 72),
			mask = MASK_PLAYERSOLID,
		})

		if hull.Hit then return false end

		local ground = util.TraceLine({
			start = spot + Vector(0, 0, 16),
			endpos = spot - Vector(0, 0, 200),
			mask = MASK_SOLID_BRUSHONLY,
		})

		return ground.Hit, ground.HitPos
	end

	--- No navmesh on the map (common on a P2P host's map): sample points in
	-- a ring around a player and trace them into the floor. Slower and
	-- dumber than the navmesh version, but it is the difference between the
	-- director working and the director doing nothing at all.
	local function FindSpawnSpotNoNav(players)
		local anchor = players[math.random(#players)]
		local origin = anchor:GetPos()
		local minDist = hg_bot_dir_min_dist:GetFloat()
		local maxDist = hg_bot_dir_max_dist:GetFloat()

		for _ = 1, 60 do
			local ang = math.Rand(0, math.pi * 2)
			local dist = math.Rand(minDist, maxDist)
			local spot = origin + Vector(math.cos(ang) * dist, math.sin(ang) * dist, 0)

			-- Drop it onto the floor from well above head height.
			local down = util.TraceLine({
				start = spot + Vector(0, 0, 200),
				endpos = spot - Vector(0, 0, 600),
				mask = MASK_SOLID_BRUSHONLY,
			})

			if down.Hit and not down.StartSolid then
				local ok, ground = UsableSpot(down.HitPos, players)

				if ok then return ground or down.HitPos end
			end
		end

		return nil
	end

	--- A navmesh spot in the distance band around a player, out of sight of
	-- every player, preferring behind them (where they are not looking).
	local function FindSpawnSpot(players)
		if not navmesh.IsLoaded() then
			state.lastReason = "no navmesh, using the trace fallback"

			return FindSpawnSpotNoNav(players)
		end

		local anchor = players[math.random(#players)]
		local minDist = hg_bot_dir_min_dist:GetFloat()
		local maxDist = hg_bot_dir_max_dist:GetFloat()
		local areas = navmesh.Find(anchor:GetPos(), maxDist, 128, 512)

		if not areas or #areas == 0 then return nil end

		local best, bestScore

		for _ = 1, math.min(40, #areas) do
			local area = areas[math.random(#areas)]

			if IsValid(area) and not area:IsUnderwater() then
				local spot = area:GetRandomPoint()
				local dist = spot:Distance(anchor:GetPos())

				if dist >= minDist and dist <= maxDist then
					local usable = UsableSpot(spot, players)

					if usable then
						-- Behind them scores better than in front: they walk
						-- into the fight rather than having it appear ahead.
						local to = spot - anchor:GetPos()
						to.z = 0

						if to:LengthSqr() > 1 then to:Normalize() end

						local score = dist + anchor:GetAimVector():Dot(to) * 900

						if not bestScore or score < bestScore then best, bestScore = spot, score end
					end
				end
			end
		end

		if not best then state.lastReason = "no hidden, standable navmesh spot in the distance band" end

		return best
	end
--//

--\\ Spawning
	local function DirectorBots()
		local alive = 0

		for bot in pairs(state.bots) do
			if IsValid(bot) and bot:Alive() then
				alive = alive + 1
			else
				state.bots[bot] = nil
			end
		end

		return alive
	end

	hg.bots.DirectorAlive = DirectorBots

	--- How many bots the director wants alive right now.
	local function WantCount(playerCount)
		if playerCount == 0 then return 0 end

		local diff = Difficulty()
		local base = hg_bot_dir_per_player:GetFloat() * playerCount * diff.count

		-- Phase share of that allowance.
		local share = (state.phase == "peak" and 1)
			or (state.phase == "buildup" and 0.5)
			or 0 -- relax and idle add nothing

		-- Players standing far apart need their own bots each.
		local spreadBonus = math.Clamp((state.spread or 0) / 2500, 0, 0.5)

		return math.min(math.floor(base * share * (1 + spreadBonus) + 0.5), hg_bot_dir_max:GetInt())
	end

	local function SpawnOne(players)
		-- A fake player needs a free slot. A P2P host usually runs with far
		-- fewer slots than a dedicated server, so this is the first thing
		-- that stops the director there - and it used to fail silently.
		if player.GetCount() >= game.MaxPlayers() then
			state.lastReason = ("no free player slots (%d of %d used) - host with more slots (maxplayers)"):format(
				player.GetCount(), game.MaxPlayers())

			if hg_bot_dir_debug:GetBool() then print("[hg.bots] director: " .. state.lastReason) end

			return false
		end

		local spot = FindSpawnSpot(players)

		if not spot then return false end

		local kit = hg.bots.DirectorKit(state.phase)
		local ang = Angle(0, math.Rand(0, 360), 0)
		local bot = hg.bots.SpawnWithKit and hg.bots.SpawnWithKit(spot + Vector(0, 0, 8), ang, kit)
			or hg.bots.Spawn(spot + Vector(0, 0, 8), ang)

		if not IsValid(bot) then
			state.lastReason = "player.CreateNextBot failed (no free slot, or bots are blocked on this server)"

			return false
		end

		state.lastReason = nil
		state.bots[bot] = true
		state.spawned = state.spawned + 1

		-- A share of them can be on the players' side (sv_bot_factions.lua).
		if hg.bots.SetFaction and math.random() < hg_bot_dir_guards:GetFloat() then
			hg.bots.SetFaction(bot, "guard")
		end

		if hg_bot_dir_debug:GetBool() then
			print(("[hg.bots] director: spawned %s (%s / %s) at %s"):format(
				bot:Nick(), state.phase, kit and kit.role or "?", tostring(spot)))
		end

		return true
	end
--//

--\\ Phases
	local function SetPhase(phase)
		if state.phase == phase then return end

		state.phase = phase
		state.phaseSince = CurTime()

		if hg_bot_dir_debug:GetBool() then
			print(("[hg.bots] director: phase -> %s (pressure %.2f)"):format(phase, state.pressure))
		end

		hook.Run("HG_DirectorPhase", phase, state.pressure)
	end

	hg.bots.DirectorSetPhase = SetPhase

	local function Running()
		if hg_bot_director:GetBool() then return true end

		-- Or an ent_hg_director somewhere in the world.
		return #ents.FindByClass("ent_hg_director") > 0
	end

	--- A clean slate, for when the director is switched (back) on: no
	-- leftover phase timer, spawn clock, pressure or old error from the
	-- previous run. Without it a director switched off and on again could
	-- sit in whatever it was doing when it was stopped.
	local function ResetState()
		local now = CurTime()

		state.phase = "idle"
		state.phaseSince = now - 20 -- straight into the build-up
		state.pressure = 0
		state.lastSpawn = 0
		state.lastFight = 0
		state.lastReason = nil
	end

	local wasRunning = false

	local function Tick()
		local running = Running()

		if running ~= wasRunning then
			wasRunning = running

			if running then ResetState() end

			print("[hg.bots] director: " .. (running and "started" or "stopped"))
		end

		if not running then
			if state.phase ~= "idle" then SetPhase("idle") end

			return
		end

		local pressure, playerCount, contact = Pressure()

		if playerCount == 0 then
			SetPhase("idle")

			return
		end

		local now = CurTime()
		local inPhase = now - state.phaseSince
		local diff = Difficulty()

		if state.phase == "idle" then
			-- Anything happening, or simply long enough quiet: start again.
			if pressure > 0.25 or inPhase > 20 then SetPhase("buildup") end
		elseif state.phase == "buildup" then
			if inPhase > hg_bot_dir_buildup:GetFloat() or pressure > 0.6 then SetPhase("peak") end
		elseif state.phase == "peak" then
			-- The peak ends when it has run its length, or when the fight
			-- is clearly over (nothing left in contact and pressure down).
			if inPhase > hg_bot_dir_peak:GetFloat() or (pressure < 0.25 and contact == 0 and inPhase > 10) then
				SetPhase("relax")
			end
		elseif state.phase == "relax" then
			if inPhase > hg_bot_dir_relax:GetFloat() * diff.relax then SetPhase("idle") end
		end

		-- Spawning, on its own slower clock.
		if now < state.lastSpawn + hg_bot_dir_rate:GetFloat() then return end

		state.lastSpawn = now

		local alive = DirectorBots()
		local want = WantCount(playerCount)

		if alive >= want then return end

		-- One at a time: a trickle reads as a fight coming, a dozen at once
		-- reads as a bug (and hits the server in one frame).
		local players = LivePlayers()

		if #players > 0 then SpawnOne(players) end
	end

	timer.Create("HG_Bots_Director", 1, 0, function()
		local ok, err = pcall(Tick)

		if not ok then print("[hg.bots] director error: " .. tostring(err)) end
	end)

	concommand.Add("hg_bot_director_status", function(ply)
		local function say(line)
			print(line)

			if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, line) end
		end

		say(("[hg.bots] director: %s (switch %s, entities %d), phase %s for %.0f s, pressure %.2f"):format(
			Running() and "running" or "off", hg_bot_director:GetBool() and "on" or "off",
			#ents.FindByClass("ent_hg_director"), state.phase, CurTime() - state.phaseSince, state.pressure))
		say(("  difficulty %d, its bots alive %d, cap %d, spawned in total %d, player spread %.0f u"):format(
			hg_bot_dir_difficulty:GetInt(), hg.bots.DirectorAlive(), hg_bot_dir_max:GetInt(), state.spawned, state.spread or 0))
		say(("  slots %d/%d, navmesh %s, wants %d bots now"):format(
			player.GetCount(), game.MaxPlayers(), tostring(navmesh.IsLoaded()), WantCount(#LivePlayers())))

		if state.lastReason then say("  last problem: " .. state.lastReason) end
	end, nil, "Print the director's phase and pressure")

	--- Wipes only the bots the director made.
	concommand.Add("hg_bot_director_clear", function(ply)
		if IsValid(ply) and not ply:IsSuperAdmin() then return end

		for bot in pairs(state.bots) do
			if IsValid(bot) then hg.bots.Remove(bot) end
		end

		state.bots = {}

		print("[hg.bots] director: its bots removed")
	end, nil, "Remove every bot the director spawned")
--//

--\\ The entity, and switching it on and off
	-- The entity itself is defined in sh_bot_director_ent.lua: it has to
	-- exist on the client too. Registered here on the server only, a
	-- client that saw one placed printed "Error creating 'ent_hg_director'
	-- (Make sure the file is AddCSLuaFile'd...)".

	--- On: the convar (an entity isn't needed). Off: the convar AND every
	-- director entity - with one left in the world the director kept
	-- running whatever the switch said.
	function hg.bots.DirectorSetEnabled(on)
		local cvar = GetConVar("hg_bot_director")

		if cvar then cvar:SetBool(on) end

		if not on then
			for _, ent in ipairs(ents.FindByClass("ent_hg_director")) do ent:Remove() end
		end

		if hg.bots.SaveSettings then hg.bots.SaveSettings() end
	end

	concommand.Add("hg_bot_director_on", function(ply)
		if IsValid(ply) and not ply:IsSuperAdmin() then return end

		hg.bots.DirectorSetEnabled(true)
	end, nil, "Start the AI director")

	concommand.Add("hg_bot_director_off", function(ply)
		if IsValid(ply) and not ply:IsSuperAdmin() then return end

		hg.bots.DirectorSetEnabled(false)
	end, nil, "Stop the AI director (removes the director entities too)")

	concommand.Add("hg_bot_director_place", function(ply)
		if IsValid(ply) and not ply:IsSuperAdmin() then return end

		local pos = IsValid(ply) and ply:GetEyeTrace().HitPos + Vector(0, 0, 8) or Vector(0, 0, 0)
		local ent = ents.Create("ent_hg_director")

		if not IsValid(ent) then
			print("[hg.bots] director: could not create ent_hg_director - is sh_bot_director_ent.lua loaded?")

			return
		end

		ent:SetPos(pos)
		ent:Spawn()
	end, nil, "Place the AI director entity where you are looking")
--//
