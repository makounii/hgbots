-- Director combat rules. These use our own sides without changing the
-- gamemode's Player:Team(), player classes or round system.
hg.bots = hg.bots or {}

local mode = CreateConVar("hg_bot_director_mode", "0", {FCVAR_ARCHIVE}, "Director mode: 0 = survival, 1 = TDM (players and guards vs raiders), 2 = free for all. Deathmatch modes keep peak population without quiet phases.", 0, 2)

function hg.bots.DirectorMode()
	return mode:GetInt()
end

function hg.bots.IsDirectorBot(bot)
	local director = hg.bots.Director
	return IsValid(bot) and director and director.bots[bot] == true or false
end

local function Side(ent)
	if not ent:IsPlayer() then return nil end
	if not ent.IsHomigradBot then return 1 end -- humans play on the guard side
	if hg.bots.IsDirectorBot(ent) then return ent.hgBotDirectorTeam end
	local faction = hg.bots.GetFaction and hg.bots.GetFaction(ent)
	if faction == "guard" then return 1 end
	if faction == "raider" then return 2 end
end

-- true = allies, false = enemies, nil = ordinary faction/trust rules.
function hg.bots.DirectorFriendly(a, b)
	if mode:GetInt() == 0 or not IsValid(a) or not IsValid(b) then return nil end
	if not a:IsPlayer() or not b:IsPlayer() then return nil end
	if not hg.bots.IsDirectorBot(a) and not hg.bots.IsDirectorBot(b) then return nil end
	if a == b then return true end
	if mode:GetInt() == 2 then return false end
	local sideA, sideB = Side(a), Side(b)
	if sideA and sideB then return sideA == sideB end
end

function hg.bots.ConfigureDirectorBot(bot)
	if not IsValid(bot) then return end
	local side, faction
	if mode:GetInt() == 1 then
		local counts = { 0, 0 }
		for _, human in ipairs(player.GetHumans()) do
			if human:Alive() then counts[1] = counts[1] + 1 end
		end
		local director = hg.bots.Director
		for other in pairs(director and director.bots or {}) do
			if other ~= bot and IsValid(other) and (other:Alive() or other.hgBotSpawning) then
				local team = other.hgBotDirectorTeam
				if team == 1 or team == 2 then counts[team] = counts[team] + 1 end
			end
		end
		side = counts[1] <= counts[2] and 1 or 2
		faction = side == 1 and "guard" or "raider"
	elseif mode:GetInt() == 2 then
		faction = "raider"
	else
		local guards = GetConVar("hg_bot_director_guards")
		faction = guards and math.random() < guards:GetFloat() and "guard" or "raider"
	end
	bot.hgBotDirectorTeam = side
	bot:SetNWInt("hg_bot_director_team", side or 0)
	if hg.bots.SetFaction then hg.bots.SetFaction(bot, faction) end
end

function hg.bots.ReconfigureDirector()
	local director = hg.bots.Director
	if not director then return end
	-- Clear old team assignments before balancing the existing population.
	for bot in pairs(director.bots) do
		if IsValid(bot) then bot.hgBotDirectorTeam = nil end
	end
	for bot in pairs(director.bots) do
		hg.bots.ConfigureDirectorBot(bot)
	end
	for bot in pairs(hg.bots.List or {}) do
		local data = IsValid(bot) and bot.Bot
		local mem = data and data.Memory
		if mem and (hg.bots.IsDirectorBot(bot) or hg.bots.IsDirectorBot(mem.Target)) then
			mem.Target, mem.TargetPos, mem.TargetSeenPos = nil, nil, nil
			mem.Spot = {}
			data.SquadRole = nil
			if hg.bots.ClearPath then hg.bots.ClearPath(data) end
			if hg.bots.SetState then hg.bots.SetState(bot, "idle") end
		end
	end
end

local revision = 0
cvars.AddChangeCallback("hg_bot_director_mode", function(_, old, new)
	if old == new then return end
	revision = revision + 1
	local current = revision
	timer.Simple(0, function()
		if current == revision then hg.bots.ReconfigureDirector() end
	end)
end, "HG_Bots_DirectorMode")
