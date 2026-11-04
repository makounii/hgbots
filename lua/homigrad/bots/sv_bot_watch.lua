--[[
	Tarkov AI - Watch

	Where a bot looks while nothing is happening yet (idle, alert). Without
	this a bot looked only where its feet went: walking, its view was the
	next waypoint; standing, wherever that last pointed - and it hardly ever
	stood, since a bot that got where it was going was handed the next place
	on the same tick. Its eyes only ever passed over its own path, so anyone
	beside or behind it went unseen until he fired.

	Now a gaze of fixations, the way a man looks about:
	- ahead, mostly, while walking; now and then the ground in front of him
	- openings: each place he stands is surveyed (16 rays round at eye
	  height, 8 tilted up); long sightlines and corners / doorways (a ray
	  running far past its neighbour) are what he looks at, a balcony or a
	  window above sometimes
	- coverage: every side remembers when he last had it in view; the longer
	  unchecked, the more it pulls - so a man standing works round to what is
	  behind him
	- glances: walking, a look to one side now and then (a locked look). He
	  stands still a while where he got to, sometimes stops on the way at a
	  corner that opened up, and gets his bearings when he spawns
	- people he knows are harmless (trust mode, his own side): looked at now
	  and then, more when close, armed or coming his way, not stared at
	- reflexes: a shape half made out (its detection meter started filling)
	  turns his head to it after a human reaction time, and so does a noise
	How often and how long follows a vigilance: 0.25 calm, up with the
	alertness, the alert state and a fight not long ago (hg_bot_watch_vigil).

	Runs from the dispatcher's hg.bots.BeforeThink / AfterThink around the
	idle and alert Thinks; it only takes the view the state left free
	(data.LookPos nil), a known harmless man's endless glance, or the alert
	state's stare at where the trouble came from. The faster detection where
	he looks is in sv_bot_perception.lua (AttentionGain reads data.Watch).
]]

hg.bots = hg.bots or {}

local hg_bot_watch        = CreateConVar("hg_bot_watch",        "1", {FCVAR_ARCHIVE}, "Bots look about them while nothing is happening (openings, corners, behind, people, noises) instead of only where they walk", 0, 1)
local hg_bot_watch_vigil  = CreateConVar("hg_bot_watch_vigil",  "1", {FCVAR_ARCHIVE}, "How watchful bots are at any awareness (0.5 = lax, 1 = normal, 2 = jumpy)", 0, 3)
local hg_bot_watch_linger = CreateConVar("hg_bot_watch_linger", "1", {FCVAR_ARCHIVE}, "How long wandering bots stand and look round where they got to (0 = never)", 0, 4)
local hg_bot_watch_debug  = CreateConVar("hg_bot_watch_debug",  "0", {FCVAR_ARCHIVE}, "1 = draw each bot's gaze (debugoverlay: listen server, developer 1), 2 = also print it", 0, 2)

-- (the names the code below was written with)
local cv_on, cv_vigil, cv_linger, cv_debug = hg_bot_watch, hg_bot_watch_vigil, hg_bot_watch_linger, hg_bot_watch_debug

local SECTORS, STEP = 16, 22.5
local SURVEY_LEN = 2000
local EYE_Z = Vector(0, 0, 48)
local FACE_Z = Vector(0, 0, 14)
local EMPTY = {}

