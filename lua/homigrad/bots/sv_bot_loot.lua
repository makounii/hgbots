--[[
	Tarkov AI - Loot

	Entity search + pickup. Two different pickup mechanisms exist in Z-City
	and bots need to use the right one for each:

	1. World weapons: NOT auto-pickup-on-touch. sh_weaponsInv.lua's
	   PlayerCanPickupWeapon hook explicitly requires the picker-upper to be
	   holding +use while looking at the weapon (GetUseEntity()==wep and
	   KeyPressed(IN_USE)), unless ply.force_pickup is set. Bots can't easily
	   fake a single-frame KeyPressed the way perception-driven Think logic
	   works, so we use the sanctioned bypass: set force_pickup, satisfy the
	   hook ourselves, then call Player:PickupWeapon directly - the same
	   sequence sv_inventory.lua's own corpse-loot code uses internally.

	2. Simple item entities (ammo_base/armor_base/attachment_base and the
	   standalone hg_flashlight/hg_sling/hg_brassknuckles world models): each
	   just grants itself via ENT:Use(activator) server-side, no UI involved.
	   We call that directly.

	3. zbox_lootbox containers are the odd one out: ENT:Use only opens a
	   client-side UI (nets the loot table to a real client), and the actual
	   grant happens in a net.Receive handler that only a real client can
	   trigger. Bots have no client, so we skip the UI entirely and call
	   ENT:TakeItem(bot, itemID) directly - the same server function the UI
	   flow eventually calls anyway.

	This file doesn't define its own state. It hooks into "idle" (defined in
	sv_bot_navigation.lua) via the hg.bots.CheckLootReaction extension point,
	so loot-seeking sits at the right priority (below reacting to a spotted
	person, above aimless wandering) without both files fighting over who
	gets to register "idle".
]]

hg.bots = hg.bots or {}

local hg_bot_loot_radius   = CreateConVar("hg_bot_loot_radius",   "900", {FCVAR_ARCHIVE}, "How far a bot will notice lootable items", 100, 4000)
local hg_bot_pickup_range  = CreateConVar("hg_bot_pickup_range",  "56",  {FCVAR_ARCHIVE}, "Distance at which a bot attempts to pick up its loot target", 16, 128)
local hg_bot_loot_rescan   = CreateConVar("hg_bot_loot_rescan",   "4",   {FCVAR_ARCHIVE}, "Seconds between loot re-scans while a bot has nothing to pick up", 0.5, 15)
local hg_bot_loot_ammo_min = CreateConVar("hg_bot_loot_ammo_min", "60",  {FCVAR_ARCHIVE}, "Reserve rounds below which a bot goes for ammo boxes of that calibre", 0, 500)
local hg_bot_loot_crates   = CreateConVar("hg_bot_loot_crates",   "1",   {FCVAR_ARCHIVE}, "Break open Z-City loot crates (prop_physics from hg.loot_boxes). Does nothing in Sandbox, which has no such crates", 0, 1)
local hg_bot_loot_crate_range = CreateConVar("hg_bot_loot_crate_range", "700", {FCVAR_ARCHIVE}, "How far a bot will go to break open a loot crate", 100, 4000)
local hg_bot_loot_crate_time  = CreateConVar("hg_bot_loot_crate_time",  "14",  {FCVAR_ARCHIVE}, "Seconds spent on one crate before giving up on it", 2, 60)
local hg_bot_loot_crate_shoot = CreateConVar("hg_bot_loot_crate_shoot", "1",   {FCVAR_ARCHIVE}, "Allow shooting a crate open when there's nothing to hit it with (loud, and spends ammo)", 0, 1)
local hg_bot_loot_corpses    = CreateConVar("hg_bot_loot_corpses",    "1",   {FCVAR_ARCHIVE}, "Bots search bodies for weapons, ammo and medical items", 0, 1)
local hg_bot_loot_corpse_range = CreateConVar("hg_bot_loot_corpse_range", "900", {FCVAR_ARCHIVE}, "How far a bot will go to search a body", 100, 4000)
local hg_bot_loot_corpse_time  = CreateConVar("hg_bot_loot_corpse_time",  "20",  {FCVAR_ARCHIVE}, "Seconds spent on one body before moving on", 2, 90)

