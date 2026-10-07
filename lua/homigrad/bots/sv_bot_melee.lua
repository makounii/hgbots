--[[
	Tarkov AI - Close quarters

	Melee weapons, weapon-stock bashing and leg kicks. All three drive
	Z-City's existing mechanics through ordinary bot input or its own public
	API - nothing here reimplements damage, animation or hit detection.

	Verified against the real source rather than assumed:

	- Melee weapons are flagged SWEP.ismelee (weapon_hands_sh,
	  weapon_hg_coolhands) and/or SWEP.ismelee2 (the weapon_melee base, which
	  every knife/axe/bat/crowbar/etc derives from). They attack off plain
	  IN_ATTACK via SWEP:PrimaryAttack like any other weapon, so the
	  existing data.Attacking plumbing already works for them - the only
	  thing they need from the AI is to be CLOSE, since combat.lua's
	  hg_bot_engage_dist (250u default) is far outside any melee reach.

	- Stock bashing is in the weapon base (weapons/homigrad_base/shared.lua,
	  the GetButtstockAttack block). Its conditions are exact and all have
	  to hold simultaneously: IN_ATTACK **and** IN_USE both held, the owner
	  NOT ragdolled (`!(IsValid(owner.FakeRagdoll) or
	  IsValid(owner.FakeRagdollOld))`), not mid-leg-kick
	  (`GetNWFloat("InLegKick") <= CurTime()`), and moving slower than 250
	  u/s. That last one matters for the AI: a bot sprinting at someone
	  will silently never bash, so this file stops it first. Cooldown
	  scales with weapon weight and stamina, which is why the retry
	  interval below is generous rather than every tick.
	  Note the IN_ATTACK+IN_USE pair is the same combination
	  sv_bot_downed.lua holds (with IN_ATTACK2) to aim while ragdolled -
	  they can't collide, because bashing explicitly requires NOT being
	  ragdolled and the downed state never holds IN_ATTACK without also
	  being in FakeRagdoll.

	- Kicking is Player:LegAttack() in
	  homigrad/dynamic_anims_util/animations/legkick/sv_legkick.lua - a
	  plain method, not an input, so it's just called directly. It already
	  self-gates on alive / not ragdolled / on ground / not sprinting /
	  cooldown / the "PlayerCanLegAttack" hook and returns early when any
	  fails, so calling it optimistically is safe. Its reach is an 82u hull
	  trace forward from eye position; the convar below is deliberately a
	  little under that so a bot doesn't whiff at the very edge. It also
	  needs the hands SWEP in inventory (it notifies and aborts otherwise),
	  which every player has by default via sv_inventory.lua's giveHands.

	Why bashing/kicking instead of just shooting at point blank: both are
	genuinely better than gunfire in a shove-range scramble here - a kick
	staggers and does knockback, and a bash doesn't need a chambered round.
	That's the "Tarkov scav panics and pistol-whips you" texture rather
	than a bot calmly emptying a magazine into someone's chest from 20
	units away.
]]

hg.bots = hg.bots or {}
hg.bots.List = hg.bots.List or {}

local hg_bot_melee_range    = CreateConVar("hg_bot_melee_range",    "80",  {FCVAR_ARCHIVE}, "Distance at which a bot holding a melee weapon closes to swinging range and attacks", 32, 300)
local hg_bot_bash_range     = CreateConVar("hg_bot_bash_range",     "70",  {FCVAR_ARCHIVE}, "Distance at which a bot with a firearm will stock-bash instead of shooting", 32, 200)
local hg_bot_kick_range     = CreateConVar("hg_bot_kick_range",     "70",  {FCVAR_ARCHIVE}, "Distance at which a bot will leg-kick (the underlying mechanic reaches ~82u, this sits under that so it doesn't whiff at the edge)", 32, 120)
local hg_bot_kick_chance    = CreateConVar("hg_bot_kick_chance",    "0.35",{FCVAR_ARCHIVE}, "Chance per close-quarters decision that a bot kicks rather than bashing/swinging", 0, 1)
local hg_bot_kick_cooldown  = CreateConVar("hg_bot_kick_cooldown",  "1.5", {FCVAR_ARCHIVE}, "Minimum seconds between a bot's own kick attempts (the mechanic has its own longer cooldown too)", 0.2, 10)
local hg_bot_bash_retry     = CreateConVar("hg_bot_bash_retry",     "0.8", {FCVAR_ARCHIVE}, "Seconds a bot holds the bash input combo before re-deciding - the underlying cooldown scales with weapon weight and stamina", 0.1, 5)
local hg_bot_cqc_enabled    = CreateConVar("hg_bot_cqc_enabled",    "1",   {FCVAR_ARCHIVE}, "Enable melee swings, stock bashing and kicks at close range", 0, 1)

