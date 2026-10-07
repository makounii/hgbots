--[[
	Tarkov AI - Downed

	Handling for Z-City's FakeRagdoll state ("downed but not dead"). Bots
	fall into this on their own exactly like humans do - it's driven by the
	organism system (crit damage, explosions, leg kicks, etc), not by
	anything here - so this file's job is purely to make a downed bot act
	like a downed player instead of lying there as dead weight.

	IMPORTANT - this drives the real player-facing mechanic, it does NOT
	manipulate bones directly. An earlier version of this file tried to
	stabilize/aim by damping and torquing the ragdoll's PhysObjs itself.
	That was wrong: lua/homigrad/fake/sv_control.lua already implements all
	of this properly via ComputeShadowControl, its Think hook iterates
	player.Iterator() (bots included, not just humans), and it keys entirely
	off which buttons the player is holding. So a bot only has to hold the
	same keys a human would, and it gets the same result - and crucially,
	doing it by hand at the same time would have meant two systems fighting
	over the same torso/hand PhysObjs every tick.

	The button contract, read out of the actual source rather than guessed:
	- IN_USE (E) - sv_control.lua's big gate at the "stabilize" block
	  (`ply:KeyDown(IN_USE) || ...`) is what shadow-controls the spine and
	  head toward the player's eye angles. This is the "hold E to stabilize
	  your torso" the player-facing mechanic describes, and it's also what
	  raises the right arm (the `(ishgweapon(wep) or wep.ismelee2) and
	  ply:KeyDown(IN_USE)` branch) so the weapon actually points somewhere.
	- IN_ATTACK2 (RMB) is NOT used. With E held, SWEP:InUse() is true and
	  the weapon base (PosAngChanges in sh_worldmodel.lua) points the gun
	  along the eye angles, clamped to 45 degrees around where the head
	  faces - E alone is the proper "aim through the sights" hold. RMB only
	  adds the zoom and stretches the arms out, which is what bots used to
	  do and what's been removed.
	- IN_ATTACK - ordinary firing. The weapon base already substitutes the
	  ragdoll for the player when resolving shoot origin/angles while downed
	  (`IsValid(ply.FakeRagdoll) and ply.FakeRagdoll or ply`, used
	  throughout), so shots come from the ragdoll's actual hands with no
	  special handling needed here at all.

	Aim direction comes from the bot's eye angles as usual (data.LookPos ->
	the movement bridge in sv_bot_core.lua), because sv_control.lua reads
	`ply:EyeAngles()` to point the stabilized spine and arm.

	BUT the bullet does not come from the eyes. While ragdolled, the weapon
	base fires from the physical gun's muzzle (SWEP:GetTrace ->
	WorldModel_Transform on the ragdoll hand), and the shadow-controlled
	arm only roughly follows the eye angles: sv_control adds fixed
	rotations, the constraint is soft, and the torso sags with pain and
	blood loss. Pointing the eyes at the target used to leave the barrel
	several degrees off, so downed bots mostly shot the floor and walls.
	Now the aim is proportional, through the sights:
	- every tick the real muzzle position/direction is read
	  (wep:GetTrace(true, nil, nil, true), the same call the base's own
	  camera code uses);
	- the view is pointed along muzzle -> target (not eye -> target: the
	  gun is a hand-length away from the eyes), plus a proportional share
	  of whatever barrel error is left (hg_bot_downed_aim_gain), recomputed
	  every tick and low-pass filtered - never accumulated, so no wind-up
	  and no overshoot;
	- the trigger is only pulled when the barrel is within tolerance AND
	  the muzzle has a clear line to the target (no shooting into the
	  bot's own ragdoll, the floor, or cover right in front of the gun).

	When the body physically can't aim (GetAimCapability): spine damage
	(org.canmove false), too weak (NW "power" < 0.4 - E is ignored then),
	no usable gun arm (amputated, or arm strength 1 - rarm/1.3 near zero).
	The bot doesn't hold E or fire blindly then; it tries to get up.
	When the right hand is trapped under the torso (bone geometry), or the
	barrel simply won't follow although the eyes are on target, the bot
	lets go of E for a moment so the arms go slack and slide free, then
	retries; after three failed tries it goes for getting up instead.

	Perception now traces from the ragdoll's eyes and filters the bot's
	own ragdoll (it used to block every LOS trace from a downed bot).

	Deliberately not handled here: crawling/dragging yourself along the
	ground (Z-City has a separate freemove/"ragdoll combat" mode for moving
	while ragdolled - hg.RagdollCombatInUse - which is a much bigger
	mechanic and off by default), and any notion of playing dead.
]]

