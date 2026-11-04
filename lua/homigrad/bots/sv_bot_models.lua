--[[
	Tarkov AI - Bot models

	Which player model a bot wears. Three layers, the first that has an
	answer wins:

	- per bot: picked for one bot from its right-click menu ("Model");
	- the pool: with hg_bot_model_mode on, every new bot rolls one model
	  out of the models ticked on the "Bot models" page;
	- otherwise nothing is touched and Z-City's own random appearance
	  stays, as before.

	What may be worn is what a player could pick: Z-City's own appearance
	models (hg.Appearance.PlayerModels) and every installed player model
	(player_manager.AllValidModels). Anything else is refused - a prop or
	an NPC model without ValveBiped bones would break Z-City's ragdolls.

	Z-City models go through its appearance code (ForceApplyAppearance),
	so clothes, face and name come with them. Other models are set as is,
	with the Z-City clothing submaterials and hats cleared - they belong to
	Z-City's own meshes.

	Z-City puts a random appearance on every bot when it spawns (and round
	classes put their own), at moments this file doesn't control, so the
	wanted model is re-checked every couple of seconds and put back if
	something else replaced it. Never while ragdolled: the body on the
	floor keeps the model it fell with.

	The pool lives in data/hg_bots_models.json.

	NAMES work the same way: a list on the "Bot models" page (one name per
	line, data/hg_bots_names.json) that new bots take their names from,
	and a per-bot rename in its right-click menu. Z-City shows a
	character's name from its appearance (the PlayerName network string),
	not the player name, so that is what is set - and kept, like the model.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {}

local hg_bot_model_mode = CreateConVar("hg_bot_model_mode", "0", {FCVAR_ARCHIVE}, "New bots wear a random model from the ones ticked on the \"Bot models\" page (off: Z-City's own random appearance)", 0, 1)

local POOL_FILE = "hg_bots_models.json"

--\\ What may be worn
	local allowedCache, allowedAt

	--- [lower-case path] = { mdl = path, name = Z-City appearance name or nil }
	local function Allowed()
		if allowedCache and CurTime() - allowedAt < 60 then return allowedCache end

		allowedCache, allowedAt = {}, CurTime()

		local ap = hg.Appearance and hg.Appearance.PlayerModels

		if istable(ap) then
			for sex = 1, 2 do
				for name, tbl in pairs(ap[sex] or {}) do
					if istable(tbl) and isstring(tbl.mdl) then
						allowedCache[string.lower(tbl.mdl)] = { mdl = tbl.mdl, name = name, sex = sex }
					end
				end
			end
		end

		for _, mdl in pairs(player_manager.AllValidModels()) do
			if isstring(mdl) and not allowedCache[string.lower(mdl)] then
				allowedCache[string.lower(mdl)] = { mdl = mdl }
			end
		end

		return allowedCache
	end

	function hg.bots.IsAllowedModel(mdl)
		return isstring(mdl) and Allowed()[string.lower(mdl)] ~= nil
	end
--//

--\\ The pool
	local pool

	local function Pool()
		if pool then return pool end

		pool = {}

		local raw = file.Read(POOL_FILE, "DATA")
		local parsed = raw and util.JSONToTable(raw)

		if istable(parsed) then
			for _, mdl in pairs(parsed) do
				if isstring(mdl) then pool[string.lower(mdl)] = true end
			end
		end

		return pool
	end

	--- Ticked models, sorted (for the menu).
	function hg.bots.ModelPool()
		local out = {}

		for mdl in pairs(Pool()) do out[#out + 1] = mdl end

		table.sort(out)

		return out
	end

	function hg.bots.SetModelInPool(mdl, on)
		if not hg.bots.IsAllowedModel(mdl) then return false end

		Pool()[string.lower(mdl)] = on and true or nil

		-- A JSON array: values survive util.JSONToTable as they are.
		file.Write(POOL_FILE, util.TableToJSON(hg.bots.ModelPool(), true))

		return true
	end

	local function RollFromPool()
		local list = {}

		for mdl in pairs(Pool()) do
			if hg.bots.IsAllowedModel(mdl) then list[#list + 1] = mdl end
		end

		if #list == 0 then return nil end

		return list[math.random(#list)]
	end
--//

--\\ Wearing it
	--- The model this bot should have right now, or nil to leave it be.
	local function Wanted(bot)
		return bot.hgBotModel or bot.hgBotPoolModel
	end

	--- Puts mdl on the bot. Z-City's own models go through its appearance
	-- code; anything else is set directly.
	function hg.bots.WearModel(bot, mdl)
		if not IsValid(bot) or not bot:Alive() then return false end

		local entry = Allowed()[string.lower(mdl or "")]

		if not entry then return false end

		local ap = hg.Appearance

		if entry.name and ap and ap.ForceApplyAppearance and ap.GetRandomAppearance then
			-- A random appearance of the same sex (clothes and faces are
			-- per sex), then the model swapped in.
			local tbl

			for _ = 1, 12 do
				tbl = ap.GetRandomAppearance()

				local cur = ap.PlayerModels[entry.sex] and ap.PlayerModels[entry.sex][tbl.AModel]

				if cur then break end
			end

			tbl.AModel = entry.name

			-- Keep the name the bot already goes by.
			if bot.hgBotName then
				tbl.AName = bot.hgBotName
			elseif bot.CurAppearance and isstring(bot.CurAppearance.AName) then
				tbl.AName = bot.CurAppearance.AName
			end

			local ok = pcall(ap.ForceApplyAppearance, bot, tbl)

			if ok then return true end
		end

		bot:SetModel(entry.mdl)
		bot:SetSubMaterial()
		bot:SetSkin(0)
		bot:SetBodyGroups("00000000000000000000")

		-- Z-City's hats and glasses are fitted to its own heads.
		if bot.SetNetVar then bot:SetNetVar("Accessories", {}) end

		return true
	end

	--- Name shown for this bot (Z-City's appearance name).
	local function EnforceName(bot)
		local name = bot.hgBotName

		if not name or bot:GetNWString("PlayerName", "") == name then return end

		bot:SetNWString("PlayerName", name)

		if istable(bot.CurAppearance) then bot.CurAppearance.AName = name end
	end

	local function Enforce(bot)
		EnforceName(bot)

		local mdl = Wanted(bot)

		if not mdl or not bot:Alive() or IsValid(bot.FakeRagdoll) then return end
		if string.lower(bot:GetModel() or "") == string.lower(mdl) then return end

		hg.bots.WearModel(bot, mdl)
	end

	-- New life: roll from the pool (sv_bot_core.lua fires this once per
	-- real spawn), then put it on once Z-City has dressed the bot.
	hook.Add("HG_BotNewLife", "HG_Bots_Model", function(bot)
		bot.hgBotPoolModel = hg_bot_model_mode:GetBool() and RollFromPool() or nil

		timer.Simple(0.5, function()
			if IsValid(bot) then Enforce(bot) end
		end)
	end)

	timer.Create("HG_Bots_ModelEnforce", 2, 0, function()
		for bot in pairs(hg.bots.List) do
			if IsValid(bot) then Enforce(bot) end
		end
	end)

	--- Per-bot choice; "" or nil goes back to the pool / Z-City default.
	function hg.bots.SetBotModel(bot, mdl)
		if not IsValid(bot) then return false end

		if not mdl or mdl == "" then
			bot.hgBotModel = nil

			-- Back to what it would have rolled.
			bot.hgBotPoolModel = hg_bot_model_mode:GetBool() and RollFromPool() or nil

			if bot.hgBotPoolModel then
				hg.bots.WearModel(bot, bot.hgBotPoolModel)
			elseif hg.Appearance and hg.Appearance.ForceApplyAppearance and hg.Appearance.GetRandomAppearance then
				pcall(hg.Appearance.ForceApplyAppearance, bot, hg.Appearance.GetRandomAppearance())
			end

			return true
		end

		if not hg.bots.IsAllowedModel(mdl) then return false end

		bot.hgBotModel = mdl

		return hg.bots.WearModel(bot, mdl)
	end

	--- Every bot alive rolls again from the pool (or goes back to Z-City's
	-- look when the pool is off or empty). Per-bot choices are kept.
	function hg.bots.RerollModels()
		local count = 0

		for bot in pairs(hg.bots.List) do
			if IsValid(bot) and bot:Alive() and not bot.hgBotModel then
				hg.bots.SetBotModel(bot, nil)
				count = count + 1
			end
		end

		return count
	end
--//

--\\ Names
	local NAMES_FILE = "hg_bots_names.json"
	local names

	local function Names()
		if names then return names end

		names = {}

		local raw = file.Read(NAMES_FILE, "DATA")
		local parsed = raw and util.JSONToTable(raw)

		if istable(parsed) then
			for _, name in ipairs(parsed) do
				if isstring(name) or isnumber(name) then names[#names + 1] = tostring(name) end
			end
		end

		return names
	end

	function hg.bots.NameList()
		return Names()
	end

	local function CleanName(name)
		name = string.Trim(tostring(name or ""))
		name = string.gsub(name, "[%c\"]", "")

		return string.sub(name, 1, 31)
	end

	function hg.bots.SetNameList(list)
		names = {}

		for _, name in ipairs(istable(list) and list or {}) do
			name = CleanName(name)

			if name ~= "" and #names < 500 then names[#names + 1] = name end
		end

		file.Write(NAMES_FILE, util.TableToJSON(names, true))

		return #names
	end

	--- A name from the list nobody alive is using yet (any if all are
	-- taken), or nil when the list is empty.
	function hg.bots.PickName()
		local list = Names()

		if #list == 0 then return nil end

		local used = {}

		for _, ply in ipairs(player.GetAll()) do
			used[ply:Nick()] = true

			if ply.hgBotName then used[ply.hgBotName] = true end
		end

		local free = {}

		for _, name in ipairs(list) do
			if not used[name] then free[#free + 1] = name end
		end

		local from = #free > 0 and free or list

		return from[math.random(#from)]
	end

	--- Rename one bot; "" goes back to what Z-City gave it.
	function hg.bots.SetBotName(bot, name)
		if not IsValid(bot) then return false end

		name = CleanName(name)

		bot.hgBotName = name ~= "" and name or nil

		EnforceName(bot)

		return true
	end
--//