--\\ Classification
	-- ENT.Base chains we treat as "just call :Use(activator) to grant it".
	local SIMPLE_USE_BASES = {
		ammo_base = true,
		armor_base = true,
		attachment_base = true,
	}

	-- Standalone classes that don't share one of the bases above but still
	-- follow the same plain ENT:Use(activator) pattern.
	local SIMPLE_USE_CLASSES = {
		hg_flashlight = true,
		hg_sling = true,
		hg_brassknuckles = true,
	}

	local function classDerivesFrom(class, targetBase)
		local seen = {}

		while class and not seen[class] do
			if class == targetBase then return true end

			seen[class] = true
			class = scripted_ents.GetMember(class, "Base")
		end

		return false
	end

	-- Per-class result cache. FindNearbyLoot runs this over every entity in
	-- a 900u sphere (props, ragdolls, effects...), and walking each one's
	-- Base chain through scripted_ents.GetMember every scan, per bot, was
	-- pure waste - a class's base chain never changes at runtime.
	local simpleUseCache = {}

	local function isSimpleUseItem(ent)
		local class = ent:GetClass()
		local cached = simpleUseCache[class]

		if cached ~= nil then return cached end

		local result = SIMPLE_USE_CLASSES[class] or false

		if not result then
			for base in pairs(SIMPLE_USE_BASES) do
				if classDerivesFrom(class, base) then result = true break end
			end
		end

		simpleUseCache[class] = result

		return result
	end

	--- Whether ent is something a bot should walk over and pick up.
	function hg.bots.IsLootable(ent)
		if not IsValid(ent) then return false end

		if ent:IsWeapon() then
			-- Not held by anyone and actually sitting in the world.
			return not IsValid(ent:GetOwner())
		end

		if ent:GetClass() == "zbox_lootbox" then
			return istable(ent.Loot) and next(ent.Loot) ~= nil
		end

		return isSimpleUseItem(ent)
	end
--//

--\\ Search
	--- Nearest lootable entity to a bot within radius, or nil.
	function hg.bots.FindNearbyLoot(bot, radius, blacklist)
		local best, bestDist
		local now = CurTime()

		if blacklist then
			for ent, untilT in pairs(blacklist) do
				if not IsValid(ent) or untilT < now then blacklist[ent] = nil end
			end
		end

		for _, ent in ipairs(ents.FindInSphere(bot:GetPos(), radius)) do
			if not (blacklist and blacklist[ent]) and hg.bots.IsLootable(ent) then
				-- Best value, not nearest: what the bot is short of wins
				-- (see hg.bots.LootScore).
				local score = hg.bots.LootScore(bot, ent)

				if score and (not bestDist or score > bestDist) then
					best, bestDist = ent, score
				end
			end
		end

		return best
	end
--//

--\\ What's worth picking up
	--- Ammo names (game.GetAmmoName) the bot is short of, for guns it
	-- actually carries. An ammo box for a gun nobody has is worthless.
	local function AmmoWanted(bot)
		local want, any = {}, false

		for _, wep in ipairs(bot:GetWeapons()) do
			local id = wep.GetPrimaryAmmoType and wep:GetPrimaryAmmoType() or -1

			if id and id >= 0 then
				local name = game.GetAmmoName(id)

				if name and bot:GetAmmoCount(id) < hg_bot_loot_ammo_min:GetInt() then
					want[string.lower(name)] = true
					any = true
				end
			end
		end

		return any and want or nil
	end

	local function IsGunEnt(ent)
		if ent.ismelee or ent.ismelee2 or ent.GetFists then return false end

		return (ent.ishgweapon or (ent.GetMaxClip1 and ent:GetMaxClip1() >= 0)) and true or false
	end

	--- How much this bot wants this item right now. nil = not worth a
	-- detour. Everything is scored rather than "nearest wins", so a bot
	-- that's bleeding walks past a rifle scope to get the bandage.
	function hg.bots.LootScore(bot, ent)
		if not hg.bots.IsLootable(ent) then return nil end

		local dist = bot:GetPos():Distance(ent:GetPos())
		local base

		if ent:IsWeapon() then
			local class = ent:GetClass()

			if hg.bots.IsMedClass and hg.bots.IsMedClass(class) then
				-- Hurt and with nothing to treat it: top of the list.
				if hg.bots.HealNeed and hg.bots.HealNeed(bot) then
					base = 120
				elseif hg.bots.HasMeds and hg.bots.HasMeds(bot) then
					base = 25 -- a spare is nice, not urgent
				else
					base = 80
				end
			else
				local kind = hg.bots.GetWeaponKind and hg.bots.GetWeaponKind(bot, true) or "gun"

				if IsGunEnt(ent) then
					base = (kind == "gun") and 20 or 95 -- unarmed: a gun changes everything
				else
					base = (kind == "none") and 45 or 10
				end
			end
		elseif ent.AmmoType then
			local want = AmmoWanted(bot)

			base = (want and want[string.lower(ent.AmmoType)]) and 90 or 15
		elseif ent:GetClass() == "zbox_lootbox" then
			base = 35
		else
			base = 20 -- armour, attachments
		end

		return base - dist * 0.04
	end
