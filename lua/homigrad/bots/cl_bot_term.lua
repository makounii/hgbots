--[[
	HGBots - terminal look (palette, fonts, sounds, widgets)

	Everything the terminal window draws with. Kept apart from the pages so
	both stay under the client-file size limit. All of it hangs off
	hg.bots.Term (T): a hot reload of this file swaps the functions and the
	open window picks them up on its next frame.

	The look: black glass, one phosphor colour for text (bone white by
	default, or green / amber / cyan / red), red for anything that bites,
	thin rules, square brackets round everything clickable.

	Client options (all on the terminal's INTERFACE page):
	  hg_bot_ui_color   phosphor: 0 bone, 1 green, 2 amber, 3 cyan, 4 blood
	  hg_bot_ui_scale   text size, 0.8 - 1.5
	  hg_bot_ui_intro   boot screen: 0 never, 1 first open, 2 every open
	  hg_bot_ui_scanlines  faint still scanlines (off by default)
	  hg_bot_ui_sound   clicks and beeps
	  hg_bot_ui_help    each parameter's help line under it
	  hg_bot_ui_art     male07 in the sidebar
	  hg_bot_ui_chat    server replies also in chat while the terminal is up
]]

hg = hg or {}
hg.bots = hg.bots or {}

local T = hg.bots.Term or {}
hg.bots.Term = T

local M = hg.bots.Menu or {}
hg.bots.Menu = M

local L = function(key) return hg.bots.L and hg.bots.L(key) or key end

T.L = L

--\\ Client options
	T.cv = T.cv or {}

	local function Option(name, def, help, min, max)
		T.cv[name] = CreateClientConVar("hg_bot_ui_" .. name, def, true, false, help, min, max)
	end

	Option("color", "0", "HGBots terminal phosphor: 0 bone, 1 green, 2 amber, 3 cyan, 4 blood", 0, 4)
	Option("scale", "1", "HGBots terminal text size", 0.8, 1.5)
	Option("intro", "1", "HGBots boot screen: 0 never, 1 first open per session, 2 every open", 0, 2)
	Option("scanlines", "0", "Faint still scanlines over the HGBots terminal", 0, 1)
	Option("sound", "1", "HGBots terminal clicks and beeps", 0, 1)
	Option("help", "1", "Show each parameter's help line in the HGBots terminal", 0, 1)
	Option("art", "1", "male07 in the HGBots terminal sidebar", 0, 1)
	Option("chat", "0", "HGBots server replies also go to chat while the terminal is open", 0, 1)

--//

--\\ Palette
	local PHOSPHOR = {
		[0] = { fg = Color(196, 200, 202), acc = Color(196, 78, 70) },   -- bone, muted red marks
		[1] = { fg = Color(130, 205, 145), acc = Color(185, 235, 190) }, -- green
		[2] = { fg = Color(225, 175, 100), acc = Color(245, 215, 160) }, -- amber
		[3] = { fg = Color(135, 195, 210), acc = Color(190, 230, 240) }, -- cyan
		[4] = { fg = Color(210, 120, 110), acc = Color(240, 200, 190) }, -- blood
	}

	local function Mix(a, b, f)
		return Color(a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f, 255)
	end

	local function Alpha(c, a)
		return Color(c.r, c.g, c.b, a)
	end

	T.Mix, T.Alpha = Mix, Alpha

	T.C = T.C or {}

	--- Rebuild the colours from the phosphor option.
	function T.Theme()
		local p = PHOSPHOR[math.Clamp(math.floor(T.cv.color:GetInt()), 0, 4)] or PHOSPHOR[0]
		local C = T.C
		local black = Color(0, 0, 0)

		C.bg = Color(16, 17, 19, 252)
		C.panel = Color(21, 22, 25)
		C.row = Color(28, 30, 33)
		C.rowHi = Color(36, 38, 42)
		C.line = Color(48, 51, 56)
		C.faint = Mix(Color(20, 20, 22), p.fg, 0.42)
		C.dim = Mix(Color(20, 20, 22), p.fg, 0.66)
		C.fg = p.fg
		C.hi = Mix(p.fg, Color(255, 255, 255), 0.35)
		C.acc = p.acc
		C.accDim = Mix(black, p.acc, 0.45)
		C.red = Color(214, 82, 74)
		C.redDim = Color(120, 30, 28)
		C.ok = Color(120, 196, 135)
		C.warn = Color(220, 182, 100)
		C.black = black

		-- The art's seven grey levels, tinted with the phosphor.
		C.art = {}

		for i = 1, 7 do
			C.art[i] = Mix(black, Mix(p.fg, Color(255, 255, 255), 0.25), 0.16 + 0.84 * (i / 7) ^ 1.15)
		end
	end

	T.Theme()

	cvars.AddChangeCallback("hg_bot_ui_color", function() T.Theme() end, "HG_Bots_Term")
--//

--\\ Fonts
	-- Consolas everywhere: a fixed-width face is what makes the ASCII art
	-- line up. Clients without it fall back to another face; the art then
	-- draws cell by cell instead (see T.Mono).
	local FACE = system.IsWindows() and "Consolas" or "Courier New"

	function T.S(n)
		return math.floor(n * math.Clamp(T.cv.scale:GetFloat(), 0.8, 1.5) + 0.5)
	end

	function T.Fonts()
		surface.CreateFont("HGB.T", { font = FACE, size = T.S(15), weight = 500, antialias = true, extended = true })
		surface.CreateFont("HGB.TS", { font = FACE, size = T.S(13), weight = 500, antialias = true, extended = true })
		surface.CreateFont("HGB.TB", { font = FACE, size = T.S(15), weight = 800, antialias = true, extended = true })
		surface.CreateFont("HGB.TH", { font = FACE, size = T.S(22), weight = 800, antialias = true, extended = true })
		surface.CreateFont("HGB.TX", { font = FACE, size = T.S(34), weight = 900, antialias = true, extended = true })

		T.artFonts = {}
		T.mono = nil
	end

	T.Fonts()

	cvars.AddChangeCallback("hg_bot_ui_scale", function()
		timer.Create("hg_bot_ui_fonts", 0.3, 1, function()
			T.Fonts()

			if IsValid(hg.bots.MenuFrame) then hg.bots.OpenMenu(hg.bots.MenuFrame.PageId) end
		end)
	end, "HG_Bots_Term")

	--- An art font of a given pixel size (made the first time it is asked for).
	function T.ArtFont(size)
		size = math.Clamp(math.floor(size), 5, 18)

		local name = "HGB.Art" .. size

		if not T.artFonts[size] then
			surface.CreateFont(name, { font = FACE, size = size, weight = 700, antialias = true, extended = false })
			T.artFonts[size] = true
		end

		return name
	end

	--- Width of one character, and whether the face really is fixed-width.
	function T.Mono(font)
		surface.SetFont(font)

		local w1 = surface.GetTextSize("W")
		local w2 = surface.GetTextSize(".")
		local w10 = surface.GetTextSize("WWWWWWWWWW")

		return w10 / 10, math.abs(w1 - w2) < 0.5
	end

	function T.TextW(text, font)
		surface.SetFont(font)

		return (surface.GetTextSize(text))
	end

	function T.FontH(font)
		surface.SetFont(font)

		local _, h = surface.GetTextSize("Ag")

		return h
	end

	--- Lines of `text` that fit `width` in `font` (words kept whole).
	function T.Wrap(text, font, width)
		local out = {}

		surface.SetFont(font)

		for _, para in ipairs(string.Explode("\n", tostring(text or ""))) do
			local line = ""

			for word in string.gmatch(para, "%S+") do
				local try = line == "" and word or (line .. " " .. word)

				if surface.GetTextSize(try) > width and line ~= "" then
					out[#out + 1] = line
					line = word
				else
					line = try
				end
			end

			out[#out + 1] = line
		end

		return out
	end

	--- Cut `text` to `width`, ending in ".." when it had to be cut. Cuts
	-- only between whole UTF-8 characters (Russian labels are two bytes a
	-- letter; half a letter draws as garbage).
	function T.Fit(text, font, width)
		text = tostring(text or "")

		surface.SetFont(font)

		if surface.GetTextSize(text) <= width then return text end

		for i = #text - 1, 1, -1 do
			local nb = string.byte(text, i + 1)

			if nb < 0x80 or nb >= 0xC0 then
				local try = string.sub(text, 1, i) .. ".."

				if surface.GetTextSize(try) <= width then return try end
			end
		end

		return ""
	end

	--- string.upper that also knows Cyrillic (Lua's only does A-Z).
	function T.Upper(text)
		text = string.upper(tostring(text or ""))

		if not string.find(text, "[\208\209]") then return text end

		local out = {}

		for _, code in utf8.codes(text) do
			if code >= 0x430 and code <= 0x44F then
				code = code - 0x20
			elseif code == 0x451 then
				code = 0x401
			end

			out[#out + 1] = utf8.char(code)
		end

		return table.concat(out)
	end
--//

--\\ Sounds
	local SOUNDS = {
		click = "buttons/button15.wav",
		toggle = "buttons/blip1.wav",
		nav = "ui/buttonclickrelease.wav",
		type = "ambient/machines/keyboard2_clicks.wav",
		boot = "ambient/machines/keyboard7_clicks_enter.wav",
		granted = "buttons/button3.wav",
		deny = "buttons/button10.wav",
		open = "buttons/button9.wav",
	}

	local lastSound = 0

	function T.Sound(kind)
		if not T.cv.sound:GetBool() then return end

		local now = RealTime()

		-- A drag or a quick double click shouldn't machine-gun.
		if kind ~= "deny" and now - lastSound < 0.04 then return end

		lastSound = now

		surface.PlaySound(SOUNDS[kind] or SOUNDS.click)
	end
--//

--\\ Drawing helpers
	function T.Rect(x, y, w, h, col)
		surface.SetDrawColor(col)
		surface.DrawRect(x, y, w, h)
	end

	function T.Frame(x, y, w, h, col)
		surface.SetDrawColor(col)
		surface.DrawOutlinedRect(x, y, w, h, 1)
	end

	--- A box with corner ticks, like a terminal panel.
	function T.Box(x, y, w, h, col, tick)
		tick = tick or 6

		surface.SetDrawColor(T.C.line)
		surface.DrawOutlinedRect(x, y, w, h, 1)
		surface.SetDrawColor(col or T.C.dim)
		surface.DrawRect(x, y, tick, 1)
		surface.DrawRect(x, y, 1, tick)
		surface.DrawRect(x + w - tick, y, tick, 1)
		surface.DrawRect(x + w - 1, y, 1, tick)
		surface.DrawRect(x, y + h - 1, tick, 1)
		surface.DrawRect(x, y + h - tick, 1, tick)
		surface.DrawRect(x + w - tick, y + h - 1, tick, 1)
		surface.DrawRect(x + w - 1, y + h - tick, 1, tick)
	end

	function T.Text(text, font, x, y, col, ax, ay)
		return draw.SimpleText(text, font, x, y, col, ax or TEXT_ALIGN_LEFT, ay or TEXT_ALIGN_TOP)
	end

	--- "[##########---------]" as blocks, with `frac` of it filled.
	function T.Bar(x, y, w, h, frac, col, back)
		local cells = math.max(4, math.floor(w / T.S(6)))
		local cw = w / cells
		local filled = math.Clamp(frac, 0, 1) * cells

		for i = 0, cells - 1 do
			local cx = math.floor(x + i * cw)
			local nx = math.floor(x + (i + 1) * cw) - 1

			if i < filled then
				surface.SetDrawColor(col)
				surface.DrawRect(cx, y, math.max(1, nx - cx), h)
			else
				surface.SetDrawColor(back or T.C.line)
				surface.DrawRect(cx, y + math.floor(h / 2), math.max(1, nx - cx), 1)
			end
		end
	end

	local function Value(v, b)
		if not b then return tostring(v) end

		if (b[2] or 1) > 20 then return tostring(math.Round(v)) end

		return string.format("%.2f", v)
	end

	T.Value = Value
--//

--\\ Widgets
	--- A bracketed button. kind: nil, "danger", "accent", "ghost".
	function T.Button(parent, text, fn, kind)
		local b = vgui.Create("DButton", parent)

		b:SetText("")
		b:SetTall(T.S(26))
		b:SetCursor("hand")
		b.Label = text
		b.Kind = kind
		b.DoClick = function(self)
			if not self:IsEnabled() then return end

			T.Sound(self.Kind == "danger" and "toggle" or "click")

			if fn then fn(self) end
		end

		b.Paint = function(self, w, h)
			local C = T.C
			local on = self:IsEnabled()
			local col = self.Kind == "danger" and C.red or (self.Kind == "accent" and C.acc or C.fg)

			if not on then col = C.faint end

			local hover = on and self:IsHovered()

			if self.Kind ~= "ghost" or hover then
				T.Rect(0, 0, w, h, hover and Alpha(col, self:IsDown() and 90 or 34) or C.row)
				T.Frame(0, 0, w, h, hover and col or C.line)
			end

			local label = (hover and "> " or "") .. self.Label

			T.Text(T.Fit(label, "HGB.T", w - 10), "HGB.T", w / 2, h / 2, hover and C.hi or col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		return b
	end

	--- A section rule: "// TITLE ----------".
	function T.Header(parent, text)
		local p = vgui.Create("DPanel", parent)

		p:Dock(TOP)
		p:DockMargin(0, T.S(10), 0, T.S(4))
		p:SetTall(T.S(20))
		p.Text = text
		p.Paint = function(self, w, h)
			local C = T.C
			self.Upper = self.Upper or T.Upper(self.Text)

			local label = "// " .. self.Upper .. " "
			local tw = T.TextW(label, "HGB.TB")

			T.Text(label, "HGB.TB", 0, h / 2, C.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			T.Rect(tw + 4, math.floor(h / 2), w - tw - 4, 1, C.line)
		end

		return p
	end

	--- Wrapped dim text.
	function T.Note(parent, text, col)
		local l = vgui.Create("DLabel", parent)

		l:Dock(TOP)
		l:DockMargin(T.S(2), T.S(2), T.S(2), T.S(6))
		l:SetFont("HGB.TS")
		l:SetText(text)
		l:SetWrap(true)
		l:SetAutoStretchVertical(true)
		l:SetTextColor(col or T.C.dim)

		return l
	end

	--- A text box in the terminal style.
	function T.Entry(parent, placeholder)
		local e = vgui.Create("DTextEntry", parent)

		e:SetFont("HGB.T")
		e:SetTall(T.S(26))
		e:SetPaintBackground(false)
		e.Hint = placeholder or ""
		e.Paint = function(self, w, h)
			local C = T.C
			local focus = self:HasFocus()

			T.Rect(0, 0, w, h, C.panel)
			T.Frame(0, 0, w, h, focus and C.acc or C.line)

			if self:GetValue() == "" and not focus then
				T.Text(self.Hint, "HGB.T", T.S(6), h / 2, C.faint, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			end

			self:DrawTextEntryText(C.fg, Alpha(C.acc, 90), C.acc)
		end

		return e
	end

	--- A scroll panel with a thin bar.
	function T.Scroll(parent)
		local s = vgui.Create("DScrollPanel", parent)
		local bar = s:GetVBar()

		bar:SetWide(T.S(7))
		bar:SetHideButtons(true)
		bar.Paint = function(self, w, h) T.Rect(math.floor(w / 2), 0, 1, h, T.C.line) end
		bar.btnGrip.Paint = function(self, w, h)
			T.Rect(1, 0, w - 2, h, (self:IsHovered() or self.Depressed) and T.C.acc or T.C.faint)
		end

		return s
	end

	--- Inline number entry over `panel` (double click on a value).
	function T.AskNumber(panel, x, y, w, h, value, done)
		if IsValid(panel.Ask) then panel.Ask:Remove() end

		local e = T.Entry(panel, "")

		e:SetPos(x, y)
		e:SetSize(w, h)
		e:SetValue(tostring(value))
		e:SetNumeric(true)
		e:RequestFocus()
		e:SelectAllOnFocus()
		e.OnEnter = function(self)
			local v = tonumber(self:GetValue())

			self:Remove()

			if v then done(v) end
		end
		e.OnLoseFocus = function(self)
			timer.Simple(0, function() if IsValid(self) then self:Remove() end end)
		end

		panel.Ask = e

		return e
	end
--//

--\\ One parameter as a row
	--[[
		  * sight range ............ [#########-------] 4500
		    How far a bot can see a standing man in daylight.

		Left: pin mark (click to pin/unpin) and a "changed" dot. Right: the
		control. Under it, the convar's own help text when that option is
		on. Right click anywhere on the row puts the default back;
		click a slider's number to type one; shift + wheel nudges a
		slider (with ctrl: ten times as far). A row the player has no rights for reads LOCKED.
	]]
	local ROW_H = 26

	--- Where a row reads and writes its value. The server parameters are
	-- the usual source; the INTERFACE page hands in one for client convars.
	T.ServerSource = {
		pins = true,
		get = function(name) return M.values[name] end,
		bounds = function(name) return M.bounds[name] end,
		set = function(name, v, drag) return M.Set(name, v, false, drag) end,
		changed = function(name) return M.Changed(name) end,
		default = function(name) return M.Default(name) end,
		locked = function(name, info) return not M.MayEdit(info.level) end,
		label = function(name) return hg.bots.LSetting(name) end,
		hidden = function(name) return M.synced and not M.bounds[name] end,
	}

	local function Pinned(name)
		return T.pins and T.pins[name] == true
	end

	function T.LoadPins()
		T.pins = util.JSONToTable(file.Read("hgbots_pins.json", "DATA") or "") or {}
	end

	function T.TogglePin(name)
		if not T.pins then T.LoadPins() end

		T.pins[name] = (not T.pins[name]) or nil

		file.Write("hgbots_pins.json", util.TableToJSON(T.pins))
	end

	if not T.pins then T.LoadPins() end

	local function SliderGeom(w, h)
		local cw = math.floor(w * 0.44)
		local vx = w - T.S(64)
		local bx = w - cw

		return bx, vx - T.S(8) - bx, vx, T.S(64)
	end

	function T.SettingRow(parent, name, info, src)
		src = src or T.ServerSource

		local row = vgui.Create("DPanel", parent)

		row:Dock(TOP)
		row:DockMargin(0, 0, 0, 1)
		row.Name = name
		row.Info = info
		row.HelpLines = {}

		local function help()
			local b = src.bounds(name)

			return b and b[3] or ""
		end

		row.PerformLayout = function(self, w)
			local lines = {}

			if T.cv.help:GetBool() and help() ~= "" then
				lines = T.Wrap(help(), "HGB.TS", math.max(80, w - T.S(40)))

				if #lines > 3 then
					lines = { lines[1], lines[2], lines[3] .. " .." }
				end
			end

			self.HelpLines = lines

			local h = T.S(ROW_H) + #lines * T.FontH("HGB.TS") + (#lines > 0 and T.S(4) or 0)

			if info.choices then h = h + #info.choices * T.S(22) + T.S(4) end

			if self:GetTall() ~= h then self:SetTall(h) end
		end

		row.Paint = function(self, w, h)
			local C = T.C
			local locked = src.locked(name, info)
			local changed = src.changed(name)
			local hover = self:IsHovered() or self:IsChildHovered()
			local top = T.S(ROW_H)

			if hover then T.Rect(0, 0, w, h, C.row) end

			-- pin + changed marks
			local pinned = src.pins and Pinned(name)

			if src.pins then
				T.Text(pinned and "*" or (hover and "+" or " "), "HGB.TB", T.S(4), top / 2,
					pinned and C.acc or C.faint, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			end

			if changed then T.Rect(T.S(16), math.floor(top / 2) - 2, 4, 4, C.acc) end

			-- label
			local labelW = info.choices and (w - T.S(30)) or (math.floor(w * 0.56) - T.S(34))
			local label = src.label(name)

			T.Text(T.Fit(label, "HGB.T", labelW), "HGB.T", T.S(26), top / 2,
				locked and C.faint or (changed and C.hi or C.fg), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

			-- help
			local fh = T.FontH("HGB.TS")

			for i, line in ipairs(self.HelpLines) do
				T.Text(line, "HGB.TS", T.S(26), top + (i - 1) * fh - T.S(2), C.faint)
			end

			if locked then
				T.Text("[LOCKED]", "HGB.TS", w - T.S(6), top / 2, C.redDim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

				return
			end

			local v = src.get(name) or 0
			local b = src.bounds(name) or { 0, 1, "", 0 }

			if info.choices then return end

			if info.bool then
				local on = v >= 0.5
				local bw = T.S(52)
				local x = w - bw * 2 - T.S(6)

				for i, state in ipairs({ true, false }) do
					local bx = x + (i - 1) * bw
					local sel = on == state

					if sel then T.Rect(bx, T.S(4), bw - 2, top - T.S(8), state and Alpha(C.acc, 60) or C.rowHi) end

					T.Frame(bx, T.S(4), bw - 2, top - T.S(8), sel and (state and C.acc or C.dim) or C.line)
					T.Text(state and "ON" or "OFF", "HGB.TB", bx + (bw - 2) / 2, top / 2,
						sel and (state and C.hi or C.fg) or C.faint, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				end

				return
			end

			local bx, bw, vx, vw = SliderGeom(w, top)
			local frac = (v - b[1]) / math.max(b[2] - b[1], 0.00001)

			T.Text("[", "HGB.T", bx - T.S(2), top / 2, C.faint, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
			T.Bar(bx + T.S(2), math.floor(top / 2) - T.S(4), bw - T.S(4), T.S(8), frac,
				(self.Dragging or hover) and C.acc or C.dim, C.line)
			T.Text("]", "HGB.T", bx + bw + T.S(2), top / 2, C.faint, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

			-- the default as a tick under the bar
			local df = ((b[4] or 0) - b[1]) / math.max(b[2] - b[1], 0.00001)

			if df >= 0 and df <= 1 then
				T.Rect(bx + T.S(2) + math.floor(df * (bw - T.S(4))), math.floor(top / 2) + T.S(6), 1, T.S(3), C.faint)
			end

			T.Text(Value(v, b), "HGB.TB", vx + vw - T.S(6), top / 2, changed and C.hi or C.fg, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end

		-- Choices: one line each under the label.
		if info.choices then
			row.Choices = {}

			for index, key in ipairs(info.choices) do
				local c = vgui.Create("DButton", row)

				c:SetText("")
				c:SetCursor("hand")
				c.Value = index - 1
				c.Paint = function(self, w, h)
					local C = T.C
					local sel = math.floor(src.get(name) or 0) == self.Value
					local hover = self:IsHovered()

					if hover then T.Rect(0, 0, w, h, C.rowHi) end

					T.Text((sel and "(*) " or "( ) ") .. L(key), "HGB.T", T.S(4), h / 2,
						sel and C.acc or (hover and C.fg or C.dim), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				end
				c.DoClick = function(self)
					if src.locked(name, info) then T.Sound("deny") return end

					T.Sound("toggle")

					if src.set(name, self.Value) then M.Notify() end
				end
				c.DoRightClick = function() row:OnMousePressed(MOUSE_RIGHT) end

				row.Choices[index] = c
			end

			local layout = row.PerformLayout

			row.PerformLayout = function(self, w, h)
				layout(self, w, h)

				local y = T.S(ROW_H) + #self.HelpLines * T.FontH("HGB.TS") + (#self.HelpLines > 0 and T.S(4) or 0)

				for i, c in ipairs(self.Choices) do
					c:SetPos(T.S(26), y + (i - 1) * T.S(22))
					c:SetSize(w - T.S(32), T.S(20))
				end
			end
		end

		row.OnMousePressed = function(self, code)
			local x, y = self:CursorPos()
			local w = self:GetWide()
			local top = T.S(ROW_H)

			if code == MOUSE_RIGHT then
				local def = src.default(name)

				if def and not src.locked(name, info) then
					if src.set(name, def) then
						T.Sound("toggle")
						M.Notify()
					end
				end

				return
			end

			if code ~= MOUSE_LEFT then return end

			-- the pin mark
			if src.pins and x < T.S(22) and y < top then
				T.TogglePin(name)
				T.Sound("click")

				if T.OnPins then T.OnPins() end

				return
			end

			if y > top or info.choices then return end

			if src.locked(name, info) then T.Sound("deny") return end

			if info.bool then
				local bw = T.S(52)
				local bx = w - bw * 2 - T.S(6)

				if x >= bx then
					local on = x < bx + bw

					if src.set(name, on and 1 or 0) then
						T.Sound("toggle")
						M.Notify()
					end
				end

				return
			end

			local bx, bw, vx = SliderGeom(w, top)

			if x >= bx - T.S(4) and x <= bx + bw + T.S(4) then
				self.Dragging = true
				self:MouseCapture(true)
				T.Sound("click")
			elseif x >= vx then
				-- a click on the number: type one in
				local b = src.bounds(name) or { 0, 1 }

				T.AskNumber(self, vx, T.S(2), w - vx - T.S(2), top - T.S(4), Value(src.get(name) or 0, b), function(v)
					if src.set(name, v) then M.Notify() end
				end)
			end
		end

		row.OnMouseReleased = function(self, code)
			if self.Dragging then
				self.Dragging = nil
				self:MouseCapture(false)
				M.Notify()
			end
		end

		row.Think = function(self)
			if not self.Dragging then return end

			if not input.IsMouseDown(MOUSE_LEFT) then
				self.Dragging = nil
				self:MouseCapture(false)
				M.Notify()

				return
			end

			local x = self:CursorPos()
			local bx, bw = SliderGeom(self:GetWide(), T.S(ROW_H))
			local b = src.bounds(name)

			if not b then return end

			local frac = math.Clamp((x - bx - T.S(2)) / math.max(bw - T.S(4), 1), 0, 1)
			local v = b[1] + (b[2] - b[1]) * frac

			-- whole numbers on wide ranges, otherwise steps of 0.01
			v = (b[2] > 20) and math.Round(v) or math.Round(v, 2)

			src.set(name, v, true)
		end

		row.OnMouseWheeled = function(self, delta)
			if info.bool or info.choices or not input.IsShiftDown() or src.locked(name, info) then return false end

			local b = src.bounds(name)

			if not b then return false end

			local step = (b[2] > 20) and math.max(1, math.Round((b[2] - b[1]) / 100)) or 0.01

			if input.IsControlDown() then step = step * 10 end

			if src.set(name, (src.get(name) or 0) + delta * step, true) then
				T.Sound("click")
				M.Notify()
			end

			return true
		end

		row.Refresh = function(self)
			-- Not in the server's catalogue (the convar doesn't exist
			-- there): a control that changes nothing is worse than none.
			local hide = src.hidden(name)

			if self:IsVisible() == hide then
				self:SetVisible(not hide)
				self:InvalidateParent()
			end

			local tip = name

			if help() ~= "" then tip = tip .. "\n" .. help() end

			local def = src.default(name)

			if def then tip = tip .. "\n" .. L("term.default") .. ": " .. Value(def, src.bounds(name)) end

			tip = tip .. "\n" .. (src.locked(name, info) and L(info.level == "superadmin" and "need.superadmin" or "need.admin")
				or L("term.row.hint"))

			if self.Tip ~= tip then
				self.Tip = tip
				self:SetTooltip(tip)
			end

			self:InvalidateLayout()
		end

		row:Refresh()

		return row
	end
--//

--\\ A list with columns (bots, kits, items)
	--[[
		cols = { { "NAME", 0.4 }, { "STATE", 0.3 }, ... } (fractions of the
		width). list:Add({ "a", "b" }, data) returns the line;
		list.OnSelect(line, data), list.OnDouble(line, data) and
		list.OnRight(line, data) are the hooks.
	]]
	function T.List(parent, cols)
		local wrap = vgui.Create("DPanel", parent)

		wrap.Cols = cols
		wrap.Paint = function(self, w, h)
			local C = T.C

			T.Rect(0, 0, w, h, C.panel)
			T.Frame(0, 0, w, h, C.line)

			local x = T.S(8)

			for _, col in ipairs(self.Cols) do
				T.Text(col[1], "HGB.TS", x, T.S(11), C.faint, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
				x = x + math.floor((w - T.S(16)) * col[2])
			end

			T.Rect(T.S(4), T.S(21), w - T.S(8), 1, C.line)
		end

		local scroll = T.Scroll(wrap)

		scroll:Dock(FILL)
		scroll:DockMargin(1, T.S(23), 1, 1)

		wrap.Scroll = scroll
		wrap.Lines = {}

		function wrap:Clear()
			for _, line in ipairs(self.Lines) do if IsValid(line) then line:Remove() end end

			self.Lines = {}
			self.SelectedLine = nil
		end

		function wrap:Add(cells, data, col)
			local line = vgui.Create("DButton", self.Scroll)

			line:SetText("")
			line:Dock(TOP)
			line:SetTall(T.S(22))
			line.Cells = cells
			line.Data = data
			line.Col = col
			line.Paint = function(s, w, h)
				local C = T.C
				local sel = self.SelectedLine == s
				local hover = s:IsHovered()

				if sel then
					T.Rect(0, 0, w, h, Alpha(C.acc, 40))
					T.Rect(0, 0, 2, h, C.acc)
				elseif hover then
					T.Rect(0, 0, w, h, C.rowHi)
				end

				local x = T.S(7)

				for i, c in ipairs(self.Cols) do
					local cw = math.floor((w - T.S(14)) * c[2])
					local text = tostring(s.Cells[i] or "")

					T.Text(T.Fit(text, "HGB.T", cw - T.S(6)), "HGB.T", x, h / 2,
						(i == 1 and (s.Col or (sel and C.hi or C.fg))) or (sel and C.fg or C.dim), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
					x = x + cw
				end
			end
			line.DoClick = function(s)
				self.SelectedLine = s
				T.Sound("click")

				if self.OnSelect then self.OnSelect(s, s.Data) end
			end
			line.DoDoubleClick = function(s)
				if self.OnDouble then self.OnDouble(s, s.Data) end
			end
			line.DoRightClick = function(s)
				self.SelectedLine = s

				if self.OnRight then self.OnRight(s, s.Data) end
			end

			self.Lines[#self.Lines + 1] = line

			return line
		end

		function wrap:Selected()
			local line = self.SelectedLine

			return IsValid(line) and line.Data or nil, line
		end

		return wrap
	end
--//

--\\ The bot right-click menu in the same clothes
	local function SkinOptions(menu, depth)
		if not IsValid(menu) or depth > 3 then return end

		menu.Paint = function(self, w, h)
			local C = T.C

			T.Rect(0, 0, w, h, Color(6, 7, 8, 245))
			T.Box(0, 0, w, h, C.acc, 5)
		end

		local canvas = menu.GetCanvas and menu:GetCanvas() or menu

		for _, opt in ipairs(canvas:GetChildren()) do
			if opt.SetTextColor and opt.SetFont then
				opt:SetFont("HGB.TS")
				opt:SetTextColor(T.C.fg)
				opt.Paint = function(self, w, h)
					if self:IsHovered() or self.Highlight then
						T.Rect(1, 0, w - 2, h, Alpha(T.C.acc, 50))
						T.Rect(1, 0, 2, h, T.C.acc)
					end
				end

				if opt.SubMenu then SkinOptions(opt.SubMenu, depth + 1) end
			else
				opt.Paint = function(self, w, h) T.Rect(T.S(6), math.floor(h / 2), w - T.S(12), 1, T.C.line) end
			end
		end
	end

	function T.SkinMenu(menu)
		SkinOptions(menu, 0)
	end
--//
