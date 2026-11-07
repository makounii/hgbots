--[[
	Tarkov AI - Squad

	Two jobs:

	1. Bots stop hurting each other. Perception never targets another bot
	   (every candidate list is player.GetHumans() and every threat hook
	   ignores IsHomigradBot sources), so the infighting was never a
	   targeting decision - it was crossfire: a bot firing at a player
	   through the bot standing in front of it, and Z-City's damage landing
	   normally. Both halves are handled here: the shot is held while a
	   friendly is in the line, and friendly damage is cancelled outright
	   (hg_bot_friendlyfire 1 brings it back).

	2. A first pass at working together rather than several bots happening
	   to walk at the same player:
	   - contacts are shared: one bot seeing someone tells the others
	     nearby, after a short radio-ish delay. They get the POSITION, not
	     eyes on the target - they still have to go and look.
	   - roles per target: the closest bot pushes, the next one flanks, the
	     rest hold and suppress. That is what makes one bot advance while
	     another fires at the corner (see sv_bot_combat.lua's suppression).
	   - positions are spread: two bots don't walk to the same spot.

	Damage cancelling is deliberately a hard block rather than a friendly-
	fire chance: a bot that kills its own squad is never the interesting
	kind of chaos, and the player's own damage is untouched either way.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {}

local hg_bot_friendlyfire   = CreateConVar("hg_bot_friendlyfire",   "0",    {FCVAR_ARCHIVE}, "Let bots damage each other (0 = friendly fire between bots is cancelled)", 0, 1)
local hg_bot_squad          = CreateConVar("hg_bot_squad",          "1",    {FCVAR_ARCHIVE}, "Bots coordinate: shared contacts, push/flank/support roles, spread positions", 0, 1)
local hg_bot_squad_radius   = CreateConVar("hg_bot_squad_radius",   "2000", {FCVAR_ARCHIVE}, "How far a spotted contact is passed on to other bots", 100, 10000)
local hg_bot_squad_spread   = CreateConVar("hg_bot_squad_spread",   "140",  {FCVAR_ARCHIVE}, "Minimum spacing between two bots' destinations", 0, 600)
local hg_bot_squad_pushers  = CreateConVar("hg_bot_squad_pushers",  "2",    {FCVAR_ARCHIVE}, "How many bots advance on one target at once (the rest hold and suppress)", 1, 8)

--\\ Who counts as a friendly
	--- Both are our bots. Players are never friendly - shooting at them is
	-- the whole point.
	function hg.bots.IsFriendly(a, b)
		if not IsValid(a) or not IsValid(b) or a == b then return false end

		if not (a.IsHomigradBot and b.IsHomigradBot) then return false end

		-- Two bots of opposing factions are enemies, not friends
		-- (sv_bot_factions.lua) - their fire must land and they must not
		-- hold their shots for each other.
		if hg.bots.SameFaction then return hg.bots.SameFaction(a, b) end

		return true
	end

	--- The bot an entity belongs to: the bot itself, or the bot whose
	-- ragdoll this is (a downed bot takes damage on its FakeRagdoll).
	local function OwnerBot(ent)
		if not IsValid(ent) then return nil end
		if ent.IsHomigradBot then return ent end

		local ply = hg.RagdollOwner and hg.RagdollOwner(ent)

		if IsValid(ply) and ply.IsHomigradBot then return ply end

		return nil
	end

	hg.bots.OwnerBot = OwnerBot
--//

--\\ No friendly damage
	hook.Add("EntityTakeDamage", "HG_Bots_NoFriendlyFire", function(ent, dmginfo)
		if hg_bot_friendlyfire:GetBool() then return end

		local victim = OwnerBot(ent)

		if not victim then return end

		local attacker = dmginfo:GetAttacker()

		-- Explosions and the like name the weapon/entity as attacker;
		-- ResolveShooter (sv_bot_perception.lua) maps those back to a player.
		if hg.bots.ResolveShooter then
			local real = hg.bots.ResolveShooter(attacker)

			if IsValid(real) then attacker = real end
		end

		local shooter = OwnerBot(attacker)

		if shooter and shooter ~= victim and hg.bots.IsFriendly(shooter, victim) then return true end
	end)
--//

--\\ Don't shoot through each other
	local lineCache = {} -- [bot] = { t = CurTime(), aim = Vector, blocked = bool }

	--- Is one of our own in the way of this shot? Cached briefly: it runs
	-- on every trigger decision of every bot.
	function hg.bots.FriendlyInLine(bot, aimPoint)
		if not IsValid(bot) or not aimPoint then return false end

		local now = CurTime()
		local c = lineCache[bot]

		if c and now - c.t < 0.1 and c.aim:DistToSqr(aimPoint) < 400 then return c.blocked end

		local eye = hg.bots.GetEyePos and hg.bots.GetEyePos(bot) or bot:EyePos()
		local dir = aimPoint - eye
		local len = dir:Length()

		if len < 1 then return false end

		dir:Normalize()

		local blocked = false

		for other in pairs(hg.bots.List) do
			if IsValid(other) and other ~= bot and other:Alive() and hg.bots.IsFriendly(bot, other) then
				local char = IsValid(other.FakeRagdoll) and other.FakeRagdoll or other
				local to = char:WorldSpaceCenter() - eye
				local along = to:Dot(dir)

				-- Only what is actually between us and the aim point.
				if along > 24 and along < len + 40 then
					local off = (to - dir * along):Length()

					-- Wider than the body: a bullet passing this close to a
					-- friendly is close enough to hold the shot.
					if off < 34 then
						blocked = true
						break
					end
				end
			end
		end

		lineCache[bot] = { t = now, aim = Vector(aimPoint.x, aimPoint.y, aimPoint.z), blocked = blocked }

		return blocked
	end
--//

--\\ Sharing contacts
	--- bot has just seen target: pass the position to nearby bots that
	-- don't have anything better to do. They get a place to check, not a
	-- free lock on the target.
	function hg.bots.ShareContact(bot, target, pos)
		if not hg_bot_squad:GetBool() then return end
		if not IsValid(bot) or not IsValid(target) then return end

		pos = pos or target:GetPos()

		local radiusSqr = hg_bot_squad_radius:GetFloat() ^ 2
		local botPos = bot:GetPos()

		for other in pairs(hg.bots.List) do
			local data = IsValid(other) and other ~= bot and other:Alive() and other.Bot

			-- Only our own side gets the radio call; the other faction is
			-- not on this channel (sv_bot_factions.lua).
			if data and not hg.bots.IsFriendly(bot, other) then data = nil end

			if data and data.Enabled and not IsValid(other.FakeRagdoll) and botPos:DistToSqr(other:GetPos()) < radiusSqr then
				local mem = data.Memory

				-- Not somebody we may shoot (trust mode): still worth
				-- drawing and watching that direction (sv_bot_alert.lua).
				if hg.bots.IsHostile and not hg.bots.IsHostile(target, other) then
					if hg.bots.Alert then hg.bots.Alert(other, pos, "report") end
				end

				-- Busy with their own contact: leave them alone.
				if not (mem.Target and IsValid(mem.Target)) and (not hg.bots.IsHostile or hg.bots.IsHostile(target, other)) then
					local at = CurTime() + math.Rand(0.4, 1.4) -- passing it on takes a moment

					if (mem.SharedAt or 0) < CurTime() - 3 then
						mem.SharedAt = at

						timer.Simple(at - CurTime(), function()
							if not IsValid(other) or not IsValid(target) or not other.Bot then return end
							if not target:Alive() then return end
								if not hg.bots.IsFriendly(bot, other) then return end
								if hg.bots.IsHostile and not hg.bots.IsHostile(target, other) then return end

							local m = other.Bot.Memory

							if IsValid(m.Target) then return end

							m.Target = target
							m.TargetPos = pos
							m.TargetSeenPos = pos
							m.TargetVel = nil
							m.LastSeen = nil
							m.ContactHold = CurTime()
							m.Alertness = math.max(m.Alertness or 0, 0.6)

							if hg.bots.Say then hg.bots.Say(other, "roger") end

							if hg.bots.ApplyReaction then
								hg.bots.ApplyReaction(other)
							elseif other.Bot.State == "idle" then
								hg.bots.SetState(other, "combat")
							end
						end)
					end
				end
			end
		end
	end
--//

--\\ Roles and spacing
	-- [bot] = { spot = Vector, until = CurTime() } while it is firing at a
	-- place to keep someone's head down.
	hg.bots.Suppressors = hg.bots.Suppressors or {}

	function hg.bots.MarkSuppressing(bot, spot, firing)
		if not firing then
			hg.bots.Suppressors[bot] = nil
			return
		end

		hg.bots.Suppressors[bot] = { spot = spot, expires = CurTime() + 1.5 }
	end

	--- Is a teammate currently shooting at roughly the same place? That's
	-- the moment to move.
	local function CoveredByFire(bot, spot)
		if not spot then return false end

		local now = CurTime()

		for other, s in pairs(hg.bots.Suppressors) do
			if IsValid(other) and other ~= bot and hg.bots.IsFriendly(bot, other) and s.expires > now and s.spot:DistToSqr(spot) < 300 * 300 then
				return true
			end
		end

		return false
	end

	hg.bots.CoveredByFire = CoveredByFire

	--- Roles are recomputed centrally so they stay consistent: the bots
	-- closest to a shared target advance, everyone else holds the angle.
	local function AssignRoles()
		local byTarget = {}

		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and bot.Bot

			if data and data.Enabled then
				local target = data.Memory and data.Memory.Target

				if IsValid(target) then
					byTarget[target] = byTarget[target] or {}
					local group
					for _, allies in ipairs(byTarget[target]) do
						if hg.bots.IsFriendly(bot, allies[1]) then group = allies break end
					end
					if not group then
						group = {}
						table.insert(byTarget[target], group)
					end
					table.insert(group, bot)
				else
					data.SquadRole = nil
				end
			end
		end

		local pushers = hg_bot_squad_pushers:GetInt()

		for target, groups in pairs(byTarget) do
			local tPos = target:GetPos()
			for _, bots in ipairs(groups) do

				table.sort(bots, function(a, b) return a:GetPos():DistToSqr(tPos) < b:GetPos():DistToSqr(tPos) end)

				for i, bot in ipairs(bots) do
					local role

					if #bots == 1 then
						role = nil -- alone: no squad behaviour, act normally
					elseif i == 1 then
						role = "push"
					elseif i <= pushers then
						role = "flank"
					else
						role = "support"
					end

					if role and bot.Bot.SquadRole ~= role and hg.bots.Say then
						hg.bots.Say(bot, role == "support" and "spreadout" or "going")
					end

					bot.Bot.SquadRole = role
				end
			end
		end
	end

	timer.Create("HG_Bots_SquadRoles", 1, 0, function()
		if not hg_bot_squad:GetBool() then return end

		AssignRoles()
	end)

	--- Tactic forced by the squad role, or nil to let the bot decide for
	-- itself (sv_bot_selfpreservation.lua's GetTactic).
	function hg.bots.SquadTactic(bot)
		if not hg_bot_squad:GetBool() then return nil end

		local data = bot.Bot
		local role = data and data.SquadRole

		if not role then return nil end

		if role == "push" then
			-- Someone is shooting at the spot for us: go.
			local mem = data.Memory

			if CoveredByFire(bot, mem and (mem.TargetSeenPos or mem.TargetPos)) then return "push" end

			return math.random() < 0.65 and "push" or "careful"
		end

		if role == "flank" then return "careful" end

		return "wait" -- support: hold the angle and keep their head down
	end

	--- Keeps two bots from walking onto the same spot: pushes the point
	-- sideways when a teammate is already headed there.
	function hg.bots.SpreadPoint(bot, pos)
		if not hg_bot_squad:GetBool() or not pos then return pos end

		local spread = hg_bot_squad_spread:GetFloat()

		if spread <= 0 then return pos end

		local spreadSqr = spread * spread

		for other in pairs(hg.bots.List) do
			local data = IsValid(other) and other ~= bot and other.Bot

			if data and hg.bots.IsFriendly(bot, other) then
				local theirs = data.Goal or data.MoveTarget

				if theirs and theirs:DistToSqr(pos) < spreadSqr then
					local away = pos - theirs
					away.z = 0

					if away:LengthSqr() < 1 then away = Vector(math.Rand(-1, 1), math.Rand(-1, 1), 0) end

					away:Normalize()

					local moved = pos + away * spread

					if not hg.bots.IsSegmentWalkable or hg.bots.IsSegmentWalkable(pos, moved, bot) then
						return moved
					end
				end
			end
		end

		return pos
	end
--//

--\\ Keeping out of each other's way
	local hg_bot_squad_personal = CreateConVar("hg_bot_squad_personal", "90", {FCVAR_ARCHIVE}, "Personal space between bots: closer than this they drift apart while moving (0 disables)", 0, 400)

	--- A sideways push away from teammates standing too close. Used by the
	-- steering in sv_bot_navigation.lua, so it bends the route rather than
	-- replacing it: bots keep their spacing without abandoning where they
	-- were going. Wider in a fight, where a clump is one grenade.
	-- @return Vector (may be zero)
	function hg.bots.SeparationVector(bot, data)
		local space = hg_bot_squad_personal:GetFloat()

		if space <= 0 or not hg_bot_squad:GetBool() then return vector_origin end

		local pos = bot:GetPos()
		local push = Vector(0, 0, 0)
		local fighting = data and (data.State == "combat" or data.State == "alert")
		local reach = space * (fighting and 1.4 or 1)
		local reachSqr = reach * reach

		for other in pairs(hg.bots.List) do
			if IsValid(other) and other ~= bot and other:Alive() then
				local away = pos - other:GetPos()
				away.z = 0

				local d2 = away:LengthSqr()

				if d2 > 1 and d2 < reachSqr then
					local d = math.sqrt(d2)

					away:Normalize()

					-- The closer they are, the harder the push.
					push = push + away * (1 - d / reach)
				end
			end
		end

		if push:LengthSqr() < 0.0001 then return vector_origin end

		-- Never more than a firm nudge: this is spacing, not fleeing.
		if push:Length() > 1 then push:Normalize() end

		return push
	end
--//

--\\ Cleanup
	hook.Add("PlayerDisconnected", "HG_Bots_SquadCleanup", function(ply)
		hg.bots.Suppressors[ply] = nil
		lineCache[ply] = nil
	end)
--//
