--[[
	Tarkov AI - Nerve

	Whether to run from a fight is put to a reckoning of the fight, and only
	taken when running is the better bet. Without it any blow a bot took was
	"being under fire" (2.5 s of it, and a big dose of suppression), and a
	bot holding nothing but its fists runs whenever it is under fire - so the
	first punch that landed sent it off to hide, alone or not; and the
	hurt-flee roll was a 60 % (and more) coin at 30 % health whatever the
	fight looked like.

	The reckoning:
	- condition: his body against the other man's (health, blood, shock,
	  consciousness; a man on the ground counts for less)
	- the exchange: who has been landing on whom over the last seconds
	- weapons: what he holds against what the other man holds (fists against
	  fists is even; a gun across the room is not, a gun within grabbing
	  reach much less so)
	- numbers: his own side on the same man against the other man's friends
	- bullets: someone else shooting at a man with only his fists
	- mood: morale and anger (sv_bot_morale.lua), and whatever other add-ons
	  add through the HG_BotNerve hook
	The worse his condition, the less it takes to send him off: unhurt he
	stays unless the odds are plainly hopeless, half dead he goes unless the
	fight is going his way. Decisions hold for a few seconds, so a bot does
	not flip between running and fighting.

	Used by: ChooseReaction (sv_bot_selfpreservation.lua) and ShouldFlee
	(sv_bot_flee.lua) put a flee to hg.bots.NerveVerdict; the flee state asks
	hg.bots.NerveFleeCheck (a bot run down turns and fights, one whose odds
	came back goes back in); the hold state asks hg.bots.NerveHoldCheck (a
	bare-handed bot hiding comes out when its man shows up).

	For other add-ons: hook "HG_BotNerve" (bot, target) may return a mood
	shift (about -0.3 .. 0.3, added to the odds) and true as a second value
	for a bot that never runs.
]]

hg.bots = hg.bots or {}

local cv_on = CreateConVar("hg_bot_nerve", "1", {FCVAR_ARCHIVE}, "Bots weigh a fight up before running from it (instead of fleeing on the first punch, or on a fixed coin at low health)", 0, 1)
local cv_grit = CreateConVar("hg_bot_nerve_grit", "1", {FCVAR_ARCHIVE}, "How much worse the odds must get before a bot runs (0 = runs readily, 1 = rational, 2 = stubborn)", 0, 3)
local cv_debug = CreateConVar("hg_bot_nerve_debug", "0", {FCVAR_ARCHIVE}, "Print each fight-or-run reckoning", 0, 1)

local N = {}

--\\ The reckoning

local STAND_HOLD = 3.5	-- a decision to stay holds this long
local RUN_HOLD = 2	-- and one to run
local RALLY = 0.2	-- how much better than the line the odds must be to stop running
local HALF = 6	-- the exchange's memory: half of it gone after this many seconds

local function Say(bot, ...)
	if cv_debug:GetBool() then print("[nerve] " .. bot:Nick() .. ": " .. string.format(...)) end
end

-- what other add-ons say about this bot: a mood shift, and whether it never runs
local function Extra(bot, target)
	local mood, never = hook.Run("HG_BotNerve", bot, target)

	return tonumber(mood) or 0, never == true
end

--[[ the reckoning ]]--

-- 0 (finished) .. 1 (fresh)
local function Condition(ply)
	local maxHP = ply:GetMaxHealth()
	local c = maxHP > 0 and math.Clamp(ply:Health() / maxHP, 0, 1) or 1
	local org = ply.organism

	if org then
		if org.blood then c = math.min(c, math.Clamp((org.blood - 2500) / 2500, 0, 1)) end

		c = c * (1 - math.Clamp((org.shock or 0) / 60, 0, 0.6))

		if org.consciousness then c = c * math.Clamp(org.consciousness, 0.2, 1) end
	end

	return c
end

-- my weapon against his: how far it tips the fight my way
local MATCH = {
	gun = {gun = 0, melee = 0.5, none = 0.6},
	melee = {gun = -0.6, melee = 0, none = 0.3},
	none = {gun = -0.85, melee = -0.5, none = 0},
}

-- the blows between him and his man, fading
local function Exchange(bot)
	local n = bot.hgNerve
	if not n then return 0, 0 end

	local now = CurTime()
	local k = 0.5 ^ ((now - (n.t or now)) / HALF)

	n.dealt, n.taken, n.t = (n.dealt or 0) * k, (n.taken or 0) * k, now

	return n.dealt, n.taken
end

