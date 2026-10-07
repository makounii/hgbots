--[[
	Tarkov AI - Settings menu (server side)

	The menu's parameters are ordinary server convars, which a client can't
	set directly, so the client asks for their values and sends back the
	ones it changed. Everything is checked against the shared catalogue
	(sh_bot_settings.lua): a name that isn't in it, or a player without the
	rights for it, changes nothing.

	Rights are split the way the user asked for:
	- admin: everything about how bots fight;
	- superadmin: spawning/removing bots, friendly fire, and the navmesh
	  patcher, since those change the server or the map rather than
	  behaviour.
]]

AddCSLuaFile("sh_bot_lang.lua")
AddCSLuaFile("sh_bot_settings.lua")
AddCSLuaFile("cl_bot_menu.lua")

hg.bots = hg.bots or {}

-- Load order isn't guaranteed (the client may include this before the
-- shared catalogue), so the net names are re-stated here as defaults.
hg.bots.NetSync = hg.bots.NetSync or "hg_bot_cfg_sync"
hg.bots.NetReq = hg.bots.NetReq or "hg_bot_cfg_req"
hg.bots.NetSet = hg.bots.NetSet or "hg_bot_cfg_set"
hg.bots.NetAct = hg.bots.NetAct or "hg_bot_cfg_act"
hg.bots.NetMsg = hg.bots.NetMsg or "hg_bot_cfg_msg"
hg.bots.NetKits = hg.bots.NetKits or "hg_bot_cfg_kits"

hg.bots.SettingIndex = hg.bots.SettingIndex or {}
hg.bots.SettingGroups = hg.bots.SettingGroups or {}
hg.bots.MenuActions = hg.bots.MenuActions or {}

util.AddNetworkString(hg.bots.NetSync)
util.AddNetworkString(hg.bots.NetReq)
util.AddNetworkString(hg.bots.NetSet)
util.AddNetworkString(hg.bots.NetAct)
util.AddNetworkString(hg.bots.NetMsg)
util.AddNetworkString(hg.bots.NetKits)

--\\ Rights
	function hg.bots.CanEdit(ply, level)
		if not IsValid(ply) then return true end -- server console

		if level == "superadmin" then return ply:IsSuperAdmin() end

		return ply:IsAdmin()
	end

	local function Deny(ply, level)
		net.Start(hg.bots.NetMsg)
		net.WriteString(level == "superadmin" and "need.superadmin" or "need.admin")
		net.WriteString("")
		net.Send(ply)
	end

	local function Tell(ply, key, extra)
		if not IsValid(ply) then return end

		net.Start(hg.bots.NetMsg)
		net.WriteString(key)
		net.WriteString(extra or "")
		net.Send(ply)
	end
--//