--\\ Recognition
	--- Whether wep is a dedicated melee weapon (knife, bat, crowbar, fists).
	function hg.bots.IsMeleeWeapon(wep)
		if not IsValid(wep) then return false end

		return (wep.ismelee or wep.ismelee2) and true or false
	end

	--- Whether wep is a firearm that could be used to stock-bash. Melee
	-- weapons are excluded because they have their own (better) swing, and
	-- clipless non-melee weapons because there's nothing to bash with.
	function hg.bots.CanStockBash(bot, wep)
		if not IsValid(bot) or not IsValid(wep) then return false end
		if hg.bots.IsMeleeWeapon(wep) then return false end

		-- Both are hard requirements of the underlying mechanic - see header.
		if IsValid(bot.FakeRagdoll) or IsValid(bot.FakeRagdollOld) then return false end
		if bot:GetNWFloat("InLegKick", 0) > CurTime() then return false end

		return true
	end

	--- How far a swing of this weapon reaches FROM THE EYES - the same
	-- number the weapon itself traces with (weapon_melee's AttackLen1,
	-- the hands SWEP's ReachDistance).
	function hg.bots.MeleeSwingReach(wep)
		if not IsValid(wep) then return 45 end

		return (wep.AttackLen1 or wep.ReachDistance or 45)
	end

	--- Distance from the bot's eyes to the NEAREST point of the target's
	-- body, not to its origin. Origin-to-origin is what made bots swing at
	-- air: two player origins 70 units apart can be 20 units of actual
	-- body gap, or 70, depending on where each one is standing.
	-- @return distance, the entity actually being hit (ragdoll if downed)
	function hg.bots.MeleeBodyDist(bot, target)
		local char = (IsValid(target.FakeRagdoll) and target.FakeRagdoll) or target
		local eye = bot:EyePos()
		local point = char.NearestPoint and char:NearestPoint(eye) or char:WorldSpaceCenter()

		return eye:Distance(point), char
	end

	--- Would a swing land right now? Mirrors what the weapon does when it
	-- swings: a hull along the aim line from the eyes.
	-- @return boolean, distance to the body
	function hg.bots.MeleeWillHit(bot, wep, target, reach)
		reach = reach or hg.bots.MeleeSwingReach(wep)

		local dist, char = hg.bots.MeleeBodyDist(bot, target)

		if dist > reach + 8 then return false, dist end

		local eye = bot:EyePos()
		local tr = util.TraceHull({
			start = eye,
			endpos = eye + bot:GetAimVector() * (reach + 8),
			mins = Vector(-6, -6, -6),
			maxs = Vector(6, 6, 6),
			filter = bot,
			mask = MASK_SHOT,
		})

		if tr.Entity == char or tr.Entity == target then return true, dist end

		-- Point blank: the real swing sweeps sideways, so a single line
		-- down the middle understates it.
		if dist < reach * 0.6 then
			local to = char:WorldSpaceCenter() - eye

			to:Normalize()

			return bot:GetAimVector():Dot(to) > 0.7, dist
		end

		return false, dist
	end

	--- Is a melee weapon (weapon_melee base or hands) ready for a new swing?
	function hg.bots.IsMeleeReady(wep, now)
		now = now or CurTime()

		if wep.GetInAttack then
			if wep:GetInAttack() then return false end

			if wep.GetLastAttack and wep.GetAttackWait and wep:GetLastAttack() + wep:GetAttackWait() > now then
				return false
			end
		end

		if wep.GetNextPrimaryFire and wep:GetNextPrimaryFire() > now then return false end

		return true
	end

	--- Whether a leg kick would actually land and is currently allowed.
	-- LegAttack self-gates too, but checking here avoids burning the AI's
	-- own cooldown on attempts the mechanic would reject outright.
	function hg.bots.CanKick(bot)
		if not IsValid(bot) or not bot:Alive() then return false end
		if IsValid(bot.FakeRagdoll) then return false end
		if not bot:IsOnGround() then return false end
		if bot:GetNWFloat("InLegKick", 0) > CurTime() then return false end

		return true
	end
--//

--\\ Melee duel (circling, feints, short combos)
	--[[
		Against someone who fights hand to hand too (melee weapon or fists),
		a bot doesn't just walk up and swing nonstop. It duels the way a
		brawler game fight looks:

		- circle: strafe around the enemy just outside their reach (their
		  weapon, or a kick - everyone can kick), facing them, switching
		  direction now and then. Z-City stamina recovers meanwhile, and a
		  guard can only come up with stamina > 90, so the circling is what
		  makes parries (the defense section below) possible at all.
		- engage: step in and throw a short combo (1-3 swings, sometimes
		  opened with a kick), then
		- retreat: step back out and circle again.
		- feint: step into range and straight back out without swinging -
		  baits a swing out of the enemy.
		- sway: step back out of an enemy swing that is on its way (the
		  alternative to the parry roll).

		Openings are punished at once: an enemy swing that whiffed (landed
		while the bot was out of reach), a successful parry, an enemy who
		turned away or went down. Enemies with a gun are rushed instead -
		circling at 100u in front of a gun is suicide.
	]]

	local hg_bot_duel            = CreateConVar("hg_bot_duel",            "1",   {FCVAR_ARCHIVE}, "Melee duels vs melee/unarmed enemies: circle, feint, strike in short combos and step back instead of swinging nonstop", 0, 1)
	local hg_bot_duel_range      = CreateConVar("hg_bot_duel_range",      "220", {FCVAR_ARCHIVE}, "Distance at which a melee bot starts dueling instead of just closing in", 100, 600)
	local hg_bot_duel_aggression = CreateConVar("hg_bot_duel_aggression", "0.5", {FCVAR_ARCHIVE}, "0 = patient (long circling, few attacks), 1 = presses constantly", 0, 1)
	local hg_bot_duel_restyle    = CreateConVar("hg_bot_duel_restyle",    "12",  {FCVAR_ARCHIVE}, "Seconds before a bot re-picks its fighting style mid-duel (it also re-picks when badly hurt)", 3, 120)
	local hg_bot_duel_force      = CreateConVar("hg_bot_duel_force",      "",    {FCVAR_ARCHIVE}, "Force every bot into one fighting style (circler / hitrun / brawler / counter / kicker / feinter). Empty = pick per bot")
	local hg_bot_duel_guard      = CreateConVar("hg_bot_duel_guard",      "0.5", {FCVAR_ARCHIVE}, "How much melee bots play through the guard: chance of raising a block before stepping in", 0, 1)
	local hg_bot_duel_space      = CreateConVar("hg_bot_duel_space",      "150", {FCVAR_ARCHIVE}, "Free space a bot needs around the circle to keep circling; boxed in, it fights head on", 60, 400)
	local hg_bot_duel_gunrush    = CreateConVar("hg_bot_duel_gunrush",    "260", {FCVAR_ARCHIVE}, "Inside this distance a melee bot crowds an enemy holding a gun instead of running straight at them from afar", 0, 600)
	local hg_bot_lunge           = CreateConVar("hg_bot_lunge",           "1",   {FCVAR_ARCHIVE}, "Melee bots finish a run-in with a jumping lunge", 0, 1)
	local hg_bot_lunge_min       = CreateConVar("hg_bot_lunge_min",       "110", {FCVAR_ARCHIVE}, "Closest distance a lunge is started from", 40, 400)
	local hg_bot_lunge_max       = CreateConVar("hg_bot_lunge_max",       "260", {FCVAR_ARCHIVE}, "Furthest distance a lunge is started from", 60, 700)
	local hg_bot_lunge_chance    = CreateConVar("hg_bot_lunge_chance",    "0.4", {FCVAR_ARCHIVE}, "Chance a run-in becomes a lunge", 0, 1)
	local hg_bot_lunge_cooldown  = CreateConVar("hg_bot_lunge_cooldown",  "3",   {FCVAR_ARCHIVE}, "Seconds between a bot's lunges", 0.5, 30)
	local hg_bot_pummel          = CreateConVar("hg_bot_pummel",          "1",   {FCVAR_ARCHIVE}, "Bots crouch over a downed enemy and keep hitting instead of standing on them", 0, 1)
	local hg_bot_pummel_range    = CreateConVar("hg_bot_pummel_range",    "95",  {FCVAR_ARCHIVE}, "How close a bot gets before crouching over a downed enemy", 40, 250)
	local hg_bot_pummel_time     = CreateConVar("hg_bot_pummel_time",     "6",   {FCVAR_ARCHIVE}, "Seconds a bot spends finishing a downed enemy before moving on", 1, 30)

	--[[
		Fighting styles. Each one is the same state machine (circle ->
		engage -> retreat, with feints and sways) driven by different
		numbers, so they read as different fighters rather than different
		code paths:

		- circler: the default. Holds the edge of their reach, takes the
		  openings, short combos.
		- hitrun:  waits further out, sprints in, one or two hits, then
		  sprints back out of reach before the answer arrives.
		- brawler: forward pressure. Stands almost inside their reach,
		  long strings, barely backs off. Wins on stamina, loses to parries.
		- counter: rarely attacks first, keeps a guard up, and punishes
		  hard the moment a swing misses (or a block lands).
		- kicker:  leads with Z-City's leg kick - it knocks the target down
		  four times out of five (sv_legkick.lua) - then finishes.
		- feinter: fakes the entry over and over until they swing at air.

		gap      extra distance kept beyond both fighters' reach
		engage   base chance to attack when a circling stretch ends
		combo    swings per attack
		retreat  seconds of backing off after an attack
		backoff  distance of that retreat
		kick     chance a strike is a kick instead of a swing
		block    multiplier on this bot's parry chance (defense section)
		punish   multiplier on the chance to punish a whiff / parry
	]]
	--
	-- guard    chance of raising the guard before stepping in (scaled by
	--          hg_bot_duel_guard), and of holding it while circling close
	-- lunge    multiplier on the chance a run-in becomes a jumping lunge
	local STYLES = {
		circler = { gap = { 28, 55 }, engage = 0.28, combo = { 1, 3 }, retreat = { 0.45, 0.8 }, backoff = 110, feint = 0.15, kick = 0.25, block = 1.0, punish = 1.0, guard = 0.45, lunge = 1.0, sprintIn = false, sprintOut = false, flip = { 1.0, 2.8 } },
		hitrun  = { gap = { 60, 95 }, engage = 0.45, combo = { 1, 2 }, retreat = { 0.9, 1.5 }, backoff = 260, feint = 0.08, kick = 0.30, block = 0.8, punish = 1.3, guard = 0.25, lunge = 1.8, sprintIn = true,  sprintOut = true,  flip = { 1.5, 3.2 } },
		brawler = { gap = { 8,  26 }, engage = 0.80, combo = { 3, 5 }, retreat = { 0.2, 0.4 }, backoff = 70,  feint = 0.05, kick = 0.45, block = 0.6, punish = 1.0, guard = 0.20, lunge = 1.2, sprintIn = true,  sprintOut = false, flip = { 0.8, 1.8 } },
		counter = { gap = { 35, 65 }, engage = 0.08, combo = { 1, 2 }, retreat = { 0.5, 0.9 }, backoff = 120, feint = 0.30, kick = 0.10, block = 1.9, punish = 1.8, guard = 0.90, lunge = 0.4, sprintIn = false, sprintOut = false, flip = { 1.2, 3.0 } },
		kicker  = { gap = { 25, 50 }, engage = 0.45, combo = { 1, 2 }, retreat = { 0.35, 0.7 }, backoff = 100, feint = 0.10, kick = 0.85, block = 0.9, punish = 1.2, guard = 0.40, lunge = 0.8, sprintIn = false, sprintOut = false, flip = { 1.0, 2.5 } },
		feinter = { gap = { 30, 55 }, engage = 0.20, combo = { 1, 3 }, retreat = { 0.4, 0.7 }, backoff = 110, feint = 0.50, kick = 0.20, block = 1.3, punish = 1.6, guard = 0.65, lunge = 0.6, sprintIn = false, sprintOut = false, flip = { 0.9, 2.4 } },
		-- Not rolled: forced on anyone dueling somebody who holds a gun.
		-- You don't dance in front of a muzzle, you crowd it - stay inside
		-- their guard, never give them the two metres they need.
		crowd   = { gap = { 0,  12 }, engage = 0.95, combo = { 3, 6 }, retreat = { 0.1, 0.25 }, backoff = 45, feint = 0.02, kick = 0.55, block = 0.5, punish = 1.0, guard = 0.10, lunge = 2.0, sprintIn = true,  sprintOut = false, flip = { 0.5, 1.1 } },
	}

	local STYLE_WEIGHT = {}

	for name in pairs(STYLES) do
		if name ~= "crowd" then
			STYLE_WEIGHT[name] = CreateConVar("hg_bot_duel_style_" .. name, "1", {FCVAR_ARCHIVE}, "Relative chance of the '" .. name .. "' melee fighting style", 0, 10)
		end
	end

	--- How far (origin to origin) this melee weapon lands a hit.
	local function MeleeReach(wep)
		if not IsValid(wep) then return 50 end

		return math.Clamp((wep.AttackLen1 or wep.ReachDistance or 45) + 10, 40, 110)
	end

	--- How far the enemy can hit us: their melee weapon, or a kick (~82u
	-- from the eyes) which anyone can throw.
	local function EnemyReach(target)
		local reach = 72
		local tw = target:GetActiveWeapon()

		if IsValid(tw) and (tw.ismelee or tw.ismelee2) then
			reach = math.max(reach, MeleeReach(tw))
		end

		return reach
	end

	--- Picks a style for this fight. The weights are the convars above,
	-- bent by the situation: hurt bots stop brawling, a heavy slow weapon
	-- suits hit-and-run, bare fists suit kicking, and an unarmed opponent
	-- is worth walking straight through.
	local function PickStyle(bot, wep, target, tKind)
		local forced = hg_bot_duel_force:GetString()

		if forced ~= "" and STYLES[forced] then return forced end

		local hp = bot:GetMaxHealth() > 0 and (bot:Health() / bot:GetMaxHealth()) or 1
		local org = bot.organism
		local stamina = (org and org.stamina and org.stamina[1]) or 100
		local heavy = IsValid(wep) and ((wep.weight or 1) >= 1.4 or (wep.AttackLen1 or 0) >= 60)
		local fists = IsValid(wep) and wep.GetFists ~= nil

		local weights, total = {}, 0

		for name, cvar in pairs(STYLE_WEIGHT) do
			local w = cvar:GetFloat()

			if hp < 0.45 then
				w = w * ((name == "brawler") and 0.3 or (name == "counter" or name == "hitrun") and 2 or 1.2)
			end

			if stamina < 60 then
				w = w * ((name == "brawler") and 0.4 or (name == "counter" or name == "circler") and 1.5 or 1)
			end

			if heavy then
				w = w * ((name == "hitrun") and 1.6 or (name == "brawler") and 0.7 or 1)
			end

			if fists then
				w = w * ((name == "kicker") and 1.6 or (name == "brawler") and 1.3 or 1)
			end

			if tKind == "none" then -- they're unarmed: walk through them
				w = w * ((name == "brawler") and 2 or (name == "kicker") and 1.5 or (name == "counter") and 0.5 or 1)
			end

			weights[name] = w
			total = total + w
		end

		if total <= 0 then return "circler" end

		local roll = math.Rand(0, total)

		for name, w in pairs(weights) do
			roll = roll - w

			if roll <= 0 then return name end
		end

		return "circler"
	end

	local function SetPhase(d, phase, dur)
		d.phase = phase
		d.phaseUntil = CurTime() + dur
	end

	local function StartEngage(d, combo)
		local st = d.st

		SetPhase(d, "engage", 2.2)

		d.combo = combo or math.random(st.combo[1], st.combo[2])
		d.kickFirst = math.random() < st.kick
	end

	local function Rotate2D(v, deg)
		local r = Vector(v.x, v.y, 0)
		r:Rotate(Angle(0, deg, 0))

		return r
	end

	local function TryMove(bot, data, p)
		if hg.bots.IsSegmentClear and not hg.bots.IsSegmentClear(bot:GetPos(), p, bot) then return false end

		data.MoveTarget = p

		return true
	end

	--- @return nil when a duel doesn't apply (the plain close-in-and-swing
	-- logic runs), true when the duel handled this tick.
	local function UpdateMeleeDuel(bot, data, wep, target, dist)
		if not hg_bot_duel:GetBool() then data.Duel = nil return nil end

		local d = data.Duel
		local range = hg_bot_duel_range:GetFloat()

		if d and d.target ~= target then d = nil end
		if dist > range + (d and 100 or 0) then data.Duel = nil return nil end

		-- A gun in their hands: from a distance, close the gap (no dancing
		-- in front of a muzzle). Once inside knife range, fight anyway -
		-- crowding a gunman is what a knife is for, and turning around to
		-- run is worse. That branch uses the "crowd" style.
		local tKind = hg.bots.GetEnemyWeaponKind and hg.bots.GetEnemyWeaponKind(bot, target) or "gun"
		local forceStyle

		if tKind == "gun" then
			if dist > hg_bot_duel_gunrush:GetFloat() then data.Duel = nil return nil end

			forceStyle = "crowd"
		end

		local now = CurTime()

		-- Their weapon changed hands mid-fight: so does the way this is
		-- fought (drew a pistol = crowd them, dropped it = duel properly).
		if d and forceStyle and d.style ~= forceStyle then d = nil end
		if d and not forceStyle and d.style == "crowd" then d = nil end

		if not d then
			d = { target = target, orbit = math.random() < 0.5 and 1 or -1 }
			d.style = forceStyle or PickStyle(bot, wep, target, tKind)
			d.st = STYLES[d.style]
			d.styleUntil = now + hg_bot_duel_restyle:GetFloat() * math.Rand(0.7, 1.4)
			d.extra = math.Rand(d.st.gap[1], d.st.gap[2])
			d.nextFlip = now + math.Rand(d.st.flip[1], d.st.flip[2])
			data.Duel = d
			SetPhase(d, "circle", math.Rand(0.4, 1.1))

			if hg.bots.Say then hg.bots.Say(bot, "knifesonly") end
		end

		-- A fight that drags on (or goes badly) changes how it's fought.
		local hp = bot:GetMaxHealth() > 0 and (bot:Health() / bot:GetMaxHealth()) or 1

		if not forceStyle and (now >= (d.styleUntil or 0) or (hp < 0.45 and not d.hurtRestyle)) then
			if hp < 0.45 then d.hurtRestyle = true end

			d.style = PickStyle(bot, wep, target, tKind)
			d.st = STYLES[d.style]
			d.styleUntil = now + hg_bot_duel_restyle:GetFloat() * math.Rand(0.7, 1.4)
			d.extra = math.Rand(d.st.gap[1], d.st.gap[2])
		end

		local st = d.st
		local reach = MeleeReach(wep)
		local tReach = EnemyReach(target)
		local circleDist = math.max(reach, tReach) + d.extra

		local pos, tPos = bot:GetPos(), target:GetPos()
		local fromT = pos - tPos
		fromT.z = 0

		if fromT:LengthSqr() < 1 then fromT = Vector(1, 0, 0) end

		fromT:Normalize()

		local tAim = target:GetAimVector()
		tAim.z = 0

		local facing = tAim:LengthSqr() > 0.01 and tAim:GetNormalized():Dot(-fromT) > 0.6
		local down = IsValid(target.FakeRagdoll)

		-- Tired = more careful (and the guard needs stamina > 90 anyway).
		local aggr = hg_bot_duel_aggression:GetFloat()
		local org = bot.organism

		if org and org.stamina and org.stamina[1] then
			aggr = aggr * math.Clamp(org.stamina[1] / 100, 0.3, 1)
		end

		-- Mood (sv_bot_morale.lua): a bot with a score to settle presses
		-- the duel, a rattled one gives ground.
		if hg.bots.MoraleAggression then
			aggr = math.Clamp(aggr * hg.bots.MoraleAggression(bot, target), 0, 1)
		end

		hg.bots.ClearPath(data)
		data.Crouching = false
		data.SlowWalk = false
		data.UseKey = false
		data.LookPos = target:WorldSpaceCenter() + Vector(0, 0, 10)
		data.LookLock = true -- circling sideways: keep the eyes on them
		data.BlockBias = st.block -- read by the defense roll below

		-- Their swing: sway out of it, and punish it if it whiffed.
		local tw = target:GetActiveWeapon()

		if IsValid(tw) and tw.GetLastAttack and tw.GetInAttack then
			local hitAt = tw:GetLastAttack()

			if hitAt ~= d.seenSwing then
				d.seenSwing = hitAt

				if tw:GetInAttack() and hitAt >= now - 0.05 then
					d.enemyHitAt = hitAt

					if d.phase ~= "engage" and dist < tReach + 20 and not data.DefendUntil and math.random() < 0.5 * st.punish then
						SetPhase(d, "sway", math.Rand(0.3, 0.45))
					end
				end
			end
		end

		if d.enemyHitAt and now > d.enemyHitAt + 0.05 then
			if dist > tReach and d.phase ~= "engage" and math.random() < (0.45 + aggr * 0.5) * st.punish then
				StartEngage(d, math.random(math.max(st.combo[1], 2), st.combo[2] + 1))
			end

			d.enemyHitAt = nil
		end

		-- Right after a parry (defense section): counter.
		if data.DuelCounterAt then
			if now - data.DuelCounterAt < 0.5 then StartEngage(d) end

			data.DuelCounterAt = nil
		end

		-- Playing through the guard: before stepping into range (and while
		-- circling inside it) the bot raises its block instead of standing
		-- there open. Rolled once per stretch, not every tick, and the
		-- defense section still refuses it when the weapon can't block.
		local guardChance = (st.guard or 0.3) * hg_bot_duel_guard:GetFloat() * 2

		if IsValid(wep) and wep.GetFists then guardChance = guardChance * 1.3 end

		if d.phase ~= "engage" and dist < tReach + 40 and now >= (d.nextGuardRoll or 0) then
			d.nextGuardRoll = now + math.Rand(0.8, 1.6)
			d.guardUntil = (math.random() < math.Clamp(guardChance, 0, 1)) and (now + math.Rand(0.5, 1.1)) or 0
		end

		if d.guardUntil and now < d.guardUntil then
			data.WantGuard = now + 0.5
			data.WantGuardFrom = target
		end

		-- Turned away / down: go in.
		if (d.phase == "circle" or d.phase == "retreat") and (down or not facing) and now >= (d.nextOpening or 0) then
			d.nextOpening = now + 0.8

			if math.random() < 0.6 + aggr * 0.4 then StartEngage(d, st.combo[2]) end
		end

		-- They stepped into our reach while we circle: hit first, or back off.
		if d.phase == "circle" and dist < reach then
			if not d.closeRolled then
				d.closeRolled = true

				if math.random() < 0.45 + aggr * 0.4 + (st.engage - 0.28) then
					StartEngage(d)
				else
					SetPhase(d, "retreat", math.Rand(st.retreat[1], st.retreat[2]))
				end
			end
		elseif dist > reach + 25 then
			d.closeRolled = nil
		end

		if d.phase == "circle" then
			data.Running = false

			if now >= d.nextFlip then
				d.orbit = -d.orbit
				d.nextFlip = now + math.Rand(st.flip[1], st.flip[2])
			end

			-- A point a bit further round the circle: strafes around them
			-- and corrects the distance at the same time.
			local want = tPos + Rotate2D(fromT, d.orbit * 35) * circleDist
			want.z = pos.z

			if not TryMove(bot, data, want) then
				d.orbit = -d.orbit
				d.nextFlip = now + math.Rand(st.flip[1], st.flip[2])

				want = tPos + Rotate2D(fromT, d.orbit * 35) * circleDist
				want.z = pos.z

				-- Boxed in: no room to circle. Either give ground to find
				-- some (if there is any behind us) or take the fight here.
				if not TryMove(bot, data, want) then
					local room = hg_bot_duel_space:GetFloat()
					local back = pos + fromT * room

					if math.random() < 0.5 and TryMove(bot, data, back) then
						SetPhase(d, "retreat", math.Rand(st.retreat[1], st.retreat[2]))
					else
						StartEngage(d)
					end
				end
			end

			if d.phase == "circle" and now >= d.phaseUntil then
				local r = math.random()
				local engageP = st.engage + aggr * 0.4

				if r < engageP then
					StartEngage(d)
				elseif r < engageP + st.feint then
					SetPhase(d, "feint", math.Rand(0.25, 0.4))
				else
					SetPhase(d, "circle", math.Rand(0.6, 1.6) * (1.5 - aggr))
				end
			end
		end

		if d.phase == "engage" then
			-- Everything about landing a hit uses the distance to the
			-- BODY and the weapon's own reach, not origin-to-origin.
			local swingReach = hg.bots.MeleeSwingReach(wep)
			local willHit, bodyDist = hg.bots.MeleeWillHit(bot, wep, target, swingReach)

			if not willHit and bodyDist > swingReach * 0.7 then
				data.MoveTarget = tPos
				data.Running = st.sprintIn or bodyDist > swingReach + 60

				-- Finish the run-in with a jump at them: Z-City lets a
				-- sprinting player jump, and the swing lands as the bot
				-- comes down on top of them. Also closes the last stretch
				-- faster than walking into a gun would allow.
				if hg_bot_lunge:GetBool() and data.Running and bot:IsOnGround()
					and not IsValid(target.FakeRagdoll)
					and bodyDist >= hg_bot_lunge_min:GetFloat() and bodyDist <= hg_bot_lunge_max:GetFloat()
					and now >= (data.NextLungeAt or 0)
					and math.random() < math.Clamp(hg_bot_lunge_chance:GetFloat() * (st.lunge or 1), 0, 1)
				then
					data.NextLungeAt = now + hg_bot_lunge_cooldown:GetFloat() * math.Rand(0.8, 1.3)
					data.JumpUntil = now + 0.12
					d.lungeUntil = now + 0.8

					if hg.bots.Say then hg.bots.Say(bot, "fight") end
				end
			else
				data.MoveTarget = nil
				data.Running = false
			end

			-- A lunge always ends in a swing, even if the combo is spent.
			if d.lungeUntil and now < d.lungeUntil and willHit and d.combo <= 0 then d.combo = 1 end

			local canKick = bodyDist <= 74 and hg.bots.CanKick(bot) and not bot:IsSprinting()

			-- Kicks knock people down (and a downed enemy is a free finish),
			-- so kick-heavy styles lead with them and mix them into strings.
			if canKick and (d.kickFirst or (d.combo > 0 and math.random() < st.kick * 0.35)) and now >= (data.NextSwingAt or 0) then
				d.kickFirst = false
				bot:LegAttack()

				if bot:GetNWFloat("InLegKick", 0) > now then
					d.combo = d.combo - 1
					data.NextSwingAt = now + 0.7
				end
			elseif willHit and d.combo > 0 and hg.bots.IsMeleeReady(wep, now) and now >= (data.NextSwingAt or 0) then
				data.SwingPressUntil = now + 0.1
				data.NextSwingAt = now + math.Rand(0.12, 0.3)
				d.combo = d.combo - 1
			end

			local swingDone = hg.bots.IsMeleeReady(wep, now) and now >= (data.SwingPressUntil or 0)

			if (d.combo <= 0 and swingDone) or now >= d.phaseUntil then
				SetPhase(d, "retreat", math.Rand(st.retreat[1], st.retreat[2]))
			end
		elseif d.phase == "feint" then
			data.Running = false

			local p = tPos + fromT * math.max(reach + 12, 50)
			p.z = pos.z
			data.MoveTarget = p

			if now >= d.phaseUntil then SetPhase(d, "retreat", math.Rand(0.35, 0.6)) end
		elseif d.phase == "retreat" or d.phase == "sway" then
			local far = (d.phase == "retreat") and st.backoff or 110
			local sprintOut = st.sprintOut and d.phase == "retreat" and dist < tReach + 40

			-- Straight back, or back and to the side if there's a wall.
			if not TryMove(bot, data, pos + fromT * far) and not TryMove(bot, data, pos + Rotate2D(fromT, d.orbit * 70) * far) then
				data.MoveTarget = nil
				sprintOut = false
			end

			-- Hit-and-run actually turns and runs: sprinting only works
			-- moving forwards, so the bot looks where it's going and gives
			-- up on watching them for that second.
			if sprintOut and data.MoveTarget then
				data.Running = true
				data.LookPos = data.MoveTarget
			else
				data.Running = false
			end

			local out = st.sprintOut and (circleDist + 60) or circleDist

			if now >= d.phaseUntil or (d.phase == "retreat" and dist >= out) then
				SetPhase(d, "circle", math.Rand(0.5, 1.4) * (1.5 - aggr))
			end
		end

		data.Attacking = now < (data.SwingPressUntil or 0)

		return true
	end

	--- What this bot is doing in a melee fight right now ("circler",
	-- "hitrun", ...) - used by the debug command.
	function hg.bots.GetDuelStyle(bot)
		local d = bot.Bot and bot.Bot.Duel

		return d and d.style or nil
	end