hg.bots = hg.bots or {}

-- Same defensive redeclare as the other extension files - see
-- sv_bot_combat.lua's header for why load order isn't guaranteed.
hg.bots.States = hg.bots.States or {}
hg.bots.RegisterState = hg.bots.RegisterState or function(name, tbl) hg.bots.States[name] = tbl end

local hg_bot_downed_think_rate  = CreateConVar("hg_bot_downed_think_rate",  "0.05", {FCVAR_ARCHIVE}, "Seconds between downed-state AI ticks (stand-up attempts and aim updates)", 0.05, 1)
local hg_bot_downed_force_after = CreateConVar("hg_bot_downed_force_after", "25",  {FCVAR_ARCHIVE}, "Seconds downed before a bot forces itself up regardless of the normal rules, as a stuck-forever safety valve", 5, 180)
local hg_bot_downed_fight       = CreateConVar("hg_bot_downed_fight",       "1",   {FCVAR_ARCHIVE}, "Whether downed bots stabilize, aim and shoot back at a visible target instead of only trying to get up", 0, 1)
local hg_bot_downed_aimspeed    = CreateConVar("hg_bot_downed_aimspeed",    "90",  {FCVAR_ARCHIVE}, "Aim turn speed (deg/sec) while downed - lower than standing combat, since bracing a rifle on the ground is slower than shouldering it", 10, 720)
local hg_bot_downed_getup_when_safe = CreateConVar("hg_bot_downed_getup_when_safe", "1", {FCVAR_ARCHIVE}, "Only attempt to stand up when there's no visible target - while someone's actively shooting at them, downed bots stay down and return fire instead of standing into it", 0, 1)
local hg_bot_downed_aim_gain    = CreateConVar("hg_bot_downed_aim_gain",    "0.5",  {FCVAR_ARCHIVE}, "Proportional gain: fraction of the measured barrel error added back onto the view angle while downed", 0, 1.5)
local hg_bot_downed_aim_tol     = CreateConVar("hg_bot_downed_aim_tol",     "20",  {FCVAR_ARCHIVE}, "Downed bots fire only when the barrel line passes within this many units of the aim point (min 2.5 degrees)", 2, 200)
local hg_bot_downed_max_offset  = CreateConVar("hg_bot_downed_max_offset",  "15",  {FCVAR_ARCHIVE}, "Max proportional view-angle correction (degrees) while downed", 0, 45)

local GetAimCapability, IsArmPinned, FreeArms -- defined in the section below

