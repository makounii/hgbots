--[[
	Tarkov AI - Loadouts

	Two ways to kit a bot out, both driven from the menu:

	- RANDOM: a kit rolled from what the server actually has, but not
	  nonsense - a tier is picked first (a scav with a pistol, a decent
	  fighter, a kitted raider) and the gun, its ammo, armour, medical kit
	  and grenades are chosen to match. Ammo always fits the gun in hand,
	  which is the part a purely random pick gets wrong.
	- SAVED: the player gears up the way they want, saves that as a named
	  preset, and spawns bots with it afterwards. What is saved is exactly
	  what the player is carrying - weapons (with their attachments through
	  SWEP:GetInfo), ammo, and armour.

	Everything goes through Z-City's own API: Player:Give for weapons,
	GiveAmmo for rounds, hg.AddArmor for armour (it works out the placement
	and refuses what can't go together), so a bot ends up equipped exactly
	as a player would be.

	Presets live in data/hg_bots_loadouts.json, the items switched off for
	random kits in data/hg_bots_kit_blacklist.json.
]]

hg.bots = hg.bots or {}

local hg_bot_kit_random = CreateConVar("hg_bot_kit_random", "0", {FCVAR_ARCHIVE}, "Give every newly spawned bot a random kit, even when it wasn't spawned from the menu", 0, 1)
local hg_bot_kit_strip  = CreateConVar("hg_bot_kit_strip",  "1", {FCVAR_ARCHIVE}, "Take away whatever a bot spawned with before handing it its kit", 0, 1)
local hg_bot_kit_adminonly = CreateConVar("hg_bot_kit_adminonly", "1", {FCVAR_ARCHIVE}, "Random kits (and the director) may hand out admin-only weapons (RPGs, AGS, PTRD...)", 0, 1)

local KIT_FILE = "hg_bots_loadouts.json"
local BLACKLIST_FILE = "hg_bots_kit_blacklist.json"

--\\ Items bots never get
	--[[
		Z-City's joke/experimental stims - Pluviska, Fury-13 and the 'Uber'
		Fury-16 - are never on a bot, whatever put them there: random kits,
		the director, saved presets, the kit builder, looting, round systems.
		Matched by class AND by display name, so a renamed copy (a _tpik
		variant, a fork's own version) is caught as well.
	]]
	local BANNED_CLASSES = { weapon_pluviska = true, weapon_fury13 = true, weapon_fury16 = true }
	local BANNED_WORDS = { "pluv", "fury", "uber" }

	local bannedCache = {}

	function hg.bots.IsBannedItem(class)
		if not isstring(class) or class == "" then return false end

		local cached = bannedCache[class]

		if cached ~= nil then return cached end

		local lower = string.lower(class)
		local stored = weapons.GetStored(class)
		local name = stored and string.lower(tostring(stored.PrintName or "")) or ""
		local banned = BANNED_CLASSES[lower] or false

		for _, word in ipairs(BANNED_WORDS) do
			if banned then break end

			banned = string.find(lower, word, 1, true) ~= nil or string.find(name, word, 1, true) ~= nil
		end

		-- Not registered yet: decide again once it is.
		if stored or banned then bannedCache[class] = banned end

		return banned
	end

	-- The last line of defence: whatever handed a banned item to a bot
	-- (a round system's loadout, a loot box, another addon), it doesn't
	-- stay. Next tick, so the Give that is still running isn't pulled out
	-- from under itself.
	hook.Add("WeaponEquip", "HG_Bots_NoBannedItems", function(wep, owner)
		if not IsValid(wep) or not IsValid(owner) or not owner:IsPlayer() or not owner:IsBot() then return end

		local class = wep:GetClass()

		if not hg.bots.IsBannedItem(class) then return end

		timer.Simple(0, function()
			if IsValid(owner) and IsValid(wep) and wep:GetOwner() == owner then owner:StripWeapon(class) end
		end)
	end)
--//

--\\ Items switched off for random kits
	--[[
		Admins can take any weapon or armour piece out of the random rolls
		(menu: "Random kit items"). That covers every random kit - the
		menu's random spawn, hg_bot_kit_random, a rolled kit in the builder
		and the director. Kits put together by hand are left alone: picking
		an item yourself is the point of the builder.

		Stored as a plain JSON array of names: util.JSONToTable turns keys
		that look like numbers into numbers, values it leaves alone.
	]]
	local blacklist

	local function Blacklist()
		if blacklist then return blacklist end

		blacklist = {}

		local raw = file.Read(BLACKLIST_FILE, "DATA")
		local parsed = raw and util.JSONToTable(raw)

		if istable(parsed) then
			for _, name in pairs(parsed) do
				if isstring(name) then blacklist[name] = true end
			end
		end

		return blacklist
	end

	function hg.bots.IsBlacklisted(name)
		return Blacklist()[name] == true
	end

	--- Every switched-off name, sorted (for the menu).
	function hg.bots.KitBlacklist()
		local out = {}

		for name in pairs(Blacklist()) do out[#out + 1] = name end

		table.sort(out)

		return out
	end
--//

--\\ What the server has
	local pool, poolBuiltAt
	local rolls -- Pool() minus the blacklist, rebuilt whenever either changes

	local function IsGrenadeClass(tbl)
		return (tbl.ENT ~= nil and tbl.Throw ~= nil) or string.find(tbl.ClassName or "", "grenade") ~= nil
	end

	--[[
		Sorting a weapon into a bucket has to work off the STATIC SWEP table,
		because that is all weapons.GetList() gives. The obvious flag,
		wep.ishgweapon, is NOT usable here: Z-City sets it at runtime in the
		base's Initialize (lua/weapons/homigrad_base/shared.lua sets
		self.ishgweapon = true), so it is simply absent from the registered
		table. Testing it meant every firearm failed and the pool held only
		melee weapons - which is why every rolled kit came out as a knife.

		What IS static:
		  guns      SWEP.Base == "homigrad_base"
		  melee     SWEP.ismelee2 / ismelee (weapon_melee and everything
		            derived from it)
		  grenades  derived from weapon_hg_grenade_tpik / weapon_tpik_base
		  medical   derived from weapon_bandage_sh (plus IsMedClass)
		Fields like weight and HoldType may live in a parent, so they are
		read through the base chain rather than off the leaf table.
	]]
	local GUN_BASES = { homigrad_base = true }
	local NADE_BASES = { weapon_hg_grenade_tpik = true, weapon_tpik_base = true }
	local MELEE_BASES = { weapon_melee = true }
	local MED_BASES = { weapon_bandage_sh = true, weapon_hg_medicine_base = true }

	--- Every class in this weapon's inheritance chain, itself included.
	local function BaseChain(tbl)
		local chain, seen = { tbl }, {}
		local cur = tbl

		for _ = 1, 6 do
			local base = cur.Base

			if not base or base == "" or seen[base] then break end

			seen[base] = true

			local parent = weapons.GetStored and weapons.GetStored(base) or weapons.Get(base)

			if not parent then break end

			chain[#chain + 1] = parent
			cur = parent
		end

		return chain, seen
	end

	--- A field from the weapon or the first parent that has it.
	local function Field(chain, key)
		for _, t in ipairs(chain) do
			if t[key] ~= nil then return t[key] end
		end

		return nil
	end

	--- Everything worth handing out, sorted into buckets. Built once and
	-- cached: weapons.GetList() is not cheap and the list never changes.
	-- This is the FULL list (minus the banned items) - the menu shows it
	-- as is; rolls go through Rolls() below, which drops the blacklist.
	local function Pool()
		if pool and CurTime() - poolBuiltAt < 300 then return pool end

		pool = { pistol = {}, light = {}, heavy = {}, melee = {}, grenade = {}, med = {} }
		poolBuiltAt = CurTime()
		rolls = nil

		for _, tbl in ipairs(weapons.GetList()) do
			local class = tbl.ClassName

			-- Spawnable weeds out the base classes themselves.
			if class and tbl.Spawnable and not hg.bots.IsBannedItem(class) then
				local chain, bases = BaseChain(tbl)
				local function derives(set)
					for name in pairs(set) do
						if bases[name] then return true end
					end

					return false
				end

				local isMed = (hg.bots.IsMedClass and hg.bots.IsMedClass(class)) or derives(MED_BASES)
				local isNade = derives(NADE_BASES) or IsGrenadeClass(tbl) or string.find(class, "grenade", 1, true) ~= nil
				local isMelee = Field(chain, "ismelee2") or Field(chain, "ismelee") or derives(MELEE_BASES)

				if isMed then
					table.insert(pool.med, class)
				elseif isNade then
					table.insert(pool.grenade, class)
				elseif isMelee then
					table.insert(pool.melee, class)
				elseif derives(GUN_BASES) then
					local weight = tonumber(Field(chain, "weight")) or 1
					local hold = Field(chain, "HoldType")

					if Field(chain, "IsPistol") or hold == "pistol" or hold == "revolver" then
						table.insert(pool.pistol, class)
					elseif weight >= 3.2 then
						table.insert(pool.heavy, class)
					else
						table.insert(pool.light, class)
					end
				end
			end
		end

		return pool
	end

	--- What random kits actually roll from: the pool without the items an
	-- admin switched off, and without admin-only weapons unless allowed.
	local function Rolls()
		local p = Pool()

		if rolls then return rolls end

		local adminOnly = hg_bot_kit_adminonly:GetBool()

		rolls = {}

		for bucket, list in pairs(p) do
			rolls[bucket] = {}

			for _, class in ipairs(list) do
				local stored = weapons.GetStored(class)

				if not hg.bots.IsBlacklisted(class) and (adminOnly or not (stored and stored.AdminOnly)) then
					table.insert(rolls[bucket], class)
				end
			end
		end

		return rolls
	end

	cvars.AddChangeCallback("hg_bot_kit_adminonly", function() rolls = nil end, "HG_Bots_KitRolls")

	--- Switch one weapon class or armour name on/off for random kits.
	function hg.bots.SetBlacklisted(name, off)
		if not isstring(name) or name == "" then return false end

		Blacklist()[name] = off and true or nil
		rolls = nil

		file.Write(BLACKLIST_FILE, util.TableToJSON(hg.bots.KitBlacklist(), true))

		return true
	end

	concommand.Add("hg_bot_kit_pool", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		local p, r = Pool(), Rolls()

		for bucket, list in pairs(p) do
			print(("[hg.bots] pool %-8s %d (%d in random kits)"):format(bucket, #list, #(r[bucket] or {})))
		end

		print("[hg.bots] (all zero but melee means the weapon classification is broken again - see the comment above Pool())")
	end, nil, "Print how many weapons of each kind the kit roller can see")

	hg.bots.LoadoutPoolAll = Pool
	hg.bots.LoadoutPool = Rolls

	local function Pick(list)
		if not list or #list == 0 then return nil end

		return list[math.random(#list)]
	end

	--- Rounds that fit this gun, and a sensible number of them.
	local function AmmoFor(class, mags)
		local tbl = weapons.Get(class)

		if not tbl or not tbl.Primary then return nil, 0 end

		local ammo = tbl.Primary.Ammo

		if not ammo or ammo == "" or ammo == "none" then return nil, 0 end

		local clip = math.max(tonumber(tbl.Primary.ClipSize) or 30, 1)

		return ammo, clip * (mags or 3)
	end
--//

--\\ Rolling a kit
	--[[
		A kit is rolled as a ROLE at a TIER, not as a bag of random items.
		The role decides what the bot is for (and therefore what it carries
		together); the tier decides how much of it there is. That is what
		keeps a roll sensible: a knife fighter gets a blade and a pistol
		rather than a sniper rifle with two rounds, and nobody ends up with
		a rifle and no magazines.

		primary   which bucket the main weapon comes from, in order of
		          preference
		mags      magazines for it, scaled by tier further down
		sidearm   chance of a pistol as well
		melee     chance of a blade
		meds      how many medical items
		grenade   chance of a grenade (never at the lowest tier)
		armorMul  multiplier on the tier's armour chance
	]]
	local ROLES = {
		scav     = { primary = { "pistol", "light" },  mags = 2, sidearm = 0.10, melee = 0.70, meds = 1, grenade = 0.05, armorMul = 0.6 },
		rifleman = { primary = { "light", "heavy" },   mags = 4, sidearm = 0.35, melee = 0.30, meds = 2, grenade = 0.35, armorMul = 1.0 },
		raider   = { primary = { "heavy", "light" },   mags = 5, sidearm = 0.60, melee = 0.35, meds = 3, grenade = 0.70, armorMul = 1.2 },
		marksman = { primary = { "heavy", "light" },   mags = 3, sidearm = 0.70, melee = 0.20, meds = 2, grenade = 0.10, armorMul = 0.8 },
		knifer   = { primary = { "melee" },            mags = 2, sidearm = 0.55, melee = 1.00, meds = 2, grenade = 0.15, armorMul = 0.9 },
		medic    = { primary = { "light", "pistol" },  mags = 3, sidearm = 0.30, melee = 0.40, meds = 5, grenade = 0.10, armorMul = 0.9 },
	}

	hg.bots.LoadoutRoles = {}

	for name in pairs(ROLES) do hg.bots.LoadoutRoles[#hg.bots.LoadoutRoles + 1] = name end

	table.sort(hg.bots.LoadoutRoles)

	-- Which roles turn up at which tier: a scav is a low-tier thing, a
	-- raider a high-tier one.
	local ROLE_BY_TIER = {
		low  = { "scav", "scav", "knifer", "rifleman" },
		mid  = { "rifleman", "rifleman", "knifer", "medic", "marksman" },
		high = { "raider", "raider", "rifleman", "marksman", "medic" },
	}

	local MAG_MUL = { low = 0.6, mid = 1, high = 1.4 }

	local function PickFrom(p, buckets)
		for _, bucket in ipairs(buckets) do
			local class = Pick(p[bucket])

			if class then return class, bucket end
		end

		return nil
	end

	--- @param tier "low" | "mid" | "high" (nil = rolled)
	-- @param role a key of ROLES (nil = rolled to fit the tier)
	function hg.bots.RandomLoadout(tier, role)
		local p = Rolls()

		if not tier or not ROLE_BY_TIER[tier] then
			local r = math.random()

			tier = (r < 0.45 and "low") or (r < 0.8 and "mid") or "high"
		end

		role = (role and ROLES[role] and role) or Pick(ROLE_BY_TIER[tier]) or "rifleman"

		local spec = ROLES[role]
		local kit = { weapons = {}, ammo = {}, armor = {}, tier = tier, role = role }

		local function give(class, mags)
			if not class then return end

			table.insert(kit.weapons, class)

			local ammo, count = AmmoFor(class, mags)

			if ammo then kit.ammo[ammo] = (kit.ammo[ammo] or 0) + count end
		end

		-- Main weapon, with magazines that actually fit it.
		local primary, bucket = PickFrom(p, spec.primary)
		local mags = math.max(math.floor(spec.mags * (MAG_MUL[tier] or 1) + 0.5), 1)

		give(primary, mags)

		-- A pistol as backup - always for someone whose main weapon is a
		-- blade, otherwise by the role's own chance.
		if bucket == "melee" or math.random() < spec.sidearm then
			give(Pick(p.pistol), math.max(math.floor(2 * (MAG_MUL[tier] or 1) + 0.5), 1))
		end

		-- A blade, unless the main weapon already is one.
		if bucket ~= "melee" and math.random() < spec.melee then
			local blade = Pick(p.melee)

			if blade then table.insert(kit.weapons, blade) end
		end

		-- Something to patch up with. Bandages and the like are separate
		-- items, so the same class twice is a second bandage, not a
		-- duplicate - but never more than the pool has distinct entries
		-- plus a couple of spares.
		local meds = math.max(math.floor(spec.meds * (tier == "low" and 0.7 or tier == "high" and 1.3 or 1) + 0.5), 1)

		for _ = 1, meds do
			local med = Pick(p.med)

			if med then table.insert(kit.weapons, med) end
		end

		if tier ~= "low" and math.random() < spec.grenade then
			local nade = Pick(p.grenade)

			if nade then give(nade, 1) end
		end

		-- Armour, by tier and role. hg.AddArmor sorts out placement and
		-- refuses anything that can't be worn together.
		if hg.armor then
			local slots = (tier == "low" and { "torso" })
				or (tier == "mid" and { "torso", "head" })
				or { "torso", "head", "face", "ears" }
			local chance = (tier == "low" and 0.35 or tier == "mid" and 0.7 or 0.95) * spec.armorMul

			for _, slot in ipairs(slots) do
				local set = hg.armor[slot]

				if set and math.random() < chance then
					local names = {}

					for name, info in pairs(set) do
						if not info.nodrop and not hg.bots.IsBlacklisted(name) then table.insert(names, name) end
					end

					local armor = Pick(names)

					if armor then table.insert(kit.armor, armor) end
				end
			end
		end

		-- A bot with nothing to fight with is a bug, not a poor roll.
		if #kit.weapons == 0 then
			give(Pick(p.pistol) or Pick(p.light), 2)

			local blade = Pick(p.melee)

			if #kit.weapons == 0 and blade then table.insert(kit.weapons, blade) end
		end

		return kit
	end
--//

--\\ Putting a kit on
	function hg.bots.ApplyLoadout(bot, kit)
		if not IsValid(bot) or not kit then return false end

		if hg_bot_kit_strip:GetBool() then
			bot:StripWeapons()
			bot:RemoveAllAmmo()
			bot:Give("weapon_hands_sh") -- never leave a bot with no hands
		end

		for _, class in ipairs(kit.weapons or {}) do
			-- Presets saved before the ban can still list them.
			local wep = isstring(class) and not hg.bots.IsBannedItem(class) and bot:Give(class, true)

			-- Attachments / remaining charges from a captured preset.
			if IsValid(wep) and kit.info and kit.info[class] and wep.SetInfo then
				wep:SetInfo(kit.info[class])
			end
		end

		for ammo, count in pairs(kit.ammo or {}) do
			bot:GiveAmmo(count, ammo, true)
		end

		if hg.AddArmor then
			for _, armor in ipairs(kit.armor or {}) do
				hg.AddArmor(bot, armor)
			end
		end

		local data = bot.Bot

		if data then
			data.NextWeaponSwitch = 0

			if hg.bots.EquipBestWeapon then hg.bots.EquipBestWeapon(bot) end
		end

		return true
	end

	--- Whatever this player is carrying right now, as a kit.
	function hg.bots.CaptureLoadout(ply)
		if not IsValid(ply) then return nil end

		local kit = { weapons = {}, ammo = {}, armor = {}, info = {} }

		for _, wep in ipairs(ply:GetWeapons()) do
			local class = wep:GetClass()

			if class ~= "weapon_hands_sh" and class ~= "weapon_hg_coolhands" and not hg.bots.IsBannedItem(class) then
				table.insert(kit.weapons, class)

				if wep.GetInfo then
					local ok, info = pcall(wep.GetInfo, wep)

					if ok and istable(info) then kit.info[class] = info end
				end

				local id = wep.GetPrimaryAmmoType and wep:GetPrimaryAmmoType() or -1

				if id and id >= 0 then
					local name = game.GetAmmoName(id)

					if name then kit.ammo[name] = math.max(kit.ammo[name] or 0, ply:GetAmmoCount(id)) end
				end
			end
		end

		for _, armor in pairs(ply.armors or {}) do
			if isstring(armor) then table.insert(kit.armor, armor) end
		end

		return kit
	end
--//

--\\ Saved presets
	local kits

	local function LoadKits()
		if kits then return kits end

		kits = {}

		local raw = file.Read(KIT_FILE, "DATA")
		local parsed = raw and util.JSONToTable(raw)

		-- util.JSONToTable turns every key that looks like a number into a
		-- number, so a kit saved as "1" or "2077" came back keyed 2077.
		-- table.sort then had to compare that number with the string
		-- names of the other kits and threw ("sort - [C]:-1" from
		-- KitNames), which killed the menu sync for everyone; GetKit("2077")
		-- didn't find it either. Names are strings, always.
		if istable(parsed) then
			for name, kit in pairs(parsed) do
				if istable(kit) then kits[tostring(name)] = kit end
			end
		end

		return kits
	end

	local function SaveKits()
		file.Write(KIT_FILE, util.TableToJSON(LoadKits(), true))
	end

	function hg.bots.GetKit(name)
		if name == nil then return nil end

		return LoadKits()[tostring(name)]
	end

	function hg.bots.KitNames()
		local out = {}

		for name in pairs(LoadKits()) do out[#out + 1] = tostring(name) end

		table.sort(out, function(a, b) return string.lower(a) < string.lower(b) end)

		return out
	end

	function hg.bots.SaveKit(name, kit)
		if name == nil or not kit then return false end

		name = string.sub(string.Trim(tostring(name)), 1, 40)

		if name == "" then return false end

		LoadKits()[name] = kit

		SaveKits()

		return true
	end

	function hg.bots.DeleteKit(name)
		if name == nil then return false end

		name = tostring(name)

		if not LoadKits()[name] then return false end

		kits[name] = nil

		SaveKits()

		return true
	end
--//

--\\ Spawning with a kit
	--- Spawns a bot and puts a kit on it once it's on its feet.
	-- @param kit a loadout table, "random", a preset name, or nil
	function hg.bots.SpawnWithKit(pos, ang, kit, name)
		local bot = hg.bots.Spawn(pos, ang, name)

		if not IsValid(bot) then return nil end

		local resolved

		if istable(kit) then
			resolved = kit
		elseif kit == "random" then
			resolved = hg.bots.RandomLoadout()
		elseif isstring(kit) then
			resolved = hg.bots.GetKit(kit)
		end

		if not resolved then return bot end

		-- After the spawn refresh has finished with it (sv_bot_core.lua).
		timer.Simple(1.2, function()
			if IsValid(bot) and bot:Alive() then hg.bots.ApplyLoadout(bot, resolved) end
		end)

		return bot
	end

	-- Bots created by anything else (round systems, hg_bot_spawn) get a
	-- random kit too when that's switched on.
	hook.Add("HG_BotInitialized", "HG_Bots_RandomKit", function(bot)
		if not hg_bot_kit_random:GetBool() then return end

		timer.Simple(1.2, function()
			if IsValid(bot) and bot:Alive() then hg.bots.ApplyLoadout(bot, hg.bots.RandomLoadout()) end
		end)
	end)

	concommand.Add("hg_bot_kit_list", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end

		print("[hg.bots] kits: " .. (table.concat(hg.bots.KitNames(), ", ")))
	end)
--//