--//

--\\ Close-quarters handling
	--- Called from combat's Think once a target is close enough to matter.
	-- Returns true if it took over the bot's attack handling this tick
	-- (in which case combat skips its normal shoot/reload logic).
	--
	-- @param canSee whether the bot currently has line of sight - a bot
	--        that's lost sight of someone at knife range shouldn't keep
	--        swinging at empty air, so this hands control straight back.
	--- Finishing somebody who is already on the floor: walk onto them,
	-- crouch so the swing actually reaches the ragdoll (a standing swing
	-- from the eyes passes over a body lying at foot height) and keep
	-- hitting. Kicks go in between - those work standing.
	-- @return true while the bot is busy with this
	local function GroundPummel(bot, data, wep, target, now)
		if not hg_bot_pummel:GetBool() then return false end

		local rag = target.FakeRagdoll

		if not IsValid(rag) or not target:Alive() then
			data.PummelUntil = nil

			return false
		end

		-- Only hand-to-hand finishes this way; with a gun, shooting them
		-- where they lie is better.
		if not (wep.GetFists or hg.bots.IsMeleeWeapon(wep)) then return false end

		local range = hg_bot_pummel_range:GetFloat()
		local bodyDist, char = hg.bots.MeleeBodyDist(bot, target)
		local aim = char:WorldSpaceCenter()

		if bodyDist > range + 60 then
			data.PummelUntil = nil

			return false
		end

		-- Had our turn a moment ago: let the fight move on instead of
		-- standing on the body forever.
		if now < (data.PummelDoneUntil or 0) then return false end

		if not data.PummelUntil or data.PummelTarget ~= target then
			data.PummelUntil = now + hg_bot_pummel_time:GetFloat() * math.Rand(0.7, 1.3)
			data.PummelTarget = target
		elseif now > data.PummelUntil then
			data.PummelUntil = nil
			data.PummelDoneUntil = now + 4

			return false
		end

		data.LookPos = aim
		data.LookLock = true
		data.AimSpeed = 300
		data.Running = false
		data.AttackingSecondary = false

		-- Step onto them, then settle and crouch over the body.
		if bodyDist > range then
			data.Crouching = false
			data.MoveTarget = char:GetPos()

			return true
		end

		hg.bots.ClearPath(data)

		data.MoveTarget = nil
		data.Crouching = true

		-- A kick needs to stand up, so it is thrown only now and then,
		-- between the crouched swings.
		if now >= (data.NextKickTry or 0) and math.random() < 0.2 and hg.bots.CanKick(bot) then
			data.NextKickTry = now + hg_bot_kick_cooldown:GetFloat()
			data.Crouching = false

			bot:LegAttack()
		end

		local willHit = hg.bots.MeleeWillHit(bot, wep, target)

		if willHit and hg.bots.IsMeleeReady(wep, now) and now >= (data.NextSwingAt or 0) then
			data.SwingPressUntil = now + 0.1
			data.NextSwingAt = now + math.Rand(0.15, 0.35)
		end

		data.Attacking = now < (data.SwingPressUntil or 0)

		return true
	end

	function hg.bots.CheckCloseQuarters(bot, data, wep, target, canSee)
		if not hg_bot_cqc_enabled:GetBool() then return false end
		if not IsValid(wep) or not IsValid(target) then return false end
		if not canSee then return false end

		-- Already down: stand over them and finish it.
		if GroundPummel(bot, data, wep, target, CurTime()) then
			data.Duel = nil

			return true
		end

		local dist = bot:GetPos():Distance(target:GetPos())
		local isMelee = hg.bots.IsMeleeWeapon(wep)
		local meleeRange = isMelee and hg_bot_melee_range:GetFloat() or hg_bot_bash_range:GetFloat()

		-- Hand-to-hand against hand-to-hand: duel (circle / combos / step
		-- back) instead of walking up and swinging nonstop.
		if isMelee then
			local handled = UpdateMeleeDuel(bot, data, wep, target, dist)

			if handled ~= nil then return handled end
		end

		-- A melee-armed bot should be closing the whole way in, not
		-- stopping at combat's firearm engagement distance where it can
		-- never reach anyone. Handled here (rather than in combat) so the
		-- knowledge of "this weapon needs contact range" stays in one file.
		if isMelee and dist > meleeRange then
			data.Attacking = false

			-- Coming at somebody who hasn't noticed us: crouched, from
			-- behind their shoulder, no sprinting (sv_bot_stealth.lua).
			if hg.bots.ShouldStalk and hg.bots.ShouldStalk(bot, data, target, dist)
				and hg.bots.StalkTick(bot, data, target, dist)
			then
				return true
			end

			if hg.bots.EndStalk then hg.bots.EndStalk(data) end

			data.Running = true
			data.Crouching = false

			-- Re-path toward the target itself rather than a flanking
			-- position - flanking is for gunfights, a knife just needs to
			-- arrive.
			if not data.Goal or data.Goal:DistToSqr(target:GetPos()) > 100 ^ 2 then
				hg.bots.SetGoal(bot, target:GetPos())
			end

			hg.bots.FollowPath(bot, data)

			return true
		end

		if dist > meleeRange then return false end

		-- In contact range now: stop. Bashing outright requires being
		-- under 250 u/s, and standing still also stops the bot from
		-- walking through/past the target while swinging.
		data.MoveTarget = nil
		data.Path = nil
		data.Goal = nil
		data.Running = false
		data.LookPos = target:EyePos()

		-- Kick: cheapest option, works with any weapon (it uses the hands
		-- SWEP, not the held one) and staggers. Rolled occasionally rather
		-- than spammed so a scramble mixes kicks with swings/bashes.
		if dist <= hg_bot_kick_range:GetFloat()
			and CurTime() >= (data.NextKickTry or 0)
			and hg.bots.CanKick(bot)
		then
			data.NextKickTry = CurTime() + hg_bot_kick_cooldown:GetFloat()

			if math.random() <= hg_bot_kick_chance:GetFloat() then
				-- Release the trigger for the kick's duration: the bash
				-- combo below and IN_ATTACK generally are pointless
				-- mid-kick (the mechanic blocks bashing while InLegKick is
				-- active anyway) and a held trigger would just burn ammo.
				data.Attacking = false
				data.UseKey = false

				bot:LegAttack()

				return true
			end
		end

		if isMelee then
			-- Melee swings on plain IN_ATTACK, but NOT held down forever:
			-- a weapon that is permanently mid-swing can never block
			-- (weapon_melee refuses to raise a block while GetInAttack() or
			-- before GetAttackTime() has passed). Click once per swing, only
			-- when the weapon is ready, with a small human pause between
			-- swings - that leaves windows where the bot can parry.
			data.UseKey = false

			local now = CurTime()

			-- Only swing when the swing would actually reach them.
			if hg.bots.IsMeleeReady(wep, now) and now >= (data.NextSwingAt or 0)
				and hg.bots.MeleeWillHit(bot, wep, target)
			then
				data.SwingPressUntil = now + 0.1
				data.NextSwingAt = now + math.Rand(0.2, 0.55)
			end

			data.Attacking = now < (data.SwingPressUntil or 0)

			return true
		end

		if hg.bots.CanStockBash(bot, wep) then
			-- The actual bash combo: IN_ATTACK + IN_USE held together
			-- while stationary and not ragdolled. Held for a stretch
			-- rather than toggled per tick because the underlying cooldown
			-- scales with weapon weight and current stamina, so there's no
			-- fixed tick count that reliably lands a hit.
			if CurTime() >= (data.NextBashDecision or 0) then
				data.NextBashDecision = CurTime() + hg_bot_bash_retry:GetFloat()
			end

			data.Attacking = true
			data.UseKey = true

			return true
		end

		-- Firearm, too close to bash for some reason (mid-leg-kick, etc) -
		-- let combat's normal shooting logic have it back.
		return false
	end