--\\ Helpers
	local function Char(ply)
		local rag = IsValid(ply) and ply.FakeRagdoll
		return IsValid(rag) and rag or ply
	end

	local function YawTo(from, to)
		local d = to - from
		return math.deg(math.atan2(d.y, d.x))
	end

	local function Off(a, b) return math.abs(math.NormalizeAngle(a - b)) end

	local function Sector(yaw) return math.floor((yaw % 360) / STEP + 0.5) % SECTORS + 1 end

	--- The watch's own state, in the bot's brain (a new life starts afresh).
	local function W(bot)
		local data = bot.Bot
		local w = data.Watch

		if not w then
			w = { seen = {}, noticed = {}, fixUntil = 0, fresh = true }
			data.Watch = w
		end

		return w
	end

	--- 0 (calm) .. 1 (on edge)
	local function Vigil(bot, data, mode, now)
		local mem = data.Memory
		local v = 0.25 + (mem.Alertness or 0) * 0.45

		if mode == "alert" then v = v + 0.35 end
		if mem.LastSeen and now - mem.LastSeen < 90 then v = v + 0.15 end

		return math.Clamp(v * hg_bot_watch_vigil:GetFloat(), 0, 1)
	end
--//
--[[ the place he stands: openings, corners, things above ]]--

local survey = {mask = MASK_VISIBLE}
local budgetTick, budgetLeft = 0, 0

local function MaySurvey()
	local t = engine.TickCount()

	if t ~= budgetTick then budgetTick, budgetLeft = t, 2 end
	if budgetLeft <= 0 then return false end

	budgetLeft = budgetLeft - 1

	return true
end

