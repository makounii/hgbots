--[[
	Tarkov AI - Perception

	Sight + hearing layer for hg.bots. This file does NOT define a state -
	it runs underneath whatever state a bot is currently in, updating a
	shared "Memory" blackboard (bot.Bot.Memory) that state modules
	(combat/patrol/looting/flee) read from.

	Sight (reworked):
	- Two cones instead of one: a central cone (hg_bot_sight_fov) with full
	  range, and a much wider peripheral cone (hg_bot_sight_fov_peripheral)
	  with reduced range and much slower detection. Peripheral vision is
	  what makes a bot turn its head toward movement at the edge of view
	  instead of being blind one degree outside its cone.
	- Detection is ACCUMULATED, not instant (mem.Spot[ply] 0..1). A target
	  has to stay visible for a while before it is registered - faster up
	  close, in central vision, when sprinting, when firing, when the bot
	  is already alert; slower far away, in peripheral vision, crouched,
	  partially covered. A partially-filled meter makes the bot glance
	  toward the target (mem.GlancePos) - the "did something move there?"
	  moment - before it actually commits to a fight. A target that was
	  recently fought (or that shot at the bot) is re-acquired instantly.
	- LOS is tested against several body points (head/chest/legs, or the
	  ragdoll's bones for a downed target), so a player peeking only their
	  head, or lying behind a low wall, is handled correctly.
	- Both the bot's own ragdoll and the target's ragdoll are taken into
	  account. Previously a downed bot's LOS trace started inside its own
	  ragdoll head and always hit it (downed bots were effectively blind),
	  and a downed PLAYER was never "visible" because the trace hit their
	  ragdoll rather than the player entity.
	- Results are cached per bot/target for a few hundredths of a second:
	  combat, downed, hold and flee all call CanSee every tick, and without
	  the cache the same traces were being repeated several times per tick.

	Hearing (reworked):
	- hg.bots.ReportNoise(pos, radius, source, kind) - generic API. Noise
	  is muffled by walls (hg_bot_hearing_wall_mult), and the heard
	  position carries a distance-scaled error: a bot knows roughly where
	  a noise came from, not the exact spot.
	- Gunfire is reported straight from EntityFireBullets. Z-City's weapon
	  base plays gunshot sounds client-side, so EntityEmitSound on the
	  server never reliably saw real gunfire - bots were effectively deaf
	  to shots. Suppressors are respected.
	- Footsteps come from PlayerFootstep (running/walking/crouching have
	  different radii).
	- A noise made by the bot's CURRENT target updates the remembered
	  target position (mem.TargetPos / mem.LastHeard), which is what lets a
	  chasing bot follow someone around a corner by ear.

	Being shot at:
	- A bullet whose real path (traced to its actual impact point, so
	  walls stop it) passes near a bot, or impacts near it, counts as being
	  shot at: the shooter becomes the target, the rough shooter position
	  is estimated from the bullet line, and suppression builds up
	  (mem.Suppression, mem.UnderFireUntil, mem.UnderFireFrom). Combat and
	  downed logic use these to take cover / face the shooter instead of
	  running straight at an unseen gunman.
	- EntityTakeDamage also resolves damage dealt to a bot's RAGDOLL back
	  to the bot. Before, a downed bot never noticed being shot.

	Memory fields (all in bot.Bot.Memory):
		Target          - Entity or nil, current perceived threat
		TargetPos       - Vector, best estimate of the target's position
		TargetSeenPos   - Vector, exact position at last real sighting
		TargetVel       - Vector, target velocity at last sighting
		TargetVisible   - bool, visible on the last scan
		LastSeen        - CurTime() of last direct sight (or threat report)
		LastHeard       - CurTime() the target was last heard
		ContactHold     - CurTime() kept fresh by an active search (combat)
		Alertness       - 0 (unaware) .. 1 (fully alerted/engaged)
		SuspicionPos    - Vector or nil, "go check this out" noise ping
		SuspicionStrength - how convincing the current SuspicionPos is
		GlancePos/GlanceUntil - brief "look over there" from partial detection
		Spot            - [ply] = 0..1 detection meters
		Attackers       - [ply] = CurTime() of last shot/hit from them
		Suppression     - 0..1 incoming-fire pressure
		UnderFireUntil/UnderFireFrom - recent incoming fire and its origin
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {} -- same table core creates; load order isn't guaranteed

local hg_bot_sight_range     = CreateConVar("hg_bot_sight_range",      "1500", {FCVAR_ARCHIVE}, "Max sight distance in units", 100, 8192)
local hg_bot_sight_fov        = CreateConVar("hg_bot_sight_fov",        "100",  {FCVAR_ARCHIVE}, "Central sight FOV in degrees (full cone, not half-angle)", 10, 180)
local hg_bot_sight_fov_peripheral = CreateConVar("hg_bot_sight_fov_peripheral", "200", {FCVAR_ARCHIVE}, "Peripheral sight FOV in degrees (full cone). Targets here are detected much slower and at reduced range", 10, 340)
local hg_bot_peripheral_range = CreateConVar("hg_bot_peripheral_range", "0.45", {FCVAR_ARCHIVE}, "Fraction of sight range that peripheral vision reaches", 0.05, 1)
local hg_bot_peripheral_speed = CreateConVar("hg_bot_peripheral_speed", "0.35", {FCVAR_ARCHIVE}, "Detection speed multiplier for targets seen only in peripheral vision", 0.05, 1)
local hg_bot_spot_time        = CreateConVar("hg_bot_spot_time",        "0.35", {FCVAR_ARCHIVE}, "Seconds of continuous visibility needed to register a fully exposed target at point-blank range in central vision", 0, 5)
local hg_bot_spot_time_far    = CreateConVar("hg_bot_spot_time_far",    "2.2",  {FCVAR_ARCHIVE}, "Seconds of continuous visibility needed to register a target at max sight range", 0, 15)
local hg_bot_spot_decay       = CreateConVar("hg_bot_spot_decay",       "0.4",  {FCVAR_ARCHIVE}, "Detection meter lost per second while a target is not visible", 0, 5)
local hg_bot_reacquire_time   = CreateConVar("hg_bot_reacquire_time",   "4",    {FCVAR_ARCHIVE}, "Seconds after last contact during which a known target is re-acquired instantly on sight", 0, 30)
local hg_bot_sight_rate       = CreateConVar("hg_bot_sight_rate",       "0.15", {FCVAR_ARCHIVE}, "Seconds between perception scans per bot", 0.05, 2)
local hg_bot_alert_gain       = CreateConVar("hg_bot_alert_gain",       "2.0",  {FCVAR_ARCHIVE}, "Alertness gained per second while target is directly visible", 0.1, 10)
local hg_bot_alert_decay      = CreateConVar("hg_bot_alert_decay",      "0.1",  {FCVAR_ARCHIVE}, "Alertness lost per second once target is no longer visible - lower means bots keep hunting longer after losing sight", 0, 10)
local hg_bot_hearing_mult     = CreateConVar("hg_bot_hearing_mult",     "1.0",  {FCVAR_ARCHIVE}, "Global multiplier applied to all reported noise radii", 0, 5)
local hg_bot_hearing_wall_mult = CreateConVar("hg_bot_hearing_wall_mult", "0.5", {FCVAR_ARCHIVE}, "Noise radius multiplier when a wall is between the noise and the bot", 0, 1)
local hg_bot_hearing_error    = CreateConVar("hg_bot_hearing_error",    "0.15", {FCVAR_ARCHIVE}, "Heard-position error as a fraction of distance to the noise", 0, 1)
local hg_bot_gunfire_radius   = CreateConVar("hg_bot_gunfire_radius",   "3500", {FCVAR_ARCHIVE}, "How far unsuppressed gunfire is heard", 0, 16000)
local hg_bot_gunfire_radius_sup = CreateConVar("hg_bot_gunfire_radius_sup", "700", {FCVAR_ARCHIVE}, "How far suppressed gunfire is heard", 0, 16000)
local hg_bot_step_radius_run  = CreateConVar("hg_bot_step_radius_run",  "900",  {FCVAR_ARCHIVE}, "How far running footsteps are heard", 0, 4000)
local hg_bot_step_radius_walk = CreateConVar("hg_bot_step_radius_walk", "400",  {FCVAR_ARCHIVE}, "How far walking footsteps are heard", 0, 4000)
local hg_bot_step_radius_duck = CreateConVar("hg_bot_step_radius_duck", "120",  {FCVAR_ARCHIVE}, "How far crouched footsteps are heard", 0, 4000)
local hg_bot_whiz_radius      = CreateConVar("hg_bot_whiz_radius",      "140",  {FCVAR_ARCHIVE}, "How close (units) a bullet's actual path must pass a bot to count as being shot AT, not just gunfire heard nearby", 8, 1000)
local hg_bot_whiz_alert       = CreateConVar("hg_bot_whiz_alert",       "0.6",  {FCVAR_ARCHIVE}, "Alertness set on a bot when a bullet passes close enough to count as being shot at", 0, 1)
local hg_bot_damage_alert     = CreateConVar("hg_bot_damage_alert",     "1.0",  {FCVAR_ARCHIVE}, "Alertness set on a bot the moment it actually takes damage from an attacker", 0, 1)
local hg_bot_suppression_gain = CreateConVar("hg_bot_suppression_gain", "0.25", {FCVAR_ARCHIVE}, "Suppression added per near miss", 0, 1)
local hg_bot_suppression_decay = CreateConVar("hg_bot_suppression_decay", "0.3", {FCVAR_ARCHIVE}, "Suppression lost per second", 0, 5)
local hg_bot_target_forget_time = CreateConVar("hg_bot_target_forget_time", "12.0", {FCVAR_ARCHIVE}, "Seconds since a target was last seen or heard before a bot forgets it - independent of Alertness, which decays much faster", 1, 120)
local hg_bot_sight_attention  = CreateConVar("hg_bot_sight_attention",  "1",    {FCVAR_ARCHIVE}, "Detection is quicker for what a bot looks straight at, and at the edge of its eye goes by movement (a still body slower, a running one quicker and further out)", 0, 1)
local hg_bot_voice_radius     = CreateConVar("hg_bot_voice_radius",     "900",  {FCVAR_ARCHIVE}, "How far bots hear a player talking in chat (whisper x0.3, yell or capitals x2; 0 = not at all)", 0, 6000)

-- Trust mode. Off (default, NOT archived so every server start is wild):
-- bots attack any human they register. On: bots only attack humans who
-- have attacked a bot (shot at, hit, kicked) within hg_bot_trust_forgive
-- seconds - everyone else is watched but left alone. Toggle with the admin
-- command hg_bot_trustmode.
local hg_bot_trust            = CreateConVar("hg_bot_trust",            "0",   {FCVAR_NOTIFY}, "Trust mode: 0 = wild bots attack every human on sight, 1 = bots only attack humans who attacked a bot", 0, 1)
local hg_bot_trust_forgive    = CreateConVar("hg_bot_trust_forgive",    "900", {FCVAR_ARCHIVE}, "Trust mode: seconds a human stays hostile to ALL bots after attacking one (each new attack restarts it; killing a bot doubles it). The bot that was attacked itself holds a grudge for its whole life regardless", 5, 36000)
local hg_bot_aim_threat_time  = CreateConVar("hg_bot_aim_threat_time",  "0.8", {FCVAR_ARCHIVE}, "Seconds a visible human must hold a gun on a bot before it treats them as a threat (half that while they aim down sights) - makes them hostile even in trust mode", 0.1, 10)
local hg_bot_shooter_window   = CreateConVar("hg_bot_shooter_window",   "6",   {FCVAR_ARCHIVE}, "A human seen within this many seconds of firing a gun is treated as a threat (the source of the shooting) - hostile even in trust mode", 0, 60)
local hg_bot_trust_forget_on_death = CreateConVar("hg_bot_trust_forget_on_death", "0", {FCVAR_ARCHIVE}, "Trust mode: whether a human's hostility is wiped when THEY die", 0, 1)

-- hg_bot_debug itself is declared (local) in sv_bot_core.lua - fetch the
-- existing ConVar rather than redeclaring it.
local hg_bot_debug = GetConVar("hg_bot_debug") or CreateConVar("hg_bot_debug", "0", {FCVAR_ARCHIVE, FCVAR_NOTIFY}, "Print Tarkov AI bot state debug info", 0, 1)

--\\ Shared helpers
	--- The entity that physically represents a player right now: their
	-- FakeRagdoll while downed, the player itself otherwise.
	local function GetCharacter(ply)
		if not IsValid(ply) then return ply end

		local rag = ply.FakeRagdoll

		if IsValid(rag) then return rag end

		return ply
	end

	hg.bots.GetCharacter = GetCharacter

	local function IsDowned(ply)
		return IsValid(ply) and IsValid(ply.FakeRagdoll)
	end

	local function CachedBone(rag, name)
		rag.hgBotBones = rag.hgBotBones or {}

		local id = rag.hgBotBones[name]

		if id == nil then
			id = rag:LookupBone(name) or false
			rag.hgBotBones[name] = id
		end

		return id or nil
	end

	local function BonePos(rag, name)
		local id = CachedBone(rag, name)
		if not id then return nil end

		local pos = rag:GetBonePosition(id)

		return pos
	end

	--- Where a bot actually sees from. While downed, EyePos() is the
	-- player entity glued to the ragdoll head (view offset 1u), which is
	-- close but sits inside the head's physics box - the eyes attachment
	-- is the correct origin, and traces from it must filter the ragdoll.
	function hg.bots.GetEyePos(bot)
		local rag = bot.FakeRagdoll

		if IsValid(rag) then
			rag.hgBotEyesAtt = rag.hgBotEyesAtt or rag:LookupAttachment("eyes")

			local att = rag.hgBotEyesAtt and rag.hgBotEyesAtt > 0 and rag:GetAttachment(rag.hgBotEyesAtt)

			if att then return att.Pos end

			return BonePos(rag, "ValveBiped.Bip01_Head1") or bot:EyePos()
		end

		return bot:EyePos()
	end

	--- Points on a target's body worth checking LOS against, most
	-- important (for aiming) first: chest, head, legs.
	local function GetBodyPoints(target)
		local rag = target.FakeRagdoll

		if IsValid(rag) then
			return {
				BonePos(rag, "ValveBiped.Bip01_Spine2") or rag:WorldSpaceCenter(),
				BonePos(rag, "ValveBiped.Bip01_Head1") or rag:WorldSpaceCenter(),
				BonePos(rag, "ValveBiped.Bip01_Pelvis") or rag:GetPos(),
			}
		end

		local feet = target:GetPos()
		local eye = target:EyePos()

		return {
			LerpVector(0.55, feet, eye), -- chest
			eye - Vector(0, 0, 2), -- head
			feet + Vector(0, 0, 14), -- legs
		}
	end

	--- Filter list for LOS traces between bot and target - both entities
	-- and both ragdolls, so the only thing that can block is the world or
	-- a genuine third object.
	local function SightFilter(bot, target)
		local f = { bot, target }

		if IsValid(bot.FakeRagdoll) then f[#f + 1] = bot.FakeRagdoll end
		if IsValid(target.FakeRagdoll) then f[#f + 1] = target.FakeRagdoll end

		local wep = bot:GetActiveWeapon()
		if IsValid(wep) then f[#f + 1] = wep end

		return f
	end

	hg.bots.SightFilter = SightFilter

	-- Last time each shooter fired - muzzle flash makes you easier to spot.
	local lastShotTime = {}

	-- Trust mode hostility: [ply] = CurTime() until which they're hostile.
	-- Shared by all bots - attack one and the others know.
	hg.bots.Hostile = hg.bots.Hostile or {}

	--- Should this bot ignore something a bot did (noise, a bullet, damage)?
	-- Bots used to ignore each other outright; with factions on, only their
	-- OWN side is ignored - an enemy faction shooting nearby is exactly as
	-- interesting as a player doing it (sv_bot_factions.lua).
	local function IgnoreBotSource(source, bot)
		if not IsValid(source) or not source.IsHomigradBot then return false end
		if not hg.bots.SameFaction then return true end

		return hg.bots.SameFaction(source, bot) or not IsValid(bot)
	end

	hg.bots.IgnoreBotSource = IgnoreBotSource

	--- May bot attack ply? Always true with trust mode off. With it on:
	-- ply attacked any bot recently (shared hostility), or attacked THIS
	-- bot at any point in its life (personal grudge, never forgiven).
	function hg.bots.IsHostile(ply, bot)
		-- Factions first (sv_bot_factions.lua): a guard bot never opens on a
		-- player, a raider always may, and the two always fight each other.
		if hg.bots.FactionHostile then
			local verdict = hg.bots.FactionHostile(ply, bot)

			if verdict ~= nil then return verdict end
		end

		if not hg_bot_trust:GetBool() then return true end
		if (hg.bots.Hostile[ply] or 0) > CurTime() then return true end

		local mem = IsValid(bot) and bot.Bot and bot.Bot.Memory

		return mem and mem.Grudge and mem.Grudge[ply] or false
	end

	--- ply attacked a bot: hostile to every bot for a long while, and the
	-- attacked bot remembers personally. Never shortens an existing,
	-- longer hostility (e.g. from killing a bot).
	function hg.bots.MarkHostile(ply, bot, mult)
		if not IsValid(ply) or ply.IsHomigradBot then return end

		local untilT = CurTime() + hg_bot_trust_forgive:GetFloat() * (mult or 1)

		hg.bots.Hostile[ply] = math.max(hg.bots.Hostile[ply] or 0, untilT)

		local mem = IsValid(bot) and bot.Bot and bot.Bot.Memory

		if mem then
			mem.Grudge = mem.Grudge or {}
			mem.Grudge[ply] = true
		end
	end

	-- Killing a bot is remembered twice as long by the rest.
	hook.Add("PlayerDeath", "HG_Bots_TrustKill", function(victim, inflictor, attacker)
		if not IsValid(victim) or not victim.IsHomigradBot then return end

		local killer = hg.bots.ResolveShooter and hg.bots.ResolveShooter(attacker) or attacker

		if IsValid(killer) and killer:IsPlayer() and killer ~= victim then
			hg.bots.MarkHostile(killer, nil, 2)
		end
	end)

	--- Drops every bot's target that trust mode no longer allows.
	function hg.bots.ApplyTrust()
		for bot in pairs(hg.bots.List) do
			local mem = IsValid(bot) and bot.Bot and bot.Bot.Memory

			if mem and IsValid(mem.Target) and not hg.bots.IsHostile(mem.Target, bot) then
				mem.Target = nil
				mem.TargetPos = nil
				mem.TargetSeenPos = nil
				mem.TargetVel = nil
				mem.ContactHold = nil
			end
		end
	end

	concommand.Add("hg_bot_trustmode", function(ply, cmd, args)
		if IsValid(ply) and not ply:IsAdmin() then return end

		local arg = args and args[1]
		local on

		if arg == "1" or arg == "on" then
			on = true
		elseif arg == "0" or arg == "off" then
			on = false
		else
			on = not hg_bot_trust:GetBool() -- no argument: toggle
		end

		RunConsoleCommand("hg_bot_trust", on and "1" or "0")

		-- The convar change applies next frame; apply trust right after.
		timer.Simple(0, hg.bots.ApplyTrust)

		local msg = "[hg.bots] Trust mode " .. (on and "ON - bots only attack players who attacked a bot" or "OFF - bots are wild and attack everyone")

		print(msg)

		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
	end, nil, "Bot trust mode: hg_bot_trustmode [1|0], no argument toggles. Off by default (wild bots).")
--//

--\\ Sight
	-- Effective range multiplier: crude stand-in for Tarkov's visibility
	-- modifiers without a full lighting model.
	local function GetTargetVisibilityMod(target)
		local mod = 1

		if IsDowned(target) then
			mod = mod * 0.7 -- lying on the ground is a small silhouette
		elseif target.Crouching and target:Crouching() then
			mod = mod * 0.55
		end

		local vel = GetCharacter(target):GetVelocity():Length2D()

		if vel > 200 then
			mod = mod * 1.35 -- sprinting stands out
		elseif vel < 10 then
			mod = mod * 0.85 -- stationary is a little harder to pick up
		end

		if target.FlashlightIsOn and target:FlashlightIsOn() then
			mod = mod * 1.5
		end

		if (lastShotTime[target] or 0) > CurTime() - 1.5 then
			mod = mod * 1.5 -- muzzle flash
		end

		return mod
	end

	local sightCache = {} -- [bot] = { [target] = { t, vis, info } }
	local SIGHT_CACHE_TIME = 0.12

	-- Sight is the most asked question there is (every bot about every
	-- candidate, several times a second), and a good part of what it cost
	-- was not the traces - those are about 7 microseconds each - but the
	-- asking: some forty calls into the engine per pair for positions,
	-- angles, speed, weapon, flashlight, convars. So:
	-- - what a body IS this tick (where, how fast, how visible, what it
	--   holds) is asked once per tick and shared by everyone who looks at
	--   it or with it: a snapshot (Snap);
	-- - range and cone are then plain arithmetic on numbers, answered
	--   cheapest-first, and only what passes is traced;
	-- - the traces use one shared query and result table and one filter
	--   list refilled in place; the answer is written into the table the
	--   cache already holds for this pair.
	local sTR = {}
	local sQ = { output = sTR, mask = MASK_VISIBLE }
	local sFilter = {}
	local util_TraceLine = util.TraceLine
	local cos, rad, sqrt = math.cos, math.rad, math.sqrt
	local Z2, Z14 = Vector(0, 0, 2), Vector(0, 0, 14)
	local TickCount = engine.TickCount

	local snaps = setmetatable({}, { __mode = "k" })

	--- This tick's snapshot of a body (a bot, a player, an NPC): its
	-- character (ragdoll when down) and centre. Everything else is filled
	-- in the first time somebody needs it (the Snap* functions below).
	local function Snap(ent)
		local tick = TickCount()
		local s = snaps[ent]

		if s then
			if s.tick == tick then return s end
		else
			s = {}
			snaps[ent] = s
		end

		local rag = ent.FakeRagdoll

		if not IsValid(rag) then rag = nil end

		local char = rag or ent
		local c = char:WorldSpaceCenter()

		s.tick, s.rag, s.char = tick, rag, char
		s.center, s.cx, s.cy, s.cz = c, c.x, c.y, c.z
		s.eye, s.fx, s.mod, s.p1, s.speed, s.kind, s.ax, s.wep, s.rmul = nil, nil, nil, nil, nil, nil, nil, nil, nil

		return s
	end

	--- Where it sees from (hg.bots.GetEyePos for a bot, the eyes for anyone).
	local function SnapEye(s, ent)
		local e = s.eye

		if not e then
			e = ent.IsHomigradBot and hg.bots.GetEyePos(ent) or ent:EyePos()
			s.eye, s.ex, s.ey, s.ez = e, e.x, e.y, e.z
		end

		return e
	end

	--- Which way it looks (s.fx, s.fy, s.fz).
	local function SnapFwd(s, ent)
		if not s.fx then
			local f = ent:EyeAngles():Forward()

			s.fx, s.fy, s.fz = f.x, f.y, f.z
		end
	end

	--- Where it aims (s.ax, s.ay, s.az).
	local function SnapAim(s, ent)
		if not s.ax then
			local a = ent:GetAimVector()

			s.ax, s.ay, s.az = a.x, a.y, a.z
		end
	end

	local function SnapSpeed(s)
		local v = s.speed

		if not v then
			v = s.char:GetVelocity():Length2D()
			s.speed = v
		end

		return v
	end

	local function SnapMod(s, ent)
		local m = s.mod

		if not m then
			m = GetTargetVisibilityMod(ent)
			s.mod = m
		end

		return m
	end

	--- Chest, head, legs (s.p1, s.p2, s.p3).
	local function SnapPoints(s, ent)
		if s.p1 then return end

		local rag = s.rag

		if rag then
			s.p1 = BonePos(rag, "ValveBiped.Bip01_Spine2") or s.center
			s.p2 = BonePos(rag, "ValveBiped.Bip01_Head1") or s.center
			s.p3 = BonePos(rag, "ValveBiped.Bip01_Pelvis") or rag:GetPos()
		else
			local feet = ent:GetPos()
			local eye = ent:EyePos()

			s.p1 = LerpVector(0.55, feet, eye)
			s.p2 = eye - Z2
			s.p3 = feet + Z14
		end
	end

	--- The weapon in its hands, or false.
	local function SnapWeapon(s, ent)
		local w = s.wep

		if w == nil then
			w = ent:GetActiveWeapon()

			if not IsValid(w) then w = false end

			s.wep = w
		end

		return w
	end

	hg.bots.Snap = Snap

	-- The sight convars, read once per tick instead of once per pair.
	local cvTick = -1
	local cvRange, cvFovCos, cvPeriCos, cvReach, cvAttention

	local function SightConvars()
		local tick = TickCount()

		if tick == cvTick then return end

		cvTick = tick
		cvRange = hg_bot_sight_range:GetFloat()
		cvFovCos = cos(rad(hg_bot_sight_fov:GetFloat() * 0.5))
		cvPeriCos = cos(rad(hg_bot_sight_fov_peripheral:GetFloat() * 0.5))
		cvReach = hg_bot_peripheral_range:GetFloat()
		cvAttention = hg_bot_sight_attention:GetBool()
	end

	--- Uncached sight query. Returns visible; when visible, info is filled:
	-- { frac = visible body fraction, central = in central cone,
	--   point = best visible aim point, dist = distance }.
	-- quick: two body points instead of three (somebody the bot has not
	-- begun to notice - see ScanOneBot).
	local function ComputeSight(bot, target, info, quick)
		SightConvars()

		local bs, ts = Snap(bot), Snap(target)
		local eyePos = SnapEye(bs, bot)

		local dx, dy, dz = ts.cx - bs.ex, ts.cy - bs.ey, ts.cz - bs.ez
		local distSqr = dx * dx + dy * dy + dz * dz

		-- (x what this bot's own eyes add: a sniper behind its scope.)
		local rmul = bs.rmul

		if not rmul then
			rmul = hg.bots.SightRangeMul and hg.bots.SightRangeMul(bot) or 1
			bs.rmul = rmul
		end

		local range = cvRange * rmul

		-- Further than any visibility bonus reaches (sprint x flashlight x
		-- muzzle flash = 3.04): no need to work the bonus out.
		if distSqr > range * range * 9.3 then return false end

		local dist = sqrt(distSqr)

		SnapFwd(bs, bot)

		local dot = (bs.fx * dx + bs.fy * dy + bs.fz * dz) / (dist > 0.001 and dist or 0.001)
		local central = dot >= cvFovCos

		-- Behind the bot: the commonest answer of all, and now the
		-- cheapest. (Up close - within ~2 m - anything counts: you feel
		-- someone standing right next to you.)
		if not central and dist > 90 and dot < cvPeriCos then return false end

		local baseRange = range * SnapMod(ts, target)

		if dist > baseRange then return false end

		local edge = false

		if not central then
			-- Peripheral vision: wider cone, much shorter reach.
			local reach = cvReach

			if dist > baseRange * reach then
				-- ...except for movement: the edge of the eye catches a body
				-- on the move a good deal further out (to 75 % of the range
				-- for a run), only it makes out less of it.
				local speed = cvAttention and SnapSpeed(ts) or 0

				if speed < 60 or dist > baseRange * Lerp(math.Clamp((speed - 60) / 220, 0, 1), reach + 0.1, 0.75) then
					return false
				end

				edge = true
			end
		end

		SnapPoints(ts, target)

		-- Both bodies and both ragdolls out of the way, so the only thing
		-- that can block is the world or a genuine third object.
		local n = 2

		sFilter[1], sFilter[2] = bot, target

		if bs.rag then n = n + 1 sFilter[n] = bs.rag end
		if ts.rag then n = n + 1 sFilter[n] = ts.rag end

		local wep = SnapWeapon(bs, bot)

		if wep then n = n + 1 sFilter[n] = wep end

		-- At the wheel (sv_bot_vehicle.lua): its own car is not a wall.
		local car = bot.Bot and bot.Bot.InVehicle

		if car and IsValid(car) then n = n + 1 sFilter[n] = car end

		for i = n + 1, #sFilter do sFilter[i] = nil end

		sQ.start, sQ.filter = eyePos, sFilter

		local visibleCount, best = 0, nil

		sQ.endpos = ts.p1
		util_TraceLine(sQ)

		if not sTR.Hit then visibleCount, best = 1, 1 end

		sQ.endpos = ts.p2
		util_TraceLine(sQ)

		if not sTR.Hit then visibleCount, best = visibleCount + 1, best or 2 end

		if not quick then
			sQ.endpos = ts.p3
			util_TraceLine(sQ)

			if not sTR.Hit then visibleCount, best = visibleCount + 1, best or 3 end
		end

		if visibleCount == 0 then return false end

		info.frac = visibleCount / (quick and 2 or 3) * (edge and 0.6 or 1)
		info.central = central
		info.edge = edge
		info.point = best == 1 and ts.p1 or best == 2 and ts.p2 or ts.p3
		info.pointIndex = best
		info.dist = dist
		info.dot = dot

		return true
	end

	function hg.bots.RebindSightTrace() util_TraceLine = util.TraceLine end

	--- Line-of-sight + FOV + range check from bot to target. Does NOT touch
	-- Memory - pure query, usable by other systems too. Cached briefly.
	-- @return boolean visible, table|nil info (see ComputeSight). The info
	--         table is the cache's own, rewritten by the next look at the
	--         same pair: read it, don't keep it.
	function hg.bots.CanSee(bot, target, quick)
		if not IsValid(bot) or not IsValid(target) then return false end
		-- Players, and NPCs / nextbots once they have the small
		-- compatibility shim (sv_bot_factions.lua) - everything downstream
		-- calls :Alive(), :Crouching() and friends on the target.
		if not target:IsPlayer() then
			if not hg.bots.IsNPCTarget or not hg.bots.IsNPCTarget(target) then return false end

			if hg.bots.ShimTarget then hg.bots.ShimTarget(target) end
		end

		if not target:Alive() then return false end

		local now = CurTime()
		local perBot = sightCache[bot]

		if not perBot then
			perBot = {}
			sightCache[bot] = perBot
		end

		local c = perBot[target]

		if c then
			if now - c[1] < SIGHT_CACHE_TIME then
				return c[2], c[2] and c[3] or nil
			end
		else
			c = { 0, false, {} }
			perBot[target] = c
		end

		local vis = ComputeSight(bot, target, c[3], quick)

		c[1], c[2] = now, vis

		return vis, vis and c[3] or nil
	end

	--- Best point to shoot at on target: the body point the last sight
	-- check found visible - where that point is NOW, not where it was when
	-- the check ran (the check is cached for a moment, a running man is
	-- not) - otherwise the chest estimate.
	function hg.bots.GetAimPoint(bot, target)
		local vis, info = hg.bots.CanSee(bot, target)
		local ts = Snap(target)

		SnapPoints(ts, target)

		if vis and info then
			local i = info.pointIndex

			return i == 2 and ts.p2 or i == 3 and ts.p3 or ts.p1
		end

		return ts.p1
	end
	--- Diagnostic version of CanSee that explains WHY, instead of just
	-- true/false. Not used in the hot path.
	function hg.bots.ExplainSight(bot, target)
		if not IsValid(bot) then return "bot is not valid" end
		if not IsValid(target) then return "target is not valid" end
		if not target:IsPlayer() and not (hg.bots.IsNPCTarget and hg.bots.IsNPCTarget(target)) then
			return "target is not a Player or an attackable NPC (" .. tostring(target:GetClass()) .. ")"
		end
		if not target:Alive() then return "target is not alive (dead/spectating?)" end

		local eyePos = hg.bots.GetEyePos(bot)
		local center = GetCharacter(target):WorldSpaceCenter()
		local range = hg_bot_sight_range:GetFloat() * GetTargetVisibilityMod(target)
		local dist = eyePos:Distance(center)
		local dir = (center - eyePos):GetNormalized()
		local angle = math.deg(math.acos(math.Clamp(bot:EyeAngles():Forward():Dot(dir), -1, 1)))

		local lines = {
			string.format("distance: %.0f / %.0f max (peripheral %.0f)", dist, range, range * hg_bot_peripheral_range:GetFloat()),
			string.format("angle off center: %.1f deg (central <= %.1f, peripheral <= %.1f)", angle, hg_bot_sight_fov:GetFloat() * 0.5, hg_bot_sight_fov_peripheral:GetFloat() * 0.5),
			"bot downed: " .. tostring(IsDowned(bot)) .. ", target downed: " .. tostring(IsDowned(target)),
		}

		local info = {}
		local vis = ComputeSight(bot, target, info)

		if vis then
			table.insert(lines, string.format("PASS: visible (%s vision, %.0f%% of body)", info.central and "central" or "peripheral", info.frac * 100))
		else
			table.insert(lines, "FAIL: not visible (range, cone or every body point blocked)")
		end

		local mem = bot.Bot and bot.Bot.Memory

		if mem and mem.Spot then
			table.insert(lines, string.format("detection meter: %.2f", mem.Spot[target] or 0))
		end

		return table.concat(lines, "\n")
	end
--//

--\\ Debug
	-- hg_bot_sight_debug [player name] - reports, for every bot, exactly
	-- which check is failing against the given human (defaults to caller).
	concommand.Add("hg_bot_sight_debug", function(ply, cmdname, args)
		if IsValid(ply) and not ply:IsAdmin() then return end

		local targetName = args and args[1]
		local target

		if targetName then
			for _, human in ipairs(player.GetHumans()) do
				if string.find(string.lower(human:Nick()), string.lower(targetName), 1, true) then
					target = human
					break
				end
			end
		else
			target = ply
		end

		if not IsValid(target) then
			print("[hg.bots] No matching human player found - pass a name or run this as a player.")
			return
		end

		local bots = hg.bots.GetAll and hg.bots.GetAll() or {}

		if #bots == 0 then
			print("[hg.bots] No active bots.")
			return
		end

		for _, bot in ipairs(bots) do
			local mem = bot.Bot and bot.Bot.Memory or {}

			print(("[hg.bots] %s -> %s:"):format(bot:Nick(), target:Nick()))
			print(hg.bots.ExplainSight(bot, target))
			print(("  Memory.Target=%s  Alertness=%.2f  Suppression=%.2f  State=%s"):format(
				tostring(mem.Target),
				mem.Alertness or 0,
				mem.Suppression or 0,
				bot.Bot and bot.Bot.State or "?"
			))

			local wep = bot:GetActiveWeapon()

			if IsValid(wep) and wep:IsWeapon() then
				print(("  Weapon=%s  Clip1=%d  ReserveAmmo=%d"):format(
					wep:GetClass(),
					wep:Clip1(),
					bot:GetAmmoCount(wep:GetPrimaryAmmoType())
				))
			else
				print("  Weapon=none (bot has no active weapon - it needs to pick one up first, see sv_bot_loot.lua)")
			end
		end
	end)
--//

--\\ Hearing
	local KIND_WEIGHT = {
		gunfire = 1.0,
		impact = 0.8,
		step = 0.5,
		generic = 0.4,
	}

	local hearTR = {}
	local hearQ = { output = hearTR, mask = MASK_SOLID_BRUSHONLY }
	local Z8 = Vector(0, 0, 8)

	local function RandomOffset2D(radius)
		if radius <= 0 then return Vector(0, 0, 0) end

		local a = math.Rand(0, math.pi * 2)
		local r = math.Rand(0, radius)

		return Vector(math.cos(a) * r, math.sin(a) * r, 0)
	end

	--- Generic noise-report API - anything can call this.
	-- @param pos Vector origin of the noise
	-- @param radius number units the noise carries (pre hg_bot_hearing_mult)
	-- @param source Entity|nil what made the noise
	-- @param kind string|nil "gunfire", "step", "impact" or "generic"
	function hg.bots.ReportNoise(pos, radius, source, kind)
		-- A bot's own noise never alerts its own side; with factions on it
		-- does alert the other one, which is filtered per bot below.
		if IsValid(source) and source.IsHomigradBot and not hg.bots.SameFaction then return end

		kind = kind or "generic"
		radius = radius * hg_bot_hearing_mult:GetFloat()

		if radius <= 0 then return end

		local now = CurTime()
		local weight = KIND_WEIGHT[kind] or KIND_WEIGHT.generic
		local wallMult = hg_bot_hearing_wall_mult:GetFloat()
		local radiusSqr = radius * radius

		if hg_bot_debug:GetBool() then
			print(("[hg.bots] ReportNoise %s from %s at %s, radius=%.0f"):format(kind, tostring(source), tostring(pos), radius))
		end

		for bot in pairs(hg.bots.List) do
			if not IsValid(bot) or bot == source or not bot:Alive() then continue end
			if IgnoreBotSource(source, bot) then continue end

			local data = bot.Bot
			if not data or not data.Enabled then continue end

			local ear = hg.bots.GetEyePos(bot)
			local distSqr = ear:DistToSqr(pos)

			if distSqr > radiusSqr then continue end

			local dist = math.sqrt(distSqr)
			local effRadius = radius

			-- Walls muffle. Only brushes count - a prop or a player in the
			-- way doesn't meaningfully block sound.
			if dist > 150 then
				hearQ.start, hearQ.endpos = ear, pos + Z8

				util.TraceLine(hearQ)

				if hearTR.Hit then
					effRadius = radius * wallMult

					if dist > effRadius then continue end
				end
			end

			local strength = 1 - (dist / effRadius)
			local mem = data.Memory

			-- Hearing is directional but not precise: the farther and
			-- fainter the noise, the vaguer the position.
			local err = math.min(dist * hg_bot_hearing_error:GetFloat() * (1.2 - strength), 450)
			local heardPos = pos + RandomOffset2D(err)

			if IsValid(source) and source == mem.Target then
				-- The known enemy just made a noise. If the bot can't see
				-- them right now, that's the freshest info about where
				-- they are - this is what lets a chase continue around a
				-- corner by ear instead of dead-ending at the last sighting.
				if not mem.TargetVisible then
					mem.TargetPos = heardPos
					mem.LastHeard = now
					mem.TargetVel = nil -- the old velocity no longer matches this position
				end
			elseif not IsValid(mem.Target) and not (kind ~= "gunfire" and IsValid(source) and mem.Spot
				and (mem.Spot[source] or 0) >= 1 and not hg.bots.IsHostile(source, bot) and hg.bots.CanSee(bot, source))
			then
				-- (Not someone it is looking at and knows to be harmless:
				-- heard, but nothing to go and investigate.)
				local score = strength * weight
				local current = (mem.SuspicionStrength or 0) - (now - (mem.SuspicionTime or now)) * 0.1

				-- Only replace an existing suspicion with something at
				-- least as convincing, so a faint footstep can't pull a bot
				-- away from investigating a gunshot.
				if not mem.SuspicionPos or score >= current then
					mem.SuspicionPos = heardPos
					mem.SuspicionStrength = score
					mem.SuspicionTime = now
					mem.SuspicionKind = kind
				end

				mem.Alertness = math.Clamp((mem.Alertness or 0) + score * 0.6, 0, 1)
			end
		end
	end

	-- Soundlevel is logarithmic dB-ish; rough dB -> radius curve.
	local function SoundLevelToRadius(level)
		return math.Clamp((level - 60) * 20, 0, 4000)
	end

	local lastEmitNoise = {} -- [ent] = CurTime(), throttles noisy entities

	hook.Add("EntityEmitSound", "HG_Bots_Hearing", function(data)
		local ent = data.Entity

		if not IsValid(ent) then return end
		if ent.IsHomigradBot and not hg.bots.SameFaction then return end
		if (data.SoundLevel or 75) < 70 then return end

		local now = CurTime()
		if (lastEmitNoise[ent] or 0) > now - 0.25 then return end
		lastEmitNoise[ent] = now

		local radius = SoundLevelToRadius(data.SoundLevel or 75)
		if radius <= 0 then return end

		local owner = ent:IsPlayer() and ent or nil

		if not owner and (ent:IsNPC() or ent:IsNextBot()) then owner = ent end

		if not owner and hg.RagdollOwner then
			owner = hg.RagdollOwner(ent) or nil
		end

		hg.bots.ReportNoise(data.Pos or ent:GetPos(), radius, owner, "generic")
	end)

	-- Footsteps come from Z-City's own step hook: its PlayerFootstep hook
	-- returns true, which (hook order being what it is) could stop ours from
	-- ever running - bots were deaf to steps. HG_PlayerFootstep_Notify runs
	-- once per real step, at the walking pace.
	hook.Add("HG_PlayerFootstep_Notify", "HG_Bots_FootstepNoise", function(ply, pos)
		if not IsValid(ply) or not ply:Alive() then return end
		if ply.IsHomigradBot and not hg.bots.SameFaction then return end

		local radius

		if ply:Crouching() or ply:KeyDown(IN_WALK) then
			radius = hg_bot_step_radius_duck:GetFloat()
		elseif ply:GetVelocity():Length2D() > 200 then
			radius = hg_bot_step_radius_run:GetFloat()
		else
			radius = hg_bot_step_radius_walk:GetFloat()
		end

		-- The kit under a torso armour rattles (Z-City plays it each step).
		local armor = ply.GetNetVar and ply:GetNetVar("Armor", {})
		if istable(armor) and armor.torso then radius = radius * 1.25 end

		hg.bots.ReportNoise(pos or ply:GetPos(), radius, ply, "step")
	end)

	-- Talk is heard. Z-City's chat (and chat add-ons built on it) run
	-- HG_PlayerSay with the speaker and the line as typed. (Its PostPlayerSay
	-- is no use: it hands on two undefined variables.)
	local NOT_SPOKEN = { "//", ".//", "[[", "/ooc", "/looc", "/me", "/it", "/roll" } -- out of character, acted

	local function Starts(s, p) return string.sub(s, 1, #p) == p end

	--- Mostly capitals (Latin or Cyrillic): yelled.
	local function Shouted(text)
		local up, low = 0, 0

		pcall(function()
			for _, c in utf8.codes(text) do
				if (c >= 65 and c <= 90) or (c >= 0x410 and c <= 0x42F) or c == 0x401 then
					up = up + 1
				elseif (c >= 97 and c <= 122) or (c >= 0x430 and c <= 0x44F) or c == 0x451 then
					low = low + 1
				end
			end
		end)

		return up >= 3 and up > low * 2
	end

	hook.Add("HG_PlayerSay", "HG_Bots_Speech", function(ply, txtTbl, raw)
		if hg_bot_voice_radius:GetFloat() <= 0 then return end
		if not IsValid(ply) or not ply:Alive() or ply.IsHomigradBot then return end
		if ply.organism and ply.organism.otrub then return end

		raw = string.Trim(tostring(raw or ""))

		local low = string.lower(raw)

		for _, p in ipairs(NOT_SPOKEN) do
			if Starts(low, p) then return end
		end

		if Starts(low, "!") then return end -- a command

		local mult = 1

		if ply.ChatWhisper or Starts(low, "/w ") or Starts(low, "/whisper") then
			mult = 0.3
		elseif Starts(low, "/y ") or Starts(low, "/yell") then
			mult = 2
		elseif Starts(low, "/") then
			return -- a command
		elseif Shouted(raw) then
			mult = 2
		end

		-- After every other HG_PlayerSay hook: a command or a muted line
		-- is left empty by them.
		timer.Simple(0, function()
			if not IsValid(ply) or not ply:Alive() or not istable(txtTbl) then return end
			if not isstring(txtTbl[1]) or string.Trim(txtTbl[1]) == "" then return end

			hg.bots.ReportNoise(ply:EyePos(), hg_bot_voice_radius:GetFloat() * mult, ply, "voice")
		end)
	end)
--//

--\\ Combat awareness
	--- Resolves whatever a damage/bullet event handed us down to an actual
	-- Player, or nil. Weapon bases differ in whether the bullet "entity" is
	-- the player or the SWEP, and damage can be attributed to a ragdoll.
	local function ResolveShooter(ent, explicitAttacker)
		if IsValid(explicitAttacker) and explicitAttacker:IsPlayer() then
			return explicitAttacker
		end

		if not IsValid(ent) then return nil end
		if ent:IsPlayer() then return ent end

		if ent.IsWeapon and ent:IsWeapon() then
			local owner = ent:GetOwner()

			if IsValid(owner) and owner:IsPlayer() then
				return owner
			end
		end

		if hg.RagdollOwner then
			local owner = hg.RagdollOwner(ent)

			if IsValid(owner) then return owner end
		end

		return nil
	end

	hg.bots.ResolveShooter = ResolveShooter

	--- Registers attacker as an immediate, confirmed threat to bot.
	-- @param pos Vector estimated shooter position
	-- @param alertLevel number alertness floor to apply
	-- @param suppress number|nil suppression to add
	function hg.bots.ReportThreat(bot, attacker, pos, alertLevel, suppress)
		if not IsValid(bot) or not bot.Bot then return end
		if not IsValid(attacker) or not attacker:IsPlayer() then return end

		local data = bot.Bot
		if not data.Enabled then return end

		-- Attacking any bot makes you hostile to all of them (trust mode).
		hg.bots.MarkHostile(attacker, bot)

		local mem = data.Memory
		local now = CurTime()

		mem.Attackers = mem.Attackers or {}
		mem.Attackers[attacker] = now
		mem.Spot = mem.Spot or {}
		mem.Spot[attacker] = 1 -- being shot at by someone means you know they exist

		mem.UnderFireUntil = now + 2.5
		mem.UnderFireFrom = pos
		mem.Suppression = math.Clamp((mem.Suppression or 0) + (suppress or 0), 0, 1)
		mem.Alertness = math.max(mem.Alertness or 0, alertLevel)

		-- Don't let fire from a DIFFERENT attacker yank focus off a target
		-- the bot can already see and is actively fighting. Suppression and
		-- UnderFire still register above, so the bot still reacts to it.
		if mem.Target and mem.Target ~= attacker and IsValid(mem.Target) and hg.bots.CanSee(bot, mem.Target) then
			return
		end

		local canSeeAttacker = hg.bots.CanSee(bot, attacker)

		mem.Target = attacker
		mem.TargetPos = canSeeAttacker and GetCharacter(attacker):GetPos() or pos
		mem.TargetVel = nil
		mem.LastSeen = now -- not a real sighting, but counts as contact
		mem.SuspicionPos = nil
		mem.SuspicionStrength = nil

		hook.Run("HG_BotThreatened", bot, attacker)
	end

	--- Distance from pos to the segment src -> src + dir * len.
	local function DistanceToSegment(pos, src, dir, len)
		local t = math.Clamp((pos - src):Dot(dir), 0, len)

		return pos:Distance(src + dir * t), t
	end

	local lastGunNoise = {} -- [shooter] = CurTime()

	--- Remembers that shooter used a GUN on bot (mem.ShotBy). Kept apart
	-- from mem.Attackers, which melee hits also feed - self-preservation
	-- reads this to know the enemy is armed with a firearm.
	local function MarkShotBy(bot, shooter)
		local mem = bot.Bot and bot.Bot.Memory
		if not mem then return end

		mem.ShotBy = mem.ShotBy or {}
		mem.ShotBy[shooter] = CurTime()
	end

	--- Did this bullet (src along dir for len units, stopping at hitPos)
	-- pass or land close enough to bot to count as being shot at?
	-- A plain local function (not a per-bot closure) - this runs for every
	-- bot on every shot fired on the server.
	local function CheckWhiz(bot, shooter, src, dir, len, hitPos, radius)
		local center = GetCharacter(bot):WorldSpaceCenter()
		local lineDist, t = DistanceToSegment(center, src, dir, len)
		local impactDist = center:Distance(hitPos)

		if lineDist > radius and impactDist > radius * 1.3 then return end

		-- The bot knows the direction the shot came from well, the
		-- distance much less so - estimate the shooter position along the
		-- bullet line with some error.
		local back = src + RandomOffset2D(math.min(t * 0.1, 250))
		local miss = math.min(lineDist, impactDist)

		if hg_bot_debug:GetBool() then
			print(("[hg.bots] %s: bullet from %s passed %.0f units away - reacting as shot at"):format(bot:Nick(), tostring(shooter), miss))
		end

		-- Closer misses are scarier.
		local closeness = 1 - miss / (radius * 1.3)

		MarkShotBy(bot, shooter)

		hg.bots.ReportThreat(bot, shooter, back, hg_bot_whiz_alert:GetFloat(), hg_bot_suppression_gain:GetFloat() * (0.5 + closeness))
	end

	local function IsSuppressed(wep)
		if not IsValid(wep) then return false end
		if wep.Supressor then return true end

		if wep.HasAttachment then
			local ok, has = pcall(wep.HasAttachment, wep, "barrel", "supressor")

			if ok and has then return true end
		end

		return false
	end

	hook.Add("EntityFireBullets", "HG_Bots_GunfireWhiz", function(ent, bulletTbl)
		local shooter = ResolveShooter(ent, bulletTbl.Attacker)

		if not IsValid(shooter) then return end
		if shooter.IsHomigradBot and not hg.bots.SameFaction then return end

		local src, dir = bulletTbl.Src, bulletTbl.Dir
		if not src or not dir or dir:LengthSqr() < 0.01 then return end

		local now = CurTime()

		lastShotTime[shooter] = now

		-- Gunfire noise, throttled so automatic fire doesn't flood
		-- ReportNoise with dozens of identical events a second.
		if (lastGunNoise[shooter] or 0) < now - 0.2 then
			lastGunNoise[shooter] = now

			local wep = (ent.IsWeapon and ent:IsWeapon()) and ent or shooter:GetActiveWeapon()
			local radius = IsSuppressed(wep) and hg_bot_gunfire_radius_sup:GetFloat() or hg_bot_gunfire_radius:GetFloat()

			hg.bots.ReportNoise(src, radius, shooter, "gunfire")
		end

		dir = dir:GetNormalized()

		-- Where the bullet actually stops. One trace per shot (not per bot)
		-- so a bot behind a solid wall isn't "shot at" by a bullet that
		-- never reached it.
		local shooterFilter = { shooter, ent }
		if IsValid(shooter.FakeRagdoll) then shooterFilter[#shooterFilter + 1] = shooter.FakeRagdoll end

		local impact = util.TraceLine({
			start = src,
			endpos = src + dir * 12000,
			filter = shooterFilter,
			mask = MASK_SHOT,
		})

		local len = src:Distance(impact.HitPos)
		local radius = hg_bot_whiz_radius:GetFloat()
		local reach = radius * 1.3 + 80 -- (+80: feet to chest, and a ragdoll lying off its player)
		local reachSqr = reach * reach

		for bot in pairs(hg.bots.List) do
			if not IsValid(bot) or not bot:Alive() then continue end
			if IgnoreBotSource(shooter, bot) then continue end

			-- Nowhere near the line of the shot or where it landed: most
			-- bots, for most bullets - told apart here without the call.
			local c = bot:GetPos()
			local t = (c - src):Dot(dir)

			if t < -reach or t > len + reach or (c - (src + dir * math.Clamp(t, 0, len))):LengthSqr() > reachSqr then
				if c:DistToSqr(impact.HitPos) > reachSqr then continue end
			end

			local ok, err = pcall(CheckWhiz, bot, shooter, src, dir, len, impact.HitPos, radius)

			if not ok then
				print(("[hg.bots] ERROR in gunfire-whiz check for %s: %s"):format(tostring(bot), tostring(err)))
			end
		end
	end)

	-- Actually taking damage is stronger evidence than a whiz. Damage to a
	-- downed bot lands on its FakeRagdoll, not the player - resolve that.
	hook.Add("EntityTakeDamage", "HG_Bots_DamageAwareness", function(target, dmg)
		if not IsValid(target) then return end

		local bot = target

		if not target.IsHomigradBot then
			if not hg.RagdollOwner then return end

			bot = hg.RagdollOwner(target)

			if not IsValid(bot) or not bot.IsHomigradBot then return end
		end

		if not bot.Bot then return end

		local attacker = ResolveShooter(dmg:GetAttacker())
		local pos = dmg:GetDamagePosition()

		if not IsValid(attacker) then
			-- World/fall damage or an unowned explosion - nothing to fight,
			-- but an explosion next to you is worth a look.
			if dmg:IsExplosionDamage() and pos and pos ~= vector_origin then
				local mem = bot.Bot.Memory

				if not IsValid(mem.Target) then
					mem.SuspicionPos = pos
					mem.SuspicionStrength = 1
					mem.SuspicionTime = CurTime()
					mem.Alertness = 1
				end
			end

			return
		end

		if attacker == bot or IgnoreBotSource(attacker, bot) then return end

		-- The attacker's rough position: for bullets, the damage position
		-- is where the bot was hit, not where the shooter stands - the
		-- attacker's real position is the honest best guess for a hit you
		-- just took (you know where it came from when it hurts).
		local attackerPos = GetCharacter(attacker):GetPos()

		if dmg:IsBulletDamage() then MarkShotBy(bot, attacker) end

		hg.bots.ReportThreat(bot, attacker, attackerPos, hg_bot_damage_alert:GetFloat(), 0.5)
	end)
--//

--\\ Perception tick
	local nextScan = {} -- [bot] = next CurTime() this bot may re-scan

	--- Is ply's held weapon a firearm / melee weapon? Uses
	-- sv_bot_selfpreservation.lua's classifier when loaded (fists are not a
	-- weapon there), a plain check otherwise.
	local function WeaponKindOf(ply)
		if hg.bots.GetWeaponKind then return hg.bots.GetWeaponKind(ply, false) end

		local wep = ply:GetActiveWeapon()

		if not IsValid(wep) or wep.GetFists then return "none" end
		if wep.ismelee or wep.ismelee2 then return "melee" end

		return (wep.ishgweapon or wep:Clip1() >= 0) and "gun" or "none"
	end

	--- Is ply a danger to bot right now? Evaluated for every VISIBLE human
	-- each scan. Returns a danger score multiplier for target priority
	-- (lower = more urgent) and flags them hostile once the threat is
	-- established - the only way a human becomes a target in trust mode
	-- without having actually hurt a bot yet:
	-- - they fired a gun within hg_bot_shooter_window seconds (the source
	--   of shooting, whoever they were shooting at);
	-- - they've held a gun on this bot for hg_bot_aim_threat_time
	--   (half that aiming down sights);
	-- - they're right in front of it with a melee weapon, squared up.
	--- How far ply's eyes are from bot, and how squarely ply aims at it
	-- (1 = dead on). Off the two snapshots: nothing is asked twice.
	local function AimAt(ply, bot)
		local ps, bs = Snap(ply), Snap(bot)

		SnapEye(ps, ply)
		SnapAim(ps, ply)

		local dx, dy, dz = bs.cx - ps.ex, bs.cy - ps.ey, bs.cz - ps.ez
		local len = sqrt(dx * dx + dy * dy + dz * dz)

		if len <= 1 then return len, -1 end

		return len, (ps.ax * dx + ps.ay * dy + ps.az * dz) / len
	end

	local function AssessDanger(bot, mem, ply, info, now, dt)
		mem.AimedAt = mem.AimedAt or {}
		mem.SeenKind = mem.SeenKind or {}

		local ps = Snap(ply)
		local kind = ps.kind

		if not kind then
			kind = WeaponKindOf(ply)
			ps.kind = kind
		end

		local score = 1

		-- Drawing a weapon: empty-handed a moment ago, armed now (or first
		-- seen already armed and close). Not an attack by itself, but the
		-- bot gets wary of them - see the "wary" handling in idle
		-- (sv_bot_navigation.lua): it readies its own weapon and covers
		-- them, or backs off when it has nothing to fight with.
		local prevKind = mem.SeenKind[ply]

		mem.SeenKind[ply] = kind

		if kind ~= "none" and (prevKind == "none" or (prevKind == nil and info.dist < 700)) then
			mem.DrewAt = mem.DrewAt or {}
			mem.DrewAt[ply] = now
			mem.WaryOf = ply
			mem.WaryUntil = now + 8
			mem.Alertness = math.max(mem.Alertness or 0, 0.7)

			-- Get our own weapon out right away.
			if bot.Bot then bot.Bot.NextWeaponSwitch = 0 end
			if hg.bots.EquipBestWeapon then hg.bots.EquipBestWeapon(bot) end

			hook.Run("HG_BotSawDraw", bot, ply, kind)
		end

		local drewRecently = mem.DrewAt and (mem.DrewAt[ply] or 0) > now - 10

		-- Still armed and close or facing us: stay wary of them.
		if mem.WaryOf == ply and kind ~= "none" and now < (mem.WaryUntil or 0) then
			local lenW, dotW = AimAt(ply, bot)

			if lenW < 500 or dotW > 0.7 then
				mem.WaryUntil = now + 4
			end
		elseif mem.WaryOf == ply and kind == "none" then
			mem.WaryUntil = math.min(mem.WaryUntil or 0, now + 1.5) -- put it away: calm down soon
		end

		if drewRecently then score = score * 0.8 end

		-- The one shooting.
		if kind == "gun" and (lastShotTime[ply] or 0) > now - hg_bot_shooter_window:GetFloat() then
			hg.bots.MarkHostile(ply, bot)
			score = score * 0.6
		end

		-- Aiming at the bot.
		local aiming = false
		local dist, dot = 0, -1

		if kind ~= "none" then dist, dot = AimAt(ply, bot) end

		if dist > 1 and kind ~= "none" then
			if kind == "gun" then
				-- Within roughly a body-width of the bot at that range.
				local tol = math.max(math.deg(math.atan(26 / dist)), 2.5)

				aiming = dot >= math.cos(math.rad(tol))
			else
				aiming = dist < 140 and dot > 0.85
			end
		end

		if aiming then
			local rate = (kind == "gun" and ply:KeyDown(IN_ATTACK2)) and 2 or 1

			if kind ~= "gun" then rate = 1.6 end

			-- Just drew on us: less benefit of the doubt.
			if drewRecently then rate = rate * 1.5 end

			mem.AimedAt[ply] = (mem.AimedAt[ply] or 0) + dt * rate

			if mem.AimedAt[ply] >= hg_bot_aim_threat_time:GetFloat() then
				hg.bots.MarkHostile(ply, bot)
			end

			score = score * 0.5
		elseif mem.AimedAt[ply] then
			mem.AimedAt[ply] = math.max(mem.AimedAt[ply] - dt, 0)

			if mem.AimedAt[ply] == 0 then mem.AimedAt[ply] = nil end
		end

		-- Someone who just became (or already is) hostile this way is
		-- known - no slow detection meter against a gun in your face.
		return score
	end

	local FOVEA = math.cos(math.rad(12))

	--- How much faster than the plain rate this bot makes ply out right now:
	-- what it looks straight at is made out quickly (1.7x); at the edge of
	-- the eye it is movement that is seen - a still body at half speed, a
	-- running one at 1.5x. Whatever it is deliberately looking at
	-- (sv_bot_watch.lua's fixation) a little quicker again.
	local function AttentionGain(bot, data, ply, info)
		local g = 1

		if info.central then
			if (info.dot or 0) >= FOVEA then g = 1.7 end
		else
			local speed = SnapSpeed(Snap(ply))

			g = speed < 20 and 0.5 or speed < 140 and 1 or 1.5
		end

		if data.Watch and data.Watch.fixEnt == ply then g = g * 1.2 end

		return g
	end

	local function ScanOneBot(bot, data, now, candidates, dt)
		local mem = data.Memory

		mem.Spot = mem.Spot or {}
		mem.Attackers = mem.Attackers or {}

		local spot = mem.Spot
		local maxRange = hg_bot_sight_range:GetFloat() * 2 * (hg.bots.SightRangeMul and hg.bots.SightRangeMul(bot) or 1) -- covers every visibility bonus
		local maxRangeSqr = maxRange * maxRange
		local bs = Snap(bot)
		local bcx, bcy, bcz = bs.cx, bs.cy, bs.cz
		local sightRange = hg_bot_sight_range:GetFloat()
		local quickSqr = (sightRange * 0.5) ^ 2
		local periSpeed = hg_bot_peripheral_speed:GetFloat()
		local attention = hg_bot_sight_attention:GetBool()
		local pass = (data.ScanPass or 0) + 1

		data.ScanPass = pass

		local spotNear = hg_bot_spot_time:GetFloat()
		local spotFar = hg_bot_spot_time_far:GetFloat()
		local reacquire = hg_bot_reacquire_time:GetFloat()
		local alert = mem.Alertness or 0

		local best, bestScore, bestInfo
		local glance, glanceMeter

		for i = 1, #candidates do
			local ply = candidates[i]

			if ply == bot then continue end

			local meter = spot[ply] or 0

			local ts = Snap(ply)
			local pdx, pdy, pdz = ts.cx - bcx, ts.cy - bcy, ts.cz - bcz
			local plyDistSqr = pdx * pdx + pdy * pdy + pdz * pdz

			if plyDistSqr > maxRangeSqr then
				if meter > 0 then spot[ply] = nil end
				continue
			end

			-- Somebody the bot has not begun to notice, is not hunting and
			-- was not hurt by is looked at at two body points instead of
			-- three; and when he is far off as well, on every other pass,
			-- with the time of both passes counted when he is. Up close,
			-- half-noticed or known, nothing changes.
			local dt = dt
			local quick = meter == 0 and ply ~= mem.Target and not mem.Attackers[ply]

			if quick and plyDistSqr > quickSqr then
				if (pass + i) % 2 == 0 then continue end

				dt = dt * 2
			end

			local vis, info = hg.bots.CanSee(bot, ply, quick)

			if vis then
				-- A target the bot is actively hunting (seen, or searched for
				-- via mem.ContactHold) is recognized instantly on sight.
				local hunted = ply == mem.Target and math.max(mem.LastSeen or 0, mem.ContactHold or 0) or 0
				local lastContact = math.max(hunted, mem.Attackers[ply] or 0)

				-- Someone who hurt this bot is recognized on sight, however
				-- long ago it was (personal grudge).
				if now - lastContact < reacquire or (mem.Grudge and mem.Grudge[ply]) then
					meter = 1
				else
					local rangeFrac = math.Clamp(info.dist / sightRange, 0, 1)
					local spotTime = Lerp(rangeFrac, spotNear, spotFar)
					local rate = (spotTime <= 0) and math.huge or (1 / spotTime)

					if not info.central then rate = rate * periSpeed end

					rate = rate * (0.4 + 0.6 * info.frac) * (1 + alert) * SnapMod(ts, ply)

					if attention then rate = rate * AttentionGain(bot, data, ply, info) end

					meter = math.min(meter + rate * dt, 1)
				end

				-- Danger check: anyone visible who shoots or aims at the bot
				-- becomes a threat (trust mode too) and a priority target.
				local hostile = hg.bots.IsHostile(ply, bot)
				local danger = AssessDanger(bot, mem, ply, info, now, dt)

				-- (Asked again only of somebody who was not hostile a moment
				-- ago: the danger check is the one thing that can change it.)
				if not hostile and hg.bots.IsHostile(ply, bot) then
					hostile = true
					meter = 1
				end

				spot[ply] = meter

				if meter >= 1 and not hostile then
					-- Trust mode: noticed, watched, not attacked.
					if not glanceMeter or meter > glanceMeter then
						glance, glanceMeter = ply, meter
					end
				elseif meter >= 1 then
					-- Prefer the current target (hysteresis) and anyone who
					-- recently shot at the bot, otherwise the nearest.
					local score = info.dist

					if ply == mem.Target then score = score * 0.6 end
					if (mem.Attackers[ply] or 0) > now - 5 then score = score * 0.7 end

					-- Eliminate the source of danger first: whoever is
					-- shooting or aiming at the bot beats a closer bystander.
					score = score * danger

					-- A player is always the more interesting target than an
					-- NPC at the same distance (sv_bot_factions.lua).
					if not ply:IsPlayer() then score = score * 1.8 end

					if not bestScore or score < bestScore then
						best, bestScore, bestInfo = ply, score, info
					end
				elseif meter > 0.25 and (not glanceMeter or meter > glanceMeter) then
					glance, glanceMeter = ply, meter
				end
			elseif meter > 0 then
				meter = meter - hg_bot_spot_decay:GetFloat() * dt
				spot[ply] = meter > 0 and meter or nil
			end
		end

		if best then
			local prevTarget = mem.Target
			local char = GetCharacter(best)

			mem.Target = best
			mem.TargetPos = char:GetPos()
			mem.TargetSeenPos = mem.TargetPos
			mem.TargetVel = char:GetVelocity()
			mem.TargetVisible = true
			mem.LastSeen = now
			mem.SuspicionPos = nil
			mem.SuspicionStrength = nil
			mem.GlancePos = nil
			mem.Alertness = math.Clamp(alert + hg_bot_alert_gain:GetFloat() * dt, 0, 1)

			if prevTarget ~= best then
				hook.Run("HG_BotSpotted", bot, best)

				-- Pass the contact to nearby bots (sv_bot_squad.lua): they
				-- get the position to check, not eyes on the target.
				if hg.bots.ShareContact then hg.bots.ShareContact(bot, best, mem.TargetPos) end
			end

			return
		end

		mem.TargetVisible = false
		mem.Alertness = math.Clamp(alert - hg_bot_alert_decay:GetFloat() * dt, 0, 1)

		-- Something half-noticed: turn to look at it. Doesn't create a
		-- target - the meter still has to fill.
		if glance then
			mem.GlancePos = GetCharacter(glance):WorldSpaceCenter()
			mem.GlanceUntil = now + 1.0
			mem.Alertness = math.max(mem.Alertness, glanceMeter * 0.5)
		end

		-- Forgetting is by clock time since last contact (seen, heard, or
		-- shot at), independent of Alertness.
		if mem.Target then
			-- ContactHold is refreshed by combat's search so an active
			-- search isn't cut short by this timer - the search decides
			-- when to give up.
			local lastContact = math.max(mem.LastSeen or 0, mem.LastHeard or 0, mem.ContactHold or 0)

			if not IsValid(mem.Target) or not mem.Target:Alive() or not hg.bots.IsHostile(mem.Target, bot) or (now - lastContact) > hg_bot_target_forget_time:GetFloat() then
				mem.Target = nil
				mem.TargetPos = nil
				mem.TargetSeenPos = nil
				mem.TargetVel = nil
				mem.ContactHold = nil
			end
		end
	end

	hook.Add("Think", "HG_Bots_Perception", function()
		local now = CurTime()
		local candidates

		for bot in pairs(hg.bots.List) do
			if not IsValid(bot) or not bot:Alive() then continue end

			local data = bot.Bot
			if not data or not data.Enabled then continue end

			local mem = data.Memory

			-- Suppression decays continuously, not only on scan ticks.
			if mem.Suppression and mem.Suppression > 0 then
				mem.Suppression = math.max(mem.Suppression - hg_bot_suppression_decay:GetFloat() * FrameTime(), 0)
			end

			if (nextScan[bot] or 0) > now then continue end

			local rate = hg_bot_sight_rate:GetFloat()

			-- First scan gets a random phase so bots spawned together don't
			-- all trace on the same tick forever.
			if not nextScan[bot] then
				nextScan[bot] = now + math.Rand(0, rate)
				continue
			end

			-- Far from every player and with nobody to fight: half as often
			-- (hg_bot_lod; the meters count the longer gap, so a far bot
			-- notices just as soon, give or take one look).
			if data.Far and not mem.Target then rate = rate * 2 end

			nextScan[bot] = now + rate

			if not candidates then
				candidates = {}

				for _, ply in ipairs(player.GetHumans()) do
					if ply:Alive() then candidates[#candidates + 1] = ply end
				end

				-- Other bots of an opposing faction, and NPCs / nextbots
				-- (sv_bot_factions.lua). Both lists are empty unless those
				-- features are switched on, so nothing changes by default.
				if hg.bots.ExtraTargets then hg.bots.ExtraTargets(candidates) end
			end

			-- A bot only sees candidates it may actually fight: its own
			-- squad is filtered out here rather than inside the scan.
			local targets = hg.bots.FilterTargets and hg.bots.FilterTargets(bot, candidates) or candidates

			local ok, err = pcall(ScanOneBot, bot, data, now, targets, rate)

			if not ok then
				print(("[hg.bots] ERROR scanning %s: %s"):format(tostring(bot), tostring(err)))
			end
		end
	end)

	hook.Add("PlayerDisconnected", "HG_Bots_Perception_Cleanup", function(ply)
		nextScan[ply] = nil
		sightCache[ply] = nil
		lastShotTime[ply] = nil
		lastGunNoise[ply] = nil
		hg.bots.Hostile[ply] = nil

		for bot in pairs(hg.bots.List) do
			local data = bot.Bot

			if data then
				local mem = data.Memory

				if mem.Target == ply then mem.Target = nil end
				if mem.Spot then mem.Spot[ply] = nil end
				if mem.Attackers then mem.Attackers[ply] = nil end
				if mem.ShotBy then mem.ShotBy[ply] = nil end
				if mem.AimedAt then mem.AimedAt[ply] = nil end
				if mem.SeenKind then mem.SeenKind[ply] = nil end
				if mem.DrewAt then mem.DrewAt[ply] = nil end
				if mem.WaryOf == ply then mem.WaryOf = nil end
			end

			if sightCache[bot] then sightCache[bot][ply] = nil end
		end
	end)

	-- Dead players can't be seen; drop cached sight results for them so the
	-- next query after a respawn is fresh.
	hook.Add("PostPlayerDeath", "HG_Bots_Perception_Death", function(ply)
		if hg_bot_trust_forget_on_death:GetBool() then
			hg.bots.Hostile[ply] = nil -- optional: a new life starts trusted
		end

		for _, perBot in pairs(sightCache) do
			perBot[ply] = nil
		end

		for bot in pairs(hg.bots.List) do
			local mem = bot.Bot and bot.Bot.Memory

			if mem and mem.Spot then mem.Spot[ply] = nil end
		end
	end)

	-- lastEmitNoise is keyed by arbitrary entities; clear it periodically
	-- so removed props don't accumulate.
	timer.Create("HG_Bots_Perception_GC", 30, 0, function()
		lastEmitNoise = {}

		for bot in pairs(sightCache) do
			if not IsValid(bot) then sightCache[bot] = nil end
		end
	end)
--//
