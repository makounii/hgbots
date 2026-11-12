--[[
	HGBots - the terminal's pages

	  SYSTEM      status (live bot table), actions, kit builder, random kit
	              items, bot models, voices, profiles (save / load / export /
	              import / reset everything)
	  PARAMETERS  pinned, changed, then one page per settings group
	  TERMINAL    interface (this window's own options, name tags)

	Every page is a function building into a scroll panel (or a plain
	panel for the kit builder) and listening for server syncs through
	M.Listen, which forgets it once the page is gone.
]]

hg = hg or {}
hg.bots = hg.bots or {}

local T = hg.bots.Term or {}
hg.bots.Term = T

local M = hg.bots.Menu or {}
hg.bots.Menu = M

local L = function(key) return hg.bots.L and hg.bots.L(key) or key end

--\\ Small builders
	local P = {} -- the page builders, kept in one table (upvalue limit)

	--- Buttons in a grid; items = { { label, fn, kind, level }, ... }.
	local function Grid(parent, items, cols)
		local p = vgui.Create("DPanel", parent)

		cols = cols or 2

		p:Dock(TOP)
		p:DockMargin(0, 0, 0, T.S(4))
		p:SetTall(math.ceil(#items / cols) * T.S(30))
		p.Paint = nil
		p.Buttons = {}

		for _, it in ipairs(items) do
			local b = T.Button(p, it[1], it[2], it[3])

			b.Need = it[4]
			p.Buttons[#p.Buttons + 1] = b
		end

		p.PerformLayout = function(self, w)
			local gap = T.S(6)
			local bw = math.floor((w - gap * (cols - 1)) / cols)

			for i, b in ipairs(self.Buttons) do
				local c, r = (i - 1) % cols, math.floor((i - 1) / cols)

				b:SetPos(c * (bw + gap), r * T.S(30))
				b:SetSize(bw, T.S(26))
			end
		end

		p.Think = function(self)
			for _, b in ipairs(self.Buttons) do
				if b.Need then b:SetEnabled(M.MayEdit(b.Need)) end
			end
		end

		return p
	end

	--- A grid item that runs a server action (with its rights, and an
	-- optional "are you sure").
	local function ActItem(action, kind, confirm, arg)
		local level = hg.bots.MenuActions and hg.bots.MenuActions[action] or "admin"

		return { L("act." .. action), function()
			if confirm then
				T.Confirm(confirm, function() M.Act(action, nil, arg) end, kind == "danger")
			else
				M.Act(action, nil, arg)
			end
		end, kind, level }
	end

	--- A button on the page title strip, right aligned.
	local function Tool(ctx, label, fn, kind)
		local b = T.Button(ctx.tools, label, fn, kind)

		b:Dock(RIGHT)
		b:DockMargin(T.S(6), 0, 0, 0)
		b:SetWide(T.TextW("> " .. label, "HGB.T") + T.S(24))

		return b
	end

	--- "[x] label" line that toggles.
	local function Check(parent, text, get, set, sub)
		local b = vgui.Create("DButton", parent)

		b:Dock(TOP)
		b:DockMargin(T.S(8), 0, 0, 1)
		b:SetTall(T.S(22))
		b:SetText("")
		b.Paint = function(self, w, h)
			local C = T.C
			local on = get()
			local hover = self:IsHovered()

			if hover then T.Rect(0, 0, w, h, C.row) end

			T.Text(on and "[x]" or "[ ]", "HGB.TB", T.S(4), h / 2, on and C.acc or C.faint, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			T.Text(T.Fit(text, "HGB.T", w * 0.6), "HGB.T", T.S(38), h / 2, on and C.fg or C.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

			if sub then T.Text(T.Fit(sub, "HGB.TS", w * 0.35), "HGB.TS", w - T.S(6), h / 2, C.faint, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER) end
		end
		b.DoClick = function()
			if not M.isAdmin then T.Sound("deny") return end

			T.Sound("toggle")
			set(not get())
		end

		return b
	end

	local function Group(id)
		for _, g in ipairs(hg.bots.SettingGroups or {}) do
			if g.id == id then return g end
		end
	end

	local function RefreshRows(rows)
		for _, row in ipairs(rows) do
			if IsValid(row) and row.Refresh then row:Refresh() end
		end
	end

	--- Rows for a list of parameter names.
	local function Rows(p, names)
		local rows = {}

		for _, name in ipairs(names) do
			local info = hg.bots.SettingIndex and hg.bots.SettingIndex[name]

			if info then rows[#rows + 1] = T.SettingRow(p, name, info) end
		end

		return rows
	end

	--- Defaults back for these names (only the ones this player may touch).
	local function ResetNames(names)
		local tbl = {}

		for _, name in ipairs(names) do
			if M.Changed(name) then tbl[name] = M.Default(name) end
		end

		local n = M.SetMany(tbl)

		M.Log(string.format(L("term.reset.done"), n), "ok")
	end

	local FACTION_COL = { raider = "red", guard = "ok", neutral = "warn" }
	local MODES = { "SURVIVAL", "TDM", "FFA" }
--//

--\\ STATUS
	function P.Status(p, ctx)
		Tool(ctx, L("term.sync"), function() M.Request() end)

		local sum = vgui.Create("DPanel", p)

		sum:Dock(TOP)
		sum:SetTall(T.S(70))
		sum.Paint = function(self, w, h)
			local C = T.C
			local c = T.Census()
			local on = (M.values.hg_bot_director or 0) >= 0.5
			local mode = MODES[math.floor(M.values.hg_bot_director_mode or 0) + 1] or "?"
			local rights, rcol = T.Rights()
			local boxes = {
				{ L("st.alive"), tostring(c.total), C.hi },
				{ L("st.factions"), string.format("R%d  G%d  N%d", c.factions.raider or 0, c.factions.guard or 0, c.factions.neutral or 0), C.fg },
				{ L("st.director"), (on and "ON " or "OFF ") .. mode, on and C.acc or C.dim },
				{ L("st.you"), rights, rcol },
			}
			local gap = T.S(8)
			local bw = (w - gap * 3) / 4

			for i, b in ipairs(boxes) do
				local x = math.floor((i - 1) * (bw + gap))

				T.Rect(x, 0, bw, h, C.panel)
				T.Box(x, 0, bw, h, C.dim, 6)
				T.Text(b[1], "HGB.TS", x + T.S(10), T.S(8), C.faint)
				T.Text(T.Fit(b[2], "HGB.TH", bw - T.S(20)), "HGB.TH", x + T.S(10), T.S(28), b[3])
			end
		end

		-- What they are doing, as bars.
		T.Header(p, L("st.states"))

		local chart = vgui.Create("DPanel", p)

		chart:Dock(TOP)
		chart:SetTall(T.S(22))
		chart.Think = function(self)
			local n = 0

			for _ in pairs(T.Census().states) do n = n + 1 end

			local h = math.max(1, math.min(n, 8)) * T.S(18) + T.S(4)

			if self:GetTall() ~= h then self:SetTall(h) end
		end
		chart.Paint = function(self, w, h)
			local C = T.C
			local c = T.Census()
			local states = {}

			for name, n in pairs(c.states) do states[#states + 1] = { name, n } end

			table.sort(states, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)

			if #states == 0 then
				T.Text(L("st.none"), "HGB.T", 0, T.S(2), C.dim)

				return
			end

			for i = 1, math.min(#states, 8) do
				local s = states[i]
				local y = (i - 1) * T.S(18) + T.S(2)

				T.Text(T.Fit(s[1], "HGB.T", T.S(150)), "HGB.T", 0, y, C.fg)
				T.Bar(T.S(160), y + T.S(4), w - T.S(220), T.S(8), s[2] / math.max(c.total, 1), C.dim, C.line)
				T.Text(tostring(s[2]), "HGB.TB", w - T.S(4), y, C.hi, TEXT_ALIGN_RIGHT)
			end
		end

		-- Every bot alive, nearest first.
		T.Header(p, L("st.bots"))

		local list = T.List(p, { { L("st.col.name"), 0.27 }, { L("st.col.faction"), 0.13 }, { L("st.col.state"), 0.2 },
			{ L("st.col.weapon"), 0.28 }, { L("st.col.dist"), 0.12 } })

		list:Dock(TOP)
		list:SetTall(T.S(230))

		local function selected()
			local ply = list:Selected()

			return IsValid(ply) and ply or nil
		end

		local function fill()
			local keep = selected()

			list:Clear()

			for _, b in ipairs(T.Census().bots) do
				local line = list:Add({ b.name, b.faction, b.state, b.weapon, string.format("%d m", b.dist * 0.01905) }, b.ply,
					T.C[FACTION_COL[b.faction] or "fg"])

				if b.ply == keep then list.SelectedLine = line end
			end
		end

		list.OnDouble = function(_, ply) if IsValid(ply) and hg.bots.OpenBotMenu then hg.bots.OpenBotMenu(ply) end end
		list.OnRight = list.OnDouble
		list.Think = function(self)
			if (self.NextFill or 0) > RealTime() then return end

			self.NextFill = RealTime() + 1
			fill()
		end

		T.Note(p, L("st.bots.help"))

		local function onBot(action, arg)
			return function()
				local ply = selected()

				if not ply then T.Sound("deny") M.Log(L("st.pick"), "error") return end

				M.Act(action, ply, arg)
			end
		end

		Grid(p, {
			{ L("ctx.state"), onBot("state"), nil, "admin" },
			{ L("ctx.freeze"), onBot("enable"), nil, "admin" },
			{ L("ctx.order.follow"), onBot("order_follow"), nil, "admin" },
			{ L("ctx.teleport"), onBot("teleport"), nil, "superadmin" },
			{ L("ctx.gear.random"), onBot("kit_apply", "random"), nil, "superadmin" },
			{ L("ctx.remove"), onBot("remove"), "danger", "superadmin" },
		}, 3)

		T.Header(p, L("st.quick"))

		Grid(p, {
			ActItem("spawn"), ActItem("spawn_random"), ActItem("spawn_guard"),
			ActItem("spawn_neutral"), ActItem("cleanup_now"), ActItem("removeall", "danger", L("confirm.removeall")),
		}, 3)
	end
--//

--\\ ACTIONS
	function P.Actions(p, ctx)
		T.Header(p, L("ac.spawn"))
		Grid(p, { ActItem("spawn"), ActItem("spawn_random"), ActItem("spawn_guard"), ActItem("spawn_neutral") }, 2)

		T.Header(p, L("kits"))

		local kits = T.List(p, { { L("kits"), 1 } })

		kits:Dock(TOP)
		kits:SetTall(T.S(140))

		local function fillKits()
			local keep = kits:Selected()

			kits:Clear()

			for _, name in ipairs(M.kits) do
				local line = kits:Add({ name }, name)

				if name == keep then kits.SelectedLine = line end
			end
		end

		fillKits()

		kits.OnDouble = function(_, name) M.Act("spawn_kit", nil, name) end

		local nameBox = T.Entry(p, L("kit.name"))

		nameBox:Dock(TOP)
		nameBox:DockMargin(0, T.S(6), 0, T.S(6))

		Grid(p, {
			{ L("act.spawn_kit"), function()
				local name = kits:Selected()

				if name then M.Act("spawn_kit", nil, name) else T.Sound("deny") end
			end, nil, "superadmin" },
			{ L("act.kit_save"), function()
				local name = string.Trim(nameBox:GetValue() or "")

				if name ~= "" then M.Act("kit_save", nil, name) else T.Sound("deny") nameBox:RequestFocus() end
			end, nil, "admin" },
			{ L("act.kit_delete"), function()
				local name = kits:Selected()

				if name then T.Confirm(string.format(L("confirm.kit_delete"), name), function() M.Act("kit_delete", nil, name) end, true) end
			end, "danger", "admin" },
			{ L("builder"), function() ctx.win:ShowPage("kits") end },
		}, 2)

		T.Header(p, L("group.director"))
		T.Note(p, L("director.settings.help"))
		Grid(p, {
			ActItem("director_on"), ActItem("director_off"), ActItem("director_place"),
			ActItem("director_status"), ActItem("director_clear", "danger", L("confirm.director_clear")),
			{ L("act.director_settings"), function() ctx.win:ShowPage("director") end },
		}, 3)

		T.Header(p, L("presets"))
		T.Note(p, L("ac.presets.help"))

		local presets = {}

		for _, id in ipairs({ "wild", "careful", "trusted", "perf" }) do
			presets[#presets + 1] = ActItem("preset", nil, string.format(L("confirm.preset"), L("preset." .. id)), id)
			presets[#presets][1] = L("preset." .. id)
		end

		Grid(p, presets, 2)

		T.Header(p, L("ac.world"))
		Grid(p, {
			ActItem("cleanup_now"),
			ActItem("removeall", "danger", L("confirm.removeall")),
			ActItem("navpatch", nil, L("confirm.navpatch")),
			ActItem("navpatch_undo", "danger", L("confirm.navpatch_undo")),
		}, 2)

		M.Listen(p, fillKits)
	end
--//

--\\ KIT BUILDER
	local CATEGORIES = { "pistol", "light", "heavy", "melee", "grenade", "med", "armor" }

	--- Rounds the guns in this kit take, as {ammo name = count}: a hand
	-- built kit would otherwise ship a rifle with nothing to feed it.
	local function SuggestAmmo(kit)
		local out = {}

		for _, class in ipairs(kit.weapons or {}) do
			for _, bucket in ipairs(CATEGORIES) do
				for _, item in ipairs(M.catalog[bucket] or {}) do
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

	local function ItemName(class)
		for _, bucket in ipairs(CATEGORIES) do
			for _, item in ipairs(M.catalog[bucket] or {}) do
				if item.class == class then return item.name, item.ammo end
			end
		end

		return class, nil
	end

	function P.Kits(p, ctx)
		local kit = { weapons = {}, ammo = {}, armor = {} }
		local cat = "pistol"

		local left = vgui.Create("DPanel", p)

		left:Dock(LEFT)
		left:SetWide(T.S(210))
		left:DockMargin(0, 0, T.S(10), 0)
		left.Paint = nil

		local saved = T.List(left, { { L("kits"), 1 } })

		saved:Dock(FILL)

		local right = vgui.Create("DPanel", p)

		right:Dock(FILL)
		right.Paint = nil

		local nameBox = T.Entry(right, L("kit.name"))

		nameBox:Dock(TOP)
		nameBox:DockMargin(0, 0, 0, T.S(6))

		local tabs = vgui.Create("DPanel", right)

		tabs:Dock(TOP)
		tabs:SetTall(T.S(26))
		tabs:DockMargin(0, 0, 0, T.S(6))
		tabs.Paint = nil
		tabs.Buttons = {}

		local bar = vgui.Create("DPanel", right)

		bar:Dock(BOTTOM)
		bar:DockMargin(0, T.S(6), 0, 0)
		bar.Paint = nil

		local body = vgui.Create("DPanel", right)

		body:Dock(FILL)
		body.Paint = nil

		local avail = T.List(body, { { L("kit.available"), 1 } })
		local contents = T.List(body, { { L("kit.contents"), 0.72 }, { L("kit.ammo"), 0.28 } })

		body.PerformLayout = function(self, w, h)
			local half = math.floor((w - T.S(8)) / 2)

			avail:SetPos(0, 0)
			avail:SetSize(half, h)
			contents:SetPos(w - half, 0)
			contents:SetSize(half, h)
		end

		local function fillContents()
			contents:Clear()

			for _, class in ipairs(kit.weapons) do
				local name, ammo = ItemName(class)

				contents:Add({ name, ammo and tostring(kit.ammo[ammo] or 0) or "-" }, { class = class })
			end

			for _, armor in ipairs(kit.armor) do contents:Add({ armor, L("cat.armor") }, { armor = armor }) end
		end

		local function fillAvail()
			avail:Clear()

			for _, item in ipairs(M.catalog[cat] or {}) do
				avail:Add({ item.name }, { class = item.class, armor = (cat == "armor") and item.class or nil })
			end
		end

		local function fillSaved()
			saved:Clear()

			for _, name in ipairs(M.kits) do saved:Add({ name }, name) end
		end

		for i, id in ipairs(CATEGORIES) do
			local b = T.Button(tabs, L("cat." .. id), function()
				cat = id
				fillAvail()
			end, "ghost")

			b.Cat = id
			b.Think = function(self) self.Kind = (cat == self.Cat) and "accent" or "ghost" end
			tabs.Buttons[i] = b
		end

		tabs.PerformLayout = function(self, w, h)
			local bw = math.floor(w / #self.Buttons)

			for i, b in ipairs(self.Buttons) do
				b:SetPos((i - 1) * bw, 0)
				b:SetSize(bw - 2, h)
			end
		end

		local function add()
			local item = avail:Selected()

			if not item then return end

			if item.armor then
				table.insert(kit.armor, item.armor)
			else
				table.insert(kit.weapons, item.class)
				kit.ammo = table.Merge(SuggestAmmo(kit), kit.ammo)
			end

			fillContents()
		end

		local function remove()
			local item = contents:Selected()

			if not item then return end

			if item.armor then table.RemoveByValue(kit.armor, item.armor) else table.RemoveByValue(kit.weapons, item.class) end

			kit.ammo = SuggestAmmo(kit)
			fillContents()
		end

		avail.OnDouble = add
		contents.OnDouble = remove

		saved.OnSelect = function(_, name)
			nameBox:SetValue(name)
			M.Act("kit_get", nil, name)
		end

		local grid = Grid(bar, {
			{ L("kit.add") .. " >>", add },
			{ "<< " .. L("kit.remove"), remove },
			{ L("kit.capture"), function() M.Act("kit_get", nil, "@me") end, nil, "admin" },
			{ L("kit.roll"), function() M.Act("kit_random", nil, "") end, nil, "admin" },
			{ L("kit.save"), function()
				local name = string.Trim(nameBox:GetValue() or "")

				if name == "" then T.Sound("deny") nameBox:RequestFocus() return end

				M.Act("kit_build", nil, util.TableToJSON({ name = name, weapons = kit.weapons, ammo = kit.ammo, armor = kit.armor }))
			end, "accent", "admin" },
			{ L("kit.spawn"), function()
				local name = string.Trim(nameBox:GetValue() or "")

				if name ~= "" then M.Act("spawn_kit", nil, name) end
			end, nil, "superadmin" },
			{ L("act.kit_delete"), function()
				local name = saved:Selected()

				if name then T.Confirm(string.format(L("confirm.kit_delete"), name), function() M.Act("kit_delete", nil, name) end, true) end
			end, "danger", "admin" },
			{ L("kit.clear"), function()
				kit = { weapons = {}, ammo = {}, armor = {} }
				nameBox:SetValue("")
				fillContents()
			end },
		}, 4)

		grid:Dock(FILL)
		bar:SetTall(grid:GetTall())

		M.Listen(p, function()
			fillSaved()

			if #avail.Lines == 0 then fillAvail() end

			-- a kit the server sent back (opened, captured or rolled)
			if M.incoming then
				kit = {
					weapons = M.incoming.kit.weapons or {},
					ammo = M.incoming.kit.ammo or {},
					armor = M.incoming.kit.armor or {},
				}

				if M.incoming.name and M.incoming.name ~= "" and M.incoming.name ~= "@me" then nameBox:SetValue(M.incoming.name) end

				M.incoming = nil
				fillContents()
			end
		end)

		fillSaved()
		fillAvail()
		fillContents()
		M.Request()
	end
--//

--\\ RANDOM KIT ITEMS
	--[[
		One tick per weapon and armour piece the server has: unticked ones
		never turn up in a random kit (the random spawn, hg_bot_kit_random,
		a rolled kit, the AI director). Hand-built kits are not affected.
	]]
	function P.Items(p, ctx)
		T.Note(p, L("ban.help"))

		local filter = T.Entry(p, L("ban.filter"))

		filter:Dock(TOP)
		filter:DockMargin(0, 0, 0, T.S(6))
		filter:SetUpdateOnType(true)

		local rows, built = {}, false

		local function apply()
			local q = string.lower(string.Trim(filter:GetValue() or ""))

			for _, row in ipairs(rows) do
				if IsValid(row) then row:SetVisible(row.IsHeader or q == "" or string.find(row.Search, q, 1, true) ~= nil) end
			end

			p:InvalidateLayout()
			p:GetCanvas():InvalidateLayout()
		end

		filter.OnValueChange = apply

		local function setBan(class, off)
			M.banned[class] = off or nil
			M.Act("kit_ban", nil, util.TableToJSON({ name = class, off = off }))
		end

		local function build()
			if built or not next(M.catalog) then return end

			built = true

			for _, id in ipairs(CATEGORIES) do
				local list = M.catalog[id]

				if istable(list) and #list > 0 then
					local head = T.Header(p, L("cat." .. id) .. "  (" .. #list .. ")")

					head.IsHeader = true
					rows[#rows + 1] = head

					local g = Grid(p, {
						{ L("ban.all_on"), function()
							for _, it in ipairs(list) do if M.banned[tostring(it.class)] then setBan(tostring(it.class), false) end end
						end, nil, "admin" },
						{ L("ban.all_off"), function()
							for _, it in ipairs(list) do if not M.banned[tostring(it.class)] then setBan(tostring(it.class), true) end end
						end, "danger", "admin" },
					}, 2)

					g.IsHeader = true
					rows[#rows + 1] = g

					for _, item in ipairs(list) do
						local class = tostring(item.class)
						local box = Check(p, tostring(item.name), function() return not M.banned[class] end,
							function(on) setBan(class, not on) end, (item.slot and ("[" .. tostring(item.slot) .. "]  ") or "") .. class)

						box.Search = string.lower(class .. " " .. tostring(item.name))
						rows[#rows + 1] = box
					end
				end
			end

			apply()
		end

		M.Listen(p, build)

		build()
		M.Request()
	end
--//

--\\ BOT MODELS
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
		local filter = T.Entry(parent, L("models.filter"))

		filter:Dock(TOP)
		filter:DockMargin(0, T.S(4), 0, T.S(6))
		filter:SetUpdateOnType(true)

		local grid = vgui.Create("DIconLayout", parent)

		grid:Dock(TOP)
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
					icon.DoClick = function() T.Sound("click") if opts.click then opts.click(item.mdl) end end
					icon.DoRightClick = function() if opts.rightClick then opts.rightClick(item.mdl) end end

					local over = icon.PaintOver

					icon.PaintOver = function(self, w, h)
						if over then over(self, w, h) end

						if opts.marked and opts.marked(item.mdl) then
							surface.SetDrawColor(T.C.acc)
							surface.DrawOutlinedRect(0, 0, w, h, 3)
						end
					end
				end
			end

			if shown > GRID_LIMIT then M.Log(string.format(L("models.limit"), GRID_LIMIT), "info") end

			grid:InvalidateLayout(true)
			parent:InvalidateLayout()
		end

		filter.OnValueChange = fill
		fill()

		return grid
	end

	function P.Models(p, ctx)
		T.Note(p, L("models.help"))

		local rows = Rows(p, { "hg_bot_model_mode" })

		Grid(p, { { L("models.reroll"), function() M.Act("model_reroll") end, nil, "admin" } }, 1)

		T.Header(p, L("names.title"))
		T.Note(p, L("names.help"))

		local names = T.Entry(p, "")

		names:Dock(TOP)
		names:SetMultiline(true)
		names:SetTall(T.S(110))
		names:SetValue(table.concat(M.botNames, "\n"))

		Grid(p, { { L("names.save"), function()
			local list = {}

			for _, line in ipairs(string.Explode("\n", names:GetValue() or "")) do
				line = string.Trim(line)

				if line ~= "" then list[#list + 1] = line end
			end

			M.Act("names_set", nil, util.TableToJSON(list))
		end, "accent", "admin" } }, 1)

		T.Header(p, L("models.title"))

		ModelGrid(p, {
			click = function(mdl)
				local on = not M.modelPool[string.lower(mdl)]

				M.modelPool[string.lower(mdl)] = on or nil
				M.Act("model_pool", nil, util.TableToJSON({ mdl = mdl, on = on }))
			end,
			rightClick = function(mdl)
				local menu = DermaMenu()

				menu:AddOption(L("models.all"), function() M.Act("model_all", nil, mdl) end):SetIcon("icon16/group.png")
				menu:AddOption(L("models.copy"), function() SetClipboardText(mdl) end):SetIcon("icon16/page_copy.png")
				T.SkinMenu(menu)
				menu:Open()
			end,
			marked = function(mdl) return M.modelPool[string.lower(mdl)] == true end,
		})

		local lastNames = M.botNames

		M.Listen(p, function()
			RefreshRows(rows)

			-- a fresh list from the server, and nothing typed over it yet
			if M.botNames ~= lastNames and IsValid(names) and not names:HasFocus() then
				lastNames = M.botNames
				names:SetValue(table.concat(M.botNames, "\n"))
			end
		end)

		M.Request()
	end

	--- A window to pick one bot's model (from its right-click menu).
	function hg.bots.OpenModelPicker(bot)
		if not IsValid(bot) then return end

		local f = vgui.Create("EditablePanel")

		f:SetSize(math.min(ScrW() - 80, T.S(680)), math.min(ScrH() - 80, T.S(580)))
		f:Center()
		f:MakePopup()
		f.Paint = function(self, w, h)
			T.Rect(0, 0, w, h, T.C.bg)
			T.Box(0, 0, w, h, T.C.acc, 8)
			T.Text(string.format(L("models.pick"), IsValid(bot) and bot:Nick() or "?"), "HGB.TB", T.S(12), T.S(10), T.C.hi)
		end
		f.PaintOver = function(self, w, h) T.PaintCRT(w, h) end

		local close = T.Button(f, "X", function() f:Remove() end, "danger")

		close:SetSize(T.S(30), T.S(24))
		close:SetPos(f:GetWide() - T.S(36), T.S(6))

		local def = T.Button(f, L("models.default"), function()
			if IsValid(bot) then M.Act("model_set", bot, "") end

			f:Remove()
		end)

		def:Dock(TOP)
		def:DockMargin(T.S(10), T.S(36), T.S(10), T.S(4))

		local scroll = T.Scroll(f)

		scroll:Dock(FILL)
		scroll:DockMargin(T.S(10), 0, T.S(10), T.S(10))

		ModelGrid(scroll, {
			click = function(mdl)
				if IsValid(bot) then M.Act("model_set", bot, mdl) end

				f:Remove()
			end,
			marked = function(mdl) return IsValid(bot) and string.lower(bot:GetModel() or "") == string.lower(mdl) end,
		})
	end
--//

--\\ VOICES
	function P.Voices(p, ctx)
		T.Note(p, L("voices.help"))
		Grid(p, { { L("voices.reload"), function() M.Act("voice_reload") end, nil, "admin" } }, 1)
		T.Header(p, L("voices.title"))

		local rows, shown = {}, nil

		local function rebuild()
			for _, r in ipairs(rows) do if IsValid(r) then r:Remove() end end

			rows = {}

			for _, pack in ipairs(M.voicePacks) do
				local sex = pack.sex == "f" and L("voices.female") or pack.sex == "m" and L("voices.male") or ""
				local sub = string.format("%d %s  %s  %s", tonumber(pack.lines) or 0, L("voices.lines"), sex,
					pack.builtin and L("voices.builtin") or "")

				rows[#rows + 1] = Check(p, tostring(pack.name), function() return pack.on == true end, function(on)
					pack.on = on
					M.Act("voice_pack", nil, util.TableToJSON({ name = pack.name, on = on }))
				end, sub)
			end

			if #M.voicePacks == 0 then rows[#rows + 1] = T.Note(p, L("voices.none")) end
		end

		M.Listen(p, function()
			if shown ~= M.voicePacks then
				shown = M.voicePacks
				rebuild()
			end
		end)

		shown = M.voicePacks
		rebuild()
		M.Request()
	end
--//

--\\ PROFILES
	--[[
		Settings as files on this computer (data/hgbots_profiles/*.json),
		as console commands on the clipboard, or pasted back in. Applying
		any of them goes through the same rights check as a slider.
	]]
	local PROFILE_DIR = "hgbots_profiles"

	local function ProfileNames()
		local files = file.Find(PROFILE_DIR .. "/*.json", "DATA") or {}
		local out = {}

		for _, f in ipairs(files) do out[#out + 1] = string.StripExtension(f) end

		table.sort(out)

		return out
	end

	local function Current(changedOnly)
		local out = {}

		for _, s in ipairs(M.AllSettings()) do
			if M.values[s.name] ~= nil and (not changedOnly or M.Changed(s.name)) then out[s.name] = M.values[s.name] end
		end

		return out
	end

	local function AsCommands(tbl)
		local lines = {}

		for name, v in SortedPairs(tbl) do lines[#lines + 1] = string.format('%s "%s"', name, T.Value(v, M.bounds[name])) end

		return table.concat(lines, "\n")
	end

	--- "hg_bot_x 12" lines, or a JSON object, into { name = value }.
	local function Parse(text)
		local tbl = util.JSONToTable(text or "")

		if istable(tbl) then return tbl end

		tbl = {}

		for _, line in ipairs(string.Explode("\n", text or "")) do
			local name, v = string.match(line, "^%s*(hg_bot_[%w_]+)%s+\"?(%-?[%d%.]+)\"?")

			if name and tonumber(v) then tbl[name] = tonumber(v) end
		end

		return tbl
	end

	local function Differs(tbl)
		local n = 0

		for name, v in pairs(tbl) do
			if M.values[name] ~= nil and math.abs(M.values[name] - (tonumber(v) or 0)) > 0.0001 then n = n + 1 end
		end

		return n
	end

	local function ApplyTable(tbl, what)
		local diff = Differs(tbl)

		if diff == 0 then M.Log(L("pr.same"), "info") return end

		T.Confirm(string.format(L("confirm.apply"), what, diff), function()
			local n = M.SetMany(tbl)

			M.Log(string.format(L("pr.applied"), what, n), "ok")
		end, true)
	end

	function P.Profiles(p, ctx)
		T.Header(p, L("pr.local"))
		T.Note(p, L("pr.local.help"))

		local list = T.List(p, { { L("pr.col.name"), 0.6 }, { L("pr.col.diff"), 0.4 } })

		list:Dock(TOP)
		list:SetTall(T.S(150))

		local function fill()
			list:Clear()

			for _, name in ipairs(ProfileNames()) do
				local tbl = util.JSONToTable(file.Read(PROFILE_DIR .. "/" .. name .. ".json", "DATA") or "") or {}

				list:Add({ name, string.format(L("pr.differs"), Differs(tbl)) }, name)
			end
		end

		local nameBox = T.Entry(p, L("pr.name"))

		nameBox:Dock(TOP)
		nameBox:DockMargin(0, T.S(6), 0, T.S(6))

		local function load(name)
			local tbl = util.JSONToTable(file.Read(PROFILE_DIR .. "/" .. name .. ".json", "DATA") or "")

			if istable(tbl) then ApplyTable(tbl, name) end
		end

		list.OnDouble = function(_, name) load(name) end

		Grid(p, {
			{ L("pr.save"), function()
				local name = string.gsub(string.Trim(nameBox:GetValue() or ""), "[^%w_%- ]", "")

				if name == "" then T.Sound("deny") nameBox:RequestFocus() return end

				file.CreateDir(PROFILE_DIR)
				file.Write(PROFILE_DIR .. "/" .. name .. ".json", util.TableToJSON(Current(false), true))
				M.Log(string.format(L("pr.saved"), name), "ok")
				fill()
			end, "accent" },
			{ L("pr.load"), function()
				local name = list:Selected()

				if name then load(name) else T.Sound("deny") end
			end, nil, "admin" },
			{ L("pr.delete"), function()
				local name = list:Selected()

				if not name then return end

				T.Confirm(string.format(L("confirm.pr_delete"), name), function()
					file.Delete(PROFILE_DIR .. "/" .. name .. ".json")
					fill()
				end, true)
			end, "danger" },
		}, 3)

		T.Header(p, L("pr.export"))
		Grid(p, {
			{ L("pr.copy_changed"), function()
				SetClipboardText(AsCommands(Current(true)))
				M.Log(L("pr.copied"), "ok")
			end },
			{ L("pr.copy_all"), function()
				SetClipboardText(AsCommands(Current(false)))
				M.Log(L("pr.copied"), "ok")
			end },
		}, 2)

		T.Header(p, L("pr.import"))
		T.Note(p, L("pr.import.help"))

		local paste = T.Entry(p, "")

		paste:Dock(TOP)
		paste:SetMultiline(true)
		paste:SetTall(T.S(100))
		paste:DockMargin(0, 0, 0, T.S(6))

		Grid(p, { { L("pr.apply"), function()
			local tbl = Parse(paste:GetValue())

			if not next(tbl) then T.Sound("deny") M.Log(L("pr.nothing"), "error") return end

			ApplyTable(tbl, L("pr.pasted"))
		end, "accent", "admin" } }, 1)

		T.Header(p, L("pr.history"))

		local hist = vgui.Create("DPanel", p)

		hist:Dock(TOP)
		hist:SetTall(T.S(20))
		hist.Paint = function(self, w, h)
			local top = M.history[#M.history]
			local text = top and string.format(L("pr.history.top"), #M.history, M.StepLabel(top)) or L("pr.history.none")

			T.Text(T.Fit(text, "HGB.T", w), "HGB.T", 0, h / 2, T.C.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end

		Grid(p, {
			{ L("pr.undo"), function()
				local what = M.Undo()

				if what then M.Log(string.format(L("term.undone"), what), "ok") else T.Sound("deny") end
			end },
			{ L("pr.reset_all"), function()
				local names = {}

				for _, s in ipairs(M.AllSettings()) do names[#names + 1] = s.name end

				T.Confirm(L("confirm.reset_all"), function() ResetNames(names) end, true)
			end, "danger", "admin" },
		}, 2)

		M.Listen(p, fill)
		fill()
	end
--//

--\\ PARAMETER PAGES
	function P.Group(p, ctx, group)
		if group.id == "director" then
			T.Note(p, L("director.settings.help"))
			Grid(p, { ActItem("director_on"), ActItem("director_off"), ActItem("director_place") }, 3)
		end

		Tool(ctx, L("reset.group"), function()
			T.Confirm(string.format(L("confirm.reset_group"), L("group." .. group.id)), function() ResetNames(group.keys) end, true)
		end, "danger")

		local rows = Rows(p, group.keys)

		M.Listen(p, function() RefreshRows(rows) end)
		M.Request()
	end

	function P.Pinned(p, ctx)
		local names = {}

		for _, s in ipairs(M.AllSettings()) do
			if T.pins and T.pins[s.name] then names[#names + 1] = s.name end
		end

		if #names == 0 then
			T.Note(p, L("pin.none"))

			return
		end

		local rows = Rows(p, names)

		M.Listen(p, function() RefreshRows(rows) end)
		M.Request()
	end

	function P.Changed(p, ctx)
		local names = {}

		for _, s in ipairs(M.AllSettings()) do
			if M.Changed(s.name) then names[#names + 1] = s.name end
		end

		if #names == 0 then
			T.Note(p, M.synced and L("changed.none") or L("term.link.wait"))

			-- built before the first sync: build again once it is here
			if not M.synced then
				M.Listen(p, function()
					if M.synced and IsValid(ctx.win) and ctx.win.PageId == "changed" then ctx.win:ShowPage("changed") end
				end)
			end

			return
		end

		Tool(ctx, L("changed.reset"), function()
			T.Confirm(string.format(L("confirm.reset_changed"), #names), function() ResetNames(names) end, true)
		end, "danger")

		local rows, lastGroup = {}, nil

		for _, name in ipairs(names) do
			local info = hg.bots.SettingIndex[name]

			if info.group ~= lastGroup then
				lastGroup = info.group
				T.Header(p, L("group." .. info.group))
			end

			rows[#rows + 1] = T.SettingRow(p, name, info)
		end

		M.Listen(p, function() RefreshRows(rows) end)
	end

	function P.Search(p, ctx)
		local query = string.lower(string.Trim(ctx.arg or ""))
		local rows, found, lastGroup = {}, 0, nil

		-- pages first
		local pages = {}

		for _, page in ipairs(T.PageList()) do
			if not page.hidden and string.find(string.lower(page.title), query, 1, true) then
				pages[#pages + 1] = { page.title, function() ctx.win:ShowPage(page.id) end }
			end
		end

		if #pages > 0 then
			T.Header(p, L("search.pages"))
			Grid(p, pages, 3)
		end

		for _, s in ipairs(M.AllSettings()) do
			local help = M.bounds[s.name] and M.bounds[s.name][3] or ""

			if string.find(string.lower(s.name), query, 1, true)
				or string.find(string.lower(hg.bots.LSetting(s.name)), query, 1, true)
				or string.find(string.lower(help), query, 1, true)
			then
				found = found + 1

				if found > 80 then
					T.Note(p, L("search.more"), T.C.warn)

					break
				end

				if s.group.id ~= lastGroup then
					lastGroup = s.group.id
					T.Header(p, L("group." .. s.group.id))
				end

				rows[#rows + 1] = T.SettingRow(p, s.name, s.info)
			end
		end

		if found == 0 and #pages == 0 then T.Note(p, L("search.none")) end

		M.Listen(p, function() RefreshRows(rows) end)
	end
--//

--\\ INTERFACE (this computer only)
	local SCALES = { 0.85, 1, 1.15, 1.3 }

	local CLIENT = {
		hg_bot_ui_color = { choices = { "ui.color.0", "ui.color.1", "ui.color.2", "ui.color.3", "ui.color.4" }, def = 0 },
		hg_bot_ui_scale = { choices = { "ui.scale.0", "ui.scale.1", "ui.scale.2", "ui.scale.3" }, def = 1 },
		hg_bot_ui_intro = { choices = { "ui.intro.0", "ui.intro.1", "ui.intro.2" }, def = 1 },
		hg_bot_ui_scanlines = { bool = true, def = 0 },
		hg_bot_ui_sound = { bool = true, def = 1 },
		hg_bot_ui_help = { bool = true, def = 1 },
		hg_bot_ui_art = { bool = true, def = 1 },
		hg_bot_ui_chat = { bool = true, def = 0 },
		hg_bot_overlay = { bool = true, def = 0 },
		hg_bot_overlay_range = { min = 200, max = 10000, def = 1600 },
	}

	local ORDER = { "hg_bot_ui_color", "hg_bot_ui_scale", "hg_bot_ui_intro", "hg_bot_ui_scanlines", "hg_bot_ui_sound",
		"hg_bot_ui_help", "hg_bot_ui_art", "hg_bot_ui_chat", "hg_bot_overlay", "hg_bot_overlay_range" }

	local function ClientGet(name)
		local cv = GetConVar(name)
		local v = cv and cv:GetFloat() or 0

		if name == "hg_bot_ui_scale" then
			local best, bi = math.huge, 1

			for i, s in ipairs(SCALES) do
				if math.abs(s - v) < best then best, bi = math.abs(s - v), i - 1 end
			end

			return bi
		end

		return v
	end

	T.ClientSource = {
		pins = false,
		get = ClientGet,
		bounds = function(name)
			local o = CLIENT[name]

			return { o.min or 0, o.max or (o.choices and #o.choices - 1 or 1), L("ui.help." .. name), o.def }
		end,
		set = function(name, v)
			if name == "hg_bot_ui_scale" then v = SCALES[math.floor(v) + 1] or 1 end

			RunConsoleCommand(name, tostring(v))

			-- the sidebar picture is built with the window
			if name == "hg_bot_ui_art" then
				timer.Simple(0.1, function()
					local f = hg.bots.MenuFrame

					if IsValid(f) then hg.bots.OpenMenu(f.PageId) end
				end)
			end

			return true
		end,
		changed = function(name) return math.abs(ClientGet(name) - CLIENT[name].def) > 0.0001 end,
		default = function(name) return CLIENT[name].def end,
		locked = function() return false end,
		label = function(name) return L("ui." .. name) end,
		hidden = function() return false end,
	}

	function P.Interface(p, ctx)
		T.Header(p, L("ui.look"))

		local rows = {}

		for _, name in ipairs(ORDER) do
			local o = CLIENT[name]

			if name == "hg_bot_overlay" then T.Header(p, L("ui.tags")) end

			rows[#rows + 1] = T.SettingRow(p, name, { level = "admin", bool = o.bool, choices = o.choices }, T.ClientSource)
		end

		T.Header(p, L("ui.window"))
		Grid(p, {
			{ L("ui.replay"), function()
				local f = ctx.win

				if IsValid(f.BootPanel) then return end

				f.BootPanel = T.Boot(f)
			end },
			{ L("ui.resetwin"), function()
				for _, k in ipairs({ "x", "y", "w", "h" }) do cookie.Delete("hgbots_term_" .. k) end

				hg.bots.OpenMenu(ctx.win.PageId)
			end },
		}, 2)

		T.Header(p, L("ui.keys"))
		T.Note(p, L("ui.keys.list"), T.C.fg)

		T.Header(p, L("ui.about"))
		T.Note(p, L("ui.about.text"))

		M.Listen(p, function() RefreshRows(rows) end)

		-- client convars change a frame after RunConsoleCommand
		p.Think = function(self)
			if (self.Next or 0) > RealTime() then return end

			self.Next = RealTime() + 0.2
			RefreshRows(rows)
		end
	end
--//

--\\ The page list
	function T.PageList()
		local sys, par, term = L("nav.system"), L("nav.params"), L("nav.term")

		local list = {
			{ id = "status", section = sys, title = L("page.status"), path = "status", build = P.Status },
			{ id = "actions", section = sys, title = L("actions"), path = "actions", build = P.Actions },
			{ id = "kits", section = sys, title = L("builder"), path = "kits", build = P.Kits, full = true },
			{ id = "items", section = sys, title = L("ban.title"), path = "kits/random", build = P.Items },
			{ id = "models", section = sys, title = L("models.title"), path = "models", build = P.Models },
			{ id = "voices", section = sys, title = L("voices.title"), path = "voices", build = P.Voices },
			{ id = "profiles", section = sys, title = L("page.profiles"), path = "profiles", build = P.Profiles },
			{ id = "pinned", section = par, title = L("page.pinned"), path = "params/pinned", build = P.Pinned,
				badge = function()
					local n = 0

					for _ in pairs(T.pins or {}) do n = n + 1 end

					return n > 0 and tostring(n) or ""
				end },
			{ id = "changed", section = par, title = L("page.changed"), path = "params/changed", build = P.Changed,
				badge = function()
					local n = 0

					for _, s in ipairs(M.AllSettings()) do if M.Changed(s.name) then n = n + 1 end end

					return n > 0 and tostring(n) or ""
				end },
		}

		for _, group in ipairs(hg.bots.SettingGroups or {}) do
			list[#list + 1] = {
				id = group.id, section = par, title = L("group." .. group.id), path = "params/" .. group.id,
				build = function(p, ctx) P.Group(p, ctx, group) end,
				badge = function()
					local n = M.GroupChanged(group)

					return n > 0 and ("*" .. n) or ""
				end,
			}
		end

		list[#list + 1] = { id = "interface", section = term, title = L("page.interface"), path = "interface", build = P.Interface }
		list[#list + 1] = { id = "search", section = term, title = L("search.results"), path = "search", build = P.Search, hidden = true }

		T.pageIndex = {}

		for _, page in ipairs(list) do T.pageIndex[page.id] = page end

		return list
	end

	function T.FindPage(id)
		if not T.pageIndex then T.PageList() end

		return T.pageIndex[id]
	end

	T.OnPins = function()
		local f = hg.bots.MenuFrame

		if IsValid(f) and f.PageId == "pinned" then f:ShowPage("pinned") end
	end
--//