--//

--\\ Defense: block / parry (Z-City's own mechanic, nothing custom)
	--[[
		Bots block and parry through exactly the same input a player uses,
		so Z-City itself produces the block pose (networked GetBlocking()),
		the raise/lower sounds, the view punch and the perfect-block result.
		Verified against weapons/weapon_melee.lua and weapon_hands_sh.lua:

		- weapon_melee: IN_ATTACK2 raises a block only while ALL hold:
		  stamina > 90, not mid-swing (!GetInAttack() and GetAttackTime()
		  passed), 3 s since the last successful block (GetLastBlocked()),
		  and not re-raised within 1 s of the previous raise
		  (GetStartedBlocking()). A hit landing < 0.5 s after the raise is
		  a PERFECT block = parry: zero damage.
		  The hit moment of an incoming swing is known in advance - the
		  attacker's SWEP:GetLastAttack() is set on the click to "now +
		  wind-up" - so a bot that notices the wind-up raises the guard
		  right before it and parries.
		- Fists (hands with GetFists()): IN_ATTACK2 blocks (halves damage,
		  no perfect window). A punch lands ~0.06 s after the click, too
		  fast to react to per punch, so bots keep a guard up for a moment
		  when a fist fighter squares up to them.
		- The block only counts when the hit lands near the blocker's aim
		  line, so the bot turns to face the attacker (normal human turn
		  speed, not a snap) while the guard is up.

		The previous version pressed the keys without checking these
		conditions - the guard mostly never actually came up (bots were
		permanently mid-swing), while the bot still snapped round and stopped
		attacking, which is what looked instant and broken. It also had a
		custom kick block that Z-City doesn't have; that's gone.

		Rolled at hg_bot_block_chance (35%) per incoming blow, only against
		attackers the bot actually knows about (its target, or visible).
		After a successful block the bot counters right away.
	]]

	local hg_bot_block_chance    = CreateConVar("hg_bot_block_chance",    "0.35", {FCVAR_ARCHIVE}, "Chance a bot blocks/parries an incoming melee swing or punch", 0, 1)
	local hg_bot_block_react_min = CreateConVar("hg_bot_block_react_min", "0.05", {FCVAR_ARCHIVE}, "Min reaction delay (seconds) before a bot raises its guard", 0, 1)
	local hg_bot_block_react_max = CreateConVar("hg_bot_block_react_max", "0.14", {FCVAR_ARCHIVE}, "Max reaction delay (seconds) before a bot raises its guard", 0, 1)
	local hg_bot_block_range     = CreateConVar("hg_bot_block_range",     "130",  {FCVAR_ARCHIVE}, "How close an attacker must be for a bot to react to their swing", 32, 400)
	local hg_bot_block_turnspeed = CreateConVar("hg_bot_block_turnspeed", "420",  {FCVAR_ARCHIVE}, "Turn speed (deg/sec) while facing an attacker to block", 60, 2000)

	--- Can the bot's current weapon raise a block RIGHT NOW, by Z-City's
	-- own rules? Checked before committing, so a bot never "reacts" with a
	-- guard that the weapon is going to refuse.
	-- @return boolean, string kind ("melee" / "fists")
	function hg.bots.CanBlockNow(bot)
		if IsValid(bot.FakeRagdoll) then return false end

		local wep = bot:GetActiveWeapon()
		if not IsValid(wep) or not wep.GetBlocking then return false end

		local now = CurTime()

		if wep.GetFists then
			if not wep:GetFists() then return false end
			if wep.GetNextSecondaryFire and wep:GetNextSecondaryFire() > now then return false end

			return true, "fists"
		end

		if not wep.GetStartedBlocking then return false end
		if wep.CanBlock and not wep:CanBlock() then return false end

		local org = bot.organism

		if not (org and org.stamina and org.stamina[1] > 90) then return false end
		if wep.GetInAttack and wep:GetInAttack() then return false end
		if wep.GetAttackTime and wep:GetAttackTime() > now then return false end
		if wep.GetLastBlocked and wep:GetLastBlocked() + 3 >= now then return false end

		if not wep:GetBlocking() and now - wep:GetStartedBlocking() <= 1 then return false end

		return true, "melee"
	end

	--- Does bot know about attacker, and is attacker squared up to it?
	local function IsThreatTo(bot, attacker, range, minDot)
		if not IsValid(bot) or not bot:Alive() or IsValid(bot.FakeRagdoll) then return false end

		local data = bot.Bot
		if not data or not data.Enabled then return false end

		local toBot = bot:WorldSpaceCenter() - attacker:EyePos()
		local dist = toBot:Length()

		if dist > range or dist < 1 then return false end
		if attacker:GetAimVector():Dot(toBot / dist) < minDot then return false end

		return data.Memory.Target == attacker or hg.bots.CanSee(bot, attacker)
	end

	local function StartDefense(bot, attacker, delay, duration)
		local data = bot.Bot
		local now = CurTime()
		local wep = bot:GetActiveWeapon()

		data.DefendStart = now + delay
		data.DefendUntil = now + delay + duration
		data.DefendFrom = attacker
		data.DefendLookPos = attacker:EyePos() - Vector(0, 0, 8)
		data.DefendBlockKey = true
		data.DefendTurnSpeed = hg_bot_block_turnspeed:GetFloat()
		data.DefendLastBlocked = IsValid(wep) and wep.GetLastBlocked and wep:GetLastBlocked() or 0
		data.DefendChecked = false
	end

	local function EndDefense(data)
		data.DefendUntil = nil
		data.DefendStart = nil
		data.DefendLookPos = nil
		data.DefendBlockKey = nil
		data.DefendFrom = nil
		data.DefendTurnSpeed = nil
		data.DefendLastBlocked = nil
		data.DefendChecked = nil
	end

	hg.bots.EndDefense = EndDefense

	local function ReactionDelay()
		local lo = hg_bot_block_react_min:GetFloat()

		return math.Rand(lo, math.max(lo, hg_bot_block_react_max:GetFloat()))
	end

	--- A new swing from attacker landing in timeToHit seconds.
	local function OnIncomingSwing(attacker, timeToHit)
		local range = hg_bot_block_range:GetFloat()
		local chance = hg_bot_block_chance:GetFloat()

		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and bot.Bot

			-- The bot's fighting style bends its parry chance: a counter
			-- fighter blocks far more than a brawler (see STYLES above).
			local ownChance = math.Clamp(chance * (data and data.BlockBias or 1), 0, 1)

			if data and not data.DefendUntil and IsThreatTo(bot, attacker, range, 0.75) and hg.bots.CanBlockNow(bot) and math.random() < ownChance then
				-- Up before the blow lands, and inside the 0.5 s perfect
				-- window when it does: raise no earlier than 0.4 s before.
				local delay = math.Clamp(math.max(ReactionDelay(), timeToHit - 0.4), 0, math.max(timeToHit - 0.04, 0))

				-- Hold a little past the hit so the pose reads naturally.
				StartDefense(bot, attacker, delay, math.max(timeToHit - delay, 0) + math.Rand(0.35, 0.6))
			end
		end
	end

	local swingSeen = {} -- [ply] = last seen SWEP:GetLastAttack()
	local fistRoll = {} -- [bot] = { [ply] = next CurTime() to roll a guard }

	hook.Add("Think", "HG_Bots_Defense", function()
		if not next(hg.bots.List) then return end
		if not hg_bot_cqc_enabled:GetBool() then return end

		local now = CurTime()

		for _, ply in ipairs(player.GetHumans()) do
			if not ply:Alive() or IsValid(ply.FakeRagdoll) then continue end

			local wep = ply:GetActiveWeapon()

			if not IsValid(wep) then continue end

			-- Melee swing: GetLastAttack() jumps to the hit moment on the
			-- click. A changed value = a new swing.
			if wep.GetLastAttack and wep.GetInAttack then
				local hitAt = wep:GetLastAttack()

				if hitAt ~= swingSeen[ply] then
					swingSeen[ply] = hitAt

					if wep:GetInAttack() and hitAt >= now - 0.02 then
						OnIncomingSwing(ply, hitAt - now)
					end
				end
			end

			-- Fists: guard up for a moment, rolled once a second.
			if wep.GetFists and wep:GetFists() then
				local chance = hg_bot_block_chance:GetFloat()

				for bot in pairs(hg.bots.List) do
					local data = IsValid(bot) and bot.Bot

					if data and not data.DefendUntil then
						local rolls = fistRoll[bot]

						if not rolls then
							rolls = {}
							fistRoll[bot] = rolls
						end

						if now >= (rolls[ply] or 0) and IsThreatTo(bot, ply, 95, 0.8) then
							rolls[ply] = now + 1

							if hg.bots.CanBlockNow(bot) and math.random() < math.Clamp(chance * (data.BlockBias or 1), 0, 1) then
								StartDefense(bot, ply, ReactionDelay(), math.Rand(0.7, 1.1))
							end
						end
					end
				end
			end
		end

		-- Defensive styles (sv_bot_melee.lua's "counter") hold a guard up
		-- before anything comes in, instead of only reacting to a swing.
		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and bot.Bot

			if data and data.WantGuard and now < data.WantGuard and not data.DefendUntil then
				local from = data.WantGuardFrom

				if IsValid(from) and from:Alive() and hg.bots.CanBlockNow(bot) then
					StartDefense(bot, from, 0, math.Rand(0.6, 1.0))
				end
			end
		end

		-- Running defenses: keep facing the attacker, verify the guard
		-- actually came up, counter after a successful block.
		for bot in pairs(hg.bots.List) do
			local data = IsValid(bot) and bot.Bot

			if not (data and data.DefendUntil) then continue end

			if now > data.DefendUntil or IsValid(bot.FakeRagdoll) or not IsValid(data.DefendFrom) then
				EndDefense(data)
				continue
			end

			data.DefendLookPos = data.DefendFrom:EyePos() - Vector(0, 0, 8)

			local wep = bot:GetActiveWeapon()

			if not IsValid(wep) or not wep.GetBlocking then
				EndDefense(data)
				continue
			end

			-- Give the weapon a moment to accept the input; if the block
			-- didn't come up (conditions changed), stop pretending.
			if not data.DefendChecked and now > (data.DefendStart or now) + 0.12 then
				data.DefendChecked = true

				if not wep:GetBlocking() then
					EndDefense(data)
					continue
				end
			end

			-- Blocked something: Z-City sets LastBlocked. Drop the guard
			-- and hit back straight away - the opening after a parry.
			if wep.GetLastBlocked and wep:GetLastBlocked() > (data.DefendLastBlocked or 0) then
				EndDefense(data)
				data.NextSwingAt = now + 0.05
				data.DuelCounterAt = now
			end
		end
	end)

	hook.Add("PlayerDisconnected", "HG_Bots_Defense_Cleanup", function(ply)
		swingSeen[ply] = nil
		fistRoll[ply] = nil

		for _, rolls in pairs(fistRoll) do
			rolls[ply] = nil
		end
	end)
--//

--\\ Cleanup
	-- IN_USE held for bashing must not leak into other states - the same
	-- reasoning as sv_bot_downed.lua's Leave. Any state change clears it;
	-- combat/CQC re-asserts it every tick it actually wants it.
	hook.Add("HG_BotStateChanged", "HG_Bots_ClearBashKeys", function(bot, oldState, newState)
		local data = bot.Bot
		if not data then return end

		data.UseKey = false
		data.NextBashDecision = nil
		data.Duel = nil
		data.BlockBias = nil
		data.WantGuard = nil
		data.WantGuardFrom = nil
	end)
--//
