--[[
	Tarkov AI - Core

	Foundation for an Escape From Tarkov-style bot (Scav/PMC-alike behaviour).

	Design notes:
	- Bots are real fake players (player.CreateBot), NOT NextBots. This means
	  they flow through the exact same PlayerInitialSpawn / "Player Spawn" /
	  StartCommand pipeline as humans, so hg's organism system (health, blood,
	  pain, stamina, brain, etc.) and hg's inertia/movement math apply to them
	  automatically - no need to reimplement damage or movement feel.
	- hg's own movement hook ("HG(StartCommand)" in sh_inertia.lua) reads
	  cmd:GetForwardMove()/GetSideMove() and cmd:GetViewAngles() to derive
	  travel direction; it only cares about the SIGN of forward/side move, not
	  the magnitude. So all we need to do each tick is: set view angles, and
	  set forward/side move with the correct sign. hg handles inertia, weight,
	  stamina debuffs, blood loss slowdown, etc. on top of that by itself.
	- Our command-filling hook MUST run before hg's inertia hook consumes the
	  cmd, so it's registered with HOOK_HIGH to guarantee tick order instead
	  of relying on file load order.
	- This file only sets up the scaffolding: registry, spawn/remove, the
	  movement bridge, and a state dispatcher. Concrete states (patrol,
	  perception/hearing & sight, combat, looting, fear/flee - the Tarkov-like
	  behaviours) get registered from separate files via hg.bots.RegisterState,
	  so this file shouldn't need to change again.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {} -- [bot] = true
hg.bots.States = hg.bots.States or {} -- [state name] = { Enter, Think, Leave }

local hg_bot_debug = CreateConVar("hg_bot_debug", "0", {FCVAR_ARCHIVE, FCVAR_NOTIFY}, "Print Tarkov AI bot state debug info", 0, 1)
local hg_bot_think_rate = CreateConVar("hg_bot_think_rate", "0.1", {FCVAR_ARCHIVE}, "How often (seconds) bot AI state logic ticks", 0.02, 1)
local hg_bot_spawn_refresh = CreateConVar("hg_bot_spawn_refresh", "1", {FCVAR_ARCHIVE}, "On spawn, drop the bot into a Z-City ragdoll and instantly pick it back up. That refresh pass is what makes the server apply its clothes, armour, held weapon and arm animation - without it a freshly spawned bot can stand there with nothing applied", 0, 1)
local hg_bot_move_turnspeed = CreateConVar("hg_bot_move_turnspeed", "360", {FCVAR_ARCHIVE}, "Default turn speed (deg/sec) used for facing/movement direction whenever a state doesn't set its own data.AimSpeed (e.g. combat's slower, deliberate aim). Used for plain walking/wandering/fleeing so bots turn into a new heading instead of snapping - a bot with no motion at all yet still turns at this rate toward whatever it's about to walk or look at.", 30, 5000)

--\\ Registry & lifecycle
	--- Sets up (or resets) the AI/state data on an already-spawned bot entity.
	function hg.bots.Init(bot)
		if not IsValid(bot) then return end

		bot.IsHomigradBot = true
		bot:SetNWBool("hg_bot", true) -- the client side can't see the Lua flag

		bot.Bot = {
			Enabled = true,

			State = "idle",
			NextStateThink = 0,

			HomePos = bot:GetPos(),

			-- Movement bridge reads these each tick:
			MoveTarget = nil, -- Vector or nil - where the bot is walking to
			LookPos = nil, -- Vector or nil - where the bot's view should aim
			Running = false, -- whether to hold IN_SPEED while moving
			Crouching = false, -- whether to hold IN_DUCK
			Attacking = false, -- whether to hold IN_ATTACK
			AttackingSecondary = false, -- whether to hold IN_ATTACK2
			Reloading = false, -- whether to hold IN_RELOAD
			UseKey = false, -- whether to hold IN_USE (e.g. sv_bot_downed.lua's stabilize-while-ragdolled)

			-- Short timed pulses owned by navigation's unstick logic. Kept
			-- separate from UseKey/Crouching so they can't leak into (or be
			-- cleared by) state-owned inputs.
			JumpUntil = nil, -- hold IN_JUMP until this CurTime()
			UsePulseUntil = nil, -- hold IN_USE until this CurTime() (opening doors)
			NavCrouch = false, -- current path segment is a crouch-only nav area

			-- Turn speed limit in degrees/second for LookPos aiming. nil
			-- (default) snaps instantly, which is fine for nav/investigate
			-- use - combat sets this to something human-ish so aim isn't
			-- robotic. Purely additive: nothing that doesn't set this is
			-- affected.
			AimSpeed = nil,

			-- Free-form blackboard for state modules built on top of this base
			-- (perception, target, last known enemy pos, loot queue, etc.)
			Memory = {},
		}

		hg.bots.List[bot] = true
		bot.hgBotStepCache = nil

		hg.bots.SetState(bot, "idle")

		-- The ragdoll refresh pass (see hg.bots.RefreshBot) - a tick after
		-- init so the spawn itself (position, loadout) is settled.
		timer.Simple(0.1, function() hg.bots.RefreshBot(bot) end)

		-- Warm-up: the loadout (Z-City's own spawn logic, or whatever gives
		-- the bot its gun) often lands a tick or two after spawning. Pick
		-- the best weapon once it's there instead of waiting for a fight.
		timer.Simple(0.5, function()
			if not IsValid(bot) or not bot.Bot or not bot:Alive() then return end

			bot.Bot.NextWeaponSwitch = 0

			if hg.bots.EquipBestWeapon then hg.bots.EquipBestWeapon(bot) end
		end)

		return bot.Bot
	end

	--- Spawn refresh: Fake (ragdoll) and instantly FakeUp again.
	--
	-- Z-City applies a lot of a character's visible state - clothes,
	-- armour, the weapon in the hands, the arm/TPIK animation - through the
	-- ragdoll<->player transition, so a bot that never went through one can
	-- spawn "empty": no gear on the model and arms that don't hold the gun.
	-- Going down and straight back up is the same path a player takes, so
	-- everything gets applied without reimplementing any of it.
	--
	-- data.Refreshing keeps the AI out of it: the "downed" state (and the
	-- redirect in SetState, and the dispatcher's safety net) must not treat
	-- this quarter of a second as the bot being knocked down.
	function hg.bots.RefreshBot(bot)
		if not hg_bot_spawn_refresh:GetBool() then return false end
		if not IsValid(bot) or not bot:Alive() or not bot.Bot then return false end

		-- ONCE per life. hg.FakeUp calls ply:Spawn() internally
		-- (fake/sv_tier_0.lua), which fires PlayerSpawn - so without this
		-- flag the refresh re-triggers AutoInit -> Init -> RefreshBot and
		-- the bot spends its whole life falling over and getting up.
		-- Cleared in AutoInit on a real spawn, not on ours.
		if bot.hgBotRefreshDone then return false end

		bot.hgBotRefreshDone = true
		if not hg.Fake or not hg.FakeUp then return false end
		if IsValid(bot.FakeRagdoll) then return false end

		local data = bot.Bot

		data.Refreshing = true

		hg.Fake(bot)

		if not IsValid(bot.FakeRagdoll) then
			data.Refreshing = nil
			return false
		end

		timer.Simple(0.25, function()
			if not IsValid(bot) then return end

			local d = bot.Bot

			if IsValid(bot.FakeRagdoll) then
				-- forced: skip the "Should Fake Up" checks (we put it down
				-- ourselves). instant: no 1 s stand-up animation.
				hg.FakeUp(bot, true, true)
			end

			if not d then return end

			d.Refreshing = nil

			if d.State == "downed" then hg.bots.SetState(bot, "idle") end

			d.NextWeaponSwitch = 0

			if hg.bots.EquipBestWeapon then hg.bots.EquipBestWeapon(bot) end
		end)

		return true
	end

	local hg_bot_autoinit = CreateConVar("hg_bot_autoinit", "1", {FCVAR_ARCHIVE}, "Automatically (re)initialize the AI on every fake-client bot each time it spawns, however it was created (hg_bot_spawn, the 'bot' command, round systems)", 0, 1)

	--- Forced (re)initialization on spawn. Every spawn gets a fresh brain:
	-- no memory, target or path carried over from a previous life, and a
	-- bot created by something other than hg.bots.Spawn gets the AI at all.
	local function AutoInit(ply)
		if not IsValid(ply) or not ply:IsBot() then return end

		-- Getting up from ANY ragdoll goes through hg.FakeUp, which calls
		-- ply:Spawn() with the global OverrideSpawn set (fake/sv_tier_0.lua)
		-- - standing up, not a new life. Z-City's own "!!!!!!" hooks
		-- return false for it, but hook order isn't guaranteed; when ours
		-- ran first, every bot that stood back up got its brain wiped and
		-- was thrown into the spawn refresh ragdoll again.
		if OverrideSpawn then return end

		-- This spawn is our own refresh pass standing the bot back up
		-- (hg.FakeUp -> ply:Spawn), not a new life: keep the brain it has.
		if ply.Bot and ply.Bot.Refreshing then return end

		-- Both spawn hooks can fire for the same spawn - one per tick.
		if ply.hgBotInitTick == engine.TickCount() then return end
		ply.hgBotInitTick = engine.TickCount()

		-- A new life, whether or not the AI is (re)initialized on it
		-- (sv_bot_medic.lua's Fury-13 shot listens for this).
		timer.Simple(0, function()
			if IsValid(ply) and ply:Alive() then hook.Run("HG_BotNewLife", ply) end
		end)

		if not hg_bot_autoinit:GetBool() then return end

		-- A real spawn: the next refresh pass is allowed again.
		ply.hgBotRefreshDone = nil

		-- Next tick: position/loadout from the spawn itself are settled
		-- by then (HomePos must be where the bot actually stands).
		timer.Simple(0, function()
			if not IsValid(ply) or not ply:Alive() then return end

			hg.bots.Init(ply)
		end)
	end

	hook.Add("PlayerSpawn", "HG_Bots_AutoInit", AutoInit)
	hook.Add("Player Spawn", "HG_Bots_AutoInit", AutoInit)

	--- Spawns a fake-player bot at a position/angle and wires it into the AI.
	-- @param pos Vector spawn position (optional)
	-- @param ang Angle spawn facing (optional)
	-- @param name string bot name (optional)
	-- @return Player the bot entity (may still be initializing - use the
	--         "HG_BotInitialized" hook if you need to act once it's ready)
	function hg.bots.Spawn(pos, ang, name)
		name = name or ("Scav_" .. math.random(1000, 9999))

		-- NOTE: player.CreateBot no longer exists in current GMod builds.
		-- player.CreateNextBot is (despite its name) the function that now
		-- creates a real fake-client Player - not a NextBot NPC entity -
		-- and it's the one that still works with GM:StartCommand.
		local bot = player.CreateNextBot(name)

		if not IsValid(bot) then
			-- Always printed, not only with debug on: the usual cause is a
			-- full server, and on a P2P host that is a handful of slots.
			print(("[hg.bots] Failed to create bot '%s' - player slots %d/%d. A fake player needs a free slot; host with a higher maxplayers."):format(
				name, player.GetCount(), game.MaxPlayers()))

			return nil
		end

		-- CreateBot needs a tick before the bot entity is fully usable.
		timer.Simple(0, function()
			if not IsValid(bot) then return end

			bot:Spawn() -- flows through GM:PlayerSpawn -> hg's "Player Spawn" -> organism init

			timer.Simple(0, function()
				if not IsValid(bot) then return end

				if pos then bot:SetPos(pos) end

				if ang then
					bot:SetAngles(Angle(0, ang.y or ang[2] or 0, 0))
					bot:SetEyeAngles(ang)
				end

				hg.bots.Init(bot)

				hook.Run("HG_BotInitialized", bot)
			end)
		end)

		return bot
	end

	--- Cleanly removes a bot from the world & registry.
	function hg.bots.Remove(bot)
		if not IsValid(bot) then
			hg.bots.List[bot] = nil
			return
		end

		-- Whatever it leaves behind is a bot's leftovers (sv_bot_cleanup.lua).
		-- Where the BODY is: a downed bot's player entity isn't.
		local char = IsValid(bot.FakeRagdoll) and bot.FakeRagdoll or bot

		hook.Run("HG_BotRemoved", bot, char:GetPos())

		hg.bots.List[bot] = nil
		bot.IsHomigradBot = nil
		bot:SetNWBool("hg_bot", false)

		if bot:IsBot() then
			bot:Kick("Removed by hg.bots.Remove")
		end
	end

	function hg.bots.RemoveAll()
		for bot in pairs(hg.bots.List) do
			hg.bots.Remove(bot)
		end
	end

	function hg.bots.GetAll()
		local out = {}

		for bot in pairs(hg.bots.List) do
			if IsValid(bot) then
				out[#out + 1] = bot
			end
		end

		return out
	end

	hook.Add("PlayerDisconnected", "HG_Bots_Cleanup", function(ply)
		if ply.IsHomigradBot then
			hg.bots.List[ply] = nil
		end
	end)
--//

--\\ State dispatcher
	--- Registers (or overwrites) a named AI state.
	-- @param name string unique state name, e.g. "patrol", "combat"
	-- @param tbl table { Enter = function(bot, data) end,
	--                     Think = function(bot, data) end,
	--                     Leave = function(bot, data) end }
	function hg.bots.RegisterState(name, tbl)
		-- Never let the core placeholder replace a real implementation.
		if tbl and tbl.IsPlaceholder and hg.bots.States[name] then return end

		hg.bots.States[name] = tbl
	end

	function hg.bots.SetState(bot, state)
		if not IsValid(bot) or not bot.Bot then return end

		local data = bot.Bot

		-- While ragdolled only "downed" drives the bot: it holds E (torso
		-- stabilizer + gun raise) and aims by the real barrel. Every other
		-- state shoots as if standing - which is exactly the "shoots without
		-- aiming" bug: a hit on a downed bot fired HG_BotThreatened, which
		-- switched it to combat, and every following bullet did it again.
		-- Redirect here so no caller (threat hooks, spotted hook, combat's
		-- re-evaluation, error recovery) can pull a downed bot out.
		if IsValid(bot.FakeRagdoll) and state ~= "downed" and hg.bots.States.downed and not data.Refreshing then
			if data.State == "downed" then return end

			state = "downed"
		end
		local old = hg.bots.States[data.State]
		local new = hg.bots.States[state]

		if hg_bot_debug:GetBool() then
			print("[hg.bots] " .. bot:Nick() .. ": " .. tostring(data.State) .. " -> " .. tostring(state))
		end

		if old and old.Leave then old.Leave(bot, data) end

		local oldState = data.State

		data.State = state
		data.NextStateThink = 0

		-- Fired between Leave and Enter so listeners can clear inputs they
		-- own (e.g. sv_bot_melee.lua releasing a held IN_USE from bashing)
		-- without every state needing to know about every other state's
		-- keys. Enter runs after, so a state can still assert its own keys
		-- and have them survive this.
		hook.Run("HG_BotStateChanged", bot, oldState, state)

		if new and new.Enter then new.Enter(bot, data) end
	end

	-- Minimal default state so the base is testable standalone before any
	-- behaviour modules are added on top of it. ONLY if nothing registered
	-- "idle" yet: Z-City's loader doesn't guarantee this file runs before
	-- sv_bot_navigation.lua, and unconditionally registering here used to
	-- overwrite the real wandering idle whenever core happened to load
	-- last - bots then stood still after spawning until something (being
	-- shot) pushed them into another state.
	if not hg.bots.States.idle then
		hg.bots.RegisterState("idle", {
			IsPlaceholder = true,
			Think = function(bot, data)
				data.MoveTarget = nil
				data.NextStateThink = CurTime() + 1
			end,
		})
	end

	timer.Create("HG_Bots_Think", hg_bot_think_rate:GetFloat(), 0, function()
		for bot in pairs(hg.bots.List) do
			if not IsValid(bot) or not bot:Alive() then
				hg.bots.Remove(bot)
				continue
			end

			local data = bot.Bot
			if not data or not data.Enabled then continue end

			-- Safety net: ragdolled but not in "downed" (the "Fake" hook
			-- was missed - e.g. the bot went down during its own init).
			if data.State ~= "downed" and IsValid(bot.FakeRagdoll) and hg.bots.States.downed and not data.Refreshing then
				hg.bots.SetState(bot, "downed")
			end

			local state = hg.bots.States[data.State]

			if state and state.Think and CurTime() >= (data.NextStateThink or 0) then
				local ok, err = pcall(state.Think, bot, data)

				if not ok then
					print(("[hg.bots] ERROR in '%s' state Think for %s: %s"):format(tostring(data.State), tostring(bot), tostring(err)))

					-- Don't leave the bot parked in a state that's actively
					-- erroring every tick (it'll just hit the same error
					-- again in 0.1s) - fall back to "idle", which is
					-- always registered and has no external dependencies
					-- (perception, pathing, etc.) of its own to fail on.
					hg.bots.SetState(bot, "idle")
				end
			end
		end
	end)
--//

--\\ Movement bridge
	-- Walking somewhere while staring far off to the side is the "bots move
	-- without turning" look: the body slides sideways with the head locked
	-- on something else. A state that genuinely needs the view where it put
	-- it (aiming at someone in sight, checking a corner, covering an angle)
	-- sets data.LookLock every tick it needs it - the flag is cleared at the
	-- end of every command, so a stale one can't linger. Everything else
	-- hands the view back to the direction of travel once the two are more
	-- than this far apart.
	local LOOK_OFF_PATH = 65

	-- Even a locked look gives way past this: walking somewhere while
	-- staring over your own shoulder is the crab walk, and no amount of
	-- "I am aiming at them" justifies sliding sideways backwards. A bot
	-- that wants to keep the eyes on something further round than this
	-- turns and goes instead.
	local LOOK_LOCK_MAX = 105

	--- @return boolean off path, number|nil the yaw difference
	local function LookIsOffPath(ply, lookPos, moveDir, limit)
		local to = lookPos - ply:EyePos()

		to.z = 0

		if to:LengthSqr() < 1 then return false end

		local diff = math.abs(math.NormalizeAngle(to:Angle().y - moveDir:Angle().y))

		return diff > (limit or LOOK_OFF_PATH), diff
	end

	-- Translates the bot's high-level intent (data.MoveTarget / data.LookPos)
	-- into a CUserCmd every tick, ahead of hg's own movement processing.
	hook.Add("StartCommand", "HG_Bots_BuildCommand", function(ply, cmd)
		if not ply.IsHomigradBot then return end

		local data = ply.Bot
		if not data or not data.Enabled then return end

		-- Bot CUserCmds are sticky across ticks - there's no real client
		-- resending "nothing is held" every frame the way there is for a
		-- human, so anything that ever adds a key (us, another addon's
		-- StartCommand hook, a one-frame race during spawn) stays stuck
		-- forever unless we explicitly clear it first. This is exactly what
		-- caused bots to get permanently stuck crouched.
		cmd:ClearButtons()

		-- Figure out the movement direction first (if any) so it can double
		-- as the default facing when nothing else wants control of the view.
		local moveDir

		if data.MoveTarget then
			local diff = data.MoveTarget - ply:GetPos()
			diff.z = 0

			if diff:Length() <= 16 then
				data.MoveTarget = nil
			else
				moveDir = diff:GetNormalized()
			end
		end

		local desiredAng = ply:EyeAngles()
		local now = CurTime()

		-- Defensive reaction (sv_bot_melee.lua's block/parry): overrides
		-- the view for its short window so the guard faces the attacker -
		-- Z-City only counts a block when the hit lands near the blocker's
		-- aim line.
		local defending = data.DefendUntil and now < data.DefendUntil and now >= (data.DefendStart or 0)

		-- Short forced look (turning to a door before kicking it) - wins
		-- over whatever the state wants for that moment.
		local forcedLook = not defending and data.ForceLookPos and data.ForceLookUntil and now < data.ForceLookUntil

		if defending and data.DefendLookPos then
			desiredAng = (data.DefendLookPos - ply:EyePos()):Angle()
			desiredAng.r = 0
		elseif forcedLook then
			desiredAng = (data.ForceLookPos - ply:EyePos()):Angle()
			desiredAng.r = 0
		elseif data.LookPos and not (moveDir and LookIsOffPath(ply, data.LookPos, moveDir, data.LookLock and LOOK_LOCK_MAX or nil)) then
			desiredAng = (data.LookPos - ply:EyePos()):Angle()
			desiredAng.r = 0
		elseif moveDir then
			-- No explicit look target (the common case while just wandering)
			-- - face the direction we're actually walking instead of
			-- leaving the view frozen wherever it last happened to point.
			-- Without this the bot's sight cone (perception's CanSee) never
			-- sweeps toward anything it walks past, since EyeAngles() never
			-- changes on its own for a bot the way it would for a human
			-- glancing around.
			desiredAng = moveDir:Angle()
			desiredAng.r = 0
		end

		-- Always smoothed, never an instant snap - either a state's own
		-- data.AimSpeed (combat's slower, deliberate aim rate) or the
		-- default walking turn rate below. Previously this only smoothed
		-- when a state explicitly set AimSpeed, which is combat only -
		-- every other state (plain wandering, investigating, fleeing,
		-- repathing at a new waypoint) left eyeAng snapping straight to
		-- desiredAng in a single tick, which is what made ordinary
		-- movement read as robotic: a bot would walk dead straight at a
		-- waypoint, then instantly whip its whole facing to the next
		-- one the moment it arrived. Turning into the new heading instead
		-- (and deriving fm/sm from that same still-turning eyeAng below,
		-- same as it already did) reads as a person banking into a turn
		-- rather than a marker snapping between points.
		local turnSpeed = defending and (data.DefendTurnSpeed or 900) or forcedLook and 720 or data.AimSpeed or hg_bot_move_turnspeed:GetFloat()
		local curAng = ply:EyeAngles()
		local maxDelta = turnSpeed * FrameTime()

		local eyeAng = Angle(
			math.ApproachAngle(curAng.p, desiredAng.p, maxDelta),
			math.ApproachAngle(curAng.y, desiredAng.y, maxDelta),
			0
		)

		ply:SetEyeAngles(eyeAng)
		cmd:SetViewAngles(eyeAng)

		local fm, sm = 0, 0

		-- Keep off walls / centered in narrow passages / wide of corners
		-- (sv_bot_navigation.lua). Changes only where we step, not the view.
		if moveDir and hg.bots.SteerMove then
			moveDir = hg.bots.SteerMove(ply, data, moveDir)
		end

		if moveDir then
			-- Ledge guard, checked against the direction actually being
			-- MOVED, not the direction being faced. In combat those differ
			-- constantly (strafing and flanking while tracking a target),
			-- which is why bots were walking off catwalk edges specifically
			-- during fights. Optional dependency on sv_bot_navigation.lua -
			-- without it, movement is unrestricted as before.
			if hg.bots.IsStepSafe and not hg.bots.IsStepSafe(ply, moveDir) then
				-- Drop the current waypoint so the owning state repaths
				-- next tick instead of grinding against the same edge.
				data.MoveTarget = nil
				data.Path = nil
				data.LedgeBlockedAt = CurTime()

				moveDir = nil
			end
		end

		-- Brief deliberate stop (a door swinging open in front of us).
		if moveDir and data.PauseMoveUntil and now < data.PauseMoveUntil then
			moveDir = nil
		end

		-- Look ahead for things to jump over, duck under or open, before
		-- walking into them (sv_bot_navigation.lua).
		if moveDir and hg.bots.ProbeObstacles and not IsValid(ply.FakeRagdoll) then
			hg.bots.ProbeObstacles(ply, data, moveDir)
		end

		if moveDir then
			local fwd, right = eyeAng:Forward(), eyeAng:Right()

			-- Only the sign matters to hg's inertia calc - see file header.
			fm = moveDir:Dot(fwd) * 400
			sm = moveDir:Dot(right) * 400
		end

		cmd:SetForwardMove(fm)
		cmd:SetSideMove(sm)

		-- hg's own movement code (e.g. the run-speed check in sh_inertia.lua)
		-- reads the actual button bits, not just the move magnitude - keep
		-- them consistent with what we just set instead of only setting
		-- magnitude and leaving hg unable to ever see "running".
		if fm > 0 then cmd:AddKey(IN_FORWARD)
		elseif fm < 0 then cmd:AddKey(IN_BACK) end

		if sm > 0 then cmd:AddKey(IN_MOVERIGHT)
		elseif sm < 0 then cmd:AddKey(IN_MOVELEFT) end

		if data.Running and fm > 0 and not data.SlowWalk then
			cmd:AddKey(IN_SPEED)
		end

		-- Careful movement (slow walk) and Z-City's lean: IN_ALT1 leans
		-- right, IN_ALT2 leans left (weapons/homigrad_base/sh_anim.lua).
		if data.SlowWalk then
			cmd:AddKey(IN_WALK)
		end

		if data.Lean and data.Lean > 0 then
			cmd:AddKey(IN_ALT2)
		elseif data.Lean and data.Lean < 0 then
			cmd:AddKey(IN_ALT1)
		end

		if data.Crouching or data.NavCrouch or (data.DuckUntil and now < data.DuckUntil) then
			cmd:AddKey(IN_DUCK)
		end

		if data.JumpUntil and now < data.JumpUntil then
			cmd:AddKey(IN_JUMP)
		end

		if data.UsePulseUntil and now < data.UsePulseUntil then
			cmd:AddKey(IN_USE)
		end

		if defending then
			-- Guard up: IN_ATTACK2 is the block input for melee weapons
			-- and fists. No IN_ATTACK - on a melee weapon attack while
			-- blocking turns into a different move.
			if data.DefendBlockKey then
				cmd:AddKey(IN_ATTACK2)
			end
		else
			-- A grenade in hand is only ever handled by the "grenade" state
			-- (sv_bot_grenades.lua). Any other state pressing its fire keys
			-- as if it were a gun pulls the pin - and then either throws it
			-- anywhere, or a weapon switch drops it LIVE at the bot's feet
			-- (the grenade SWEP's Holster). With the pin already out and
			-- no throw planned, put it back in (Reload -> ResetThrow).
			local wep = ply:GetActiveWeapon()
			local nadeInHand = IsValid(wep) and wep.Throw ~= nil and wep.ENT ~= nil and data.State ~= "grenade"

			if nadeInHand and data.Martyr then
				-- Cooking it on purpose (sv_bot_grenades.lua's last resort):
				-- LMB stays down whatever state is running - letting go
				-- would throw it - and RMB flicks the spoon off.
				cmd:AddKey(IN_ATTACK)

				if data.AttackingSecondary then cmd:AddKey(IN_ATTACK2) end
			elseif nadeInHand then
				if wep.ReadyToThrow and not wep.InThrowing then
					cmd:AddKey(wep.IsLowThrow and IN_ATTACK2 or IN_ATTACK) -- keep holding so it isn't thrown...
					cmd:AddKey(IN_RELOAD) -- ...while the pin goes back in
				end
			else
				-- Short forced trigger/swing pulse (breaking a window on the
				-- way, sv_bot_navigation.lua's breach) - independent of what
				-- the current state does with Attacking.
				if data.Attacking or (data.ForceAttackUntil and now < data.ForceAttackUntil) then
					cmd:AddKey(IN_ATTACK)
				end

				-- Not while smashing a window: fists refuse to punch with
				-- RMB held (weapon_hands_sh PrimaryAttack).
				if data.AttackingSecondary and not (data.Breach and data.Breach.stage == "break") then
					cmd:AddKey(IN_ATTACK2)
				end
			end
		end

		if data.Reloading then
			cmd:AddKey(IN_RELOAD)
		end

		if data.UseKey then
			cmd:AddKey(IN_USE)
		end

		-- Crawling (sv_bot_crawl.lua): in a Z-City ragdoll IN_SPEED grabs
		-- with the left hand and IN_WALK with the right (fake/sv_control.lua);
		-- with a hand welded to the floor, IN_FORWARD then drags the torso
		-- along. Driven from here so the ordinary run / slow-walk keys can
		-- never fight it for the same buttons.
		-- Crawling: the grip only becomes movement while the forward key is
		-- held, and that must not depend on the walk logic above (a ragdoll
		-- has no walk direction, and the ledge guard can cancel it).
		if data.CrawlPull then
			cmd:SetForwardMove(400)
			cmd:SetSideMove(0)
			cmd:RemoveKey(IN_BACK)
			cmd:RemoveKey(IN_MOVELEFT)
			cmd:RemoveKey(IN_MOVERIGHT)
			cmd:AddKey(IN_FORWARD)
		end

		if data.GroundChoke then
			-- Both palms on a downed enemy's head is Z-City's choke
			-- (fake/sv_control.lua) - it needs the two grab keys together.
			cmd:AddKey(IN_SPEED)
			cmd:AddKey(IN_WALK)
		elseif data.CrawlGrab == "left" then
			cmd:AddKey(IN_SPEED)
		elseif data.CrawlGrab == "right" then
			cmd:AddKey(IN_WALK)
		end

		-- Per-tick: whoever still needs the view re-asserts it next tick.
		data.LookLock = nil
	end, HOOK_HIGH)
--//

--\\ Debug / testing concommands
	local function checkAccess(ply)
		return not IsValid(ply) or ply:IsAdmin()
	end

	concommand.Add("hg_bot_spawn", function(ply, cmdname, args)
		if not checkAccess(ply) then return end

		local pos, ang

		if IsValid(ply) then
			local tr = ply:GetEyeTrace()
			pos = tr.HitPos + Vector(0, 0, 4)
			ang = ply:EyeAngles()
		else
			pos = vector_origin
			ang = angle_zero
		end

		hg.bots.Spawn(pos, ang, args and args[1])
	end)

	concommand.Add("hg_bot_removeall", function(ply)
		if not checkAccess(ply) then return end

		hg.bots.RemoveAll()
	end)

	concommand.Add("hg_bot_count", function(ply)
		if not checkAccess(ply) then return end

		local msg = "[hg.bots] Active bots: " .. #hg.bots.GetAll()

		if IsValid(ply) then
			ply:PrintMessage(HUD_PRINTCONSOLE, msg)
		else
			print(msg)
		end
	end)
--//