local function Survey(bot, w, now, moveYaw)
	local eye = hg.bots.GetEyePos(bot)
	local d, near, interest, edge = {}, {}, {}, {}

	survey.start = eye
	survey.filter = bot

	for i = 1, SECTORS do
		survey.endpos = eye + Angle(0, (i - 1) * STEP, 0):Forward() * SURVEY_LEN
		d[i] = util.TraceLine(survey).Fraction * SURVEY_LEN
	end

	for i = 1, SECTORS do
		local side = math.min(d[(i - 2) % SECTORS + 1], d[i % SECTORS + 1])
		local open = math.Clamp((d[i] - 150) / 1300, 0, 1)

		-- a ray running far past a neighbour: a corner, a doorway, the mouth of a street
		edge[i] = math.Clamp((d[i] - side - 220) / 500, 0, 1)
		interest[i] = 0.15 + open * 0.55 + edge[i] * 0.9

		-- a corner is looked at where it opens; a long view somewhere down it
		near[i] = math.Clamp(edge[i] > 0 and side + 120 or d[i], 100, 900)
	end

	-- higher up: a balcony, a window, a catwalk
	local up = {}

	for j = 0, 7 do
		survey.endpos = eye + Angle(-28, j * 45, 0):Forward() * 1400

		local tr = util.TraceLine(survey)

		if tr.Hit and not tr.HitSky and tr.HitPos.z - eye.z > 100 and (tr.HitPos - eye):Length2D() > 220 then
			up[#up + 1] = {yaw = j * 45, pos = tr.HitPos - (tr.HitPos - eye):GetNormalized() * 40}
		end
	end

	-- a corner that opened up on his way: worth stopping at
	if moveYaw and w.edge then
		for i = 1, SECTORS do
			if edge[i] >= 0.6 and (w.edge[i] or 0) < 0.3 and Off((i - 1) * STEP, moveYaw) <= 75 then
				w.newEdge = now
				break
			end
		end
	end

	w.interest, w.edge, w.near, w.up = interest, edge, near, up
	w.surveyAt, w.surveyPos = now, bot:GetPos()
end

--[[ the gaze ]]--

local function Fixate(bot, w, now, kind, pos, ent, dur, speed, lock)
	w.kind, w.fix, w.fixEnt = kind, pos, ent
	w.fixUntil = now + dur
	w.speed = math.floor(speed)
	w.lockUntil = lock and w.fixUntil or nil

	local at = IsValid(ent) and Char(ent):WorldSpaceCenter() or pos
	w.sec = Sector(YawTo(bot:EyePos(), at))
end

-- stand where he is for a while (a stroll only: never an order, a check-out or a getaway)
local function Stop(bot, data, w, mode, now, dur)
	hg.bots.ClearPath(data)

	if mode == "idle" then
		data.NextWanderPick = math.max(data.NextWanderPick or 0, now + dur)
		data.IdleMovePos, data.IdleMoveTime = bot:GetPos(), now
	else
		data.NextAlertPick = math.max(data.NextAlertPick or 0, now + dur)
	end

	w.walking = false
	w.lingerUntil = now + dur
	w.fixUntil = 0
end

-- something half seen, something heard: the head goes there first
local function Reflex(bot, data, w, mem, now, v, moving)
	local hb = hg.bots
	local store = (mem.Spot or EMPTY)
	local best, bm

	for ply, m in pairs(store) do
		if m > 0.03 and m < 1 and IsValid(ply) and hb.CanSee(bot, ply) then
			if not bm or m > bm then best, bm = ply, m end
		end
	end

	for ply in pairs(w.noticed) do
		if (store[ply] or 0) <= 0 then w.noticed[ply] = nil end
	end

	if best then
		w.noticed[best] = w.noticed[best] or now

		if now - w.noticed[best] >= Lerp(v, 0.4, 0.15) then
			if w.fixEnt ~= best or now >= w.fixUntil then
				Fixate(bot, w, now, "shape", nil, best, math.Rand(0.9, 1.6), 560, moving)
			end

			return true
		end
	end

	if mem.SuspicionPos and (mem.SuspicionTime or 0) > (w.heardT or 0) then
		w.heardAt = w.heardAt or now + Lerp(v, 0.45, 0.2)

		if now >= w.heardAt then
			w.heardT, w.heardAt = mem.SuspicionTime, nil

			Fixate(bot, w, now, "sound", mem.SuspicionPos + EYE_Z, nil, math.Rand(1.2, 2.2), 520, moving)

			return true, "sound"
		end
	end

	return (w.kind == "shape" or w.kind == "sound") and now < w.fixUntil
end

local function Pick(list)
	local sum = 0
	for i = 1, #list do sum = sum + list[i].w end
	if sum <= 0 then return nil end

	local r = math.Rand(0, sum)

	for i = 1, #list do
		r = r - list[i].w
		if r <= 0 then return list[i] end
	end

	return list[#list]
end

local function Ambient(bot, data, w, mem, now, v, moveYaw)
	local hb = hg.bots
	local eye = hb.GetEyePos(bot)
	local eyeYaw = bot:EyeAngles().y
	local speed = Lerp(v, 210, 380) * math.Rand(0.85, 1.15)

	-- walking: a look to one side now and then (held past the path limit for the moment)
	if moveYaw and now >= (w.nextSide or 0) then
		w.nextSide = now + Lerp(v, math.Rand(12, 24), math.Rand(4, 9))

		if math.random() < 0.7 then
			local yaw = moveYaw + (math.random() < 0.5 and -1 or 1) * math.Rand(70, 95)

			Fixate(bot, w, now, "side", eye + Angle(math.Rand(-4, 3), yaw, 0):Forward() * 500, nil, math.Rand(0.5, 0.9), speed * 1.3, true)
			return
		end
	end

	local list = {}
	local stale = Lerp(v, 24, 9)

	local function Age(yaw)
		return math.Clamp((now - (w.seen[Sector(yaw)] or 0)) / stale, 0, 1)
	end

	if moveYaw then
		local ground = math.random() < 0.25

		list[#list + 1] = {kind = ground and "ground" or "ahead", w = Lerp(v, 2.4, 1.1), yaw = moveYaw + math.Rand(-8, 8),
			pitch = ground and math.Rand(8, 16) or math.Rand(-3, 3), dist = 700}
	end

	-- an alert man keeps coming back to where the trouble came from
	if w.watchPos then
		list[#list + 1] = {kind = "watch", w = Lerp(v, 1.6, 2.6), yaw = YawTo(eye, w.watchPos) + math.Rand(-30, 30),
			pitch = math.Rand(-4, 3), dist = math.Clamp(eye:Distance(w.watchPos), 150, 900)}
	end

	for i = 1, SECTORS do
		local yaw = (i - 1) * STEP

		if not moveYaw or Off(yaw, moveYaw) <= 58 then
			local wt = (w.interest and w.interest[i] or 0.4) * (0.12 + Age(yaw))

			-- over the shoulder: the more watchful, the more it pulls
			if not moveYaw and Off(yaw, eyeYaw) > 110 then wt = wt * Lerp(v, 0.7, 1.5) end
			if i == w.sec then wt = wt * 0.15 end

			list[#list + 1] = {kind = "look", w = wt, yaw = yaw + math.Rand(-8, 8), pitch = math.Rand(-6, 3), dist = w.near and w.near[i] or 500}
		end
	end

	for _, u in ipairs(w.up or EMPTY) do
		if not moveYaw or Off(u.yaw, moveYaw) <= 58 then
			list[#list + 1] = {kind = "up", w = 0.18 * Lerp(v, 0.6, 1.3) * (0.2 + Age(u.yaw)), pos = u.pos}
		end
	end

	-- people he knows are harmless: looked at now and then, not stared at
	local store = (mem.Spot or EMPTY)

	for ply, m in pairs(store) do
		if m >= 1 and IsValid(ply) and ply ~= w.fixEnt and ply:Alive() and not hb.IsHostile(ply, bot) and hb.CanSee(bot, ply) then
			local char = Char(ply)
			local to = char:GetPos() - bot:GetPos()
			local dist = to:Length()

			if dist < 1200 and (not moveYaw or Off(YawTo(bot:GetPos(), char:GetPos()), moveYaw) <= 58) then
				local wt = 0.7 * (dist < 250 and 3 or dist < 600 and 1.5 or 1)

				if hb.GetWeaponKind and hb.GetWeaponKind(ply, false) ~= "none" then wt = wt * 2 end
				if dist > 1 and char:GetVelocity():Dot(-to / dist) > 60 then wt = wt * 1.6 end	-- coming his way

				list[#list + 1] = {kind = "person", w = wt, ent = ply}
			end
		end
	end

	local c = Pick(list)
	if not c then return end

	local dur
	if c.kind == "ground" then
		dur = math.Rand(0.6, 1.3)
	elseif c.kind == "ahead" then
		dur = Lerp(v, math.Rand(1.6, 3.4), math.Rand(0.8, 1.6))
	elseif c.kind == "person" then
		dur = math.Rand(0.9, 2.2)
	elseif c.kind == "up" then
		dur = math.Rand(0.6, 1.2)
	else
		dur = Lerp(v, math.Rand(1.1, 2.6), math.Rand(0.5, 1.2))
	end

	local pos = c.pos or (not c.ent and eye + Angle(c.pitch, c.yaw, 0):Forward() * c.dist)

	Fixate(bot, w, now, c.kind, pos, c.ent, dur, speed, false)
end

local CHECK_Z = Vector(0, 0, 45)

-- is the state's own look one we may take over?
local function Ours(bot, data, w, mem, mode, now)
	if data.ForceLookUntil and now < data.ForceLookUntil then return false end

	-- (the alert state leaves the look where it was when it has none of its own: ours, still)
	if not data.LookPos or rawequal(data.LookPos, w.setLook) then return true end

	-- perception keeps a known harmless man in a glance for as long as he is in sight: a stare
	if mode == "idle" and mem.GlancePos and data.LookPos == mem.GlancePos then
		for ply, m in pairs((mem.Spot or EMPTY)) do
			if m >= 1 and IsValid(ply) and not hg.bots.IsHostile(ply, bot) and Char(ply):WorldSpaceCenter():DistToSqr(mem.GlancePos) < 40 * 40 then
				return true
			end
		end
	end

	-- alert, standing: it stares at where the trouble came from until it relaxes - that one
	-- becomes the side he keeps coming back to
	if mode == "alert" and data.AlertCheckPos and not data.MoveTarget
		and not (data.AlertScanUntil and now < data.AlertScanUntil)
		and data.LookPos:DistToSqr(data.AlertCheckPos + CHECK_Z) < 1
	then
		w.watchPos = data.AlertCheckPos
		return true
	end

	return false
end

local DEBUG_COL = {
	ahead = Color(120, 200, 255), ground = Color(90, 140, 200), look = Color(120, 255, 120), up = Color(200, 255, 120),
	side = Color(255, 220, 90), person = Color(255, 150, 230), watch = Color(255, 160, 60),
	shape = Color(255, 60, 60), sound = Color(255, 90, 200),
}

local function After(bot, data, mode)
	if data.State ~= mode or not bot:Alive() then return end

	local hb = hg.bots
	local now = CurTime()
	local w = W(bot)
	local mem = data.Memory

	w.walking = data.Path ~= nil
	if data.Goal then w.onWander = data.WanderPt ~= nil and data.Goal:DistToSqr(data.WanderPt) < 200 * 200 end

	local eyeYaw = bot:EyeAngles().y
	for i = 1, SECTORS do
		if Off((i - 1) * STEP, eyeYaw) <= 45 then w.seen[i] = now end
	end

	w.watchPos = nil

	if not Ours(bot, data, w, mem, mode, now) then
		if w.speed and data.AimSpeed == w.speed then data.AimSpeed = nil end

		w.fixUntil, w.lockUntil, w.setLook = 0, nil, nil
		w.kind = "state's own"

		-- (a noise heard meanwhile is the state's to look at: no turning to it once it is old)
		w.heardT, w.heardAt = math.max(w.heardT or 0, mem.SuspicionTime or 0), nil
		return
	end

	local v = Vigil(bot, data, mode, now)
	local moveYaw = data.MoveTarget and YawTo(bot:GetPos(), data.MoveTarget) or nil
	local strolling = w.onWander and w.walking and not data.Running

	if (not w.surveyAt or now - w.surveyAt > 4 or bot:GetPos():DistToSqr(w.surveyPos) > 200 * 200) and MaySurvey() then
		Survey(bot, w, now, moveYaw)
	end

	local reflex, what = Reflex(bot, data, w, mem, now, v, moveYaw ~= nil)

	if reflex then
		-- a noise off his path: he stops to listen
		if what == "sound" and strolling and moveYaw and Off(YawTo(bot:GetPos(), w.fix), moveYaw) > 55 then
			Stop(bot, data, w, mode, now, math.Rand(1.5, 2.5))
		end
	else
		local offPath = moveYaw and w.fix and not (w.lockUntil and now < w.lockUntil)
			and Off(YawTo(bot:GetPos(), IsValid(w.fixEnt) and Char(w.fixEnt):GetPos() or w.fix), moveYaw) > 60

		if now >= w.fixUntil or offPath or (w.fixEnt ~= nil and not IsValid(w.fixEnt)) then
			Ambient(bot, data, w, mem, now, v, moveYaw)

			-- now and then a stroll stops for a look round, more readily at a corner just opened up
			if strolling then
				local p = Lerp(v, 0.04, 0.1) + ((w.newEdge and now - w.newEdge < 2) and 0.3 or 0)

				if math.random() < p then
					w.newEdge = nil
					Stop(bot, data, w, mode, now, math.Rand(1.5, 3.5) * math.max(cv_linger:GetFloat(), 0.3))
				end
			end
		end
	end

	if IsValid(w.fixEnt) then w.fix = Char(w.fixEnt):WorldSpaceCenter() + FACE_Z end
	if not w.fix then return end

	data.LookPos = w.fix
	data.AimSpeed = w.speed
	w.setLook = w.fix

	-- a side glance or a reflex while walking: past the path limit (a lock holds until the next
	-- think). Never one behind him: a locked look past 105 degrees walks backwards (the
	-- movement bridge), which is for keeping a gun on a man, not for a glance.
	if w.lockUntil and now < w.lockUntil
		and not (moveYaw and Off(YawTo(bot:GetPos(), w.fix), moveYaw) > 100)
	then
		data.LookLock = true
	end

	local dbg = cv_debug:GetInt()

	if dbg > 0 then
		local eye = hb.GetEyePos(bot)

		debugoverlay.Line(eye, w.fix, 0.22, DEBUG_COL[w.kind] or color_white, true)
		debugoverlay.Text(eye + Vector(0, 0, 14), ("%s  v%.2f"):format(w.kind or "?", v), 0.22, false)

		if dbg > 1 and w.kind ~= w.lastPrinted then
			w.lastPrinted = w.kind
			print(("[watch] %s (%s): %s, vigil %.2f, %.1f s"):format(bot:Nick(), mode, tostring(w.kind), v, w.fixUntil - now))
		end
	end
end

-- before the state's own Think: arriving somewhere is a reason to stand and look
local function Before(bot, data, mode)
	local now = CurTime()
	local w = W(bot)

	if w.fresh then
		w.fresh = nil

		-- a new life: get his bearings first
		if mode == "idle" and cv_linger:GetFloat() > 0 then Stop(bot, data, w, mode, now, math.Rand(2, 4.5)) end
	end

	if not data.Path and w.walking then
		w.walking = false

		if w.onWander and cv_linger:GetFloat() > 0 then
			local v = Vigil(bot, data, mode, now)
			local t = Lerp(v, math.Rand(1.5, 5), math.Rand(2, 4))

			if math.random() < 0.3 then t = t + math.Rand(3, 9) end

			Stop(bot, data, w, mode, now, t * cv_linger:GetFloat())
		end
	end

	-- (the idle state nudges a bot that has not moved for 6 s: a linger is no such thing)
	if mode == "idle" and w.lingerUntil and now < w.lingerUntil then data.IdleMoveTime = now end
end


--\\ Into the dispatcher
	local lastErr = 0

	local function Run(fn, bot, data, name)
		local ok, err = pcall(fn, bot, data, name)

		if not ok and CurTime() > lastErr + 10 then
			lastErr = CurTime()
			print("[hg.bots] watch: " .. tostring(err))
		end
	end

	function hg.bots.BeforeThink(bot, data, name)
		if (name == "idle" or name == "alert") and hg_bot_watch:GetBool() then Run(Before, bot, data, name) end
	end

	function hg.bots.AfterThink(bot, data, name)
		if (name == "idle" or name == "alert") and hg_bot_watch:GetBool() then Run(After, bot, data, name) end
	end

	hook.Add("HG_BotStateChanged", "HG_Bots_Watch", function(bot, old, new)
		local data = bot.Bot
		local w = data and data.Watch
		if not w then return end

		if w.speed and data.AimSpeed == w.speed then data.AimSpeed = nil end

		w.fixUntil, w.lockUntil, w.fixEnt, w.setLook = 0, nil, nil, nil
	end)
--//

--\\ Debug
	-- hg_bot_watch_report - what each bot is looking at and why.
	concommand.Add("hg_bot_watch_report", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and bot.Bot

			if data then
				local w = data.Watch or {}
				local mode = (data.State == "alert") and "alert" or "idle"
				local meters = {}

				for who, m in pairs(data.Memory.Spot or EMPTY) do
					if IsValid(who) and m > 0 then meters[#meters + 1] = ("%s %.2f"):format(who:Nick(), m) end
				end

				print(("[hg.bots] %s: state %s, vigil %.2f, alertness %.2f, looking at %s, suspicion %s, meters: %s"):format(
					bot:Nick(), tostring(data.State), Vigil(bot, data, mode, CurTime()), data.Memory.Alertness or 0,
					tostring(w.kind), tostring(data.Memory.SuspicionKind or "-"), #meters > 0 and table.concat(meters, ", ") or "none"))
			end
		end
	end)
--//