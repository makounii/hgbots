--[[
	Tarkov AI - Cleanup

	Bots die a lot, and Z-City leaves the whole scene behind: the corpse
	ragdoll with its inventory, the meat chunks from SpawnMeatGore
	(prop_physics with a flesh submaterial, only auto-removed in some round
	types - lua/homigrad/headgib/init_sv.lua), the head gibs, and whatever
	the bot was carrying once the body is emptied. A long fight turns into
	a floor covered in props, and the server pays for every one of them.

	This removes only what BOTS left behind:

	- a bot's corpse, once nothing on it is worth taking or after a timeout;
	- gore spawned within a short window and radius of a bot dying;
	- weapons and items that dropped out of a bot's body and were never
	  picked up.

	Player corpses, player gore and anything a player dropped are left
	alone (hg_bot_cleanup_all 1 sweeps those too, for a server that just
	wants the floor clear).

	Three rules keep it from being annoying:
	- nothing is removed while a player stands within hg_bot_cleanup_near,
	  so bodies never vanish out from under somebody looting them;
	- a body that still has loot in it gets the full timeout, an emptied one
	  goes sooner;
	- gore fades out (model scale to 0, the way Z-City itself does it)
	  instead of blinking away.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {}

local hg_bot_cleanup         = CreateConVar("hg_bot_cleanup",         "1",   {FCVAR_ARCHIVE}, "Remove bot corpses, gore and dropped items after a while", 0, 1)
local hg_bot_cleanup_corpse  = CreateConVar("hg_bot_cleanup_corpse",  "180", {FCVAR_ARCHIVE}, "Seconds a bot's corpse stays before it is removed (0 = keep forever)", 0, 1800)
local hg_bot_cleanup_looted  = CreateConVar("hg_bot_cleanup_looted",  "45",  {FCVAR_ARCHIVE}, "Seconds an already emptied bot corpse stays", 0, 600)
local hg_bot_cleanup_gore    = CreateConVar("hg_bot_cleanup_gore",    "45",  {FCVAR_ARCHIVE}, "Seconds gore (meat chunks, gibs) from a bot stays", 0, 600)
local hg_bot_cleanup_drops   = CreateConVar("hg_bot_cleanup_drops",   "300", {FCVAR_ARCHIVE}, "Seconds an item dropped by a dying bot stays if nobody picks it up (0 = keep forever)", 0, 3600)
local hg_bot_cleanup_near    = CreateConVar("hg_bot_cleanup_near",    "350", {FCVAR_ARCHIVE}, "Nothing is removed while a player is this close to it", 0, 4000)
local hg_bot_cleanup_gore_max = CreateConVar("hg_bot_cleanup_gore_max", "150", {FCVAR_ARCHIVE}, "Hard cap on tracked gore props: over this, the oldest go early", 10, 2000)
local hg_bot_cleanup_all     = CreateConVar("hg_bot_cleanup_all",     "0",   {FCVAR_ARCHIVE}, "Also clean up gore and corpses that came from players, not only from bots", 0, 1)
local hg_bot_cleanup_debug   = CreateConVar("hg_bot_cleanup_debug",   "0",   {FCVAR_ARCHIVE}, "Print what the cleanup removes", 0, 1)

--\\ What counts as ours
	-- Bot deaths, so gore and drops that appear right after one can be
	-- attributed to it: { pos, at }.
	local deaths = {}

	local tracked = {} -- [ent] = { kind = "corpse"|"gore"|"drop", at = CurTime() }

	local function Track(ent, kind)
		if not IsValid(ent) or tracked[ent] then return end

		tracked[ent] = { kind = kind, at = CurTime() }
	end

	hg.bots.CleanupTrack = Track

	local function NoteDeath(pos)
		deaths[#deaths + 1] = { pos = pos, at = CurTime() }

		-- Only the last few seconds matter.
		for i = #deaths, 1, -1 do
			if CurTime() - deaths[i].at > 12 then table.remove(deaths, i) end
		end
	end

	--- Did a bot die near here a moment ago?
	local function FromBotDeath(pos, radius)
		local now = CurTime()

		for _, d in ipairs(deaths) do
			if now - d.at < 12 and d.pos:DistToSqr(pos) < radius * radius then return true end
		end

		return false
	end

	-- Z-City's gore: prop_physics in the debris collision group wearing the
	-- flesh submaterial (SpawnMeatGore), plus the head gib models.
	local GORE_MODELS = {
		["models/props_junk/watermelon01_chunk02a.mdl"] = true,
		["models/grub_nugget_small.mdl"] = true,
	}

	local function IsGore(ent)
		if not IsValid(ent) or ent:GetClass() ~= "prop_physics" then return false end

		local model = string.lower(ent:GetModel() or "")

		if GORE_MODELS[model] then return true end

		-- Anything wearing hg's flesh material is gore too, whatever model
		-- a future version uses.
		local sub = ent.GetSubMaterial and ent:GetSubMaterial(0)

		return isstring(sub) and string.find(sub, "flesh", 1, true) ~= nil
	end

	--- A corpse ragdoll that belongs to nobody living (the same test the
	-- looting code uses, sv_bot_loot.lua's CorpseInv).
	local function IsCorpse(ent)
		if not IsValid(ent) then return false end
		if ent:GetClass() ~= "prop_ragdoll" then return false end
		if hg.RagdollOwner and IsValid(hg.RagdollOwner(ent)) then return false end

		-- Second check, independent of hg.RagdollOwner: a ragdoll that a
		-- LIVING player (or bot) is currently lying in is not a corpse.
		-- Removing one of those would leave its owner in limbo instead of
		-- letting it get up or die.
		for _, ply in ipairs(player.GetAll()) do
			if ply:Alive() and (ply.FakeRagdoll == ent or ply.FakeRagdollOld == ent) then return false end
		end

		-- Third: Z-City hands a downed player's ragdoll the player's own
		-- organism (the "Fake" hook in organism/tier_0). A living one means
		-- somebody is in there, whatever the two checks above concluded.
		local org = ent.organism

		if istable(org) and org.alive and IsValid(org.owner) and org.owner:IsPlayer() and org.owner:Alive() then
			return false
		end

		return true
	end

	--- Is there anything left on this body?
	local function HasLoot(ent)
		local inv = ent.inventory

		if not istable(inv) then return false end

		for _, bag in pairs({ inv.Weapons, inv.Ammo, inv.Attachments }) do
			if istable(bag) and next(bag) then return true end
		end

		return istable(ent.armors) and next(ent.armors) ~= nil
	end
--//

--\\ Catching what bots leave behind
	hook.Add("PlayerDeath", "HG_Bots_CleanupDeath", function(victim)
		if not IsValid(victim) then return end

		-- IsBot too: hg.bots.Remove clears IsHomigradBot before the kick, and
		-- Z-City kills a player that leaves alive (its "hg-killniers"
		-- PlayerDisconnected hook) - a bot removed from the menu died
		-- without the flag and its body was never picked up.
		if not victim.IsHomigradBot and not victim:IsBot() and not hg_bot_cleanup_all:GetBool() then return end

		-- The body itself. Z-City's DoPlayerDeath (it runs before this)
		-- names it on the player: the ragdoll the player was lying in, or a
		-- fresh one. Looking for it around victim:GetPos() missed most of
		-- them: a bot that went down first (the usual way to die in Z-City)
		-- isn't standing where its body is, so its corpse was never
		-- tracked and never cleaned up.
		local rag = victim.RagdollDeath

		if not IsValid(rag) then rag = victim:GetNWEntity("RagdollDeath") end
		if not IsValid(rag) then rag = victim.FakeRagdoll end

		-- Positions are read ONCE, here. A bot is kicked out of the server
		-- shortly after it dies, so by the time the delayed passes below run
		-- the player entity is NULL - calling victim:GetPos() in them threw
		-- "Tried to use a NULL entity!" and killed the timer.
		local pos = victim:GetPos()

		if IsValid(rag) then
			-- Re-checked with IsCorpse at removal time like every corpse.
			Track(rag, "corpse")

			if rag:GetPos():DistToSqr(pos) > 200 * 200 then NoteDeath(rag:GetPos()) end
		end

		NoteDeath(pos)

		-- The corpse ragdoll is whichever one this player was in, and Z-City
		-- may swap it on death, so look again a moment later.
		local function catch()
			for _, ent in ipairs(ents.FindInSphere(pos, 250)) do
				if IsCorpse(ent) then Track(ent, "corpse") end
			end
		end

		catch()
		timer.Simple(0.5, catch)
		timer.Simple(2, catch)
	end)

	-- A bot removed by an admin or the director leaves its body the same way.
	hook.Add("HG_BotRemoved", "HG_Bots_CleanupRemoved", function(bot, pos)
		if pos then NoteDeath(pos) end
	end)

	-- Classes worth a second look. The hook fires for EVERYTHING the game
	-- creates (hg's physical bullets alone are hundreds a fight), so the
	-- class is filtered here, where it is already available, and only the
	-- survivors pay for a timer.
	local function MayMatter(class)
		return class == "prop_physics"
			or string.StartWith(class, "weapon_")
			or string.StartWith(class, "ent_ammo")
			or string.StartWith(class, "ent_armor")
			or string.StartWith(class, "ent_att")
	end

	hook.Add("OnEntityCreated", "HG_Bots_CleanupWatch", function(ent)
		if not hg_bot_cleanup:GetBool() then return end
		if not IsValid(ent) then return end
		if not MayMatter(ent:GetClass()) then return end

		-- Next tick: the model, material and position are not set yet.
		timer.Simple(0, function()
			if not IsValid(ent) then return end

			local all = hg_bot_cleanup_all:GetBool()

			if IsGore(ent) then
				if all or FromBotDeath(ent:GetPos(), 400) then Track(ent, "gore") end

				return
			end

			-- Items that fell out of a body: weapons, ammo boxes, armour,
			-- attachments. Only ones that appeared right where a bot died.
			local class = ent:GetClass()
			local isItem = ent:IsWeapon()
				or string.StartWith(class, "ent_ammo")
				or string.StartWith(class, "ent_armor")
				or string.StartWith(class, "ent_att")

			if isItem and (all or FromBotDeath(ent:GetPos(), 250)) then
				Track(ent, "drop")
			end
		end)
	end)
--//

--\\ The sweep
	local function PlayerNear(pos, radius)
		if radius <= 0 then return false end

		for _, ply in ipairs(player.GetHumans()) do
			if ply:Alive() and ply:GetPos():DistToSqr(pos) < radius * radius then return true end
		end

		return false
	end

	--- Fades gore out rather than blinking it away, the way Z-City's own
	-- gib removal does (SetModelScale with a transition time).
	local function FadeOut(ent, time)
		if ent.SetModelScale then ent:SetModelScale(0, time) end

		SafeRemoveEntityDelayed(ent, time)
	end

	local removedTotal = 0

	local function Sweep(force)
		local now = CurTime()
		local near = hg_bot_cleanup_near:GetFloat()
		local gore, removed = {}, 0

		for ent, info in pairs(tracked) do
			if not IsValid(ent) then
				tracked[ent] = nil
			else
				local age = now - info.at
				local limit

				if info.kind == "corpse" then
					limit = HasLoot(ent) and hg_bot_cleanup_corpse:GetFloat() or hg_bot_cleanup_looted:GetFloat()
				elseif info.kind == "gore" then
					limit = hg_bot_cleanup_gore:GetFloat()

					gore[#gore + 1] = { ent = ent, at = info.at }
				else
					limit = hg_bot_cleanup_drops:GetFloat()

					-- Somebody picked it up: it is theirs now, stop watching.
					if ent:IsWeapon() and IsValid(ent:GetOwner()) then
						tracked[ent] = nil
						limit = nil
					end
				end

				-- Re-checked at removal time: a body that turned out to be a
				-- living downed player must never be taken away.
				if info.kind == "corpse" and not IsCorpse(ent) then
					tracked[ent] = nil
					limit = nil
				end

				if limit and (limit > 0 or force) and (force or age > limit) then
					if force or not PlayerNear(ent:GetPos(), near) then
						tracked[ent] = nil
						removed = removed + 1

						if info.kind == "gore" then
							FadeOut(ent, 1)
						else
							SafeRemoveEntity(ent)
						end
					end
				end
			end
		end

		-- Too much gore on the floor whatever its age: oldest first.
		local cap = hg_bot_cleanup_gore_max:GetInt()

		if #gore > cap then
			table.sort(gore, function(a, b) return a.at < b.at end)

			for i = 1, #gore - cap do
				local ent = gore[i].ent

				if IsValid(ent) then
					tracked[ent] = nil
					removed = removed + 1

					FadeOut(ent, 0.5)
				end
			end
		end

		removedTotal = removedTotal + removed

		if removed > 0 and hg_bot_cleanup_debug:GetBool() then
			print(("[hg.bots] cleanup: removed %d (tracked %d)"):format(removed, table.Count(tracked)))
		end

		return removed
	end

	hg.bots.CleanupSweep = Sweep

	timer.Create("HG_Bots_Cleanup", 5, 0, function()
		if not hg_bot_cleanup:GetBool() then return end

		local ok, err = pcall(Sweep, false)

		if not ok then print("[hg.bots] cleanup error: " .. tostring(err)) end
	end)
--//

--\\ Commands
	concommand.Add("hg_bot_cleanup_now", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		local n = Sweep(true)

		print(("[hg.bots] cleanup: %d entities removed on demand"):format(n))
	end, nil, "Remove every tracked bot corpse, gore piece and drop right now")

	concommand.Add("hg_bot_cleanup_status", function(ply)
		local function say(line)
			print(line)

			if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, line) end
		end

		local counts = { corpse = 0, gore = 0, drop = 0 }

		for ent, info in pairs(tracked) do
			if IsValid(ent) then
				counts[info.kind] = (counts[info.kind] or 0) + 1
			else
				tracked[ent] = nil
			end
		end

		say(("[hg.bots] cleanup: %s, tracking %d corpses, %d gore, %d drops; removed %d so far"):format(
			hg_bot_cleanup:GetBool() and "on" or "off", counts.corpse, counts.gore, counts.drop, removedTotal))
		say(("  timers: corpse %ds (emptied %ds), gore %ds, drops %ds, kept while a player is within %d u"):format(
			hg_bot_cleanup_corpse:GetInt(), hg_bot_cleanup_looted:GetInt(),
			hg_bot_cleanup_gore:GetInt(), hg_bot_cleanup_drops:GetInt(), hg_bot_cleanup_near:GetInt()))
	end, nil, "What the cleanup is currently tracking")
--//