--//

--\\ Z-City loot crates (not Sandbox)
	-- Z-City spawns loot in prop_physics crates whose models are listed in
	-- hg.loot_boxes (gamemodes/zcity/.../sv_lootspawn.lua). Breaking one
	-- fires the "PropBreak" hook, and the gamemode's handler spawns the
	-- contents (weapons, ent_ammo_*, ent_armor_*, ent_att_*) on the floor -
	-- which the ordinary pickup code above then collects.
	--
	-- hg.loot_boxes only exists in the Z-City gamemode, so this whole
	-- section switches itself off in Sandbox with no extra check.
	local function IsLootCrate(ent)
		if not hg_bot_loot_crates:GetBool() then return false end
		if not hg.loot_boxes then return false end
		if not IsValid(ent) or ent:GetClass() ~= "prop_physics" then return false end

		local model = ent:GetModel()

		return model ~= nil and hg.loot_boxes[string.lower(model)] ~= nil
	end

	hg.bots.IsLootCrate = IsLootCrate

	function hg.bots.FindNearbyCrate(bot, radius, blacklist)
		local best, bestDist

		for _, ent in ipairs(ents.FindInSphere(bot:GetPos(), radius)) do
			if IsLootCrate(ent) and not (blacklist and blacklist[ent]) then
				local dist = bot:GetPos():DistToSqr(ent:GetPos())

				if not bestDist or dist < bestDist then
					best, bestDist = ent, dist
				end
			end
		end

		return best
	end

	--- Smash the crate open with whatever is in hand: a melee swing, a
	-- kick, or - last - gunfire, which costs the ammo the bot is probably
	-- looking for in the first place.
	-- @return true while the bot is busy with the crate
	local function UpdateCrate(bot, data, now)
		local crate = data.CrateTarget

		if not IsValid(crate) then
			-- Broken open: whatever fell out is ordinary loot now.
			data.CrateTarget = nil
			data.NextLootScan = 0
			data.ForceAttackUntil = nil

			if hg.bots.Say then hg.bots.Say(bot, "loot_container") end

			return false
		end

		if now - (data.CrateStart or now) > hg_bot_loot_crate_time:GetFloat() then
			data.LootBlacklist = data.LootBlacklist or {}
			data.LootBlacklist[crate] = now + 120
			data.CrateTarget = nil
			data.ForceAttackUntil = nil

			return false
		end

		local center = crate:WorldSpaceCenter()
		local dist = bot:GetPos():Distance(center)

		if dist > 90 then
			if not data.Goal or data.Goal:DistToSqr(crate:GetPos()) > 64 ^ 2 then
				if not hg.bots.SetGoal(bot, crate:GetPos()) then
					data.LootBlacklist = data.LootBlacklist or {}
					data.LootBlacklist[crate] = now + 120
					data.CrateTarget = nil

					return false
				end
			end

			if hg.bots.FollowPath(bot, data) and dist > 90 then
				-- Path ended short of it: can't get to this one.
				data.LootBlacklist = data.LootBlacklist or {}
				data.LootBlacklist[crate] = now + 120
				data.CrateTarget = nil
			end

			return true
		end

		hg.bots.ClearPath(data)

		data.MoveTarget = nil
		data.Running = false
		data.PauseMoveUntil = now + 0.2
		data.ForceLookPos = center
		data.ForceLookUntil = now + 0.4

		if now < (data.CrateNextHit or 0) then return true end

		local wep = bot:GetActiveWeapon()
		local nade = IsValid(wep) and wep.Throw ~= nil and wep.ENT ~= nil
		local melee = IsValid(wep) and not nade and not wep.GetFists and hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep)

		if melee then
			data.CrateNextHit = now + 0.75
			data.ForceAttackUntil = now + 0.1

			return true
		end

		if dist <= 70 and bot.LegAttack and (not hg.bots.CanKick or hg.bots.CanKick(bot)) then
			data.CrateNextHit = now + 1.5

			timer.Simple(0.2, function()
				if IsValid(bot) and bot:Alive() and not IsValid(bot.FakeRagdoll) and bot.Bot and bot.Bot.CrateTarget == crate then
					bot:LegAttack()
				end
			end)

			return true
		end

		-- Gunfire last: it spends the ammo this is a search for, and it is
		-- heard across the map.
		if not nade and hg_bot_loot_crate_shoot:GetBool() and hg.bots.GetWeaponKind and hg.bots.GetWeaponKind(bot, true) == "gun" then
			data.CrateNextHit = now + 0.35
			data.ForceAttackUntil = now + 0.1

			return true
		end

		data.CrateNextHit = now + 0.5

		return true
	end
