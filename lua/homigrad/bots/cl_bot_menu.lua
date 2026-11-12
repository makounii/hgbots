--[[
	HGBots - Settings menu: state, net, Q menu, bot right-click, name tags

	The menu is split over five client files (the 64 KB client-file
	limit and the 200-locals-per-chunk limit both ask for it):

	  cl_bot_menu.lua          this one: synced values, kits, net messages,
	                           the Q menu pages, the right-click bot menu,
	                           the name tags, the commands that open things
	  cl_bot_term.lua          the terminal look: palette, fonts, sounds,
	                           widgets (buttons, toggles, sliders, lists)
	  cl_bot_term_art.lua      male07 in ASCII, over crossed bones
	  cl_bot_term_pages.lua    every page of the terminal window
	  cl_bot_term_window.lua   the window itself, boot screen, sidebar, CRT

	Ways in: the "HGBots" icon in the C menu, Utilities -> HGBots in the
	Q menu, hg_bot_menu (or !bots in chat - the Z-City gamemode has no C/Q
	menu), and right-click on a bot (hg_bot_menu_target does that for the
	bot in the crosshair).

	Values come from the server (the parameters are server convars). The
	window is built from the last sync and asks for a fresh one when it
	opens. Changes go out after a short delay so dragging a slider does not
	send one message per pixel. Everything shared between the files lives in
	hg.bots.Menu (M below) so a hot reload of one file keeps the rest.
]]

hg = hg or {}
hg.bots = hg.bots or {}

-- Load order isn't guaranteed (the client may include this before the
-- shared catalogue), so the net names are re-stated here as defaults.
hg.bots.NetSync = hg.bots.NetSync or "hg_bot_cfg_sync"
hg.bots.NetReq = hg.bots.NetReq or "hg_bot_cfg_req"
hg.bots.NetSet = hg.bots.NetSet or "hg_bot_cfg_set"
hg.bots.NetAct = hg.bots.NetAct or "hg_bot_cfg_act"
hg.bots.NetMsg = hg.bots.NetMsg or "hg_bot_cfg_msg"
hg.bots.NetKits = hg.bots.NetKits or "hg_bot_cfg_kits"

local M = hg.bots.Menu or {}
hg.bots.Menu = M

local L = function(key) return hg.bots.L and hg.bots.L(key) or key end

M.L = L