--\\ Muzzle feedback
	--- Real muzzle position and direction of wep right now, or nil.
	local function GetMuzzle(wep)
		if not wep.GetTrace then return nil end

		local ok, pos, ang = pcall(wep.GetTrace, wep, true, nil, nil, true)

		if ok and isvector(pos) and isangle(ang) then return pos, ang end

		return nil
	end

	--- Clear line from the muzzle to the aim point: nothing but the target
	-- (and its ragdoll) in the way, and not the bot's own body.
	local function MuzzleLineClear(bot, target, muzzlePos, aimPoint)
		local filter = hg.bots.SightFilter and hg.bots.SightFilter(bot, target) or { bot, target, bot.FakeRagdoll }

		local tr = util.TraceLine({
			start = muzzlePos,
			endpos = aimPoint,
			filter = filter,
			mask = MASK_SHOT,
		})

		return not tr.Hit or tr.HitPos:DistToSqr(aimPoint) < 16 * 16
	end

	local function ClampOffset(v, lim)
		return math.Clamp(v, -lim, lim)
	end

	local function RagBone(rag, name)
		rag.hgBotBones = rag.hgBotBones or {}

		local id = rag.hgBotBones[name]

		if id == nil then
			id = rag:LookupBone(name) or false
			rag.hgBotBones[name] = id
		end

		return id and rag:GetBonePosition(id) or nil
	end

	--- Can this body aim a gun right now? Mirrors what sv_control.lua and
	-- the weapon base actually require - verified in Z-City's source:
	-- - org.canmove (spine intact): without it neither the torso
	--   stabilizer nor either arm is driven at all;
	-- - ply:GetNWFloat("power") >= 0.4 (pain/blood/oxygen/consciousness):
	--   below that SWEP:InUse() is false while ragdolled, E is ignored and
	--   the gun just hangs off the hand;
	-- - a right arm that exists (two-handed guns: SWEP:CanUse() refuses a
	--   missing right arm) and still has strength - the arm's shadow
	--   force is max(1 - org.rarm / 1.3, 0);
	-- - no hands at all = nothing.
	-- @return boolean, string reason when false
	GetAimCapability = function(bot, wep, ragdoll)
		local org = bot.organism

		if not org then return true end
		if org.canmove == false then return false, "paralysed (spine)" end
		if bot:GetNWFloat("power", 1) < 0.4 then return false, "too weak (pain/blood loss/consciousness)" end
		if org.rarmamputated and org.larmamputated then return false, "no arms" end

		local pistol = wep.IsPistolHoldType and wep:IsPistolHoldType()

		if org.rarmamputated and not pistol then return false, "no right arm for a two-handed gun" end

		local rightForce = math.max(1 - (org.rarm or 0) / 1.3, 0)
		local leftForce = math.max(1 - (org.larm or 0) / 1.3, 0)

		-- One-handed guns work off whichever arm still holds up.
		if pistol then
			if math.max(org.rarmamputated and 0 or rightForce, org.larmamputated and 0 or leftForce) < 0.15 then
				return false, "both arms useless"
			end
		elseif rightForce < 0.15 then
			return false, "right arm useless"
		end

		return true
	end

	--- Right hand trapped under the torso: the body is lying on it. The
	-- shadow-controlled arm can't lift the whole body's mass, so it stays
	-- pinned however long E is held.
	IsArmPinned = function(ragdoll)
		if not IsValid(ragdoll) then return false end

		local hand = RagBone(ragdoll, "ValveBiped.Bip01_R_Hand")
		local chest = RagBone(ragdoll, "ValveBiped.Bip01_Spine2")

		if not hand or not chest then return false end

		local dx, dy = hand.x - chest.x, hand.y - chest.y

		return hand.z < chest.z - 4 and (dx * dx + dy * dy) < 14 * 14
	end

	--- Arms stuck: let go of E for a moment so they go slack and can slide
	-- free, then try again. After a few failed tries, getting up is the
	-- better plan.
	FreeArms = function(data, now)
		data.DownedFreeArmsUntil = now + math.Rand(0.6, 0.9)
		data.DownedStallSince = nil
		data.DownedAimCorr = nil
		data.DownedFreeFails = (data.DownedFreeFails or 0) + 1

		if data.DownedFreeFails >= 3 then
			data.DownedPreferGetUp = true
		end
	end

	local hg_bot_downed_shoot_range = CreateConVar("hg_bot_downed_shoot_range", "2500", {FCVAR_ARCHIVE}, "A downed bot with a loaded gun and a visible enemy within this range shoots instead of crawling", 0, 8000)

	--- Is shooting from the floor possible right now? Loaded gun, a body
	-- that can aim it, and a visible enemy in range. Crawling is only for
	-- when it isn't (sv_bot_crawl.lua asks this too). Cached for 0.3 s -
	-- it runs a visibility check.
	function hg.bots.DownedCanShoot(bot, data)
		local now = CurTime()

		if data.DownedShootAt and now < data.DownedShootAt then return data.DownedShootOK end

		data.DownedShootAt = now + 0.3
		data.DownedShootOK = false

		local rag = bot.FakeRagdoll
		local target = data.Memory.Target
		local range = hg_bot_downed_shoot_range:GetFloat()

		if not IsValid(rag) or not hg_bot_downed_fight:GetBool() or range <= 0 then return false end
		if not IsValid(target) or not target:Alive() then return false end
		if not hg.bots.GetWeaponKind or hg.bots.GetWeaponKind(bot, true) ~= "gun" then return false end
		if not GetAimCapability(bot, bot:GetActiveWeapon(), rag) then return false end
		if bot:GetPos():DistToSqr(target:GetPos()) > range * range then return false end
		if not hg.bots.CanSee(bot, target) then return false end

		data.DownedShootOK = true

		return true
	end