local function Odds(bot, target)
	local data = bot.Bot
	local mem = data.Memory
	local now = CurTime()
	local pos = bot:GetPos()
	local why = {}

	local mine, theirs = Condition(bot), Condition(target)
	if IsValid(target.FakeRagdoll) then theirs = theirs * 0.6 end

	local odds = (mine - theirs) * 0.8
	why[#why + 1] = ("body %.2f/%.2f"):format(mine, theirs)

	local dealt, taken = Exchange(bot)
	local ex = (dealt - taken) / (dealt + taken + 25) * 0.4
	odds = odds + ex
	why[#why + 1] = ("exchange %+.2f"):format(ex)

	local wMine = hg.bots.GetWeaponKind and hg.bots.GetWeaponKind(bot, true) or "none"
	local wTheirs = hg.bots.GetEnemyWeaponKind and hg.bots.GetEnemyWeaponKind(bot, target) or "gun"
	local w = (MATCH[wMine] or MATCH.none)[wTheirs] or 0
	local dist = pos:Distance(target:GetPos())

	-- a gun within grabbing reach is a man to jump, not to run from
	if wTheirs == "gun" and wMine ~= "gun" and dist < 130 then w = w * 0.45 end

	odds = odds + w
	why[#why + 1] = ("%s v %s %+.2f"):format(wMine, wTheirs, w)

	-- someone else shooting at a man with no gun
	if wMine ~= "gun" and mem.ShotBy then
		for shooter, t in pairs(mem.ShotBy) do
			if shooter ~= target and t > now - 3 then
				odds = odds - 0.4
				why[#why + 1] = "bullets"
				break
			end
		end
	end

	-- his side on the same man, against the man's friends
	local allies, foes = 0, 0
	local r2 = 900 * 900

	for other in pairs(hg.bots.List) do
		local od = other ~= bot and IsValid(other) and other:Alive() and other.Bot

		if od and od.Enabled and od.State ~= "flee" and not IsValid(other.FakeRagdoll)
			and od.Memory and od.Memory.Target == target and other:GetPos():DistToSqr(pos) < r2
		then
			allies = allies + 1
		end
	end

	if mem.Attackers then
		for ply, t in pairs(mem.Attackers) do
			if ply ~= target and IsValid(ply) and ply:Alive() and t > now - 10 and ply:GetPos():DistToSqr(pos) < r2 then
				foes = foes + 1
			end
		end
	end

	local num = math.Clamp((allies - foes) * 0.2, -0.5, 0.5)
	odds = odds + num
	if allies + foes > 0 then why[#why + 1] = ("%d with, %d against"):format(allies, foes) end

	-- mood: hgbots' own morale and anger, then what other add-ons add
	local mood = 0
	if hg.bots.GetMorale then mood = mood + (hg.bots.GetMorale(bot) - 0.5) * 0.3 end
	if hg.bots.GetAnger then mood = mood + hg.bots.GetAnger(bot, target) * 0.3 end
	mood = mood + Extra(bot, target)

	odds = odds + mood
	why[#why + 1] = ("mood %+.2f"):format(mood)

	-- the line: the worse he is, the less it takes to send him off
	local line = Lerp(mine, 0.15, -0.6) - (cv_grit:GetFloat() - 1) * 0.3

	return odds, line, table.concat(why, ", ")
end

-- "stand" or "run", held a while; margin > 0 asks fresh, against a raised line (rallying)
function N.Verdict(bot, margin)
	local data = bot.Bot
	local target = data and data.Memory and data.Memory.Target

	if not IsValid(target) or not target:Alive() then return nil end

	local _, never = Extra(bot, target)
	if never then return "stand" end

	local now = CurTime()

	if not margin and data.hgVerdict and now < (data.hgVerdictUntil or 0) then return data.hgVerdict end

	local odds, line, why = Odds(bot, target)
	local v = odds >= line + (margin or 0) and "stand" or "run"

	if margin and v == "run" then return v end	-- a failed rally changes nothing held

	data.hgVerdict = v
	data.hgVerdictUntil = now + (v == "stand" and STAND_HOLD or RUN_HOLD)

	Say(bot, "%s (odds %+.2f, line %+.2f: %s)", v, odds, line, why)

	return v
end

local function Stand(bot, data, secs, why)
	data.hgVerdict = "stand"
	data.hgVerdictUntil = CurTime() + secs

	Say(bot, "turns to fight: %s", why)

	hg.bots.SetState(bot, "combat")
end

--[[ who hits whom ]]--

hook.Add("EntityTakeDamage", "HG_Bots_Nerve", function(ent, dmg)
	if not cv_on:GetBool() or not hg or not hg.bots then return end

	local amount = dmg:GetDamage()
	if amount <= 0 then return end

	local attacker = dmg:GetAttacker()
	if hg.bots.ResolveShooter then attacker = hg.bots.ResolveShooter(attacker) or attacker end

	-- the man hit, bot or not (a downed one takes it on his ragdoll)
	if not IsValid(ent) then return end

	local victim = ent:IsPlayer() and ent or (hg.RagdollOwner and hg.RagdollOwner(ent))
	if not IsValid(victim) or not IsValid(attacker) or attacker == victim then return end

	local now = CurTime()

	if victim.IsHomigradBot then
		local n = victim.hgNerve or {}
		victim.hgNerve = n

		Exchange(victim)
		n.taken, n.t = (n.taken or 0) + amount, now

		local mem = victim.Bot and victim.Bot.Memory
		if mem and mem.Target == attacker then n.hitAt = now end
	end

	if attacker.IsHomigradBot then
		local mem = attacker.Bot and attacker.Bot.Memory

		if mem and mem.Target == victim then
			local n = attacker.hgNerve or {}
			attacker.hgNerve = n

			Exchange(attacker)
			n.dealt, n.t = (n.dealt or 0) + amount, now
		end
	end
end)

hook.Add("HG_BotStateChanged", "HG_Bots_Nerve", function(bot, old, new)
	local data = bot.Bot
	if data and new == "flee" then data.hgFleeSince = CurTime() end
end)

hook.Add("PlayerSpawn", "HG_Bots_Nerve", function(ply)
	ply.hgNerve = nil

	if ply.Bot then ply.Bot.hgVerdict, ply.Bot.hgVerdictUntil = nil, nil end
end)
--//

--\\ Running, hiding
-- running: turn on a man running him down, go back in when the odds come back
-- (true: it took the think over, the flee state's own is skipped)
function N.FleeBefore(bot, data)
	local H = hg.bots
	local now = CurTime()

	if now < (data.hgFleeCheck or 0) then return end

	data.hgFleeCheck = now + 0.5

	local target = data.Memory.Target

	if IsValid(target) and target:Alive() and H.CanSee(bot, target) then
		local n = bot.hgNerve
		local ran = now - (data.hgFleeSince or now)

		if ran > 1 and n and n.hitAt and now - n.hitAt < 1.5
			and bot:GetPos():DistToSqr(target:GetPos()) < 160 * 160
		then
			Stand(bot, data, 6, "run down")
			return true
		end

		if ran > 2 and N.Verdict(bot, RALLY) == "stand" then
			Stand(bot, data, STAND_HOLD + 1, "the odds came back")
			return true
		end
	end
end

-- hiding with bare fists: hgbots only gets a melee weapon out of hold when its man shows up
-- (fists are not one to it), so a bare-handed bot crouched on, watching him come
function N.HoldBefore(bot, data)
	local H = hg.bots

	if data.Path or CurTime() < (data.hgHoldCheck or 0) then return end

	data.hgHoldCheck = CurTime() + 0.5

	local target = data.Memory.Target

	if IsValid(target) and target:Alive() and H.GetWeaponKind(bot, true) == "none" and H.CanSee(bot, target)
		and bot:GetPos():DistToSqr(target:GetPos()) < 800 * 800
	then
		local want = H.PickReaction and H.PickReaction(bot) or "combat"

		if want ~= "hold" then
			Say(bot, "out of hiding: %s", want)
			H.SetState(bot, want)
			return true
		end
	end
end

--- Is the reckoning on? (for the callers in the other files)
function hg.bots.NerveOn() return cv_on:GetBool() end

hg.bots.NerveVerdict = N.Verdict

--- From the flee state's Think: true when it turned the bot round.
function hg.bots.NerveFleeCheck(bot, data)
	return cv_on:GetBool() and N.FleeBefore(bot, data) or false
end

--- From the hold state's Think: true when it brought the bot out.
function hg.bots.NerveHoldCheck(bot, data)
	return cv_on:GetBool() and N.HoldBefore(bot, data) or false
end
--//

--\\ Debug
concommand.Add("hg_bot_nerve_report", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	if not hg or not hg.bots then return end

	for bot in pairs(hg.bots.List) do
		local data = IsValid(bot) and bot.Bot
		local target = data and data.Memory and data.Memory.Target

		if IsValid(target) and target:Alive() then
			local odds, line, why = Odds(bot, target)

			print(("[nerve] %s v %s: odds %+.2f, line %+.2f (%s), state %s, held %s"):format(
				bot:Nick(), target:Nick(), odds, line, why, tostring(data.State), tostring(data.hgVerdict)))
		elseif data then
			print(("[nerve] %s: no target, state %s"):format(bot:Nick(), tostring(data.State)))
		end
	end
end)
--//