--\\ Synced state
	M.values = M.values or {}       -- [convar] = number
	M.bounds = M.bounds or {}       -- [convar] = { min, max, help, default }
	M.listeners = M.listeners or {} -- [panel] = refresh function
	M.kits = M.kits or {}           -- saved gear preset names
	M.catalog = M.catalog or {}     -- [category] = { {class, name, ammo, clip, slot}, ... }
	M.banned = M.banned or {}       -- [class / armour] = true: off for random kits
	M.modelPool = M.modelPool or {} -- [lower-case model] = true
	M.botNames = M.botNames or {}
	M.voicePacks = M.voicePacks or {}
	M.history = M.history or {}     -- undo: { {name, old}, ... }
	M.log = M.log or {}             -- terminal log: { {t, text, kind}, ... }
	M.isAdmin = M.isAdmin or false
	M.isSuper = M.isSuper or false
	M.synced = M.synced or false

	function M.Request()
		net.Start(hg.bots.NetReq)
		net.SendToServer()
	end

	hg.bots.RequestSettings = M.Request

	function M.Notify()
		-- A listener may rebuild its page, which adds a new listener: walk
		-- a copy, never the table being changed.
		local list = {}

		for panel, refresh in pairs(M.listeners) do list[#list + 1] = { panel, refresh } end

		for _, entry in ipairs(list) do
			if IsValid(entry[1]) then
				if M.listeners[entry[1]] == entry[2] then entry[2]() end
			else
				M.listeners[entry[1]] = nil
			end
		end
	end

	--- Run `fn` whenever the server sends anything, for as long as `panel` lives.
	function M.Listen(panel, fn)
		M.listeners[panel] = fn
	end

	--- One line in the terminal's log (and in chat when the terminal is shut).
	function M.Log(text, kind)
		local log = M.log

		log[#log + 1] = { t = RealTime(), clock = os.date("%H:%M:%S"), text = tostring(text), kind = kind or "info" }

		while #log > 60 do table.remove(log, 1) end

		local open = IsValid(hg.bots.MenuFrame)
		local chatToo = GetConVar("hg_bot_ui_chat")

		if not open or (chatToo and chatToo:GetBool()) then
			local col = kind == "error" and Color(255, 120, 120) or Color(150, 200, 255)

			chat.AddText(col, "[HGBots] ", color_white, tostring(text))
		end

		hook.Run("HG_BotMenuLog", text, kind)
	end

	net.Receive(hg.bots.NetSync, function()
		M.isAdmin = net.ReadBool()
		M.isSuper = net.ReadBool()

		local count = net.ReadUInt(16)

		-- A full sync (everything at once) tells us which parameters this
		-- server actually has; a single-value broadcast does not.
		if count > 1 then
			M.synced = true
			M.syncedAt = RealTime()
		end

		for _ = 1, count do
			local name = net.ReadString()

			M.values[name] = net.ReadFloat()
			M.bounds[name] = { net.ReadFloat(), net.ReadFloat(), net.ReadString(), net.ReadFloat() }
		end

		M.Notify()
	end)

	net.Receive(hg.bots.NetMsg, function()
		local key = net.ReadString()
		local extra = net.ReadString()

		if key == "raw" then
			M.Log(extra, "info")
		elseif key == "applied" then
			M.Log(string.format(L("applied"), extra), "ok")
		else
			M.Log(L(key), "error")
		end
	end)

	net.Receive(hg.bots.NetKits, function()
		local len = net.ReadUInt(24)
		local raw = util.Decompress(net.ReadData(len) or "") or ""
		local payload = util.JSONToTable(raw)

		if not istable(payload) then return end

		M.kits = istable(payload.names) and payload.names or M.kits

		if istable(payload.catalog) then M.catalog = payload.catalog end

		if istable(payload.blacklist) then
			M.banned = {}

			for _, name in pairs(payload.blacklist) do M.banned[tostring(name)] = true end
		end

		if istable(payload.botNames) then M.botNames = payload.botNames end
		if istable(payload.voicePacks) then M.voicePacks = payload.voicePacks end

		if istable(payload.modelPool) then
			M.modelPool = {}

			for _, mdl in pairs(payload.modelPool) do M.modelPool[string.lower(tostring(mdl))] = true end
		end

		if istable(payload.kit) then
			M.incoming = { name = payload.kitName or "", kit = payload.kit }
		end

		M.Notify()
	end)
--//

--\\ Changing things
	local pending = M.pending or {}

	M.pending = pending

	local function Send(name)
		if pending[name] == nil then return end

		net.Start(hg.bots.NetSet)
		net.WriteString(name)
		net.WriteFloat(pending[name])
		net.SendToServer()

		pending[name] = nil
	end

	--- Set one parameter on the server.
	-- HARD GATE. Before the first sync a control has no real bounds, so a
	-- slider would clamp its number into 0..1 and send that junk back -
	-- opening the menu once used to drive ~every parameter to its minimum
	-- (sight range 100, FOV 10, hearing 0) and the save file kept it.
	-- Nothing is ever sent for a parameter the server has not described.
	-- @param noUndo true when the change comes from undo itself
	-- @param drag true for a slider being dragged / wheeled: those fold
	--   into one undo step; a typed value or a reset is always its own
	function M.Set(name, value, noUndo, drag)
		local b = M.bounds[name]

		if not M.synced or not b then return false end

		value = tonumber(value) or 0
		value = math.Clamp(value, b[1] or value, b[2] or value)

		local old = M.values[name]

		if old ~= nil and math.abs(old - value) < 0.00001 then return false end

		-- One undo step per drag, not one per pixel: a drag of the same
		-- parameter within a second folds into the drag step on top.
		if not noUndo and old ~= nil then
			local top = M.history[#M.history]

			if drag and top and top.drag and top.name == name and RealTime() - top.t < 1 then
				top.t = RealTime()
			else
				M.history[#M.history + 1] = { name = name, old = old, t = RealTime(), drag = drag }

				if #M.history > 100 then table.remove(M.history, 1) end
			end
		end

		M.values[name] = value
		pending[name] = value

		timer.Create("hg_bot_cfg_" .. name, 0.25, 1, function() Send(name) end)

		return true
	end

	--- What an undo step is about, for the log.
	function M.StepLabel(step)
		if not step then return "" end

		if step.batch then return string.format(L("term.batch"), table.Count(step.batch)) end

		return hg.bots.LSetting and hg.bots.LSetting(step.name) or step.name
	end

	--- Put the last change back. Returns what was undone (text), or nil.
	function M.Undo()
		local step = table.remove(M.history)

		if not step then return nil end

		if step.batch then
			M.SetMany(step.batch, true)
		else
			M.Set(step.name, step.old, true)
			M.Notify()
		end

		return M.StepLabel(step)
	end

	--- Many parameters at once ({ [name] = value }), sent a few per tick
	-- so a whole profile doesn't arrive as hundreds of messages in one go.
	-- The lot is one undo step. Returns how many of them this player may
	-- change and the server has.
	function M.SetMany(tbl, noUndo)
		local queue, before = {}, {}

		for name, value in pairs(tbl) do
			local info = hg.bots.SettingIndex and hg.bots.SettingIndex[name]

			if info and M.bounds[name] and M.MayEdit(info.level) and isnumber(tonumber(value)) then
				queue[#queue + 1] = { name, tonumber(value) }
				before[name] = M.values[name]
			end
		end

		if #queue == 0 then return 0 end

		table.sort(queue, function(a, b) return a[1] < b[1] end)

		if not noUndo then
			M.history[#M.history + 1] = { batch = before, t = RealTime() }

			if #M.history > 100 then table.remove(M.history, 1) end
		end

		local i = 0

		M.bulkId = (M.bulkId or 0) + 1

		timer.Create("hg_bot_cfg_bulk" .. M.bulkId, 0.05, math.ceil(#queue / 12), function()
			for _ = 1, 12 do
				i = i + 1

				local item = queue[i]

				if not item then break end

				M.Set(item[1], item[2], true)
			end

			M.Notify()
		end)

		return #queue
	end

	function M.Act(action, ent, arg)
		net.Start(hg.bots.NetAct)
		net.WriteString(action)
		net.WriteEntity(ent or NULL)
		net.WriteString(arg or "")
		net.SendToServer()
	end

	hg.bots.MenuAct = M.Act

	function M.MayEdit(level)
		if level == "superadmin" then return M.isSuper end

		return M.isAdmin
	end

	function M.Default(name)
		local b = M.bounds[name]

		return b and b[4]
	end

	--- Is this parameter away from the server's default?
	function M.Changed(name)
		local b, v = M.bounds[name], M.values[name]

		return b ~= nil and v ~= nil and b[4] ~= nil and math.abs(v - b[4]) > 0.0001
	end

	--- How many parameters of a group are away from their defaults.
	function M.GroupChanged(group)
		local n = 0

		for _, name in ipairs(group.keys) do
			if M.Changed(name) then n = n + 1 end
		end

		return n
	end

	--- Every catalogued parameter in group order, as { name, info, group }.
	function M.AllSettings()
		local out = {}

		for _, group in ipairs(hg.bots.SettingGroups or {}) do
			for _, name in ipairs(group.keys) do
				local info = hg.bots.SettingIndex and hg.bots.SettingIndex[name]

				if info then out[#out + 1] = { name = name, info = info, group = group } end
			end
		end

		return out
	end
--//

--\\ Q menu (Utilities -> HGBots), drawn on Garry's light background
	local LIGHT = Color(0, 0, 0)

	local function QText(panel)
		if panel.SetTextColor then panel:SetTextColor(LIGHT) end
		if IsValid(panel.Label) and panel.Label.SetTextColor then panel.Label:SetTextColor(LIGHT) end
	end

	local function QButton(panel, text, fn)
		local b = vgui.Create("DButton", panel)

		b:SetText(text)
		b:SetTall(24)
		b.DoClick = fn

		panel:AddItem(b)

		return b
	end

	local function QRow(panel, name, info)
		local b = M.bounds[name] or { 0, 1, "", 0 }
		local row

		if info.choices then
			row = vgui.Create("DComboBox", panel)

			for index, key in ipairs(info.choices) do row:AddChoice(L(key), index - 1) end

			row.OnSelect = function(self, _, _, value)
				if not self.Updating then M.Set(name, value) end
			end

			row.Refresh = function(self)
				self.Updating = true
				self:ChooseOptionID(math.floor(M.values[name] or 0) + 1)
				self.Updating = nil
			end

			local label = vgui.Create("DLabel", panel)

			label:SetText(hg.bots.LSetting(name))
			QText(label)
			panel:AddItem(label)
		elseif info.bool then
			row = vgui.Create("DCheckBoxLabel", panel)
			row:SetText(hg.bots.LSetting(name))

			row.OnChange = function(self, val)
				if not self.Updating then M.Set(name, val and 1 or 0) end
			end

			row.Refresh = function(self)
				self.Updating = true
				self:SetValue((M.values[name] or 0) >= 0.5)
				self.Updating = nil
			end
		else
			row = vgui.Create("DNumSlider", panel)
			row:SetText(hg.bots.LSetting(name))
			row:SetMinMax(b[1] or 0, b[2] or 1)
			row:SetDecimals((b[2] or 1) > 20 and 0 or 2)

			row.OnValueChanged = function(self, val)
				if self.Updating or not M.bounds[name] then return end
				if math.abs((M.values[name] or 0) - val) > 0.0001 then M.Set(name, val) end
			end

			row.Refresh = function(self)
				self.Updating = true

				local bb = M.bounds[name]

				if bb then
					self:SetMinMax(bb[1] or 0, bb[2] or 1)
					self:SetDecimals((bb[2] or 1) > 20 and 0 or 2)
				end

				self:SetValue(M.values[name] or 0)
				self.Updating = nil
			end
		end

		QText(row)
		row:Refresh()

		row.ApplyRights = function(self)
			if M.synced and not M.bounds[name] then self:SetVisible(false) return end

			local ok = M.MayEdit(info.level)
			local help = (M.bounds[name] or {})[3] or ""

			self:SetVisible(true)
			self:SetEnabled(ok)
			self:SetTooltip(ok and (name .. (help ~= "" and ("\n" .. help) or ""))
				or L(info.level == "superadmin" and "need.superadmin" or "need.admin"))
		end

		row:ApplyRights()
		panel:AddItem(row)

		return row
	end

	local function QGroup(panel, groupId)
		local group

		for _, g in ipairs(hg.bots.SettingGroups or {}) do
			if g.id == groupId then group = g break end
		end

		if not group then return end

		local rows = {}

		for _, name in ipairs(group.keys) do
			local info = hg.bots.SettingIndex[name]

			if info then rows[#rows + 1] = QRow(panel, name, info) end
		end

		QButton(panel, L("reset.group"), function()
			for _, name in ipairs(group.keys) do
				local info = hg.bots.SettingIndex[name]

				if info and M.Default(name) and M.MayEdit(info.level) then M.Set(name, M.Default(name)) end
			end

			timer.Simple(0.4, M.Request)
		end)

		M.Listen(panel, function()
			for _, row in ipairs(rows) do
				if IsValid(row) then row:Refresh() row:ApplyRights() end
			end
		end)

		M.Request()
	end

	hook.Add("PopulateToolMenu", "HG_Bots_ToolMenu", function()
		spawnmenu.AddToolMenuOption("Utilities", L("title"), "hg_bot_actions", L("actions"), "", "", function(panel)
			panel:ClearControls()

			QButton(panel, L("term.open"), function() hg.bots.OpenMenu() end)

			for _, act in ipairs({ "spawn", "spawn_random", "spawn_guard", "spawn_neutral", "removeall", "cleanup_now",
				"director_on", "director_off", "director_place", "director_status", "director_clear" }) do
				QButton(panel, L("act." .. act), function() M.Act(act) end)
			end
		end)

		for _, group in ipairs(hg.bots.SettingGroups or {}) do
			spawnmenu.AddToolMenuOption("Utilities", L("title"), "hg_bot_" .. group.id, L("group." .. group.id), "", "", function(panel)
				panel:ClearControls()

				QGroup(panel, group.id)
			end)
		end
	end)
--//

--\\ Ways into the terminal
	concommand.Add("hg_bot_menu", function(_, _, args)
		if hg.bots.OpenMenu then hg.bots.OpenMenu(args and args[1]) end
	end, nil, "Open the HGBots terminal (optional: a page id, e.g. combat, status, kits)")

	function hg.bots.OpenDirectorMenu()
		if hg.bots.OpenMenu then return hg.bots.OpenMenu("director") end
	end

	concommand.Add("hg_bot_director_menu", function() hg.bots.OpenDirectorMenu() end)

	-- C menu: the icon row of the context menu.
	--
	-- Sandbox makes a window for every icon BEFORE calling init
	-- (contextmenu.lua: Window:SetSize(newv.width, newv.height)); without
	-- width/height that SetSize errored and the click did nothing at all.
	-- The empty window it makes is thrown away and the real one opens on
	-- its own, so it stays up after C is let go.
	list.Set("DesktopWindows", "HGBotSettings", {
		title = "HGBots", -- fixed: the menu list is built at load time
		-- male07 from the terminal's own art (build\icon.ps1); a stock icon if
		-- the picture is missing (icon64/settings.png isn't on every install)
		icon = file.Exists("materials/hgbots/icon64.png", "GAME") and "hgbots/icon64.png" or "icon64/tool.png",
		width = 960,
		height = 680,
		onewindow = true,
		init = function(icon, window)
			if IsValid(window) then window:Remove() end

			hg.bots.OpenMenu()
		end,
	})

	-- The Z-City gamemode itself (base, not sandbox) has no C or Q menu,
	-- so there the chat is the way in.
	local CHAT_OPEN = { ["!bots"] = true, ["/bots"] = true, ["!botmenu"] = true, ["/botmenu"] = true, ["!hgbots"] = true }

	hook.Add("OnPlayerChat", "HG_Bots_ChatMenu", function(ply, text)
		if ply ~= LocalPlayer() or not isstring(text) then return end
		if not CHAT_OPEN[string.lower(string.Trim(text))] then return end

		hg.bots.OpenMenu()

		return true
	end)
--//

--\\ Right-click on a bot
	--[[
		One entry instead of six. The C menu's property list is flat, so a
		handful of "HGBots: ..." lines pushed everything else off the screen
		and still had no room for kits or orders. The single entry opens a
		proper menu at the cursor with everything grouped:

		  Info        what it is doing right now, and the name tag overlay
		  Faction     raider / guard / neutral
		  Gear        any saved kit, a rolled one, or strip it
		  Orders      come here, hold here, follow me, stop
		  Control     re-initialize, freeze the AI, teleport, remove

		Entries appear only if the player has the rights for them.
	]]

	-- A downed bot is a Z-City ragdoll: the right click lands on the
	-- prop_ragdoll, not on the player, so the ragdoll is traced back to
	-- the bot lying in it.
	local function BotOf(ent)
		if not IsValid(ent) then return nil end

		if ent:IsPlayer() then
			return ent:GetNWBool("hg_bot", false) and ent or nil
		end

		if ent:GetClass() ~= "prop_ragdoll" then return nil end

		local owner = hg.RagdollOwner and hg.RagdollOwner(ent)

		if not IsValid(owner) then
			local ply = ent:GetNWEntity("ply")

			owner = IsValid(ply) and ply:GetNWEntity("FakeRagdoll") == ent and ply or nil
		end

		if IsValid(owner) and owner:IsPlayer() and owner:Alive() and owner:GetNWBool("hg_bot", false) then return owner end

		return nil
	end

	M.BotOf = BotOf

	local function BotEntFor(ent, ply, super)
		if not BotOf(ent) then return false end
		if not IsValid(ply) then return false end

		return super and ply:IsSuperAdmin() or (not super and ply:IsAdmin())
	end

	--- Where the player is looking, as a string the server can read back.
	local function AimString()
		local ply = LocalPlayer()

		if not IsValid(ply) then return "" end

		local pos = ply:GetEyeTrace().HitPos

		return ("%d %d %d"):format(pos.x, pos.y, pos.z)
	end

	local overlay = CreateClientConVar("hg_bot_overlay", "0", true, false,
		"Draw a name tag over every bot with its state, faction and target")
	local overlayRange = CreateClientConVar("hg_bot_overlay_range", "1600", true, false,
		"How far away bot name tags are drawn", 200, 10000)

	local function BotMenu(ent)
		ent = BotOf(ent)

		if not ent then return end

		-- Kits and voice packs for the submenus, fresh for next time.
		M.Request()

		local ply = LocalPlayer()
		local admin = BotEntFor(ent, ply, false)
		local super = BotEntFor(ent, ply, true)

		if not admin and not super then return end

		local menu = DermaMenu()

		menu:SetMinimumWidth(210)

		menu:AddOption(ent:Nick() .. "  (" .. ent:GetNWString("hg_bot_faction", "raider") .. ")", function() end)
			:SetIcon("icon16/user_gray.png")
		menu:AddSpacer()

		-- Info
		menu:AddOption(L("ctx.state"), function() M.Act("state", ent) end):SetIcon("icon16/information.png")

		menu:AddOption(L("ctx.overlay"), function()
			RunConsoleCommand("hg_bot_overlay", overlay:GetBool() and "0" or "1")
		end):SetIcon(overlay:GetBool() and "icon16/eye.png" or "icon16/lightbulb_off.png")

		if super then
			local sub, parent = menu:AddSubMenu(L("ctx.faction"))

			parent:SetIcon("icon16/shield.png")

			sub:AddOption(L("ctx.faction.raider"), function() M.Act("faction", ent, "raider") end):SetIcon("icon16/user_red.png")
			sub:AddOption(L("ctx.faction.guard"), function() M.Act("faction", ent, "guard") end):SetIcon("icon16/user_green.png")
			sub:AddOption(L("ctx.faction.neutral"), function() M.Act("faction", ent, "neutral") end):SetIcon("icon16/user_orange.png")

			local gear, gparent = menu:AddSubMenu(L("ctx.gear"))

			gparent:SetIcon("icon16/briefcase.png")

			gear:AddOption(L("ctx.gear.random"), function() M.Act("kit_apply", ent, "random") end):SetIcon("icon16/arrow_refresh.png")
			gear:AddOption(L("ctx.gear.strip"), function() M.Act("kit_apply", ent, "strip") end):SetIcon("icon16/cross.png")

			if #M.kits > 0 then
				gear:AddSpacer()

				for _, name in ipairs(M.kits) do
					gear:AddOption(name, function() M.Act("kit_apply", ent, name) end):SetIcon("icon16/box.png")
				end
			end
		end

		if admin then
			local msub, mparent = menu:AddSubMenu(L("ctx.model"))

			mparent:SetIcon("icon16/user_suit.png")

			msub:AddOption(L("ctx.model.pick"), function()
				if hg.bots.OpenModelPicker then hg.bots.OpenModelPicker(ent) end
			end):SetIcon("icon16/application_view_icons.png")
			msub:AddOption(L("models.default"), function() M.Act("model_set", ent, "") end):SetIcon("icon16/arrow_undo.png")

			menu:AddOption(L("ctx.rename"), function()
				Derma_StringRequest(L("ctx.rename"), L("ctx.rename.help"), ent:GetNWString("PlayerName", ent:Nick()),
					function(text) if IsValid(ent) then M.Act("name_set", ent, text) end end)
			end):SetIcon("icon16/textfield_rename.png")

			local vsub, vparent = menu:AddSubMenu(L("ctx.voice"))

			vparent:SetIcon("icon16/sound.png")

			vsub:AddOption(L("ctx.voice.auto"), function() M.Act("voice_set", ent, "") end):SetIcon("icon16/arrow_refresh.png")

			if #M.voicePacks > 0 then vsub:AddSpacer() end

			for _, pack in ipairs(M.voicePacks) do
				vsub:AddOption(tostring(pack.name), function() M.Act("voice_set", ent, tostring(pack.name)) end)
					:SetIcon(pack.on and "icon16/sound.png" or "icon16/sound_mute.png")
			end
		end

		-- Orders
		local sub, parent = menu:AddSubMenu(L("ctx.orders"))

		parent:SetIcon("icon16/flag_blue.png")

		sub:AddOption(L("ctx.order.come"), function() M.Act("order_move", ent, AimString()) end):SetIcon("icon16/arrow_right.png")
		sub:AddOption(L("ctx.order.hold"), function() M.Act("order_hold", ent, AimString()) end):SetIcon("icon16/anchor.png")
		sub:AddOption(L("ctx.order.follow"), function() M.Act("order_follow", ent) end):SetIcon("icon16/user_go.png")
		sub:AddOption(L("ctx.order.stop"), function() M.Act("order_stop", ent) end):SetIcon("icon16/stop.png")

		-- Control
		menu:AddSpacer()
		menu:AddOption(L("act.reinit"), function() M.Act("reinit", ent) end):SetIcon("icon16/arrow_refresh.png")
		menu:AddOption(L("ctx.freeze"), function() M.Act("enable", ent) end):SetIcon("icon16/control_pause_blue.png")

		if super then
			menu:AddOption(L("ctx.teleport"), function() M.Act("teleport", ent) end):SetIcon("icon16/arrow_down.png")
			menu:AddOption(L("ctx.remove"), function() M.Act("remove", ent) end):SetIcon("icon16/delete.png")
		end

		menu:AddSpacer()
		menu:AddOption(L("term.open"), function() hg.bots.OpenMenu() end):SetIcon("icon16/application_xp_terminal.png")

		if hg.bots.Term and hg.bots.Term.SkinMenu then hg.bots.Term.SkinMenu(menu) end

		menu:Open()

		return menu
	end

	hg.bots.OpenBotMenu = BotMenu

	-- The same menu without the C menu (Z-City gamemode, or just a bind):
	-- for the bot (or the downed bot's body) under the crosshair.
	concommand.Add("hg_bot_menu_target", function()
		local ply = LocalPlayer()

		if not IsValid(ply) then return end

		local bot = BotOf(ply:GetEyeTrace().Entity)

		if not bot then return end

		gui.EnableScreenClicker(true)

		local menu = BotMenu(bot)

		-- Hand the cursor back once the menu is gone.
		timer.Create("hg_bot_menu_target", 0.2, 0, function()
			if IsValid(menu) and menu:IsVisible() then return end

			timer.Remove("hg_bot_menu_target")

			if not IsValid(hg.bots.MenuFrame) then gui.EnableScreenClicker(false) end
		end)
	end, nil, "Open the bot menu for the bot you're looking at")

	properties.Add("hg_bot_menu", {
		MenuLabel = "HGBots",
		Order = 4001,
		MenuIcon = "icon16/user_gray.png",
		Filter = function(self, ent, ply) return BotEntFor(ent, ply, false) end,
		Action = function(self, ent)
			-- The property list closes itself on click, so the menu is
			-- opened one frame later or it lands underneath.
			timer.Simple(0, function()
				if IsValid(ent) then BotMenu(ent) end
			end)
		end,
		Receive = function() end,
	})
--//

--\\ Name tags over bots
	-- What a bot is doing, drawn over its head: the quickest way to see why
	-- one is behaving oddly without opening anything. The state and faction
	-- come from networked strings the server keeps up to date on change.
	local TAG_UP = Vector(0, 0, 12)
	local COL_GUARD, COL_NEUTRAL, COL_RAIDER = Color(120, 220, 140), Color(235, 215, 120), Color(240, 150, 150)
	local COL_STATE = Color(210, 210, 215)

	-- Which players are bots is looked up twice a second, not on every
	-- frame: the frame only draws the ones already known to be bots.
	local tagged, nextTagScan = {}, 0

	local function PaintTags()
		local me = LocalPlayer()

		if not IsValid(me) then return end

		local eye = me:EyePos()
		local now = RealTime()
		local range = overlayRange:GetFloat()

		if now >= nextTagScan then
			nextTagScan = now + 0.5
			tagged = {}

			for _, ply in ipairs(player.GetAll()) do
				if ply ~= me and ply:GetNWBool("hg_bot", false) then tagged[#tagged + 1] = ply end
			end
		end

		for i = 1, #tagged do
			local ply = tagged[i]

			if IsValid(ply) and ply:Alive() then
				local pos = ply:EyePos() + TAG_UP
				local d2 = eye:DistToSqr(pos)

				if d2 < range * range then
					local screen = pos:ToScreen()

					if screen.visible then
						local faction = ply:GetNWString("hg_bot_faction", "raider")
						local state = ply:GetNWString("hg_bot_state", "?")
						local col = faction == "guard" and COL_GUARD or faction == "neutral" and COL_NEUTRAL or COL_RAIDER

						draw.SimpleTextOutlined(ply:Nick(), "DermaDefault", screen.x, screen.y, col,
							TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
						draw.SimpleTextOutlined(("%s  %.0f u"):format(state, math.sqrt(d2)), "DermaDefault", screen.x, screen.y + 13,
							COL_STATE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
					end
				end
			end
		end
	end

	-- The hook exists only while the name tags are on: with them off (the
	-- default) nothing of this add-on runs per frame on a client at all.
	local function SetTagHook()
		if overlay:GetBool() then
			hook.Add("HUDPaint", "HG_Bots_Overlay", PaintTags)
		else
			hook.Remove("HUDPaint", "HG_Bots_Overlay")
		end
	end

	cvars.AddChangeCallback(overlay:GetName(), SetTagHook, "HG_Bots_Overlay")
	SetTagHook()
--//