--//

--\\ Corpses
	-- When a player dies, Z-City moves their whole inventory onto the death
	-- ragdoll (hg.TransferItems in homigrad/sv_inventory.lua):
	--   ent.inventory = { Weapons = { [class] = info }, Ammo = { [ammoID] = amount },
	--                     Attachments = {...} },  ent.armors = { [slot] = armor }
	-- A player takes things out of that through a UI that nets
	-- "ply_take_item" back to the server, which bots have no way to send -
	-- so the same grants are done here directly, item by item, with the
	-- same half-second pacing the net handler enforces.
	--
	-- A ragdoll that still BELONGS to a living player (hg.RagdollOwner) is
	-- someone lying down, not a corpse: left alone.
	local function CorpseInv(ent)
		if not IsValid(ent) or ent:IsPlayer() then return nil end
		if not istable(ent.inventory) then return nil end
		if hg.RagdollOwner and IsValid(hg.RagdollOwner(ent)) then return nil end

		return ent.inventory
	end

	hg.bots.CorpseInv = CorpseInv

	--- Everything on this body that this bot actually has a use for, best
	-- first. Same reasoning as LootScore: meds when hurt, ammo for guns we
	-- carry, a gun when we have none.
	function hg.bots.CorpseWants(bot, ent)
		local inv = CorpseInv(ent)

		if not inv then return nil end

		local wants = {}
		local kind = hg.bots.GetWeaponKind and hg.bots.GetWeaponKind(bot, true) or "gun"
		local ammoWant = AmmoWanted(bot)

		for class, info in pairs(inv.Weapons or {}) do
			local score

			if hg.bots.IsMedClass and hg.bots.IsMedClass(class) then
				if hg.bots.HealNeed and hg.bots.HealNeed(bot) then
					score = 120
				elseif hg.bots.HasMeds and hg.bots.HasMeds(bot) then
					score = 30
				else
					score = 85
				end
			else
				local swep = weapons.Get(class)

				if swep then
					local isGun = swep.ishgweapon or (not swep.ismelee and not swep.ismelee2)

					if isGun then
						score = (kind == "gun") and 15 or 95
					else
						score = (kind == "none") and 45 or 10
					end
				end
			end

			if score and score > 20 then
				wants[#wants + 1] = { kind = "weapon", key = class, info = info, score = score }
			end
		end

		for id, amount in pairs(inv.Ammo or {}) do
			local name = game.GetAmmoName(tonumber(id) or -1)

			if name and amount and amount > 0 and ammoWant and ammoWant[string.lower(name)] then
				wants[#wants + 1] = { kind = "ammo", key = tonumber(id), amount = amount, score = 90 }
			end
		end

		if #wants == 0 then return nil end

		table.sort(wants, function(a, b) return a.score > b.score end)

		return wants
	end

	--- Takes one thing off the body. Mirrors homigrad/sv_inventory.lua's own
	-- transfer functions rather than inventing a shortcut.
	function hg.bots.TakeFromCorpse(bot, ent, want)
		local inv = CorpseInv(ent)

		if not inv or not want then return false end

		if want.kind == "ammo" then
			local name = game.GetAmmoName(want.key)

			if not name then return false end

			bot:GiveAmmo(want.amount, name, true)

			inv.Ammo[want.key] = nil
			ent:SetNetVar("Inventory", inv)

			return true
		end

		if want.kind == "weapon" then
			if not inv.Weapons or inv.Weapons[want.key] == nil then return false end

			local held = inv.Weapons[want.key]
			local weapon

			-- The inventory entry is either a stored entity or just info.
			if not isbool(held) and IsValid(held) and held:IsWeapon() then
				weapon = held
				weapon:SetParent(NULL)
				weapon:SetNoDraw(false)
				weapon:DrawShadow(true)
				weapon:RemoveSolidFlags(FSOLID_NOT_SOLID)
			else
				weapon = ents.Create(want.key)

				if not IsValid(weapon) then return false end

				weapon.IsSpawned = true
				weapon.init = true
				weapon:Spawn()

				if weapon.SetInfo and istable(held) then weapon:SetInfo(held) end
			end

			weapon:SetPos(ent:GetPos())
			weapon:SetAngles(ent:GetAngles())

			inv.Weapons[want.key] = nil
			ent:SetNetVar("Inventory", inv)

			weapon.IsSpawned = false
			weapon.init = false

			return hg.bots.TryPickup(bot, weapon)
		end

		return false
	end

	function hg.bots.FindNearbyCorpse(bot, radius, blacklist)
		local best, bestScore

		for _, ent in ipairs(ents.FindInSphere(bot:GetPos(), radius)) do
			if not (blacklist and blacklist[ent]) and CorpseInv(ent) then
				local wants = hg.bots.CorpseWants(bot, ent)

				if wants then
					local score = wants[1].score - bot:GetPos():Distance(ent:GetPos()) * 0.04

					if not bestScore or score > bestScore then
						best, bestScore = ent, score
					end
				end
			end
		end

		return best
	end

	--- Walk to the body, then strip what's useful off it one item at a time.
	-- @return true while the bot is busy with the body
	local function UpdateCorpse(bot, data, now)
		local corpse = data.CorpseTarget

		if not IsValid(corpse) then
			data.CorpseTarget = nil

			return false
		end

		local wants = hg.bots.CorpseWants(bot, corpse)

		if not wants or now - (data.CorpseStart or now) > hg_bot_loot_corpse_time:GetFloat() then
			data.LootBlacklist = data.LootBlacklist or {}
			data.LootBlacklist[corpse] = now + 60
			data.CorpseTarget = nil

			return false
		end

		local dist = bot:GetPos():Distance(corpse:GetPos())

		if dist > 100 then
			if not data.Goal or data.Goal:DistToSqr(corpse:GetPos()) > 64 ^ 2 then
				if not hg.bots.SetGoal(bot, corpse:GetPos()) then
					data.LootBlacklist = data.LootBlacklist or {}
					data.LootBlacklist[corpse] = now + 120
					data.CorpseTarget = nil

					return false
				end
			end

			if hg.bots.FollowPath(bot, data) and dist > 100 then
				data.LootBlacklist = data.LootBlacklist or {}
				data.LootBlacklist[corpse] = now + 120
				data.CorpseTarget = nil
			end

			return true
		end

		-- Crouched over the body, taking one thing at a time (the real UI
		-- flow is rate-limited to one item per half second too).
		hg.bots.ClearPath(data)

		data.MoveTarget = nil
		data.Running = false
		data.Crouching = true
		data.LookPos = corpse:WorldSpaceCenter()
		data.LookLock = true

		if now >= (data.CorpseNextTake or 0) then
			data.CorpseNextTake = now + 0.6

			if hg.bots.Say then hg.bots.Say(bot, "loot_body") end

			if not hg.bots.TakeFromCorpse(bot, corpse, wants[1]) then
				-- Couldn't take that one: don't keep retrying it forever.
				data.LootBlacklist = data.LootBlacklist or {}
				data.LootBlacklist[corpse] = now + 30
				data.CorpseTarget = nil
				data.Crouching = false
			end
		end

		return true
	end
--//

--\\ Pickup
	--- Attempts to pick up ent, dispatching to the right mechanism for its
	-- type. Returns true if it was granted (or an attempt was made and the
	-- entity handled its own removal, e.g. ammo boxes remove themselves).
	function hg.bots.TryPickup(bot, ent)
		if not IsValid(bot) or not IsValid(ent) then return false end

		local data = bot.Bot

		if data then data.LootedSomething = true end

		if ent:IsWeapon() then
			bot.force_pickup = true
			local allowed = hook.Run("PlayerCanPickupWeapon", bot, ent)
			bot.force_pickup = nil

			if allowed == false then return false end

			bot:PickupWeapon(ent)

			return true
		end

		if ent:GetClass() == "zbox_lootbox" then
			local itemID = next(ent.Loot or {})

			if not itemID then return false end

			ent:TakeItem(bot, itemID)

			return true
		end

		if isSimpleUseItem(ent) then
			ent:Use(bot)

			return true
		end

		return false
	end
--//

--\\ "idle" extension point (see sv_bot_navigation.lua)
	function hg.bots.CheckLootReaction(bot, data)
		if data.CorpseTarget and UpdateCorpse(bot, data, CurTime()) then return true end

		if data.CrateTarget and UpdateCrate(bot, data, CurTime()) then return true end

		if IsValid(data.LootTarget) and hg.bots.IsLootable(data.LootTarget) then
			if bot:GetPos():DistToSqr(data.LootTarget:GetPos()) <= hg_bot_pickup_range:GetFloat() ^ 2 then
				hg.bots.TryPickup(bot, data.LootTarget)

				data.LootTarget = nil
				data.Path = nil
				data.Goal = nil
			elseif hg.bots.FollowPath(bot, data) then
				-- Path finished (or failed) without getting in pickup
				-- range - the item is unreachable (on a shelf, behind a
				-- fence). Blacklist it for a while instead of retrying
				-- every tick forever and never wandering again.
				data.LootBlacklist = data.LootBlacklist or {}
				data.LootBlacklist[data.LootTarget] = CurTime() + 60
				data.LootTarget = nil

				return false
			end

			return true
		end

		data.LootTarget = nil

		if CurTime() < (data.NextLootScan or 0) then
			return false
		end

		data.NextLootScan = CurTime() + hg_bot_loot_rescan:GetFloat()

		local found = hg.bots.FindNearbyLoot(bot, hg_bot_loot_radius:GetFloat(), data.LootBlacklist)

		if not found and hg.bots.Say and data.LootedSomething then
			data.LootedSomething = nil

			hg.bots.Say(bot, "loot_nothing")
		end

		if not found then
			-- Nothing lying around: a body first (they carry whole kits),
			-- then a crate to break open.
			if hg_bot_loot_corpses:GetBool() then
				local corpse = hg.bots.FindNearbyCorpse(bot, hg_bot_loot_corpse_range:GetFloat(), data.LootBlacklist)

				if corpse then
					data.CorpseTarget = corpse
					data.CorpseStart = CurTime()
					data.CorpseNextTake = 0

					return true
				end
			end

			local crate = hg.bots.FindNearbyCrate(bot, hg_bot_loot_crate_range:GetFloat(), data.LootBlacklist)

			if crate then
				data.CrateTarget = crate
				data.CrateStart = CurTime()
				data.CrateNextHit = 0

				return true
			end

			return false
		end

		if not hg.bots.SetGoal(bot, found:GetPos()) then
			data.LootBlacklist = data.LootBlacklist or {}
			data.LootBlacklist[found] = CurTime() + 60

			return false
		end

		data.LootTarget = found

		return true
	end
--//