--\\ Catalogue sanity check
	-- Runs on Initialize, NOT at load time: the loader includes files in
	-- alphabetical order, so everything after sv_bot_menu.lua (voice,
	-- squad, stealth, morale, navpatch, ...) hasn't created its convars
	-- yet while this file loads. Checking here dropped all of those from
	-- the catalogue, and the server then refused every change to them -
	-- that was the "some toggles in the menu do nothing" bug.
	hook.Add("Initialize", "HG_Bots_CheckSettings", function()
		local missing = {}

		for name in pairs(hg.bots.SettingIndex) do
			if not ConVarExists(name) then missing[#missing + 1] = name end
		end

		for _, name in ipairs(missing) do
			hg.bots.SettingIndex[name] = nil
		end

		if #missing > 0 then
			print("[hg.bots] settings menu: no such convars, skipped: " .. table.concat(missing, ", "))
		end
	end)
--//

--\\ Saving settings between sessions
	-- FCVAR_ARCHIVE only reaches cfg/server.vdf on a clean shutdown, so a
	-- crash (or a restart from a panel) loses everything set in the menu.
	-- The catalogued values are kept in their own file instead: written on
	-- every change, applied once every convar exists.
	local SAVE_FILE = "hg_bots_settings.json"

	local function SaveSettings()
		local out = {}

		for name in pairs(hg.bots.SettingIndex) do
			local cvar = GetConVar(name)

			if cvar then out[name] = cvar:GetFloat() end
		end

		file.Write(SAVE_FILE, util.TableToJSON(out, true))
	end

	hg.bots.SaveSettings = SaveSettings

	local function LoadSettings()
		local raw = file.Read(SAVE_FILE, "DATA")

		if not raw then return 0 end

		local saved = util.JSONToTable(raw)

		if not saved then return 0 end

		-- Sanity check before trusting the file. A client that built its
		-- sliders before the first sync used to push every parameter to its
		-- minimum, and this file then restored that on every map load; a bot
		-- with 100 units of sight and a 10 degree cone notices nobody. If
		-- most of what is saved sits exactly on the minimum, the file is
		-- that accident rather than somebody's own settings.
		local total, atMin = 0, 0

		for name, value in pairs(saved) do
			if hg.bots.IsSetting(name) and isnumber(value) then
				local cvar = GetConVar(name)
				local min = cvar and cvar:GetMin()

				if cvar and min then
					total = total + 1

					if math.abs(value - min) < 0.0001 and math.abs((tonumber(cvar:GetDefault()) or min) - min) > 0.0001 then
						atMin = atMin + 1
					end
				end
			end
		end

		if total > 20 and atMin / total > 0.5 then
			print(("[hg.bots] settings: %d of %d saved values sit on their minimum - that file is broken, ignoring it and using defaults"):format(atMin, total))
			file.Delete(SAVE_FILE)

			return 0
		end

		local count = 0

		for name, value in pairs(saved) do
			if hg.bots.IsSetting(name) and isnumber(value) then
				local cvar = GetConVar(name)

				if cvar then
					cvar:SetFloat(value)
					count = count + 1
				end
			end
		end

		return count
	end

	hg.bots.LoadSettings = LoadSettings

	-- Initialize: every file has created its convars by then.
	hook.Add("Initialize", "HG_Bots_LoadSettings", function()
		local count = LoadSettings()

		if count > 0 then print(("[hg.bots] settings: %d saved values restored"):format(count)) end
	end)

	concommand.Add("hg_bot_settings_reset", function(ply)
		if not hg.bots.CanEdit(ply, "superadmin") then return end

		file.Delete(SAVE_FILE)

		-- Applied right now, not on the next map: a bad saved file (see the
		-- menu's HARD GATE comment) leaves bots blind and deaf, and waiting
		-- for a map change to fix that is no fix at all.
		local restored = 0

		for name in pairs(hg.bots.SettingIndex) do
			local cvar = GetConVar(name)

			if cvar then
				local def = tonumber(cvar:GetDefault())

				if def then
					cvar:SetFloat(def)
					restored = restored + 1
				end
			end
		end

		print(("[hg.bots] settings: saved file deleted, %d parameters put back to their defaults"):format(restored))
	end)
--//

--\\ Values
	-- Players with the menu open, so a change by one admin shows up for
	-- the others without reopening it.
	local watching = {}

	local function SendValues(ply)
		local names = {}

		for name in pairs(hg.bots.SettingIndex) do names[#names + 1] = name end

		table.sort(names)

		net.Start(hg.bots.NetSync)
		net.WriteBool(not IsValid(ply) or ply:IsAdmin())
		net.WriteBool(not IsValid(ply) or ply:IsSuperAdmin())
		net.WriteUInt(#names, 16)

		for _, name in ipairs(names) do
			local cvar = GetConVar(name)

			-- Bounds and help travel with the value: these are server
			-- convars, so a client has no way to look them up itself.
			net.WriteString(name)
			net.WriteFloat(cvar and cvar:GetFloat() or 0)
			net.WriteFloat(cvar and cvar:GetMin() or 0)
			net.WriteFloat(cvar and cvar:GetMax() or 1)
			net.WriteString(cvar and cvar:GetHelpText() or "")
			net.WriteFloat(cvar and tonumber(cvar:GetDefault()) or 0)
		end

		net.Send(ply)
	end

	local function Broadcast(name, value)
		local now = CurTime()

		for ply, until_ in pairs(watching) do
			if not IsValid(ply) or until_ < now then
				watching[ply] = nil
			else
				net.Start(hg.bots.NetSync)
				net.WriteBool(ply:IsAdmin())
				net.WriteBool(ply:IsSuperAdmin())
				local cvar = GetConVar(name)

				net.WriteUInt(1, 16)
				net.WriteString(name)
				net.WriteFloat(value)
				net.WriteFloat(cvar and cvar:GetMin() or 0)
				net.WriteFloat(cvar and cvar:GetMax() or 1)
				net.WriteString(cvar and cvar:GetHelpText() or "")
				net.WriteFloat(cvar and tonumber(cvar:GetDefault()) or 0)
				net.Send(ply)
			end
		end
	end

	net.Receive(hg.bots.NetReq, function(len, ply)
		if not IsValid(ply) then return end

		watching[ply] = CurTime() + 300

		SendValues(ply)

		-- Saved gear presets and the gear catalogue (sv_bot_loadout.lua)
		-- travel with the sync.
		if hg.bots.SendKits then hg.bots.SendKits(ply, nil, true) end
	end)

	net.Receive(hg.bots.NetSet, function(len, ply)
		local name = net.ReadString()
		local value = net.ReadFloat()

		if not hg.bots.IsSetting(name) then return end

		local level = hg.bots.SettingLevel(name)

		if not hg.bots.CanEdit(ply, level) then Deny(ply, level) return end

		local cvar = GetConVar(name)

		if not cvar then return end

		local min, max = cvar:GetMin(), cvar:GetMax()

		if min then value = math.max(value, min) end
		if max then value = math.min(value, max) end

		cvar:SetFloat(value)

		Broadcast(name, value)
		SaveSettings()
	end)
--//

--\\ Gear catalogue and kits
	-- The kit builder needs to show what the server actually has: every
	-- weapon worth handing out, sorted into the same buckets
	-- sv_bot_loadout.lua rolls from, plus the armour pieces. Built once
	-- (weapons.GetList is not cheap) and sent compressed with the kit list.
	local catalog

	local function BuildCatalog()
		if catalog then return catalog end

		catalog = { pistol = {}, light = {}, heavy = {}, melee = {}, grenade = {}, med = {}, armor = {} }

		local pool = hg.bots.LoadoutPool and hg.bots.LoadoutPool()

		for bucket, list in pairs(pool or {}) do
			if catalog[bucket] then
				for _, class in ipairs(list) do
					local tbl = weapons.Get(class)
					local ammo = tbl and tbl.Primary and tbl.Primary.Ammo

					catalog[bucket][#catalog[bucket] + 1] = {
						class = class,
						name = (tbl and tbl.PrintName ~= "" and tbl.PrintName) or class,
						ammo = (ammo ~= "" and ammo ~= "none") and ammo or nil,
						clip = tbl and tbl.Primary and tbl.Primary.ClipSize or nil,
					}
				end

				table.sort(catalog[bucket], function(a, b) return a.name < b.name end)
			end
		end

		for placement, set in pairs(hg.armor or {}) do
			for name, info in pairs(set) do
				if not info.nodrop then
					catalog.armor[#catalog.armor + 1] = { class = name, name = name, slot = placement }
				end
			end
		end

		table.sort(catalog.armor, function(a, b) return a.slot == b.slot and a.name < b.name or a.slot < b.slot end)

		return catalog
	end

	hg.bots.MenuCatalog = BuildCatalog

	--- Kit list (+ optionally one kit's contents, and the gear catalogue on
	-- the first send) as one compressed payload.
	local function SendKits(target, kitName, withCatalog)
		local payload = {
			names = hg.bots.KitNames and hg.bots.KitNames() or {},
			kit = kitName and kitName ~= "" and hg.bots.GetKit(kitName) or nil,
			kitName = kitName ~= "" and kitName or nil,
			catalog = withCatalog and BuildCatalog() or nil,
		}

		local data = util.Compress(util.TableToJSON(payload))

		net.Start(hg.bots.NetKits)
		net.WriteUInt(#data, 24)
		net.WriteData(data, #data)
		net.Send(target)
	end

	hg.bots.SendKits = SendKits

	--- A kit built in the menu, checked against what the server has: unknown
	-- weapon classes, ammo types and armour names are dropped rather than
	-- handed to Player:Give as-is.
	local function SanitizeKit(raw)
		if not istable(raw) then return nil end

		local kit = { weapons = {}, ammo = {}, armor = {} }

		for _, class in ipairs(raw.weapons or {}) do
			if isstring(class) and weapons.Get(class) and #kit.weapons < 12 then
				kit.weapons[#kit.weapons + 1] = class
			end
		end

		for name, count in pairs(raw.ammo or {}) do
			count = tonumber(count)

			if isstring(name) and count and count > 0 then
				kit.ammo[name] = math.Clamp(math.floor(count), 1, 2000)
			end
		end

		for _, name in ipairs(raw.armor or {}) do
			if isstring(name) and #kit.armor < 8 then
				for _, set in pairs(hg.armor or {}) do
					if set[name] then
						kit.armor[#kit.armor + 1] = name
						break
					end
				end
			end
		end

		return kit
	end
--//

--\\ Presets
	local PRESETS = {
		-- No trust, no hesitation: they hunt.
		wild = {
			hg_bot_trust = 0, hg_bot_tactic_push = 2, hg_bot_tactic_wait = 0.5,
			hg_bot_tactic_careful = 1, hg_bot_duel_aggression = 0.8,
			hg_bot_flee_chance = 0.35, hg_bot_morale_start = 0.8,
			hg_bot_grenade_chance = 0.7, hg_bot_suppress = 1,
		},
		-- Slow, angle-holding, prefiring bots that make you come to them.
		careful = {
			hg_bot_tactic_push = 0.5, hg_bot_tactic_wait = 1.5, hg_bot_tactic_careful = 2,
			hg_bot_duel_aggression = 0.3, hg_bot_flee_chance = 0.75,
			hg_bot_ambush = 1, hg_bot_prone_chance = 0.6, hg_bot_suppress = 1,
		},
		-- Leave them alone and they leave you alone.
		trusted = {
			hg_bot_trust = 1, hg_bot_trust_forgive = 900, hg_bot_trust_forget_on_death = 0,
		},
		-- Fewer traces, shorter searches, lighter thinking.
		perf = {
			hg_bot_think_rate = 0.2, hg_bot_sight_rate = 0.25, hg_bot_astar_max_nodes = 2000,
			hg_bot_path_budget = 2, hg_bot_cover_samples = 14, hg_bot_ambush_samples = 16,
			hg_bot_loot_radius = 600, hg_bot_loot_crates = 0, hg_bot_navpatch_follow = 0,
		},
	}

	function hg.bots.ApplyPreset(name)
		local preset = PRESETS[name]

		if not preset then return false end

		for cvarName, value in pairs(preset) do
			local cvar = GetConVar(cvarName)

			if cvar then
				cvar:SetFloat(value)
				Broadcast(cvarName, value)
			end
		end

		SaveSettings()

		return true
	end

	hg.bots.PresetNames = {}

	for name in pairs(PRESETS) do hg.bots.PresetNames[#hg.bots.PresetNames + 1] = name end

	table.sort(hg.bots.PresetNames)
--//

--\\ Orders from the context menu
	-- A bot told to do something by hand keeps doing it until it is done,
	-- it is told otherwise, or something starts shooting: the order is only
	-- honoured from the idle state, which runs after the threat check, so a
	-- fight always wins over an order.
	local ORDER_TIME = 120

	--- Called from the idle state (sv_bot_navigation.lua).
	function hg.bots.CheckOrder(bot, data)
		local order = data.Order

		if not order then return false end

		if CurTime() > (order.untilT or 0) then
			data.Order = nil

			return false
		end

		if order.kind == "follow" then
			local who = order.who

			if not IsValid(who) or not who:Alive() then
				data.Order = nil

				return false
			end

			local dist = bot:GetPos():Distance(who:GetPos())

			-- Close enough: stand and watch where they are looking.
			if dist < 220 then
				hg.bots.ClearPath(data)

				data.Running = false
				data.LookPos = who:EyePos() + who:GetAimVector() * 400

				return true
			end

			if not data.Goal or data.Goal:DistToSqr(who:GetPos()) > 200 ^ 2 then
				hg.bots.SetGoal(bot, who:GetPos())
			end

			data.Running = dist > 700

			hg.bots.FollowPath(bot, data)

			return true
		end

		if order.kind == "move" then
			if not data.Goal then hg.bots.SetGoal(bot, order.pos) end

			data.Running = bot:GetPos():Distance(order.pos) > 600

			if hg.bots.FollowPath(bot, data) then
				data.Order = nil -- arrived (or the route failed)
			end

			return true
		end

		data.Order = nil

		return false
	end

	--- @param kind "move" | "hold" | "follow" | "stop"
	function hg.bots.GiveOrder(bot, kind, pos, who)
		local data = IsValid(bot) and bot.Bot

		if not data then return false end

		hg.bots.ClearPath(data)

		if kind == "stop" then
			data.Order = nil

			if data.State == "hold" then hg.bots.SetState(bot, "idle") end

			return true
		end

		if kind == "hold" then
			if not pos then return false end

			data.Order = nil

			-- The hold state already owns "stay here and watch that way".
			if hg.bots.HoldPosition then
				hg.bots.HoldPosition(bot, pos, pos + (bot:GetPos() - pos):GetNormalized() * -400)
				data.HoldDuration = ORDER_TIME
			else
				hg.bots.SetGoal(bot, pos)
			end

			return true
		end

		if kind == "follow" then
			data.Order = { kind = "follow", who = who, untilT = CurTime() + ORDER_TIME * 4 }
		elseif kind == "move" then
			if not pos then return false end

			data.Order = { kind = "move", pos = pos, untilT = CurTime() + ORDER_TIME }

			hg.bots.SetGoal(bot, pos)
		else
			return false
		end

		-- An order is worth dropping a wander or a looting detour for.
		if data.State ~= "idle" and data.State ~= "alert" then return true end

		data.LootTarget = nil
		data.CrateTarget = nil
		data.CorpseTarget = nil

		return true
	end

	--- "12 34 56" from the client's crosshair.
	local function ParsePos(arg)
		local parts = string.Explode(" ", arg or "")

		if #parts < 3 then return nil end

		local x, y, z = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])

		if not x or not y or not z then return nil end

		return Vector(x, y, z)
	end

	-- The client draws a name tag with the bot's state, so it has to know it.
	hook.Add("HG_BotStateChanged", "HG_Bots_NetState", function(bot, old, new)
		if IsValid(bot) then bot:SetNWString("hg_bot_state", tostring(new)) end
	end)

	hook.Add("HG_BotInitialized", "HG_Bots_NetStateInit", function(bot)
		if IsValid(bot) then bot:SetNWString("hg_bot_state", tostring(bot.Bot and bot.Bot.State or "idle")) end
	end)
--//

--\\ Buttons
	net.Receive(hg.bots.NetAct, function(len, ply)
		local action = net.ReadString()
		local ent = net.ReadEntity()
		local arg = net.ReadString()

		local level = hg.bots.MenuActions[action]

		if not level then return end
		if not hg.bots.CanEdit(ply, level) then Deny(ply, level) return end

		if action == "spawn" then
			local tr = ply:GetEyeTrace()

			hg.bots.Spawn(tr.HitPos + Vector(0, 0, 8), ply:EyeAngles())
		elseif action == "spawn_random" then
			local tr = ply:GetEyeTrace()

			hg.bots.SpawnWithKit(tr.HitPos + Vector(0, 0, 8), ply:EyeAngles(), "random")
		elseif action == "spawn_kit" then
			if arg ~= "" and hg.bots.GetKit(arg) then
				local tr = ply:GetEyeTrace()

				hg.bots.SpawnWithKit(tr.HitPos + Vector(0, 0, 8), ply:EyeAngles(), arg)
			end
		elseif action == "kit_save" then
			-- Saves exactly what the caller is carrying.
			if arg ~= "" and hg.bots.SaveKit(arg, hg.bots.CaptureLoadout(ply)) then
				Tell(ply, "applied", arg)
				SendKits(ply, arg)
			end
		elseif action == "kit_build" then
			-- A kit assembled in the menu: {name, weapons, ammo, armor}.
			local raw = util.JSONToTable(arg or "")
			local name = istable(raw) and isstring(raw.name) and string.Trim(raw.name) or ""
			local kit = SanitizeKit(raw)

			if name ~= "" and kit and hg.bots.SaveKit(name, kit) then
				Tell(ply, "applied", name)
				SendKits(ply, name)
			end
		elseif action == "kit_get" then
			if arg == "@me" then
				-- "Take my current gear" in the builder: the caller's own
				-- loadout, handed back to edit rather than saved outright.
				local kit = hg.bots.CaptureLoadout(ply)

				if kit then
					local data = util.Compress(util.TableToJSON({ names = hg.bots.KitNames(), kit = kit, kitName = "" }))

					net.Start(hg.bots.NetKits)
					net.WriteUInt(#data, 24)
					net.WriteData(data, #data)
					net.Send(ply)
				end
			else
				SendKits(ply, arg)
			end
		elseif action == "kit_random" then
			-- A rolled kit handed back to the builder to edit and save.
			local kit = hg.bots.RandomLoadout and hg.bots.RandomLoadout(arg ~= "" and arg or nil)

			if kit then
				net.Start(hg.bots.NetKits)

				local data = util.Compress(util.TableToJSON({ names = hg.bots.KitNames(), kit = kit, kitName = "" }))

				net.WriteUInt(#data, 24)
				net.WriteData(data, #data)
				net.Send(ply)
			end
		elseif action == "kit_delete" then
			if hg.bots.DeleteKit(arg) then SendKits(ply) end
		elseif action == "spawn_guard" then
			-- A bot on the players' side (sv_bot_factions.lua).
			local tr = ply:GetEyeTrace()
			local bot = (arg ~= "" and hg.bots.SpawnWithKit and hg.bots.SpawnWithKit(tr.HitPos + Vector(0, 0, 8), ply:EyeAngles(), arg))
				or hg.bots.Spawn(tr.HitPos + Vector(0, 0, 8), ply:EyeAngles())

			if IsValid(bot) then
				timer.Simple(0.25, function()
					if IsValid(bot) and hg.bots.SetFaction then hg.bots.SetFaction(bot, "guard") end
				end)
			end
		elseif action == "director_place" then
			ply:ConCommand("hg_bot_director_place")
		elseif action == "director_clear" then
			ply:ConCommand("hg_bot_director_clear")
		elseif action == "director_status" then
			ply:ConCommand("hg_bot_director_status")
		elseif action == "removeall" then
			hg.bots.RemoveAll()
		elseif action == "remove" then
			if IsValid(ent) and ent.IsHomigradBot then hg.bots.Remove(ent) end
		elseif action == "kit_apply" then
			-- Re-gear a bot that is already in the world.
			if IsValid(ent) and ent.IsHomigradBot then
				if arg == "strip" then
					ent:StripWeapons()
					ent:RemoveAllAmmo()
					ent:Give("weapon_hands_sh")
				else
					local kit = (arg == "random") and hg.bots.RandomLoadout and hg.bots.RandomLoadout() or hg.bots.GetKit(arg)

					if kit and hg.bots.ApplyLoadout(ent, kit) then Tell(ply, "applied", arg) end
				end
			end
		elseif action == "enable" then
			-- Freeze / unfreeze the AI without removing the bot.
			if IsValid(ent) and ent.Bot then
				ent.Bot.Enabled = not ent.Bot.Enabled

				Tell(ply, "raw", ent:Nick() .. ": AI " .. (ent.Bot.Enabled and "on" or "frozen"))
			end
		elseif action == "teleport" then
			if IsValid(ent) and ent.IsHomigradBot and IsValid(ply) then
				local tr = ply:GetEyeTrace()

				ent:SetPos(tr.HitPos + Vector(0, 0, 8))

				if ent.Bot then
					hg.bots.ClearPath(ent.Bot)
					ent.Bot.Order = nil
				end
			end
		elseif action == "order_move" or action == "order_hold" then
			local pos = ParsePos(arg)

			if IsValid(ent) and ent.IsHomigradBot and pos then
				hg.bots.GiveOrder(ent, action == "order_move" and "move" or "hold", pos)
				Tell(ply, "raw", ent:Nick() .. ": " .. (action == "order_move" and "moving there" or "holding there"))
			end
		elseif action == "order_follow" then
			if IsValid(ent) and ent.IsHomigradBot then
				hg.bots.GiveOrder(ent, "follow", nil, ply)
				Tell(ply, "raw", ent:Nick() .. ": following you")
			end
		elseif action == "order_stop" then
			if IsValid(ent) and ent.IsHomigradBot then
				hg.bots.GiveOrder(ent, "stop")
				Tell(ply, "raw", ent:Nick() .. ": order cancelled")
			end
		elseif action == "faction" then
			if IsValid(ent) and ent.IsHomigradBot and hg.bots.SetFaction and hg.bots.SetFaction(ent, arg) then
				Tell(ply, "applied", arg)
			end
		elseif action == "reinit" then
			if IsValid(ent) and ent.IsHomigradBot then hg.bots.Init(ent) end
		elseif action == "state" then
			if IsValid(ent) and ent.Bot then
				local data = ent.Bot
				local mem = data.Memory or {}
				local wep = ent:GetActiveWeapon()

				Tell(ply, "raw", ("%s | state %s | tactic %s | squad %s | duel %s | morale %.2f | target %s | weapon %s"):format(
					ent:Nick(), tostring(data.State), tostring(data.Tactic), tostring(data.SquadRole),
					hg.bots.GetDuelStyle and tostring(hg.bots.GetDuelStyle(ent)) or "-",
					hg.bots.GetMorale and hg.bots.GetMorale(ent) or 1,
					IsValid(mem.Target) and mem.Target:Nick() or "-",
					IsValid(wep) and wep:GetClass() or "-"))
			end
		elseif action == "preset" then
			if hg.bots.ApplyPreset(arg) then Tell(ply, "applied", arg) end
		elseif action == "navpatch" then
			ply:ConCommand("hg_bot_navpatch save")
		elseif action == "navpatch_undo" then
			ply:ConCommand("hg_bot_navpatch_undo")
		end
	end)

	hook.Add("PlayerDisconnected", "HG_Bots_MenuCleanup", function(ply)
		watching[ply] = nil
	end)
--//
