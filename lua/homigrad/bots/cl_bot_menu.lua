--[[
	Tarkov AI - Settings menu (client side)

	Two ways in, both showing the same pages:
	- C menu: the "Tarkov AI Bots" icon among the context-menu windows;
	- Q menu: Utilities -> Tarkov AI, one page per group.
	Plus the client command hg_bot_menu (or !bots in chat - the Z-City
	gamemode has no C/Q menu at all), and right-click entries on a bot
	(hg_bot_menu_target opens the same thing for the bot in the crosshair).

	The window is its own dark panel with a category list down the left,
	a search box that looks through every parameter at once, and a gear
	page that builds kits item by item from what the server actually has.
	The Q menu pages sit on Garry's light background instead, so those
	are drawn in black - hence the two palettes below.

	Values come from the server (the parameters are server convars), so the
	panel is built from the last sync and asks for a fresh one whenever it
	opens. Changes are sent with a short delay so dragging a slider doesn't
	flood the server with one message per pixel.
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

local L = function(key) return hg.bots.L and hg.bots.L(key) or key end

--\\ Synced values
	local values = {}
	local bounds = {} -- [name] = { min, max, help, default }
	local isAdmin, isSuper = false, false
	local listeners = {}
	local synced = false

	local function RequestValues()
		net.Start(hg.bots.NetReq)
		net.SendToServer()
	end

	hg.bots.RequestSettings = RequestValues

	local function Notify()
		for panel, refresh in pairs(listeners) do
			if IsValid(panel) then refresh() else listeners[panel] = nil end
		end
	end

	net.Receive(hg.bots.NetSync, function()
		isAdmin = net.ReadBool()
		isSuper = net.ReadBool()

		local count = net.ReadUInt(16)

		-- A full sync (everything at once) tells us which parameters this
		-- server actually has; a single-value broadcast does not.
		if count > 1 then synced = true end

		for _ = 1, count do
			local name = net.ReadString()

			values[name] = net.ReadFloat()
			bounds[name] = { net.ReadFloat(), net.ReadFloat(), net.ReadString(), net.ReadFloat() }
		end

		Notify()
	end)

	net.Receive(hg.bots.NetMsg, function()
		local key = net.ReadString()
		local extra = net.ReadString()

		if key == "raw" then
			chat.AddText(Color(150, 200, 255), "[hg.bots] ", color_white, extra)
		elseif key == "applied" then
			chat.AddText(Color(150, 200, 255), "[hg.bots] ", color_white, string.format(L("applied"), extra))
		else
			chat.AddText(Color(255, 120, 120), "[hg.bots] ", color_white, L(key))
		end
	end)

	-- Saved gear presets and the server's gear catalogue.
	local kits = {}
	local catalog = {}
	local banned = {} -- [class or armour name] = true: off for random kits
	local modelPool = {} -- [lower-case model path] = true: ticked on "Bot models"
	local botNames = {} -- the name list new bots take their names from
	local voicePacks = {} -- { {name, lines, sex, on, builtin}, ... }
	local incoming -- the last kit the server sent back, for the builder

	net.Receive(hg.bots.NetKits, function()
		local len = net.ReadUInt(24)
		local raw = util.Decompress(net.ReadData(len) or "") or ""
		local payload = util.JSONToTable(raw)

		if not istable(payload) then return end

		kits = istable(payload.names) and payload.names or kits

		if istable(payload.catalog) then catalog = payload.catalog end

		if istable(payload.blacklist) then
			banned = {}

			for _, name in pairs(payload.blacklist) do banned[tostring(name)] = true end
		end

		if istable(payload.botNames) then botNames = payload.botNames end
		if istable(payload.voicePacks) then voicePacks = payload.voicePacks end

		if istable(payload.modelPool) then
			modelPool = {}

			for _, mdl in pairs(payload.modelPool) do modelPool[string.lower(tostring(mdl))] = true end
		end

		if istable(payload.kit) then
			incoming = { name = payload.kitName or "", kit = payload.kit }
		end

		Notify()
	end)

	local pending = {}

	local function SetValue(name, value)
		-- HARD GATE. Before the first sync a slider has no real bounds, so
		-- SetValue() on it clamps the number into 0..1, which fires
		-- OnValueChanged, which used to send that clamped junk to the
		-- server. Opening the menu once therefore drove ~every parameter to
		-- its minimum (sight range 100, FOV 10, hearing 0 - bots that see
		-- and hear nothing) and the persistence file saved it. Nothing is
		-- ever sent for a parameter the server has not described.
		if not synced or not bounds[name] then return end

		values[name] = value
		pending[name] = value

		timer.Create("hg_bot_cfg_" .. name, 0.25, 1, function()
			if pending[name] == nil then return end

			net.Start(hg.bots.NetSet)
			net.WriteString(name)
			net.WriteFloat(pending[name])
			net.SendToServer()

			pending[name] = nil
		end)
	end

	local function Act(action, ent, arg)
		net.Start(hg.bots.NetAct)
		net.WriteString(action)
		net.WriteEntity(ent or NULL)
		net.WriteString(arg or "")
		net.SendToServer()
	end

	hg.bots.MenuAct = Act

	local function MayEdit(level)
		if level == "superadmin" then return isSuper end

		return isAdmin
	end
--//

--\\ Look
	local DARK = {
		bg = Color(28, 30, 34),
		panel = Color(38, 41, 46),
		row = Color(46, 50, 56),
		accent = Color(96, 160, 220),
		text = Color(225, 228, 232),
		dim = Color(150, 156, 164),
	}

	-- Q menu pages sit on the light spawnmenu background.
	local LIGHT_TEXT = Color(0, 0, 0)

	--- Text colour for controls built into `dark` or light surroundings.
	local function Paint(panel, dark)
		if not IsValid(panel) then return end

		local col = dark and DARK.text or LIGHT_TEXT

		if panel.SetTextColor then panel:SetTextColor(col) end
		if IsValid(panel.Label) and panel.Label.SetTextColor then panel.Label:SetTextColor(col) end
		if IsValid(panel.lblTitle) and panel.lblTitle.SetTextColor then panel.lblTitle:SetTextColor(col) end
	end

	local function Flat(panel, col, hover)
		panel.Paint = function(self, w, h)
			local c = col

			if hover and self:IsHovered() then c = hover end

			draw.RoundedBox(4, 0, 0, w, h, c)
		end
	end

	local function Button(parent, text, dark, fn)
		local b = vgui.Create("DButton", parent)

		b:SetText(text)
		b:Dock(TOP)
		b:DockMargin(4, 2, 4, 2)
		b:SetTall(26)
		b.DoClick = fn

		if dark then
			Flat(b, DARK.row, DARK.accent)
		end

		Paint(b, dark)

		if parent.AddItem then parent:AddItem(b) end

		return b
	end
--//

--\\ Setting rows
	--- One parameter as a control, with its own refresh/rights hooks.
	-- @param dark whether it is drawn on the dark window or the Q menu
	local function BuildRow(panel, name, info, dark)
		local bound = bounds[name] or { 0, 1, "", 0 }
		local row

		if info.bool then
			row = vgui.Create("DCheckBoxLabel", panel)
			row:SetText(hg.bots.LSetting(name))

			row.Updating = true
			row:SetValue((values[name] or 0) >= 0.5)
			row.Updating = nil

			row.OnChange = function(self, val)
				-- Refresh() writes the synced value back into the box;
				-- that must not bounce straight back to the server.
				if self.Updating or not bounds[name] then return end

				SetValue(name, val and 1 or 0)
			end

			row.Refresh = function(self)
				self.Updating = true
				self:SetValue((values[name] or 0) >= 0.5)
				self.Updating = nil
			end
		else
			row = vgui.Create("DNumSlider", panel)
			row:SetText(hg.bots.LSetting(name))
			row:SetMinMax(bound[1] or 0, bound[2] or 1)
			row:SetDecimals((bound[2] or 1) > 20 and 0 or 2)

			row.Updating = true
			row:SetValue(values[name] or 0)
			row.Updating = nil

			row.OnValueChanged = function(self, val)
				if self.Updating or not bounds[name] then return end
				if math.abs((values[name] or 0) - val) > 0.0001 then SetValue(name, val) end
			end

			row.Refresh = function(self)
				local b = bounds[name]

				if b then
					self:SetMinMax(b[1] or 0, b[2] or 1)
					self:SetDecimals((b[2] or 1) > 20 and 0 or 2)
				end

				self.Updating = true
				self:SetValue(values[name] or 0)
				self.Updating = nil
			end
		end

		row:Dock(TOP)
		row:DockMargin(4, 2, 4, 2)

		Paint(row, dark)

		-- Right click on any part of the control puts it back to the
		-- server's default (sent along with the value). A DNumSlider and a
		-- DCheckBoxLabel both hand their clicks to CHILD panels, so the
		-- handler is wrapped onto the whole subtree - and it keeps whatever
		-- each panel already did with a left click, otherwise overriding
		-- this broke dragging the slider and ticking the box.
		local function reset()
			local b = bounds[name]

			if b and b[4] and MayEdit(info.level) then
				SetValue(name, b[4])

				if row.Refresh then row:Refresh() end
			end
		end

		local function WrapRightClick(pnl)
			if not IsValid(pnl) then return end

			local old = pnl.OnMousePressed

			pnl.OnMousePressed = function(self, code)
				if code == MOUSE_RIGHT then
					reset()

					return
				end

				if old then return old(self, code) end
			end

			for _, child in ipairs(pnl:GetChildren()) do WrapRightClick(child) end
		end

		WrapRightClick(row)

		-- Rights and help text are only known once the server has answered
		-- the first sync request, so both are (re)applied every time one
		-- arrives. Without this the whole panel was built disabled.
		row.ApplyRights = function(self)
			-- Not in the server's catalogue (the convar doesn't exist there):
			-- showing a control that changes nothing is worse than hiding it.
			if synced and not bounds[name] then
				self:SetVisible(false)

				return
			end

			self:SetVisible(true)

			local ok = MayEdit(info.level)
			local b = bounds[name] or {}
			local text = b[3] or ""

			self:SetEnabled(ok)
			self:SetTooltip(ok and (name .. (text ~= "" and ("\n" .. text) or "") .. "\n" .. L("reset"))
				or L(info.level == "superadmin" and "need.superadmin" or "need.admin"))
		end

		row:ApplyRights()

		if panel.AddItem then panel:AddItem(row) end

		return row
	end

	--- One group's controls into `panel` (a DForm or anything with :Add).
	local function BuildGroup(panel, groupId, dark)
		local group

		for _, g in ipairs(hg.bots.SettingGroups or {}) do
			if g.id == groupId then group = g break end
		end

		if not group then return end

		local rows = {}

		for _, name in ipairs(group.keys) do
			local info = hg.bots.SettingIndex[name]

			if info then rows[#rows + 1] = BuildRow(panel, name, info, dark) end
		end

		-- Everything on this page back to its defaults at once.
		Button(panel, L("reset.group"), dark, function()
			for _, name in ipairs(group.keys) do
				local info = hg.bots.SettingIndex[name]
				local b = bounds[name]

				if info and b and b[4] and MayEdit(info.level) then SetValue(name, b[4]) end
			end

			timer.Simple(0.4, RequestValues)
		end)

		local function refresh()
			for _, row in ipairs(rows) do
				if IsValid(row) then
					if row.Refresh then row:Refresh() end
					if row.ApplyRights then row:ApplyRights() end
				end
			end
		end

		listeners[panel] = refresh

		RequestValues()
	end

	--- Everything matching `query` across all groups.
	local function BuildSearch(panel, query, dark)
		query = string.lower(string.Trim(query or ""))

		if query == "" then return end

		local rows = {}
		local found = 0

		for _, group in ipairs(hg.bots.SettingGroups or {}) do
			for _, name in ipairs(group.keys) do
				local info = hg.bots.SettingIndex[name]
				local help = bounds[name] and bounds[name][3] or ""

				if info and (string.find(string.lower(name), query, 1, true)
					or string.find(string.lower(hg.bots.LSetting(name)), query, 1, true)
					or string.find(string.lower(help), query, 1, true))
				then
					rows[#rows + 1] = BuildRow(panel, name, info, dark)
					found = found + 1
				end
			end
		end

		if found == 0 then
			local empty = vgui.Create("DLabel", panel)

			empty:SetText(L("search.none"))
			empty:Dock(TOP)
			empty:DockMargin(8, 8, 8, 8)

			Paint(empty, dark)
		end

		listeners[panel] = function()
			for _, row in ipairs(rows) do
				if IsValid(row) then
					if row.Refresh then row:Refresh() end
					if row.ApplyRights then row:ApplyRights() end
				end
			end
		end
	end
--//

--\\ Actions page
	local function BuildActions(panel, dark)
		Button(panel, L("act.spawn"), dark, function() Act("spawn") end)
		Button(panel, L("act.spawn_random"), dark, function() Act("spawn_random") end)
		Button(panel, L("act.spawn_guard"), dark, function() Act("spawn_guard") end)
		Button(panel, L("act.spawn_neutral"), dark, function() Act("spawn_neutral") end)
		Button(panel, L("act.removeall"), dark, function() Act("removeall") end)

		Button(panel, L("act.cleanup_now"), dark, function() Act("cleanup_now") end)

		Button(panel, L("act.director_on"), dark, function() Act("director_on") end)
		Button(panel, L("act.director_off"), dark, function() Act("director_off") end)
		Button(panel, L("act.director_place"), dark, function() Act("director_place") end)
		Button(panel, L("act.director_status"), dark, function() Act("director_status") end)
		Button(panel, L("act.director_clear"), dark, function() Act("director_clear") end)

		local kitBox = vgui.Create("DComboBox", panel)

		kitBox:Dock(TOP)
		kitBox:DockMargin(4, 8, 4, 2)
		kitBox:SetValue(L("kits"))

		Paint(kitBox, dark)

		if panel.AddItem then panel:AddItem(kitBox) end

		local function fillKits()
			kitBox:Clear()
			kitBox:SetValue(L("kits"))

			for _, name in ipairs(kits) do kitBox:AddChoice(name, name) end
		end

		fillKits()

		listeners[kitBox] = fillKits

		Button(panel, L("act.spawn_kit"), dark, function()
			local _, name = kitBox:GetSelected()

			if name then Act("spawn_kit", nil, name) end
		end)

		local nameBox = vgui.Create("DTextEntry", panel)

		nameBox:Dock(TOP)
		nameBox:DockMargin(4, 6, 4, 2)
		nameBox:SetPlaceholderText(L("kit.name"))

		if panel.AddItem then panel:AddItem(nameBox) end

		Button(panel, L("act.kit_save"), dark, function()
			local name = string.Trim(nameBox:GetValue() or "")

			if name ~= "" then Act("kit_save", nil, name) end
		end)

		Button(panel, L("act.kit_delete"), dark, function()
			local _, name = kitBox:GetSelected()

			if name then Act("kit_delete", nil, name) end
		end)

		local presets = vgui.Create("DComboBox", panel)

		presets:Dock(TOP)
		presets:DockMargin(4, 6, 4, 2)
		presets:SetValue(L("presets"))

		for _, name in ipairs({ "wild", "careful", "trusted", "perf" }) do
			presets:AddChoice(L("preset." .. name), name)
		end

		presets.OnSelect = function(_, _, _, data) Act("preset", nil, data) end

		Paint(presets, dark)

		if panel.AddItem then panel:AddItem(presets) end

		Button(panel, L("act.navpatch"), dark, function() Act("navpatch") end)
		Button(panel, L("act.navpatch_undo"), dark, function() Act("navpatch_undo") end)
	end
--//

--\\ Kit builder
	local CATEGORIES = { "pistol", "light", "heavy", "melee", "grenade", "med", "armor" }

	--- Rounds the guns in this kit actually take, as {ammo name = count}.
	-- A kit built by hand would otherwise ship a rifle with nothing to
	-- feed it, which is the mistake the random roller avoids too.
	local function SuggestAmmo(kit)
		local out = {}

		for _, class in ipairs(kit.weapons or {}) do
			for _, bucket in ipairs(CATEGORIES) do
				for _, item in ipairs(catalog[bucket] or {}) do
					if item.class == class and item.ammo then
						local mags = (bucket == "pistol") and 3 or 4
						local clip = math.max(tonumber(item.clip) or 30, 1)

						out[item.ammo] = math.max(out[item.ammo] or 0, clip * mags)
					end
				end
			end
		end

		return out
	end

	local function BuildBuilder(panel)
		local kit = { weapons = {}, ammo = {}, armor = {} }
		local kitName = ""

		local wrap = vgui.Create("DPanel", panel)

		wrap:Dock(FILL)
		Flat(wrap, DARK.panel)

		-- Left: the saved kits.
		local left = vgui.Create("DPanel", wrap)

		left:Dock(LEFT)
		left:SetWide(190)
		left:DockMargin(6, 6, 3, 6)
		Flat(left, DARK.bg)

		local list = vgui.Create("DListView", left)

		list:Dock(FILL)
		list:DockMargin(4, 4, 4, 4)
		list:SetMultiSelect(false)
		list:AddColumn(L("kits"))

		-- Right: the editor.
		local right = vgui.Create("DPanel", wrap)

		right:Dock(FILL)
		right:DockMargin(3, 6, 6, 6)
		Flat(right, DARK.bg)

		local nameBox = vgui.Create("DTextEntry", right)

		nameBox:Dock(TOP)
		nameBox:DockMargin(6, 6, 6, 4)
		nameBox:SetPlaceholderText(L("kit.name"))

		local body = vgui.Create("DPanel", right)

		body:Dock(FILL)
		body:DockMargin(6, 2, 6, 2)
		Flat(body, DARK.bg)

		-- Available items (by category) on the left of the editor, the
		-- kit's own contents on the right.
		local avail = vgui.Create("DPanel", body)

		avail:Dock(LEFT)
		avail:SetWide(280)
		Flat(avail, DARK.bg)

		local catBox = vgui.Create("DComboBox", avail)

		catBox:Dock(TOP)
		catBox:DockMargin(0, 0, 0, 4)

		for _, id in ipairs(CATEGORIES) do catBox:AddChoice(L("cat." .. id), id) end

		catBox:ChooseOptionID(1)

		local availList = vgui.Create("DListView", avail)

		availList:Dock(FILL)
		availList:SetMultiSelect(false)
		availList:AddColumn(L("kit.available"))

		local contents = vgui.Create("DPanel", body)

		contents:Dock(FILL)
		contents:DockMargin(6, 0, 0, 0)
		Flat(contents, DARK.bg)

		local contentList = vgui.Create("DListView", contents)

		contentList:Dock(FILL)
		contentList:SetMultiSelect(false)
		contentList:AddColumn(L("kit.contents"))
		contentList:AddColumn(L("kit.ammo")):SetFixedWidth(70)

		local function label(class)
			for _, bucket in ipairs(CATEGORIES) do
				for _, item in ipairs(catalog[bucket] or {}) do
					if item.class == class then return item.name, item.ammo end
				end
			end

			return class, nil
		end

		local function fillContents()
			contentList:Clear()

			for _, class in ipairs(kit.weapons) do
				local name, ammo = label(class)

				contentList:AddLine(name, ammo and tostring(kit.ammo[ammo] or 0) or "-").Class = class
			end

			for _, armor in ipairs(kit.armor) do
				contentList:AddLine(armor, L("cat.armor")).Armor = armor
			end
		end

		local function fillAvail()
			local _, id = catBox:GetSelected()

			availList:Clear()

			for _, item in ipairs(catalog[id or "pistol"] or {}) do
				local line = availList:AddLine(item.name)

				line.Class = item.class
				line.Armor = (id == "armor") and item.class or nil
			end
		end

		catBox.OnSelect = fillAvail

		local function fillKitList()
			list:Clear()

			for _, name in ipairs(kits) do list:AddLine(name) end
		end

		fillKitList()
		fillAvail()

		-- Buttons under the two lists.
		local bar = vgui.Create("DPanel", right)

		bar:Dock(BOTTOM)
		bar:SetTall(220)
		bar:DockMargin(6, 4, 6, 6)
		Flat(bar, DARK.bg)

		Button(bar, L("kit.add"), true, function()
			local line = availList:GetSelectedLine()

			if not line then return end

			local row = availList:GetLine(line)

			if row.Armor then
				table.insert(kit.armor, row.Armor)
			else
				table.insert(kit.weapons, row.Class)

				kit.ammo = table.Merge(SuggestAmmo(kit), kit.ammo)
			end

			fillContents()
		end)

		Button(bar, L("kit.remove"), true, function()
			local line = contentList:GetSelectedLine()

			if not line then return end

			local row = contentList:GetLine(line)

			if row.Armor then
				table.RemoveByValue(kit.armor, row.Armor)
			else
				table.RemoveByValue(kit.weapons, row.Class)
			end

			kit.ammo = SuggestAmmo(kit)

			fillContents()
		end)

		Button(bar, L("kit.capture"), true, function() Act("kit_get", nil, "@me") end)
		Button(bar, L("kit.roll"), true, function() Act("kit_random", nil, "") end)

		Button(bar, L("kit.save"), true, function()
			local name = string.Trim(nameBox:GetValue() or "")

			if name == "" then return end

			Act("kit_build", nil, util.TableToJSON({
				name = name,
				weapons = kit.weapons,
				ammo = kit.ammo,
				armor = kit.armor,
			}))
		end)

		Button(bar, L("kit.spawn"), true, function()
			local name = string.Trim(nameBox:GetValue() or "")

			if name ~= "" then Act("spawn_kit", nil, name) end
		end)

		Button(bar, L("act.kit_delete"), true, function()
			local line = list:GetSelectedLine()

			if line then Act("kit_delete", nil, list:GetLine(line):GetColumnText(1)) end
		end)

		-- Clicking a saved kit loads it into the editor.
		list.OnRowSelected = function(_, _, row)
			kitName = row:GetColumnText(1)

			nameBox:SetValue(kitName)

			Act("kit_get", nil, kitName)
		end

		listeners[wrap] = function()
			fillKitList()
			fillAvail()

			-- A kit the server sent back (opened, captured or rolled).
			if incoming then
				kit = {
					weapons = incoming.kit.weapons or {},
					ammo = incoming.kit.ammo or {},
					armor = incoming.kit.armor or {},
				}

				if incoming.name and incoming.name ~= "" then nameBox:SetValue(incoming.name) end

				incoming = nil

				fillContents()
			end
		end

		fillContents()
		RequestValues()
	end
--//

--\\ Random kit items
	--[[
		One tick box per weapon and armour piece the server has: unticked
		ones never turn up in a random kit (the menu's random spawn,
		hg_bot_kit_random, a rolled kit in the builder, the AI director).
		Hand-built kits are not affected. Pluviska and the Fury syringes
		aren't listed - bots never get those at all.
	]]
	local function BuildBlacklist(panel)
		local help = vgui.Create("DLabel", panel)

		help:SetText(L("ban.help"))
		help:SetWrap(true)
		help:SetAutoStretchVertical(true)
		help:Dock(TOP)
		help:DockMargin(6, 6, 6, 6)

		Paint(help, true)

		local filter = vgui.Create("DTextEntry", panel)

		filter:Dock(TOP)
		filter:DockMargin(4, 0, 4, 6)
		filter:SetPlaceholderText(L("ban.filter"))
		filter:SetUpdateOnType(true)

		local rows = {}
		local built = false

		local function applyFilter()
			local q = string.lower(string.Trim(filter:GetValue() or ""))

			for _, row in ipairs(rows) do
				if IsValid(row) then
					row:SetVisible(row.IsHeader or q == "" or string.find(row.Search, q, 1, true) ~= nil)
				end
			end

			if panel.GetCanvas then panel:GetCanvas():InvalidateLayout() end

			panel:InvalidateLayout()
		end

		filter.OnValueChange = applyFilter

		local function build()
			if built or not next(catalog) then return end

			built = true

			for _, id in ipairs({ "pistol", "light", "heavy", "melee", "grenade", "med", "armor" }) do
				local list = catalog[id]

				if istable(list) and #list > 0 then
					local header = vgui.Create("DLabel", panel)

					header:SetText(L("cat." .. id))
					header:SetFont("DermaDefaultBold")
					header:Dock(TOP)
					header:DockMargin(6, 10, 6, 2)
					header.IsHeader = true

					Paint(header, true)

					rows[#rows + 1] = header

					-- Whitelist in two clicks: everything off, then tick the
					-- few that should stay.
					local bar = vgui.Create("DPanel", panel)

					bar:Dock(TOP)
					bar:SetTall(22)
					bar:DockMargin(14, 0, 6, 2)
					bar.Paint = function() end
					bar.IsHeader = true

					local function setAll(on)
						for _, it in ipairs(list) do
							local cls = tostring(it.class)

							if (not banned[cls]) ~= on then
								banned[cls] = (not on) or nil

								Act("kit_ban", nil, util.TableToJSON({ name = cls, off = not on }))
							end
						end

						for _, r in ipairs(rows) do
							if IsValid(r) and r.Category == id then
								r.Updating = true
								r:SetValue(on)
								r.Updating = nil
							end
						end
					end

					for i, on in ipairs({ true, false }) do
						local b = vgui.Create("DButton", bar)

						b:SetText(L(on and "ban.all_on" or "ban.all_off"))
						b:Dock(LEFT)
						b:SetWide(150)
						b:DockMargin(0, 0, 4, 0)
						b.DoClick = function() if isAdmin then setAll(on) end end

						Flat(b, DARK.row, DARK.accent)
						Paint(b, true)
					end

					rows[#rows + 1] = bar

					for _, item in ipairs(list) do
						local class = tostring(item.class)
						local box = vgui.Create("DCheckBoxLabel", panel)

						box:SetText(tostring(item.name) .. (item.slot and ("  [" .. tostring(item.slot) .. "]") or ""))
						box:SetTooltip(class)
						box:Dock(TOP)
						box:DockMargin(14, 1, 6, 1)
						box.Class = class
						box.Category = id
						box.Search = string.lower(class .. " " .. tostring(item.name))

						Paint(box, true)

						box.Updating = true
						box:SetValue(not banned[class])
						box.Updating = nil

						box.OnChange = function(self, val)
							if self.Updating then return end

							banned[class] = (not val) or nil

							Act("kit_ban", nil, util.TableToJSON({ name = class, off = not val }))
						end

						rows[#rows + 1] = box
					end
				end
			end

			applyFilter()
		end

		local function refresh()
			build()

			for _, row in ipairs(rows) do
				if IsValid(row) and row.Class then
					row.Updating = true
					row:SetValue(not banned[row.Class])
					row.Updating = nil
					row:SetEnabled(isAdmin)
				end
			end
		end

		listeners[panel] = refresh

		refresh()
		RequestValues()
	end
--//

--\\ Bot models
	--[[
		What a bot may wear: Z-City's own appearance models first, then
		every player model installed (the same list the server accepts -
		sv_bot_models.lua refuses anything else).
	]]
	local function ModelList()
		local out, seen = {}, {}
		local ap = hg.Appearance and hg.Appearance.PlayerModels

		if istable(ap) then
			for sex = 1, 2 do
				for name, tbl in SortedPairs(ap[sex] or {}) do
					if istable(tbl) and isstring(tbl.mdl) and not seen[string.lower(tbl.mdl)] then
						seen[string.lower(tbl.mdl)] = true
						out[#out + 1] = { name = "Z-City: " .. name, mdl = tbl.mdl }
					end
				end
			end
		end

		for name, mdl in SortedPairs(player_manager.AllValidModels()) do
			if isstring(mdl) and not seen[string.lower(mdl)] then
				seen[string.lower(mdl)] = true
				out[#out + 1] = { name = name, mdl = mdl }
			end
		end

		return out
	end

	local GRID_LIMIT = 400

	--- Filter box + a grid of model icons.
	-- opts.click(mdl), opts.rightClick(mdl), opts.marked(mdl) -> bool
	local function ModelGrid(parent, opts)
		local filter = vgui.Create("DTextEntry", parent)

		filter:Dock(TOP)
		filter:DockMargin(4, 4, 4, 4)
		filter:SetPlaceholderText(L("models.filter"))
		filter:SetUpdateOnType(true)

		local grid = vgui.Create("DIconLayout", parent)

		grid:Dock(TOP)
		grid:DockMargin(4, 0, 4, 4)
		grid:SetSpaceX(4)
		grid:SetSpaceY(4)

		local all = ModelList()

		local function fill()
			grid:Clear()

			local q = string.lower(string.Trim(filter:GetValue() or ""))
			local shown = 0

			for _, item in ipairs(all) do
				if q == "" or string.find(string.lower(item.name .. " " .. item.mdl), q, 1, true) then
					shown = shown + 1

					if shown > GRID_LIMIT then break end

					local icon = grid:Add("SpawnIcon")

					icon:SetSize(64, 64)
					icon:SetModel(item.mdl)
					icon:SetTooltip(item.name .. "\n" .. item.mdl)

					icon.DoClick = function() if opts.click then opts.click(item.mdl) end end
					icon.DoRightClick = function() if opts.rightClick then opts.rightClick(item.mdl) end end

					local paintOver = icon.PaintOver

					icon.PaintOver = function(self, w, h)
						if paintOver then paintOver(self, w, h) end

						if opts.marked and opts.marked(item.mdl) then
							surface.SetDrawColor(90, 210, 120)
							surface.DrawOutlinedRect(0, 0, w, h, 3)
						end
					end
				end
			end

			if shown > GRID_LIMIT then
				chat.AddText(Color(150, 200, 255), "[hg.bots] ", color_white, string.format(L("models.limit"), GRID_LIMIT))
			end

			grid:InvalidateLayout(true)
			parent:InvalidateLayout()
		end

		filter.OnValueChange = fill

		fill()

		return grid
	end

	--- The "Bot models" tab: the random pool, plus "put this on every bot".
	local function BuildModels(panel)
		local help = vgui.Create("DLabel", panel)

		help:SetText(L("models.help"))
		help:SetWrap(true)
		help:SetAutoStretchVertical(true)
		help:Dock(TOP)
		help:DockMargin(6, 6, 6, 6)

		Paint(help, true)

		local info = hg.bots.SettingIndex and hg.bots.SettingIndex.hg_bot_model_mode
		local row = info and BuildRow(panel, "hg_bot_model_mode", info, true)

		Button(panel, L("models.reroll"), true, function() Act("model_reroll") end)

		-- Names: one per line, new bots take theirs from here.
		local namesLabel = vgui.Create("DLabel", panel)

		namesLabel:SetText(L("names.help"))
		namesLabel:SetWrap(true)
		namesLabel:SetAutoStretchVertical(true)
		namesLabel:Dock(TOP)
		namesLabel:DockMargin(6, 10, 6, 2)

		Paint(namesLabel, true)

		local namesBox = vgui.Create("DTextEntry", panel)

		namesBox:SetMultiline(true)
		namesBox:SetTall(110)
		namesBox:Dock(TOP)
		namesBox:DockMargin(4, 2, 4, 2)
		namesBox:SetValue(table.concat(botNames, "\n"))

		Button(panel, L("names.save"), true, function()
			local list = {}

			for _, line in ipairs(string.Explode("\n", namesBox:GetValue() or "")) do
				line = string.Trim(line)

				if line ~= "" then list[#list + 1] = line end
			end

			Act("names_set", nil, util.TableToJSON(list))
		end)

		ModelGrid(panel, {
			click = function(mdl)
				local on = not modelPool[string.lower(mdl)]

				modelPool[string.lower(mdl)] = on or nil

				Act("model_pool", nil, util.TableToJSON({ mdl = mdl, on = on }))
			end,
			rightClick = function(mdl)
				local menu = DermaMenu()

				menu:AddOption(L("models.all"), function() Act("model_all", nil, mdl) end):SetIcon("icon16/group.png")
				menu:AddOption(L("models.copy"), function() SetClipboardText(mdl) end):SetIcon("icon16/page_copy.png")
				menu:Open()
			end,
			marked = function(mdl) return modelPool[string.lower(mdl)] == true end,
		})

		local lastNames = botNames

		listeners[panel] = function()
			if IsValid(row) then
				if row.Refresh then row:Refresh() end
				if row.ApplyRights then row:ApplyRights() end
			end

			-- Fresh list from the server, and nothing typed over it yet.
			if botNames ~= lastNames and IsValid(namesBox) and not namesBox:HasFocus() then
				lastNames = botNames
				namesBox:SetValue(table.concat(botNames, "\n"))
			end
		end

		RequestValues()
	end

	--- The "Voices" tab: which voice packs bots may use.
	local function BuildVoices(panel)
		local help = vgui.Create("DLabel", panel)

		help:SetText(L("voices.help"))
		help:SetWrap(true)
		help:SetAutoStretchVertical(true)
		help:Dock(TOP)
		help:DockMargin(6, 6, 6, 6)

		Paint(help, true)

		Button(panel, L("voices.reload"), true, function() Act("voice_reload") end)

		local rows = {}

		local function rebuild()
			for _, r in ipairs(rows) do if IsValid(r) then r:Remove() end end

			rows = {}

			for _, pack in ipairs(voicePacks) do
				local box = vgui.Create("DCheckBoxLabel", panel)
				local sex = pack.sex == "f" and L("voices.female") or pack.sex == "m" and L("voices.male") or ""
				local kind = pack.builtin and L("voices.builtin") or ""

				box:SetText(("%s   (%d %s)%s%s"):format(tostring(pack.name), tonumber(pack.lines) or 0, L("voices.lines"),
					sex ~= "" and ("  " .. sex) or "", kind ~= "" and ("  " .. kind) or ""))
				box:Dock(TOP)
				box:DockMargin(10, 2, 6, 2)

				Paint(box, true)

				box.Updating = true
				box:SetValue(pack.on == true)
				box.Updating = nil
				box:SetEnabled(isAdmin)

				box.OnChange = function(self, val)
					if self.Updating then return end

					Act("voice_pack", nil, util.TableToJSON({ name = pack.name, on = val }))
				end

				rows[#rows + 1] = box
			end

			if #voicePacks == 0 then
				local empty = vgui.Create("DLabel", panel)

				empty:SetText(L("voices.none"))
				empty:Dock(TOP)
				empty:DockMargin(10, 6, 6, 6)

				Paint(empty, true)

				rows[#rows + 1] = empty
			end
		end

		local shown

		listeners[panel] = function()
			if shown ~= voicePacks then
				shown = voicePacks
				rebuild()
			end
		end

		rebuild()
		shown = voicePacks
		RequestValues()
	end

	--- A window to pick one bot's model (from its right-click menu).
	function hg.bots.OpenModelPicker(bot)
		if not IsValid(bot) then return end

		local frame = vgui.Create("DFrame")

		frame:SetSize(math.min(ScrW() - 80, 640), math.min(ScrH() - 80, 560))
		frame:Center()
		frame:SetTitle(string.format(L("models.pick"), bot:Nick()))
		frame:MakePopup()

		frame.Paint = function(self, w, h)
			draw.RoundedBox(6, 0, 0, w, h, DARK.bg)
		end

		Paint(frame, true)

		local def = vgui.Create("DButton", frame)

		def:SetText(L("models.default"))
		def:Dock(TOP)
		def:DockMargin(4, 2, 4, 2)
		def:SetTall(26)
		def.DoClick = function()
			Act("model_set", bot, "")
			frame:Close()
		end

		Flat(def, DARK.row, DARK.accent)
		Paint(def, true)

		local scroll = vgui.Create("DScrollPanel", frame)

		scroll:Dock(FILL)

		ModelGrid(scroll, {
			click = function(mdl)
				if IsValid(bot) then Act("model_set", bot, mdl) end

				frame:Close()
			end,
			marked = function(mdl) return IsValid(bot) and string.lower(bot:GetModel() or "") == string.lower(mdl) end,
		})
	end
--//

--\\ The window (C menu icon / hg_bot_menu)
	function hg.bots.OpenMenu()
		if IsValid(hg.bots.MenuFrame) then hg.bots.MenuFrame:Remove() end

		local frame = vgui.Create("DFrame")

		frame:SetSize(math.min(ScrW() - 80, 900), math.min(ScrH() - 80, 660))
		frame:Center()
		frame:SetTitle(L("title"))
		frame:SetDeleteOnClose(true)
		frame:MakePopup()

		frame.Paint = function(self, w, h)
			draw.RoundedBox(6, 0, 0, w, h, DARK.bg)
			draw.RoundedBox(0, 0, 24, w, h - 24, DARK.panel)
		end

		hg.bots.MenuFrame = frame

		Paint(frame, true)

		-- Left: search box over the category list.
		local nav = vgui.Create("DPanel", frame)

		nav:Dock(LEFT)
		nav:SetWide(210)
		nav:DockMargin(6, 4, 3, 6)
		Flat(nav, DARK.bg)

		local content = vgui.Create("DPanel", frame)

		content:Dock(FILL)
		content:DockMargin(3, 4, 6, 6)
		Flat(content, DARK.bg)

		local page

		local function Show(builder)
			if IsValid(page) then
				listeners[page] = nil
				page:Remove()
			end

			page = vgui.Create("DScrollPanel", content)
			page:Dock(FILL)
			page:DockMargin(4, 4, 4, 4)

			builder(page)
		end

		local search = vgui.Create("DTextEntry", nav)

		search:Dock(TOP)
		search:DockMargin(4, 4, 4, 4)
		search:SetPlaceholderText(L("search"))
		search:SetUpdateOnType(true)

		search.OnValueChange = function(self, text)
			if string.Trim(text) == "" then
				Show(function(p) BuildActions(p, true) end)

				return
			end

			Show(function(p) BuildSearch(p, text, true) end)
		end

		local navList = vgui.Create("DScrollPanel", nav)

		navList:Dock(FILL)

		local function NavButton(text, builder)
			local b = vgui.Create("DButton", navList)

			b:SetText(text)
			b:Dock(TOP)
			b:DockMargin(4, 2, 4, 2)
			b:SetTall(28)
			b.DoClick = function() Show(builder) end

			Flat(b, DARK.row, DARK.accent)
			Paint(b, true)

			return b
		end

		NavButton(L("actions"), function(p) BuildActions(p, true) end)

		-- The builder wants the whole page, not a scroll list of rows.
		local builderButton = vgui.Create("DButton", navList)

		builderButton:SetText(L("builder"))
		builderButton:Dock(TOP)
		builderButton:DockMargin(4, 2, 4, 2)
		builderButton:SetTall(28)

		Flat(builderButton, DARK.row, DARK.accent)
		Paint(builderButton, true)

		builderButton.DoClick = function()
			if IsValid(page) then
				listeners[page] = nil
				page:Remove()
			end

			page = vgui.Create("DPanel", content)
			page:Dock(FILL)
			Flat(page, DARK.bg)

			BuildBuilder(page)
		end

		NavButton(L("ban.title"), function(p) BuildBlacklist(p) end)
		NavButton(L("models.title"), function(p) BuildModels(p) end)
		NavButton(L("voices.title"), function(p) BuildVoices(p) end)

		for _, group in ipairs(hg.bots.SettingGroups or {}) do
			NavButton(L("group." .. group.id), function(p) BuildGroup(p, group.id, true) end)
		end

		Show(function(p) BuildActions(p, true) end)

		RequestValues()

		return frame
	end

	concommand.Add("hg_bot_menu", function() hg.bots.OpenMenu() end)

	-- C menu: the icon row along the bottom of the context menu.
	--
	-- Sandbox makes a window for every icon BEFORE calling init
	-- (contextmenu.lua: Window:SetSize(newv.width, newv.height)), and
	-- without width/height that SetSize errored out - the click did
	-- nothing at all, which is the "C menu doesn't open" report. The
	-- empty window it makes is thrown away (Z-City's own player model
	-- icon does the same) and the real one opens on its own, so it stays
	-- up after C is let go.
	list.Set("DesktopWindows", "HGBotSettings", {
		title = "Tarkov AI Bots", -- fixed: the menu list is built at load time
		icon = "icon64/settings.png",
		width = 900,
		height = 660,
		onewindow = true,
		init = function(icon, window)
			if IsValid(window) then window:Remove() end

			hg.bots.OpenMenu()
		end,
	})

	-- The Z-City gamemode itself (base, not sandbox) has no C or Q menu,
	-- so there the chat is the way in.
	local CHAT_OPEN = { ["!bots"] = true, ["/bots"] = true, ["!botmenu"] = true, ["/botmenu"] = true }

	hook.Add("OnPlayerChat", "HG_Bots_ChatMenu", function(ply, text)
		if ply ~= LocalPlayer() or not isstring(text) then return end
		if not CHAT_OPEN[string.lower(string.Trim(text))] then return end

		hg.bots.OpenMenu()

		return true
	end)
--//

--\\ Q menu: Utilities -> Tarkov AI
	hook.Add("PopulateToolMenu", "HG_Bots_ToolMenu", function()
		spawnmenu.AddToolMenuOption("Utilities", L("title"), "hg_bot_actions", L("actions"), "", "", function(panel)
			panel:ClearControls()

			local open = vgui.Create("DButton", panel)

			open:SetText(L("builder"))
			open:SetTall(26)
			open.DoClick = function() hg.bots.OpenMenu() end

			panel:AddItem(open)

			BuildActions(panel, false)
		end)

		for _, group in ipairs(hg.bots.SettingGroups or {}) do
			spawnmenu.AddToolMenuOption("Utilities", L("title"), "hg_bot_" .. group.id, L("group." .. group.id), "", "", function(panel)
				panel:ClearControls()

				BuildGroup(panel, group.id, false)
			end)
		end
	end)
--//

--\ Right-click on a bot
	--[[
		One entry instead of six. The C menu's property list is flat, so a
		handful of "Tarkov AI: ..." lines pushed everything else off the
		screen and still had no room for kits or orders. The single entry
		opens a proper menu at the cursor with everything grouped:

		  Info        what it is doing right now, and the name tag overlay
		  Faction     raider / guard
		  Gear        any saved kit, a rolled one, or strip it
		  Orders      come here, hold here, follow me, stop
		  Control     re-initialize, freeze the AI, teleport, remove

		Entries appear only if the player has the rights for them, so a
		plain admin sees the harmless half and a superadmin sees all of it.
	]]

	-- The server-side IsHomigradBot flag isn't visible here, so bots carry
	-- a networked marker (set in hg.bots.Init).
	--
	-- A downed bot is a Z-City ragdoll: the right click lands on the
	-- prop_ragdoll, not on the player, and the entry used to simply not
	-- show up for it ("sometimes it isn't there"). The ragdoll is traced
	-- back to the bot lying in it.
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

	local function BotEntFor(ent, ply, super)
		if not BotOf(ent) then return false end
		if not IsValid(ply) then return false end

		return super and ply:IsSuperAdmin() or (not super and ply:IsAdmin())
	end

	--- Where the player is looking, as a string the server can read back.
	local function AimString()
		local ply = LocalPlayer()

		if not IsValid(ply) then return "" end

		local tr = ply:GetEyeTrace()
		local pos = tr.HitPos

		return ("%d %d %d"):format(pos.x, pos.y, pos.z)
	end

	local overlay = CreateClientConVar("hg_bot_overlay", "0", true, false,
		"Draw a name tag over every bot with its state, faction and target")

	local function BotMenu(ent)
		ent = BotOf(ent)

		if not ent then return end

		-- Kits and voice packs for the submenus, fresh for next time.
		RequestValues()

		local ply = LocalPlayer()
		local admin = BotEntFor(ent, ply, false)
		local super = BotEntFor(ent, ply, true)

		if not admin and not super then return end

		local menu = DermaMenu()

		menu:SetMinimumWidth(190)

		menu:AddOption(ent:Nick() .. "  (" .. ent:GetNWString("hg_bot_faction", "raider") .. ")", function() end)
			:SetIcon("icon16/user_gray.png")
		menu:AddSpacer()

		-- Info
		menu:AddOption(L("ctx.state"), function() Act("state", ent) end):SetIcon("icon16/information.png")

		local tag = menu:AddOption(L("ctx.overlay"), function()
			RunConsoleCommand("hg_bot_overlay", overlay:GetBool() and "0" or "1")
		end)

		tag:SetIcon(overlay:GetBool() and "icon16/eye.png" or "icon16/lightbulb_off.png")

		-- Faction
		if super then
			local sub, parent = menu:AddSubMenu(L("ctx.faction"))

			parent:SetIcon("icon16/shield.png")

			sub:AddOption(L("ctx.faction.raider"), function() Act("faction", ent, "raider") end)
				:SetIcon("icon16/user_red.png")
			sub:AddOption(L("ctx.faction.guard"), function() Act("faction", ent, "guard") end)
				:SetIcon("icon16/user_green.png")
			sub:AddOption(L("ctx.faction.neutral"), function() Act("faction", ent, "neutral") end)
				:SetIcon("icon16/user_orange.png")
		end

		-- Gear
		if super then
			local sub, parent = menu:AddSubMenu(L("ctx.gear"))

			parent:SetIcon("icon16/briefcase.png")

			sub:AddOption(L("ctx.gear.random"), function() Act("kit_apply", ent, "random") end)
				:SetIcon("icon16/arrow_refresh.png")
			sub:AddOption(L("ctx.gear.strip"), function() Act("kit_apply", ent, "strip") end)
				:SetIcon("icon16/cross.png")

			if #kits > 0 then
				sub:AddSpacer()

				for _, name in ipairs(kits) do
					sub:AddOption(name, function() Act("kit_apply", ent, name) end)
						:SetIcon("icon16/box.png")
				end
			end
		end

		-- Model (sv_bot_models.lua)
		if admin then
			local msub, mparent = menu:AddSubMenu(L("ctx.model"))

			mparent:SetIcon("icon16/user_suit.png")

			msub:AddOption(L("ctx.model.pick"), function() hg.bots.OpenModelPicker(ent) end)
				:SetIcon("icon16/application_view_icons.png")
			msub:AddOption(L("models.default"), function() Act("model_set", ent, "") end)
				:SetIcon("icon16/arrow_undo.png")

			menu:AddOption(L("ctx.rename"), function()
				Derma_StringRequest(L("ctx.rename"), L("ctx.rename.help"), ent:GetNWString("PlayerName", ent:Nick()),
					function(text) if IsValid(ent) then Act("name_set", ent, text) end end)
			end):SetIcon("icon16/textfield_rename.png")

			-- Voice pack (sv_bot_voice.lua).
			local vsub, vparent = menu:AddSubMenu(L("ctx.voice"))

			vparent:SetIcon("icon16/sound.png")

			vsub:AddOption(L("ctx.voice.auto"), function() Act("voice_set", ent, "") end):SetIcon("icon16/arrow_refresh.png")

			if #voicePacks > 0 then vsub:AddSpacer() end

			for _, pack in ipairs(voicePacks) do
				vsub:AddOption(tostring(pack.name), function() Act("voice_set", ent, tostring(pack.name)) end)
					:SetIcon(pack.on and "icon16/sound.png" or "icon16/sound_mute.png")
			end
		end

		-- Orders
		local sub, parent = menu:AddSubMenu(L("ctx.orders"))

		parent:SetIcon("icon16/flag_blue.png")

		sub:AddOption(L("ctx.order.come"), function() Act("order_move", ent, AimString()) end)
			:SetIcon("icon16/arrow_right.png")
		sub:AddOption(L("ctx.order.hold"), function() Act("order_hold", ent, AimString()) end)
			:SetIcon("icon16/anchor.png")
		sub:AddOption(L("ctx.order.follow"), function() Act("order_follow", ent) end)
			:SetIcon("icon16/user_go.png")
		sub:AddOption(L("ctx.order.stop"), function() Act("order_stop", ent) end)
			:SetIcon("icon16/stop.png")

		-- Control
		menu:AddSpacer()
		menu:AddOption(L("act.reinit"), function() Act("reinit", ent) end):SetIcon("icon16/arrow_refresh.png")

		menu:AddOption(L("ctx.freeze"), function() Act("enable", ent) end):SetIcon("icon16/control_pause_blue.png")

		if super then
			menu:AddOption(L("ctx.teleport"), function() Act("teleport", ent) end):SetIcon("icon16/arrow_down.png")
			menu:AddOption(L("ctx.remove"), function() Act("remove", ent) end):SetIcon("icon16/delete.png")
		end

		menu:AddSpacer()
		menu:AddOption(L("title"), function() hg.bots.OpenMenu() end):SetIcon("icon16/cog.png")

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
		MenuLabel = "Tarkov AI",
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

--\ Name tags over bots
	-- What a bot is doing, drawn over its head: the quickest way to see why
	-- one is behaving oddly without opening anything. The state and faction
	-- come from networked strings the server keeps up to date on change.
	local TAG_RANGE = 1600

	hook.Add("HUDPaint", "HG_Bots_Overlay", function()
		if not overlay:GetBool() then return end

		local me = LocalPlayer()

		if not IsValid(me) then return end

		local eye = me:EyePos()

		for _, ply in ipairs(player.GetAll()) do
			if ply ~= me and ply:Alive() and ply:GetNWBool("hg_bot", false) then
				local pos = ply:EyePos() + Vector(0, 0, 12)
				local dist = eye:Distance(pos)

				if dist < TAG_RANGE then
					local screen = pos:ToScreen()

					if screen.visible then
						local faction = ply:GetNWString("hg_bot_faction", "raider")
						local state = ply:GetNWString("hg_bot_state", "?")
						local col = faction == "guard" and Color(120, 220, 140)
							or faction == "neutral" and Color(235, 215, 120)
							or Color(240, 150, 150)

						draw.SimpleTextOutlined(ply:Nick(), "DermaDefault", screen.x, screen.y, col,
							TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
						draw.SimpleTextOutlined(("%s  %.0f u"):format(state, dist), "DermaDefault", screen.x, screen.y + 13,
							Color(210, 210, 215), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
					end
				end
			end
		end
	end)
--//
