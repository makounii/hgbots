--[[
	HGBots - the terminal window

	  +-[ HGBOTS // TERMINAL ]------- LINK OK . 7 BOTS . DIRECTOR ON --[X]-+
	  | (male07)       | root@hgbots:~/params/combat $                      |
	  | [search.....]  | COMBAT                              [RESET PAGE]   |
	  | SYSTEM         | -------------------------------------------------- |
	  |  01 STATUS     |   rows ...                                         |
	  |  02 ACTIONS    |                                                    |
	  | PARAMETERS     |                                                    |
	  |  ...           |                                                    |
	  +-- 12:01:33 applied: hg_bot_sight_range ----- CTRL+F . CTRL+Z . ESC -+

	Opening it plays the boot screen first (male07 in ASCII over crossed
	bones, INITIALIZING... and a bar that fills as the server answers);
	click or press a key to skip it, or switch it off on INTERFACE.

	Keys while it is focused: CTRL+F search, CTRL+Z undo the last change,
	F5 ask the server for fresh values, ESC close. Size, position and the
	last page are remembered.
]]

hg = hg or {}
hg.bots = hg.bots or {}

local T = hg.bots.Term or {}
hg.bots.Term = T

local M = hg.bots.Menu or {}
hg.bots.Menu = M

local L = function(key) return hg.bots.L and hg.bots.L(key) or key end

--\\ Who is out there (header, status page)
	--- Bots in the world, counted at most twice a second.
	function T.Census()
		local now = RealTime()

		if T.census and now - T.census.at < 0.5 then return T.census end

		local c = { at = now, total = 0, factions = { raider = 0, guard = 0, neutral = 0 }, states = {}, bots = {} }
		local me = LocalPlayer()

		for _, ply in ipairs(player.GetAll()) do
			if ply:GetNWBool("hg_bot", false) and ply:Alive() then
				local faction = ply:GetNWString("hg_bot_faction", "raider")
				local state = ply:GetNWString("hg_bot_state", "idle")

				c.total = c.total + 1
				c.factions[faction] = (c.factions[faction] or 0) + 1
				c.states[state] = (c.states[state] or 0) + 1

				local wep = ply:GetActiveWeapon()

				c.bots[#c.bots + 1] = {
					ply = ply,
					name = ply:Nick(),
					faction = faction,
					state = state,
					weapon = IsValid(wep) and (wep.GetPrintName and wep:GetPrintName() or wep:GetClass()) or "-",
					dist = IsValid(me) and me:GetPos():Distance(ply:GetPos()) or 0,
				}
			end
		end

		table.sort(c.bots, function(a, b) return a.dist < b.dist end)

		T.census = c

		return c
	end

	function T.Rights()
		if M.isSuper then return "ROOT", T.C.acc end
		if M.isAdmin then return "ADMIN", T.C.fg end

		return "GUEST", T.C.dim
	end
--//

--\\ ASCII art
	--- The art split into one string per colour per row (made once).
	function T.ArtData(name)
		T.ArtCache = T.ArtCache or {}

		if T.ArtCache[name] then return T.ArtCache[name] end

		local art = T.Art and T.Art[name]

		if not art then return nil end

		local keys = { "1", "2", "3", "4", "5", "6", "7", "r" }
		local rows, cols, eyes = {}, 0, {}

		for r, chars in ipairs(art.chars) do
			local lv = art.levels[r] or ""
			local bufs = {}

			for _, k in ipairs(keys) do bufs[k] = {} end

			cols = math.max(cols, #chars)

			for i = 1, #chars do
				local k = string.sub(lv, i, i)
				local ch = string.sub(chars, i, i)

				for _, key in ipairs(keys) do bufs[key][i] = (key == k) and ch or " " end

				if k == "r" then eyes[#eyes + 1] = { i, r } end
			end

			local layers = {}

			for _, k in ipairs(keys) do
				local s = string.TrimRight(table.concat(bufs[k]))

				if s ~= "" then layers[#layers + 1] = { k, s } end
			end

			rows[r] = { layers = layers, levels = lv, chars = chars }
		end

		-- Two eye centres, for the glow behind them.
		local centres = {}

		if #eyes > 0 then
			local mid = 0

			for _, e in ipairs(eyes) do mid = mid + e[1] end

			mid = mid / #eyes

			for side = 1, 2 do
				local sx, sy, n = 0, 0, 0

				for _, e in ipairs(eyes) do
					if (side == 1) == (e[1] < mid) then sx, sy, n = sx + e[1], sy + e[2], n + 1 end
				end

				if n > 0 then centres[#centres + 1] = { sx / n, sy / n } end
			end
		end

		local data = { rows = rows, cols = cols, nrows = #art.chars, eyes = centres }

		T.ArtCache[name] = data

		return data
	end

	T.monoCache = T.monoCache or {}

	local function Cell(font)
		local c = T.monoCache[font]

		if not c then
			local w, mono = T.Mono(font)

			c = { w = w, mono = mono }
			T.monoCache[font] = c
		end

		return c.w, c.mono
	end

	--- Pixel size of the art drawn with font size `size`.
	function T.ArtSize(name, size)
		local art = T.ArtData(name)

		if not art then return 0, 0 end

		local cw = Cell(T.ArtFont(size))
		local lh = math.max(1, math.Round(cw * 1.85))

		return art.cols * cw, art.nrows * lh
	end

	--- The biggest font size at which the art fits w x h.
	function T.ArtFit(name, w, h)
		for size = 16, 5, -1 do
			local aw, ah = T.ArtSize(name, size)

			if aw <= w and ah <= h then return size end
		end

		return 5
	end

	--- Draw the art at x, y. opt: reveal (0-1, rows printed so far),
	-- alpha (0-255). Steady: no pulsing, no jumping rows.
	function T.DrawArt(name, x, y, size, opt)
		opt = opt or {}

		local art = T.ArtData(name)

		if not art then return end

		local font = T.ArtFont(size)
		local cw, mono = Cell(font)
		local lh = math.max(1, math.Round(cw * 1.85))
		local C = T.C
		local alpha = (opt.alpha or 255) / 255
		local limit = math.floor(math.Clamp(opt.reveal or 1, 0, 1) * art.nrows + 0.0001)

		-- the eyes' glow, under everything
		if limit >= art.nrows * 0.4 then
			for _, e in ipairs(art.eyes) do
				local ex, ey = x + (e[1] - 0.5) * cw, y + (e[2] - 0.5) * lh

				for i = 3, 1, -1 do
					local rw, rh = cw * (2.5 + i * 2.2), lh * (0.9 + i * 0.9)

					draw.RoundedBox(math.floor(rh / 2), ex - rw / 2, ey - rh / 2, rw, rh,
						Color(210, 40, 36, (10 + 7 * (3 - i)) * alpha))
				end
			end
		end

		surface.SetFont(font)

		for r = 1, math.min(limit, art.nrows) do
			local row = art.rows[r]
			local yy = math.floor(y + (r - 1) * lh)

			for _, layer in ipairs(row.layers) do
				local k, s = layer[1], layer[2]

				if k == "r" then
					surface.SetTextColor(225, 60, 52, 255 * alpha)
				else
					local c = C.art[tonumber(k)]

					surface.SetTextColor(c.r, c.g, c.b, 255 * alpha)
				end

				if mono then
					surface.SetTextPos(math.floor(x), yy)
					surface.DrawText(s)
				else
					for i = 1, #s do
						local ch = string.sub(s, i, i)

						if ch ~= " " then
							surface.SetTextPos(math.floor(x + (i - 1) * cw), yy)
							surface.DrawText(ch)
						end
					end
				end
			end
		end

		-- the line being printed, a touch brighter
		if limit < art.nrows then
			surface.SetTextColor(C.hi.r, C.hi.g, C.hi.b, 200 * alpha)
			surface.SetTextPos(math.floor(x), math.floor(y + limit * lh))
			surface.DrawText(art.rows[limit + 1].chars)
		end
	end
--//

--\\ CRT
	--- Faint, still scanlines when the option is on (off by default).
	-- Nothing moves and nothing flickers: it is a settings window.
	function T.PaintCRT(w, h)
		if not T.cv.scanlines:GetBool() then return end

		surface.SetDrawColor(0, 0, 0, 22)

		for y = 0, h, 3 do surface.DrawRect(0, y, w, 1) end
	end
--//

--\\ Boot screen
	--[[
		The reference: a black screen, the face in ASCII over crossed bones
		with red eyes, and under it a box reading INITIALIZING... with a bar.
		Here the bar is honest: it waits for the server's answer (and gives
		up after a few seconds, saying so), and the lines in the corner are
		what actually came back.
	]]
	function T.Boot(parent, onDone)
		local boot = vgui.Create("DPanel", parent)

		boot:SetPos(0, 0)
		boot:SetSize(parent:GetWide(), parent:GetTall())
		boot:SetZPos(1000)
		boot:SetCursor("hand")
		boot:MoveToFront()

		boot.Start = RealTime()
		boot.Shown = 0
		boot.Lines = {}
		boot.Stage = "init"

		local function line(text)
			boot.Lines[#boot.Lines + 1] = { text = text, at = RealTime() }

			T.Sound("click")
		end

		local function finish()
			if boot.Stage == "fade" then return end

			boot.Stage = "fade"
			boot.FadeAt = RealTime()
		end

		boot.Skip = finish

		line("HGBOTS TERMINAL  //  " .. string.upper(game.GetMap()) .. "  //  " .. os.date("%Y-%m-%d %H:%M"))
		line(L("boot.link"))
		T.Sound("boot")

		boot.Think = function(self)
			local t = RealTime() - self.Start

			if self.Stage == "init" then
				if not self.Answered and M.synced and (M.syncedAt or 0) >= self.Start - 0.1 then
					self.Answered = true

					local params = table.Count(M.bounds)
					local census = T.Census()
					local rights = T.Rights()

					line(string.format("%-26s %s", L("boot.params"), params))
					line(string.format("%-26s %s", L("boot.groups"), #(hg.bots.SettingGroups or {})))
					line(string.format("%-26s %s", L("boot.kits"), #M.kits))
					line(string.format("%-26s %s", L("boot.voices"), #M.voicePacks))
					line(string.format("%-26s %s", L("boot.bots"), census.total))
					line(string.format("%-26s %s", L("boot.rights"), rights))
				elseif not self.Answered and t > 4 then
					self.Answered = true
					self.Offline = true

					line(L("boot.noreply"))
				end

				local target = self.Answered and 1 or math.min(0.82, t / 1.6)

				self.Shown = math.Approach(self.Shown, target, FrameTime() * (self.Answered and 1.6 or 0.6))

				if self.Shown >= 1 and t > 1.3 then
					self.Stage = "granted"
					self.GrantedAt = RealTime()

					T.Sound(self.Offline and "deny" or "granted")
				end
			elseif self.Stage == "granted" then
				if RealTime() - self.GrantedAt > 0.6 then finish() end
			elseif self.Stage == "fade" then
				if RealTime() - self.FadeAt > 0.3 then
					self:Remove()

					if onDone then onDone() end
				end
			end
		end

		boot.OnMousePressed = function() finish() end

		boot.Paint = function(self, w, h)
			local C = T.C
			local t = RealTime() - self.Start
			local fade = self.Stage == "fade" and math.Clamp(1 - (RealTime() - self.FadeAt) / 0.3, 0, 1) or 1

			surface.SetDrawColor(3, 3, 4, 255 * fade)
			surface.DrawRect(0, 0, w, h)

			-- the picture
			local boxH = T.S(64)
			local size = T.ArtFit("big", w - T.S(40), h - boxH - T.S(70))
			local aw, ah = T.ArtSize("big", size)
			local ax, ay = math.floor((w - aw) / 2), math.floor(T.S(18) + (h - boxH - T.S(70) - ah) / 2)

			T.DrawArt("big", ax, ay, size, { reveal = t / 1.0, alpha = 255 * fade })

			-- INITIALIZING... box
			local bw = math.min(T.S(340), w - T.S(40))
			local bx, by = math.floor((w - bw) / 2), ay + ah + T.S(18)
			local granted = self.Stage ~= "init"
			local col = granted and (self.Offline and C.red or C.acc) or C.hi

			surface.SetDrawColor(0, 0, 0, 230 * fade)
			surface.DrawRect(bx, by, bw, boxH)
			surface.SetDrawColor(col.r, col.g, col.b, 255 * fade)
			surface.DrawOutlinedRect(bx, by, bw, boxH, 2)

			local dots = string.rep(".", math.floor(t * 3) % 4)
			local word = granted and (self.Offline and L("boot.offline") or L("boot.granted")) or (L("boot.init") .. dots)

			do
				draw.SimpleText(word, "HGB.TH", bx + bw / 2, by + T.S(18), Color(col.r, col.g, col.b, 255 * fade),
					TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end

			local px, py, pw, ph = bx + T.S(12), by + T.S(36), bw - T.S(24), T.S(16)

			surface.SetDrawColor(C.fg.r, C.fg.g, C.fg.b, 200 * fade)
			surface.DrawOutlinedRect(px, py, pw, ph, 1)
			surface.SetDrawColor(col.r, col.g, col.b, 235 * fade)
			surface.DrawRect(px + 3, py + 3, math.floor((pw - 6) * self.Shown), ph - 6)

			-- what actually came back, typed in the corner
			local fh = T.FontH("HGB.TS")
			local ly = h - T.S(10) - #self.Lines * fh

			for i, ln in ipairs(self.Lines) do
				local chars = math.floor((RealTime() - ln.at) * 90)
				local text = "> " .. string.sub(ln.text, 1, chars)

				draw.SimpleText(text, "HGB.TS", T.S(12), ly + (i - 1) * fh, Color(C.dim.r, C.dim.g, C.dim.b, 255 * fade))
			end

			draw.SimpleText(L("boot.skip"), "HGB.TS", w - T.S(12), h - T.S(10) - fh, Color(C.faint.r, C.faint.g, C.faint.b, 255 * fade),
				TEXT_ALIGN_RIGHT)

			T.PaintCRT(w, h)
		end

		return boot
	end
--//

--\\ Confirm
	--- A yes/no box over the terminal (Derma_Query when it is shut).
	function T.Confirm(text, yes, danger)
		local f = hg.bots.MenuFrame

		if not IsValid(f) then
			Derma_Query(text, L("title"), L("term.yes"), yes, L("term.no"))

			return
		end

		local shade = vgui.Create("DPanel", f)

		shade:SetPos(0, 0)
		shade:SetSize(f:GetWide(), f:GetTall())
		shade:SetZPos(900)
		shade:MoveToFront()
		shade.Paint = function(self, w, h)
			T.Rect(0, 0, w, h, Color(0, 0, 0, 200))
		end
		shade.OnMousePressed = function(self) self:Remove() end

		local bw = math.min(T.S(460), f:GetWide() - T.S(40))
		local lines = T.Wrap(text, "HGB.T", bw - T.S(32))
		local bh = T.S(84) + #lines * T.FontH("HGB.T")

		local box = vgui.Create("DPanel", shade)

		box:SetSize(bw, bh)
		box:Center()
		box.Paint = function(self, w, h)
			local C = T.C

			T.Rect(0, 0, w, h, C.bg)
			T.Box(0, 0, w, h, danger and C.red or C.acc, 8)
			T.Text(danger and L("term.warning") or L("term.confirm"), "HGB.TB", T.S(14), T.S(10), danger and C.red or C.acc)

			for i, ln in ipairs(lines) do
				T.Text(ln, "HGB.T", T.S(16), T.S(32) + (i - 1) * T.FontH("HGB.T"), C.fg)
			end
		end

		local no = T.Button(box, L("term.no"), function() shade:Remove() end)
		local ok = T.Button(box, L("term.yes"), function()
			shade:Remove()
			yes()
		end, danger and "danger" or "accent")

		local half = math.floor((bw - T.S(42)) / 2)

		no:SetSize(half, T.S(26))
		no:SetPos(T.S(14), bh - T.S(38))
		ok:SetSize(half, T.S(26))
		ok:SetPos(bw - T.S(14) - half, bh - T.S(38))

		T.Sound(danger and "deny" or "click")
	end
--//

--\\ Window
	local function Save(f)
		if not IsValid(f) then return end

		local x, y = f:GetPos()

		cookie.Set("hgbots_term_x", x)
		cookie.Set("hgbots_term_y", y)
		cookie.Set("hgbots_term_w", f:GetWide())
		cookie.Set("hgbots_term_h", f:GetTall())
	end

	local function Header(f)
		local head = vgui.Create("DPanel", f)

		head:Dock(TOP)
		head:SetTall(T.S(32))
		head:SetCursor("sizeall")
		head.Paint = function(self, w, h)
			local C = T.C
			local census = T.Census()

			T.Rect(0, 0, w, h, C.panel)
			T.Rect(0, h - 1, w, 1, C.line)

			local x = T.S(12)

			local tw = T.Text("HGBOTS", "HGB.TH", x, h / 2, C.hi, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

			x = x + tw + T.S(6)
			T.Text("// TERMINAL", "HGB.TS", x, h / 2 + 1, C.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

			local link = M.synced and L("term.link.ok") or L("term.link.wait")
			local director = (M.values.hg_bot_director or 0) >= 0.5
			local rights, rcol = T.Rights()
			local parts = {
				{ link, M.synced and C.ok or C.warn },
				{ string.format(L("term.bots"), census.total), C.fg },
				{ director and L("term.dir.on") or L("term.dir.off"), director and C.acc or C.dim },
				{ rights, rcol },
			}

			local rx = w - T.S(48)

			for i = #parts, 1, -1 do
				local tw = T.TextW(parts[i][1], "HGB.TS")

				T.Text(parts[i][1], "HGB.TS", rx, h / 2, parts[i][2], TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
				rx = rx - tw - T.S(8)

				if i > 1 then
					T.Text("|", "HGB.TS", rx, h / 2, C.line, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
					rx = rx - T.S(14)
				end
			end
		end

		head.OnMousePressed = function(self, code)
			if code ~= MOUSE_LEFT then return end

			local mx, my = gui.MousePos()
			local fx, fy = f:GetPos()

			self.Drag = { mx - fx, my - fy }
			self:MouseCapture(true)
		end

		head.OnMouseReleased = function(self)
			self.Drag = nil
			self:MouseCapture(false)
			Save(f)
		end

		head.Think = function(self)
			if not self.Drag then return end

			if not input.IsMouseDown(MOUSE_LEFT) then
				self:OnMouseReleased()

				return
			end

			local mx, my = gui.MousePos()

			f:SetPos(math.Clamp(mx - self.Drag[1], 0, ScrW() - f:GetWide()), math.Clamp(my - self.Drag[2], 0, ScrH() - T.S(32)))
		end

		local close = vgui.Create("DButton", head)

		close:Dock(RIGHT)
		close:SetWide(T.S(40))
		close:SetText("")
		close.Paint = function(self, w, h)
			local C = T.C
			local hover = self:IsHovered()

			if hover then T.Rect(0, 0, w, h, C.red) end

			T.Text("[X]", "HGB.TB", w / 2, h / 2, hover and C.black or C.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		close.DoClick = function() f:Close() end

		return head
	end

	local function Footer(f)
		local foot = vgui.Create("DPanel", f)

		foot:Dock(BOTTOM)
		foot:SetTall(T.S(24))
		foot.Paint = function(self, w, h)
			local C = T.C

			T.Rect(0, 0, w, h, C.panel)
			T.Rect(0, 0, w, 1, C.line)

			local last = M.log[#M.log]
			local hints = L("term.keys")
			local hw = T.TextW(hints, "HGB.TS")

			T.Text(hints, "HGB.TS", w - T.S(22), h / 2, C.faint, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

			if last then
				local age = RealTime() - last.t
				local col = last.kind == "error" and C.red or (last.kind == "ok" and C.ok or C.fg)

				if age > 6 then col = C.dim end

				local text = last.clock .. "  " .. last.text

				T.Text(T.Fit(text, "HGB.TS", w - hw - T.S(50)), "HGB.TS", T.S(10), h / 2, col, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			else
				T.Text(L("term.ready"), "HGB.TS", T.S(10), h / 2, C.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			end
		end

		-- Resize grip, bottom right.
		local grip = vgui.Create("DPanel", foot)

		grip:Dock(RIGHT)
		grip:SetWide(T.S(18))
		grip:SetCursor("sizenwse")
		grip.Paint = function(self, w, h)
			local C = T.C

			for i = 0, 2 do T.Rect(w - 4 - i * 4, h - 4 - (2 - i) * 4, 2, 2 + (2 - i) * 4, C.faint) end
		end
		grip.OnMousePressed = function(self)
			self.From = { gui.MouseX(), gui.MouseY(), f:GetWide(), f:GetTall() }
			self:MouseCapture(true)
		end
		grip.OnMouseReleased = function(self)
			self.From = nil
			self:MouseCapture(false)
			Save(f)
		end
		grip.Think = function(self)
			if not self.From then return end

			if not input.IsMouseDown(MOUSE_LEFT) then
				self:OnMouseReleased()

				return
			end

			local fx, fy = f:GetPos()
			local w = math.Clamp(self.From[3] + gui.MouseX() - self.From[1], T.S(760), ScrW() - fx)
			local h = math.Clamp(self.From[4] + gui.MouseY() - self.From[2], T.S(500), ScrH() - fy)

			f:SetSize(w, h)
		end

		return foot
	end

	local function NavButton(f, list, page, index)
		local b = vgui.Create("DButton", list)

		b:Dock(TOP)
		b:SetTall(T.S(22))
		b:SetText("")
		b.Page = page
		b.Paint = function(self, w, h)
			local C = T.C
			local sel = f.PageId == self.Page.id
			local hover = self:IsHovered()

			if sel then
				T.Rect(0, 0, w, h, C.rowHi)
				T.Rect(0, 0, 2, h, C.acc)
			elseif hover then
				T.Rect(0, 0, w, h, C.row)
			end

			local num = string.format("%02d", index)

			T.Text(num, "HGB.TS", T.S(8), h / 2, sel and C.acc or C.faint, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			T.Text(T.Fit((sel and "> " or "") .. self.Page.title, "HGB.T", w - T.S(64)), "HGB.T", T.S(30), h / 2,
				sel and C.hi or (hover and C.fg or C.dim), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

			local badge = self.Page.badge and self.Page.badge()

			if badge and badge ~= "" then
				T.Text(badge, "HGB.TS", w - T.S(8), h / 2, C.acc, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
			end
		end
		b.DoClick = function(self) f:ShowPage(self.Page.id) end

		return b
	end

	local function Sidebar(f)
		local side = vgui.Create("DPanel", f)

		side:Dock(LEFT)
		side:SetWide(T.S(236))
		side.Paint = function(self, w, h)
			T.Rect(0, 0, w, h, T.C.panel)
			T.Rect(w - 1, 0, 1, h, T.C.line)
		end

		-- male07, small, with his eyes going
		if T.cv.art:GetBool() then
			local art = vgui.Create("DPanel", side)

			art:Dock(TOP)
			art:SetTall(T.S(150))
			art:SetCursor("hand")
			art.Paint = function(self, w, h)
				local size = T.ArtFit("mini", w - T.S(16), h - T.S(16))
				local aw, ah = T.ArtSize("mini", size)

				T.DrawArt("mini", math.floor((w - aw) / 2), math.floor((h - ah) / 2), size)
			end
			art.OnMousePressed = function() f:ShowPage("status") end
			art:SetTooltip(L("term.art.tip"))
		end

		local search = T.Entry(side, L("search"))

		search:Dock(TOP)
		search:DockMargin(T.S(8), T.S(6), T.S(8), T.S(6))
		search:SetUpdateOnType(true)
		search.OnValueChange = function(self, text)
			timer.Create("hg_bot_term_search", 0.15, 1, function()
				if not IsValid(f) then return end

				if string.Trim(text) == "" then
					f:ShowPage(f.LastPage or "status")
				else
					f:ShowPage("search", text, true)
				end
			end)
		end

		f.Search = search

		local list = T.Scroll(side)

		list:Dock(FILL)
		list:DockMargin(0, 0, 1, 0)

		local index = 0
		local section

		for _, page in ipairs(T.PageList()) do
			if not page.hidden then
				if page.section ~= section then
					section = page.section

					local head = vgui.Create("DPanel", list)

					head:Dock(TOP)
					head:SetTall(T.S(24))
					head.Text = section
					head.Paint = function(self, w, h)
						T.Text(self.Text, "HGB.TS", T.S(8), h - T.S(5), T.C.faint, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
						T.Rect(T.S(8), h - 2, w - T.S(16), 1, T.C.line)
					end
				end

				index = index + 1
				NavButton(f, list, page, index)
			end
		end

		return side
	end

	--- Open the terminal. opts (tests): manual = build it without taking the
	-- mouse (for an off-screen picture), boot = force the boot screen on/off.
	function hg.bots.OpenMenu(pageId, opts)
		opts = opts or {}

		if IsValid(hg.bots.MenuFrame) then hg.bots.MenuFrame:Remove() end

		T.Theme()

		local f = vgui.Create("EditablePanel")
		local w = math.Clamp(cookie.GetNumber("hgbots_term_w", T.S(1000)), math.min(T.S(760), ScrW()), ScrW())
		local h = math.Clamp(cookie.GetNumber("hgbots_term_h", T.S(700)), math.min(T.S(500), ScrH()), ScrH())
		local x = cookie.GetNumber("hgbots_term_x", -1)
		local y = cookie.GetNumber("hgbots_term_y", -1)

		f:SetSize(w, h)

		if x < 0 or y < 0 or x + w > ScrW() or y + h > ScrH() then f:Center() else f:SetPos(x, y) end

		if opts.manual then
			f:SetPaintedManually(true)
			f:SetMouseInputEnabled(false)
		else
			f:MakePopup()
			f:SetKeyboardInputEnabled(true)
			f:SetAlpha(0)
			f:AlphaTo(255, 0.12)
		end

		hg.bots.MenuFrame = f

		f.Paint = function(self, pw, ph)
			local C = T.C

			T.Rect(0, 0, pw, ph, C.bg)
		end

		f.PaintOver = function(self, pw, ph)
			T.Box(0, 0, pw, ph, T.C.acc, 10)

			if not IsValid(self.BootPanel) then T.PaintCRT(pw, ph) end
		end

		function f:Close()
			if self.Closing then return end

			self.Closing = true

			Save(self)
			self:SetMouseInputEnabled(false)
			self:SetKeyboardInputEnabled(false)
			self:AlphaTo(0, 0.1, 0, function() if IsValid(self) then self:Remove() end end)
		end

		Header(f)
		Footer(f)
		Sidebar(f)

		local content = vgui.Create("DPanel", f)

		content:Dock(FILL)
		content.Paint = nil

		-- Page title strip: the path, the page name, the page's own tools.
		local top = vgui.Create("DPanel", content)

		top:Dock(TOP)
		top:SetTall(T.S(58))
		top:DockMargin(T.S(14), T.S(8), T.S(14), 0)
		top.Paint = function(self, pw, ph)
			local C = T.C
			local page = f.PageDef

			if not page then return end

			local user = string.lower(T.Rights())

			T.Text(user .. "@hgbots:~/" .. (page.path or page.id) .. " $", "HGB.TS", 0, T.S(2), C.faint)

			do
				local tw = T.TextW(user .. "@hgbots:~/" .. (page.path or page.id) .. " $ ", "HGB.TS")

				T.Rect(tw, T.S(4), T.S(7), T.FontH("HGB.TS") - T.S(4), C.dim)
			end

			page.upper = page.upper or T.Upper(page.title)

			T.Text(page.upper, "HGB.TH", 0, T.S(20), C.hi)
			T.Rect(0, ph - 1, pw, 1, C.line)
		end

		local tools = vgui.Create("DPanel", top)

		tools:Dock(RIGHT)
		tools:DockMargin(0, T.S(20), 0, T.S(6))
		tools:SetWide(T.S(420))
		tools.Paint = nil

		local holder = vgui.Create("DPanel", content)

		holder:Dock(FILL)
		holder:DockMargin(T.S(14), T.S(8), T.S(10), T.S(8))
		holder.Paint = nil

		f.Tools = tools
		f.Holder = holder

		--- Put a page up. `arg` goes to the page (the search text).
		function f:ShowPage(id, arg, keepSearch)
			local page = T.FindPage(id) or T.FindPage("status")

			if not page then return end

			if IsValid(self.Page) then
				M.listeners[self.Page] = nil
				self.Page:Remove()
			end

			self.Tools:Clear()

			if page.id ~= "search" then
				self.LastPage = page.id
				cookie.Set("hgbots_term_page", page.id)

				if not keepSearch and IsValid(self.Search) and self.Search:GetValue() ~= "" then
					self.Search:SetText("")
				end
			end

			local p

			if page.full then
				p = vgui.Create("DPanel", self.Holder)
				p.Paint = nil
			else
				p = T.Scroll(self.Holder)
			end

			p:Dock(FILL)

			self.Page = p
			self.PageId = page.id
			self.PageDef = page

			page.build(p, { win = self, arg = arg, tools = self.Tools })

			if id ~= self.LastSound then T.Sound("nav") end

			self.LastSound = id
		end

		function f:OnKeyCodePressed(code)
			if input.IsControlDown() and code == KEY_F and IsValid(self.Search) then
				self.Search:RequestFocus()
			elseif input.IsControlDown() and code == KEY_Z then
				local what = M.Undo()

				if what then
					M.Log(string.format(L("term.undone"), what), "ok")
					T.Sound("toggle")
				else
					T.Sound("deny")
				end
			elseif code == KEY_F5 then
				M.Request()
				T.Sound("click")
			elseif IsValid(self.BootPanel) then
				self.BootPanel.Skip()
			end
		end

		f.OnRemove = function(self)
			if hg.bots.MenuFrame == self then hg.bots.MenuFrame = nil end
		end

		f:ShowPage(pageId or cookie.GetString("hgbots_term_page", "status"))

		M.Request()

		-- The boot sequence: every time, the first time per session, never.
		local intro = T.cv.intro:GetInt()

		if opts.boot == true or (opts.boot == nil and (intro == 2 or (intro == 1 and not T.bootedOnce))) then
			T.bootedOnce = true

			f.BootPanel = T.Boot(f, function() if IsValid(f) and IsValid(f.Search) then f:RequestFocus() end end)
		elseif not opts.manual then
			T.Sound("open")
		end

		return f
	end

	-- Escape closes the terminal instead of opening the pause menu
	-- (Z-City asks OnShowZCityPause first; sandbox only has the engine hook).
	local function EscClose()
		local f = hg.bots.MenuFrame

		if IsValid(f) and not f.Closing then
			f:Close()

			return false
		end
	end

	hook.Add("OnShowZCityPause", "HG_Bots_Term", EscClose)
	hook.Add("OnPauseMenuShow", "HG_Bots_Term", EscClose)
--//