--//

--\\ Downed state
--\ Fighting from the floor
	--[[
		A downed bot is not a sack of potatoes. Everything here is a real
		Z-City ragdoll control (fake/sv_control.lua), not a scripted stunt:

		- IN_USE stabilizes the torso and drives the arms, so any of this
		  needs E held first.
		- With a melee weapon the ragdoll swings on IN_ATTACK (weapon_melee's
		  InUse wants E held while ragdolled); bare fists punch the same way.
		- IN_SPEED / IN_WALK grab with the left / right hand. Holding BOTH
		  with another RAGDOLL's head between the palms is Z-City's choke:
		  it damages them continuously and knocks them out, which is the one
		  thing that actually wins a fight on the ground.
		- Grabbing the floor and pulling is crawling (sv_bot_crawl.lua) -
		  used here to drag ourselves away from someone standing over us.

		Priority while down: shoot if there's a gun and room to use it,
		otherwise choke a downed enemy, otherwise swing at whoever is in
		reach, otherwise crawl away and shout for help.
	]]
	local hg_bot_downed_ground = CreateConVar("hg_bot_downed_ground", "1", {FCVAR_ARCHIVE}, "Downed bots fight back from the floor: swings, chokes, struggling and crawling away, instead of lying still", 0, 1)
	local hg_bot_downed_ground_range = CreateConVar("hg_bot_downed_ground_range", "110", {FCVAR_ARCHIVE}, "How close someone has to be for a downed bot to fight them by hand", 40, 300)

	--- Nearest live enemy close enough to matter to a bot on the floor.
	local function GroundThreat(bot, data, radius)
		local mem = data.Memory
		local best, bestDist
		local pos = bot:GetPos()

		for _, ply in ipairs(player.GetHumans()) do
			if ply:Alive() and not ply.IsHomigradBot and (not hg.bots.IsHostile or hg.bots.IsHostile(ply, bot) or mem.Target == ply) then
				local char = IsValid(ply.FakeRagdoll) and ply.FakeRagdoll or ply
				local d = pos:DistToSqr(char:GetPos())

				if d < radius * radius and (not bestDist or d < bestDist) then
					best, bestDist = ply, d
				end
			end
		end

		return best, bestDist and math.sqrt(bestDist) or nil
	end

	--- Both hands on a downed enemy's head = Z-City's choke. Only works on
	-- a ragdoll (the trace in sv_control.lua looks for head physbone 10 on
	-- a ragdoll), so it's for finishing someone who is also on the floor.
	local function TryChoke(bot, data, threat, now)
		local rag = IsValid(threat.FakeRagdoll) and threat.FakeRagdoll or nil

		if not rag then return false end

		local head = rag:GetPhysicsObjectNum(rag:TranslateBoneToPhysBone(rag:LookupBone("ValveBiped.Bip01_Head1") or 0))
		local headPos = IsValid(head) and head:GetPos() or rag:GetPos()

		if bot:GetPos():DistToSqr(headPos) > 90 * 90 then return false end

		data.UseKey = true
		data.GroundChoke = true -- both grab keys (core's movement bridge)
		data.LookPos = headPos
		data.LookLock = true
		data.MoveTarget = headPos
		data.Attacking = false

		return true
	end

	--- Swinging / punching from the floor at whoever is standing over us.
	local function GroundMelee(bot, data, wep, threat, dist, now)
		local char = IsValid(threat.FakeRagdoll) and threat.FakeRagdoll or threat

		-- Dragging ourselves along and swinging are the same two hands.
		if hg.bots.StopCrawl and data.CrawlDest then hg.bots.StopCrawl(data) end

		data.UseKey = true -- E: stabilize and drive the arms
		data.CrawlGrab = nil
		data.AttackingSecondary = false

		-- Turn to them first. Someone holding a downed bot moves around it,
		-- so the aim point is refreshed every tick and the head turns fast
		-- enough to follow - swinging at where they used to be is exactly
		-- the "hitting the air" case.
		data.LookPos = char:WorldSpaceCenter()
		data.LookLock = true
		data.AimSpeed = 320

		-- And only swing once the swing would actually connect.
		local willHit = not hg.bots.MeleeWillHit or hg.bots.MeleeWillHit(bot, wep, threat)

		if willHit and now >= (data.GroundSwingAt or 0) then
			data.GroundSwingAt = now + math.Rand(0.5, 0.85)
			data.GroundSwingUntil = now + 0.15
		end

		data.Attacking = now < (data.GroundSwingUntil or 0)

		return true
	end

	--- Being thrown around / dragged: grab at whatever is there to stop
	-- sliding, alternating hands the way a crawl does.
	local function Struggle(bot, data, now)
		local rag = bot.FakeRagdoll

		if not IsValid(rag) then return false end

		local phys = rag:GetPhysicsObject()
		local speed = IsValid(phys) and phys:GetVelocity():Length() or 0

		if speed < 120 then return false end

		data.UseKey = true

		if now >= (data.GroundGrabAt or 0) then
			data.GroundGrabAt = now + 0.5
			data.CrawlGrab = (data.CrawlGrab == "left") and "right" or "left"
		end

		return true
	end

	--- Called from the downed state's Think, after healing and crawling.
	-- @return true if it took over the bot's inputs this tick
	function hg.bots.DownedReact(bot, data, now, canShoot)
		if not hg_bot_downed_ground:GetBool() then return false end

		local org = bot.organism

		if not org or org.otrub then return false end

		data.GroundChoke = nil

		local radius = hg_bot_downed_ground_range:GetFloat()
		local threat, dist = GroundThreat(bot, data, radius + 60)

		if not IsValid(threat) then
			-- Nobody on top of us: only struggling is left (someone is
			-- dragging the body, or we're rolling down something).
			return Struggle(bot, data, now)
		end

		-- Someone is right here: the rest of the bots should know.
		if now >= (data.GroundCallAt or 0) then
			data.GroundCallAt = now + 5

			if hg.bots.ShareContact then hg.bots.ShareContact(bot, threat, threat:GetPos()) end
		end

		-- A gun still beats hands, as long as they're not close enough to
		-- simply take it off us.
		if canShoot and dist > 70 then return false end

		if TryChoke(bot, data, threat, now) then return true end

		local wep = bot:GetActiveWeapon()
		local handy = IsValid(wep) and (wep.GetFists ~= nil or (hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep)))

		if handy and dist <= radius then
			return GroundMelee(bot, data, wep, threat, dist, now)
		end

		-- Nothing to fight with in reach: get away from them. The crawl
		-- module picks the direction and drives the hands.
		if hg.bots.StartCrawl and not data.CrawlDest then
			local away = bot:GetPos() - threat:GetPos()
			away.z = 0

			if away:LengthSqr() > 1 then
				away:Normalize()

				hg.bots.StartCrawl(bot, data, bot:GetPos() + away * 220, 6)
			end
		end

		return Struggle(bot, data, now)
	end
--//

	hg.bots.RegisterState("downed", {
		Enter = function(bot, data)
			-- Drop anything movement-related: the player entity is dragged
			-- along by the ragdoll while downed, so any leftover path would
			-- just be fighting sv_control for position.
			data.MoveTarget = nil
			data.Path = nil
			data.Goal = nil
			data.Running = false
			data.Crouching = false

			data.Attacking = false
			data.AttackingSecondary = false
			data.Reloading = false
			data.UseKey = false

			data.AimSpeed = hg_bot_downed_aimspeed:GetFloat()
			data.DownedSince = CurTime()
			data.DownedAimCorr = nil
			data.DownedCmdAng = nil
			data.DownedStallSince = nil
			data.DownedFreeArmsUntil = nil
			data.DownedFreeFails = 0
			data.DownedPreferGetUp = nil
			data.DownedAimBlocked = nil
		end,

		Leave = function(bot, data)
			-- Every key this state holds has to be released explicitly.
			-- Nothing else clears UseKey, and a bot that stood back up
			-- while still holding E would keep triggering +use on whatever
			-- it walked past.
			data.UseKey = false
			data.Attacking = false
			data.AttackingSecondary = false
			data.AimSpeed = nil
			data.DownedSince = nil
			data.DownedAimCorr = nil
			data.DownedCmdAng = nil
			data.DownedStallSince = nil
			data.DownedFreeArmsUntil = nil
			data.DownedFreeFails = nil
			data.DownedPreferGetUp = nil
			data.DownedAimBlocked = nil
			data.GroundChoke = nil
			data.GroundSwingAt = nil
			data.GroundSwingUntil = nil
			data.GroundGrabAt = nil
			data.CrawlGrab = nil
			data.CrawlPull = nil
		end,

		Think = function(bot, data)
			data.NextStateThink = CurTime() + hg_bot_downed_think_rate:GetFloat()

			local ragdoll = bot.FakeRagdoll

			if not IsValid(ragdoll) then
				-- Already up (or the ragdoll was removed outright) - hand
				-- back to idle, which re-checks for threats on its next
				-- tick via CheckThreatReaction anyway.
				data.UseKey = false
				data.Attacking = false
				data.AttackingSecondary = false

				hg.bots.SetState(bot, "idle")

				return
			end

			local now = CurTime()
			local mem = data.Memory
			local target = mem.Target
			local wep = bot:GetActiveWeapon()
			local org = bot.organism

			-- Unconscious: no input does anything useful, and a held
			-- trigger would fire the moment consciousness returns.
			if org and org.otrub then
				data.UseKey = false
				data.Attacking = false
				data.AttackingSecondary = false
				data.LookPos = nil

				return
			end

			-- Bleeding out with a grenade and somebody coming: the pin goes
			-- out down here (sv_bot_grenades.lua's last resort).
			if hg.bots.DownedMartyr and hg.bots.DownedMartyr(bot, data, now) then return end

			-- Patch yourself up down here: Z-City's meds work in the
			-- ragdoll, and bleeding out is what actually kills a downed
			-- bot (sv_bot_medic.lua).
			if hg.bots.TryHealDowned and hg.bots.TryHealDowned(bot, data, now) then return end


			-- Fighting back from the floor (chokes, swings, struggling,
			-- crawling away): decided before the gun logic, since at
			-- grappling range hands beat a rifle.
			local gunReady = hg.bots.GetWeaponKind and hg.bots.GetWeaponKind(bot, true) == "gun"

			-- Someone in reach is dealt with BEFORE crawling: hands can
			-- either drag the body or hit, never both at once.
			if hg.bots.DownedReact and hg.bots.DownedReact(bot, data, now, gunReady) then return end

			-- An enemy in the sights beats getting somewhere better: drop
			-- the crawl and shoot (a grenade next to us still wins).
			if data.CrawlDest and not IsValid(data.EvadeGrenade) and hg.bots.StopCrawl
				and hg.bots.DownedCanShoot(bot, data)
			then
				hg.bots.StopCrawl(data)
			end

			-- Dragging ourselves somewhere better on our elbows
			-- (sv_bot_crawl.lua): both hands are busy while it runs.
			if hg.bots.CrawlTick and hg.bots.CrawlTick(bot, data, now) then return end

			local fight = hg_bot_downed_fight:GetBool()
			local targetAlive = IsValid(target) and target:Alive()
			local canSee, info = false, nil

			if fight and targetAlive then
				canSee, info = hg.bots.CanSee(bot, target)
			end

			-- What to point at: the visible body point, else the last known
			-- position, else wherever fire is coming from.
			local aimPoint

			if canSee then
				local char = hg.bots.GetCharacter and hg.bots.GetCharacter(target) or target

				mem.TargetPos = char:GetPos()
				mem.TargetVel = char:GetVelocity()
				mem.LastSeen = now

				-- No synthetic jitter: ragdoll physics already wobble.
				aimPoint = hg.bots.GetAimPoint and hg.bots.GetAimPoint(bot, target) or target:EyePos()
			elseif mem.UnderFireFrom and now < (mem.UnderFireUntil or 0) then
				aimPoint = mem.UnderFireFrom + Vector(0, 0, 48)
			elseif mem.TargetPos then
				aimPoint = mem.TargetPos + Vector(0, 0, 40)
			end

			-- Only guns are braced and aimed; hands/melee holding E while
			-- ragdolled means grabbing, not aiming.
			local isGun = IsValid(wep) and wep:IsWeapon() and (wep.ishgweapon or (wep:Clip1() >= 0 and not (hg.bots.IsMeleeWeapon and hg.bots.IsMeleeWeapon(wep))))
			local wantsToFight = fight and targetAlive and aimPoint ~= nil and isGun

			-- Aiming is E ONLY: E alone stabilizes the torso and raises both
			-- arms with the gun (sv_control.lua), and with E held the
			-- weapon base points the gun along the eye angles (within 45
			-- degrees of where the head faces). RMB would only add the zoom
			-- and stretch the arms out - not wanted.
			data.AttackingSecondary = false

			-- Can this body aim at all right now?
			local canAim, why = true, nil

			if wantsToFight then
				canAim, why = GetAimCapability(bot, wep, ragdoll)
			end

			if not wantsToFight then
				data.UseKey = false
				data.Attacking = false
				data.LookPos = aimPoint
			elseif not canAim then
				-- Paralysed / too weak / no working gun arm: E does nothing
				-- useful and a trigger pull would shoot wherever the limp
				-- arm points. Don't; getting up (below) is the only way out.
				data.UseKey = false
				data.Attacking = false
				data.LookPos = aimPoint
				data.DownedPreferGetUp = true
				data.DownedAimBlocked = why

				hg.bots.ServiceWeapon(bot, data, wep, false) -- reload/rack still fine
			elseif data.DownedFreeArmsUntil and now < data.DownedFreeArmsUntil then
				-- Recovering from a pinned/stuck arm: E released so the
				-- arms go slack and can slide out from under the body.
				data.UseKey = false
				data.Attacking = false
				data.LookPos = aimPoint
			else
				data.UseKey = true
				data.DownedAimBlocked = nil

				local eye = bot:EyePos() -- same origin the movement bridge aims from
				local muzzlePos, muzzleAng = GetMuzzle(wep)
				local cmdAng, barrelErr, dist

				if muzzlePos then
					-- Aim THROUGH THE SIGHTS: the direction the barrel has to
					-- point is muzzle -> target (not eye -> target; the gun
					-- sits in the hands, a hand-length off the eyes).
					local toAim = aimPoint - muzzlePos
					local barrelWant = toAim:Angle()

					dist = math.max(toAim:Length(), 1)
					barrelErr = math.deg(math.acos(math.Clamp(muzzleAng:Forward():Dot(toAim / dist), -1, 1)))

					-- Proportional correction for what's left (sway, soft
					-- constraints, the head-cone clamp): recomputed each
					-- tick, never accumulated, low-pass filtered against
					-- physics jitter. Only once the eyes have caught up with
					-- the last command - before that the error is just lag.
					local k = hg_bot_downed_aim_gain:GetFloat()
					local lim = hg_bot_downed_max_offset:GetFloat()
					local corr = Angle(0, 0, 0)

					local settled = data.DownedCmdAng and math.abs(math.AngleDifference(bot:EyeAngles().y, data.DownedCmdAng.y)) < 5
						and math.abs(math.AngleDifference(bot:EyeAngles().p, data.DownedCmdAng.p)) < 5

					if settled then
						corr.p = ClampOffset(math.AngleDifference(barrelWant.p, muzzleAng.p) * k, lim)
						corr.y = ClampOffset(math.AngleDifference(barrelWant.y, muzzleAng.y) * k, lim)
					end

					local prev = data.DownedAimCorr or corr

					data.DownedAimCorr = LerpAngle(0.35, prev, corr)

					cmdAng = Angle(barrelWant.p + data.DownedAimCorr.p, barrelWant.y + data.DownedAimCorr.y, 0)

					-- Stuck-arm detection: eyes are where they should be but
					-- the barrel just isn't following (arm under the body,
					-- wedged against the floor or a wall).
					if settled and barrelErr > 20 then
						data.DownedStallSince = data.DownedStallSince or now
					elseif barrelErr < 10 then
						data.DownedStallSince = nil
					end

					if IsArmPinned(ragdoll) or (data.DownedStallSince and now - data.DownedStallSince > 1.2) then
						FreeArms(data, now)
					end
				else
					cmdAng = (aimPoint - eye):Angle()
					dist = eye:Distance(aimPoint)
				end

				data.DownedCmdAng = cmdAng
				data.LookPos = eye + cmdAng:Forward() * math.max(dist, 64)

				local tol = math.max(2.5, math.deg(math.atan(hg_bot_downed_aim_tol:GetFloat() / dist)))
				local onTarget = muzzlePos ~= nil and barrelErr <= tol and MuzzleLineClear(bot, target, muzzlePos, aimPoint)

				-- Same reload/rack/burst logic standing combat uses. Fires
				-- only with the barrel actually on a visible target; reloads
				-- and racks regardless.
				hg.bots.ServiceWeapon(bot, data, wep, canSee and onTarget)
			end

			-- Standing up: hg.FakeUp already encodes every real rule for
			-- whether it's currently allowed (ragdoll settled, not stunned,
			-- organism state, etc - see the "Should Fake Up" hook in
			-- sv_tier_0.lua) and returns false when it isn't, so this just
			-- keeps asking rather than reimplementing any of it.
			--
			-- While a target is visible though, staying down and returning
			-- fire beats standing up into someone's line - getting up is a
			-- slow, helpless animation. The forced fallback still overrides
			-- this so a bot can't end up pinned down forever by a target it
			-- can see but never kills.
			local downedFor = CurTime() - (data.DownedSince or CurTime())
			local forced = downedFor > hg_bot_downed_force_after:GetFloat()

			-- Deliberately prone (sv_bot_combat.lua's TryProne): stay on the
			-- floor and keep shooting until the time is up, the target is
			-- gone, or they get close enough that lying there is a death
			-- sentence.
			if data.Prone then
				local tooClose = targetAlive and bot:GetPos():DistToSqr(target:GetPos()) < 300 * 300

				if now < (data.ProneUntil or 0) and targetAlive and not tooClose then return end

				data.Prone = nil
				data.ProneUntil = nil
			end

			-- Crawling somewhere: finish the trip before standing up.
			if data.CrawlDest then return end

			-- Dove away from a grenade: stay flat until it has gone off.
			if data.StayDownUntil and CurTime() < data.StayDownUntil then
				return
			end

			-- Staying down to shoot only makes sense if the body can
			-- actually aim; a paralysed/pinned bot tries to get up instead.
			if canSee and hg_bot_downed_getup_when_safe:GetBool() and not forced and not data.DownedPreferGetUp then
				return
			end

			if hg.FakeUp(bot, forced) then
				data.UseKey = false
				data.Attacking = false
				data.AttackingSecondary = false

				hg.bots.SetState(bot, "idle")
			end
		end,
	})

	-- Fired by hg.Fake (lua/homigrad/fake/sv_tier_0.lua) the moment any
	-- player enters FakeRagdoll, whatever caused it.
	hook.Add("Fake", "HG_Bots_EnterDowned", function(ply, ragdoll)
		if not IsValid(ply) or not ply.IsHomigradBot then return end
		if not ply.Bot then return end

		-- The spawn refresh pass (sv_bot_core.lua) puts the bot down and
		-- picks it straight back up - that isn't being knocked down.
		if ply.Bot.Refreshing then return end

		hg.bots.SetState(ply, "downed")
	end)

	-- Whatever state a bot switches to next shouldn't inherit a held E from
	-- being downed. Cheap belt-and-braces against any path that leaves
	-- "downed" without going through its Leave (e.g. the error-recovery
	-- fallback to idle in sv_bot_core.lua's Think dispatcher).
	hook.Add("Fake Up", "HG_Bots_LeaveDowned", function(ply, ragdoll)
		if not IsValid(ply) or not ply.IsHomigradBot then return end

		local data = ply.Bot
		if not data then return end

		data.UseKey = false

		if data.State == "downed" then
			hg.bots.SetState(ply, "idle")
		end
	end)
--//
